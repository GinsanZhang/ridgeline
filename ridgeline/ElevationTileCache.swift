import CoreLocation
import Foundation
import ImageIO
import zlib

struct ElevationCacheFile: Equatable, Sendable {
    let name: String
    let byteCount: Int
    let lastAccess: Date
}

struct ElevationTileCachePolicy: Sendable {
    let maximumByteCount: Int
    let maximumAge: TimeInterval

    static let standard = ElevationTileCachePolicy(
        maximumByteCount: 500 * 1_024 * 1_024,
        maximumAge: 30 * 24 * 60 * 60
    )

    func filesToRemove(from files: [ElevationCacheFile], now: Date) -> [String] {
        let expired = files.filter { now.timeIntervalSince($0.lastAccess) > maximumAge }
        var removals = Set(expired.map(\.name))
        var retainedBytes = files
            .filter { !removals.contains($0.name) }
            .reduce(0) { $0 + $1.byteCount }

        for file in files.sorted(by: { $0.lastAccess < $1.lastAccess })
            where retainedBytes > maximumByteCount && !removals.contains(file.name) {
            removals.insert(file.name)
            retainedBytes -= file.byteCount
        }
        return files.map(\.name).filter(removals.contains)
    }
}

struct ElevationDownloadProgress: Equatable, Sendable {
    let completed: Int
    let total: Int
    let failed: Int

    var message: String {
        let suffix = failed > 0 ? " · \(failed)块失败" : ""
        return "30米精细高程 \(completed)/\(total)\(suffix)"
    }
}

struct ConcurrentTileScheduler: Sendable {
    let maximumConcurrentTasks: Int

    init(maximumConcurrentTasks: Int) {
        self.maximumConcurrentTasks = max(1, maximumConcurrentTasks)
    }

    func run<Item: Sendable, Output: Sendable>(
        items: [Item],
        operation: @escaping @Sendable (Item) async -> Output,
        progress: (Int, Int, Output) async -> Void
    ) async {
        guard !items.isEmpty else { return }
        await withTaskGroup(of: Output.self) { group in
            var iterator = items.makeIterator()
            for _ in 0..<min(maximumConcurrentTasks, items.count) {
                if let item = iterator.next() {
                    group.addTask { await operation(item) }
                }
            }
            var completed = 0
            while let output = await group.next() {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                completed += 1
                await progress(completed, items.count, output)
                if !Task.isCancelled, let item = iterator.next() {
                    group.addTask { await operation(item) }
                }
            }
        }
    }
}

enum RouteElevationTilePlanner {
    static func tileNames(for coordinates: [CLLocationCoordinate2D]) -> [String] {
        guard let first = coordinates.first else { return [] }
        var result: [String] = []
        var seen: Set<String> = []

        func append(_ coordinate: CLLocationCoordinate2D) {
            let name = HGTElevationStore.tileName(for: coordinate)
            if seen.insert(name).inserted { result.append(name) }
        }

        append(first)
        for index in coordinates.indices.dropFirst() {
            let start = coordinates[index - 1]
            let end = coordinates[index]
            let distance = CLLocation(latitude: start.latitude, longitude: start.longitude)
                .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
            let steps = max(Int(ceil(distance / 20_000)), 1)
            for step in 1...steps {
                let fraction = Double(step) / Double(steps)
                append(CLLocationCoordinate2D(
                    latitude: start.latitude + (end.latitude - start.latitude) * fraction,
                    longitude: start.longitude + (end.longitude - start.longitude) * fraction
                ))
            }
        }
        return result
    }
}

