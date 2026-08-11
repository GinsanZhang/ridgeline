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
        session: URLSession = .shared
    ) {
        self.directory = directory
        self.policy = policy
        self.session = session
    }

    func prepareTiles(named tileNames: [String], excluding immutableTiles: Set<String>) async throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        for tileName in tileNames where !immutableTiles.contains(tileName) {
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

        for tileName in tileNames where !immutableTiles.contains(tileName) {
            let destination = directory.appendingPathComponent("\(tileName).hgt")
            if FileManager.default.fileExists(atPath: destination.path) {
                continue
            }
            try await download(tileName: tileName, to: destination)
            try cleanup()
        }
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

    private func download(tileName: String, to destination: URL) async throws {
        let latitudeFolder = String(tileName.prefix(3))
        let url = URL(string:
            "https://s3.amazonaws.com/elevation-tiles-prod/skadi/\(latitudeFolder)/\(tileName).hgt.gz"
        )!
        let (compressed, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
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
        try touch(destination)
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

private enum ElevationTileError: Error {
    case downloadFailed
    case invalidTile
    case decompressionFailed
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
