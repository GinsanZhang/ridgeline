import CoreLocation
import Foundation

enum ElevationDataSource: Codable, Equatable, Sendable {
    case offlineDEM
    case overviewDEM
    case partialDEM
    case unavailable

    var title: String {
        switch self {
        case .offlineDEM: "本地 HGT 高程"
        case .overviewDEM: "概览高程 · 约 300m"
        case .partialDEM: "HGT 覆盖不完整"
        case .unavailable: "高程数据不可用"
        }
    }

    var hasUsableElevation: Bool {
        self == .offlineDEM || self == .overviewDEM
    }

    var isFineResolution: Bool { self == .offlineDEM }
}

enum ElevationUpgradePolicy {
    static func shouldReplaceOverview(with source: ElevationDataSource) -> Bool {
        source == .offlineDEM
    }
}

struct ElevationProfileResult: Sendable {
    let points: [RoutePoint]
    let source: ElevationDataSource

    var route: RidgeRoute? {
        points.isEmpty ? nil : RidgeRoute(points: points)
    }

    var hasCompleteElevation: Bool {
        source.hasUsableElevation
    }
}

struct ElevationProfileBuilder: Sendable {
    let sampleSpacing: CLLocationDistance

    init(sampleSpacing: CLLocationDistance = 75) {
        self.sampleSpacing = max(sampleSpacing, 1)
    }

    func build(
        coordinates: [CLLocationCoordinate2D],
        elevation: (CLLocationCoordinate2D) -> Int16?
    ) -> ElevationProfileResult {
        guard !coordinates.isEmpty else {
            return ElevationProfileResult(points: [], source: .unavailable)
        }

        let sampledCoordinates = equidistantSamples(from: coordinates)
        let elevations = sampledCoordinates.map(elevation)
        let availableCount = elevations.compactMap { $0 }.count
        let source: ElevationDataSource = if availableCount == sampledCoordinates.count {
            .offlineDEM
        } else if availableCount > 0 {
            .partialDEM
        } else {
            .unavailable
        }

        // Zero is only a storage placeholder when coverage is incomplete. Callers must
        // suppress elevation-derived UI unless source is `.offlineDEM`.
        let points = zip(sampledCoordinates, elevations).map { coordinate, elevation in
            RoutePoint(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                elevation: Double(elevation ?? 0)
            )
        }
        return ElevationProfileResult(points: points, source: source)
    }

    private func equidistantSamples(
        from coordinates: [CLLocationCoordinate2D]
    ) -> [CLLocationCoordinate2D] {
        guard coordinates.count > 1 else { return coordinates }

        let locations = coordinates.map {
            CLLocation(latitude: $0.latitude, longitude: $0.longitude)
        }
        let segmentDistances = locations.indices.dropLast().map {
            locations[$0].distance(from: locations[$0 + 1])
        }
        let totalDistance = segmentDistances.reduce(0, +)
        guard totalDistance > 0 else { return [coordinates[0]] }

        let intervalCount = max(Int(ceil(totalDistance / sampleSpacing)), 1)
        var result: [CLLocationCoordinate2D] = []
        result.reserveCapacity(intervalCount + 1)
        var segmentIndex = 0
        var traversed: CLLocationDistance = 0

        for sampleIndex in 0...intervalCount {
            let target = totalDistance * Double(sampleIndex) / Double(intervalCount)
            while segmentIndex < segmentDistances.count - 1,
                  target > traversed + segmentDistances[segmentIndex] {
                traversed += segmentDistances[segmentIndex]
                segmentIndex += 1
            }

            let distance = segmentDistances[segmentIndex]
            let fraction = distance > 0 ? (target - traversed) / distance : 0
            let start = coordinates[segmentIndex]
            let end = coordinates[segmentIndex + 1]
            result.append(
                CLLocationCoordinate2D(
                    latitude: start.latitude + (end.latitude - start.latitude) * fraction,
                    longitude: start.longitude + (end.longitude - start.longitude) * fraction
                )
            )
        }
        return result
    }
}

enum HGTFileValidator {
    static let expectedByteCount = 3_601 * 3_601 * MemoryLayout<Int16>.size

    static func isValid(fileName: String, byteCount: Int) -> Bool {
        guard byteCount == expectedByteCount else { return false }
        return fileName.range(
            of: #"^[NS]\d{2}[EW]\d{3}\.hgt$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }
}

struct HGTElevationStore: Sendable {
    private let readersByTileName: [String: HGTReader]
    let bundledTileNames: Set<String>

    init(fileURLs: [URL] = Self.discoverFiles()) {
        readersByTileName = fileURLs.reduce(into: [:]) { result, url in
            let key = url.deletingPathExtension().lastPathComponent.uppercased()
            // Discovery orders Bundle before Documents, so an imported tile replaces
            // the bundled version with the same SRTM tile name.
            result[key] = HGTReader(hgtFileURL: url)
        }
        let bundleRoot = Bundle.main.resourceURL?.standardizedFileURL.path
        bundledTileNames = Set(fileURLs.compactMap { url in
            guard let bundleRoot,
                  url.standardizedFileURL.path.hasPrefix(bundleRoot + "/") else { return nil }
            return url.deletingPathExtension().lastPathComponent.uppercased()
        })
    }

    func elevation(at coordinate: CLLocationCoordinate2D) -> Int16? {
        readersByTileName[Self.tileName(for: coordinate)]?.elevation(
            lat: coordinate.latitude,
            lon: coordinate.longitude
        )
    }

    var availableTileNames: Set<String> {
        Set(readersByTileName.keys)
    }

    static func discoverFiles() -> [URL] {
        let fileManager = FileManager.default
        var directories = [Bundle.main.resourceURL].compactMap { $0 }
        directories.append(ElevationTileCache.defaultDirectory)

        return directories.flatMap { directory -> [URL] in
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }

            var files: [URL] = []
            while let url = enumerator.nextObject() as? URL {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
                if url.pathExtension.lowercased() == "hgt",
                   values?.isRegularFile == true {
                    files.append(url)
                }
            }
            return files
        }
    }

    static func tileName(for coordinate: CLLocationCoordinate2D) -> String {
        let latitude = Int(floor(coordinate.latitude))
        let longitude = Int(floor(coordinate.longitude))
        return String(
            format: "%@%02d%@%03d",
            latitude >= 0 ? "N" : "S",
            abs(latitude),
            longitude >= 0 ? "E" : "W",
            abs(longitude)
        )
    }
}