actor ElevationTileCache {
    static let directoryName = "ElevationTiles"

    private let directory: URL
    private let policy: ElevationTileCachePolicy
    private let session: URLSession

    init(
        directory: URL = ElevationTileCache.defaultDirectory,
        policy: ElevationTileCachePolicy = .standard,
        session: URLSession = ElevationTileCache.downloadSession()
    ) {
        self.directory = directory
        self.policy = policy
        self.session = session
    }

    func prepareTiles(
        named tileNames: [String],
        excluding immutableTiles: Set<String>,
        progress: @escaping @Sendable (ElevationDownloadProgress) async -> Void = { _ in }
    ) async throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let requiredTiles = tileNames.filter { !immutableTiles.contains($0) }
        for tileName in requiredTiles {
            let destination = directory.appendingPathComponent("\(tileName).hgt")
            if FileManager.default.fileExists(atPath: destination.path) {
                if isValidCachedTile(destination) {
                    try touch(destination)
                } else {
                    try FileManager.default.removeItem(at: destination)
                }
            }
        }
        try cleanup()

        let missingTiles = requiredTiles.filter { tileName in
            let destination = directory.appendingPathComponent("\(tileName).hgt")
            return !FileManager.default.fileExists(atPath: destination.path)
        }
        let requiredByteCount = requiredTiles.count * HGTFileValidator.expectedByteCount
        guard requiredByteCount <= policy.maximumByteCount else {
            throw ElevationTileError.routeExceedsCacheCapacity
        }
        try reserveCapacity(
            incomingByteCount: missingTiles.count * HGTFileValidator.expectedByteCount,
            protecting: Set(requiredTiles.map { "\($0).hgt" })
        )
        var failed = 0
        let scheduler = ConcurrentTileScheduler(maximumConcurrentTasks: 3)
        await scheduler.run(items: missingTiles) { [session, directory] tileName in
            await Self.downloadWithRetry(
                tileName: tileName,
                to: directory.appendingPathComponent("\(tileName).hgt"),
                session: session,
                maximumAttempts: 2
            )
        } progress: { completed, total, succeeded in
            if !succeeded { failed += 1 }
            await progress(ElevationDownloadProgress(
                completed: completed,
                total: total,
                failed: failed
            ))
        }
        try cleanup()
    }

    func prepareOverviewTiles(_ tileIDs: [TerrariumTileID]) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for tile in tileIDs {
            let destination = directory.appendingPathComponent(tile.fileName)
            if FileManager.default.fileExists(atPath: destination.path) {
                if isValidImage(destination) {
                    try touch(destination)
                } else {
                    try FileManager.default.removeItem(at: destination)
                }
            }
        }
        try cleanup()
        for tile in tileIDs {
            let destination = directory.appendingPathComponent(tile.fileName)
            guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
            do {
                let url = URL(string:
                    "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/\(tile.zoom)/\(tile.x)/\(tile.y).png"
                )!
                let (data, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse,
                      http.statusCode == 200,
                      CGImageSourceCreateWithData(data as CFData, nil) != nil else { continue }
                try data.write(to: destination, options: .atomic)
                try touch(destination)
                try cleanup()
            } catch {
                continue
            }
        }
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    nonisolated static func downloadSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }

    private nonisolated static func downloadWithRetry(
        tileName: String,
        to destination: URL,
        session: URLSession,
        maximumAttempts: Int
    ) async -> Bool {
        for attempt in 1...maximumAttempts {
            guard !Task.isCancelled else { return false }
            do {
                try await download(tileName: tileName, to: destination, session: session)
                return true
            } catch is CancellationError {
                return false
            } catch let error as URLError where error.code == .cancelled {
                return false
            } catch {
                guard !Task.isCancelled,
                      attempt < maximumAttempts,
                      isRetryable(error) else { return false }
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return false
                }
            }
        }
        return false
    }

    private nonisolated static func isRetryable(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return [
                .timedOut, .cannotFindHost, .cannotConnectToHost,
                .networkConnectionLost, .dnsLookupFailed, .notConnectedToInternet
            ].contains(urlError.code)
        }
        if case ElevationTileError.serverUnavailable = error { return true }
        return false
    }

    private nonisolated static func download(
        tileName: String,
        to destination: URL,
        session: URLSession
    ) async throws {
        let latitudeFolder = String(tileName.prefix(3))
        let url = URL(string:
            "https://s3.amazonaws.com/elevation-tiles-prod/skadi/\(latitudeFolder)/\(tileName).hgt.gz"
        )!
        let (compressed, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw ElevationTileError.downloadFailed
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 429 || (500...599).contains(http.statusCode) {
                throw ElevationTileError.serverUnavailable
            }
            throw ElevationTileError.downloadFailed
        }
        let data = try Gzip.decompress(compressed, expectedSize: HGTFileValidator.expectedByteCount)
        guard HGTFileValidator.isValid(
            fileName: destination.lastPathComponent,
            byteCount: data.count
        ) else {
            throw ElevationTileError.invalidTile
        }
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: destination.path
        )
    }

    private func cleanup(now: Date = Date()) throws {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentAccessDateKey, .contentModificationDateKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ).filter { ["hgt", "png"].contains($0.pathExtension.lowercased()) }
        let files = urls.compactMap { url -> ElevationCacheFile? in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            return ElevationCacheFile(
                name: url.lastPathComponent,
                byteCount: values.fileSize ?? 0,
                lastAccess: values.contentModificationDate ?? values.contentAccessDate ?? .distantPast
            )
        }
        let removals = Set(policy.filesToRemove(from: files, now: now))
        for url in urls where removals.contains(url.lastPathComponent) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func reserveCapacity(
        incomingByteCount: Int,
        protecting protectedNames: Set<String>
    ) throws {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentAccessDateKey, .contentModificationDateKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ).filter { ["hgt", "png"].contains($0.pathExtension.lowercased()) }
        let entries = urls.compactMap { url -> (URL, Int, Date)? in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            return (
                url,
                values.fileSize ?? 0,
                values.contentModificationDate ?? values.contentAccessDate ?? .distantPast
            )
        }
        var currentBytes = entries.reduce(0) { $0 + $1.1 }
        for entry in entries
            .filter({ !protectedNames.contains($0.0.lastPathComponent) })
            .sorted(by: { $0.2 < $1.2 })
            where currentBytes + incomingByteCount > policy.maximumByteCount {
            try FileManager.default.removeItem(at: entry.0)
            currentBytes -= entry.1
        }
        guard currentBytes + incomingByteCount <= policy.maximumByteCount else {
            throw ElevationTileError.routeExceedsCacheCapacity
        }
    }

    private func touch(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: url.path
        )
    }

    private func isValidCachedTile(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let byteCount = attributes[.size] as? Int else { return false }
        return HGTFileValidator.isValid(
            fileName: url.lastPathComponent,
            byteCount: byteCount
        )
    }

    private func isValidImage(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetCount(source) > 0
    }
}

enum ElevationTileError: Error {
    case downloadFailed
    case invalidTile
    case decompressionFailed
    case serverUnavailable
    case routeExceedsCacheCapacity
}

private enum Gzip {
    static func decompress(_ data: Data, expectedSize: Int) throws -> Data {
        var stream = z_stream()
        let initialized = inflateInit2_(
            &stream,
            15 + 32,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initialized == Z_OK else { throw ElevationTileError.decompressionFailed }
        defer { inflateEnd(&stream) }

        var output = Data(count: expectedSize)
        let status = data.withUnsafeBytes { inputBuffer in
            output.withUnsafeMutableBytes { outputBuffer in
                stream.next_in = UnsafeMutablePointer<Bytef>(
                    mutating: inputBuffer.bindMemory(to: Bytef.self).baseAddress
                )
                stream.avail_in = uInt(inputBuffer.count)
                stream.next_out = outputBuffer.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(outputBuffer.count)
                return inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END else { throw ElevationTileError.decompressionFailed }
        output.count = Int(stream.total_out)
        return output
    }
}
