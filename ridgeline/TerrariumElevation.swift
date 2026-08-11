import CoreGraphics
import CoreLocation
import Foundation
import ImageIO

enum TerrariumElevation {
    static func decode(red: UInt8, green: UInt8, blue: UInt8) -> Double {
        Double(red) * 256 + Double(green) + Double(blue) / 256 - 32_768
    }
}

struct TerrariumTileID: Hashable, Sendable {
    let zoom: Int
    let x: Int
    let y: Int

    init(zoom: Int, x: Int, y: Int) {
        self.zoom = zoom
        self.x = x
        self.y = y
    }

    init(coordinate: CLLocationCoordinate2D, zoom: Int) {
        let scale = pow(2.0, Double(zoom))
        let latitude = min(max(coordinate.latitude, -85.05112878), 85.05112878)
        let latitudeRadians = latitude * .pi / 180
        x = Int(floor((coordinate.longitude + 180) / 360 * scale))
        y = Int(floor(
            (1 - log(tan(latitudeRadians) + 1 / cos(latitudeRadians)) / .pi) / 2 * scale
        ))
        self.zoom = zoom
    }

    var fileName: String { "terrarium-\(zoom)-\(x)-\(y).png" }
}

enum RouteOverviewTilePlanner {
    static let zoom = 9

    static func tileIDs(for coordinates: [CLLocationCoordinate2D]) -> [TerrariumTileID] {
        guard let first = coordinates.first else { return [] }
        var result: [TerrariumTileID] = []
        var seen: Set<TerrariumTileID> = []
        func append(_ coordinate: CLLocationCoordinate2D) {
            let tile = TerrariumTileID(coordinate: coordinate, zoom: zoom)
            if seen.insert(tile).inserted { result.append(tile) }
        }
        append(first)
        for index in coordinates.indices.dropFirst() {
            let start = coordinates[index - 1]
            let end = coordinates[index]
            let distance = CLLocation(latitude: start.latitude, longitude: start.longitude)
                .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
            let steps = max(Int(ceil(distance / 10_000)), 1)
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

struct TerrariumElevationStore: Sendable {
    private let readers: [TerrariumTileID: TerrariumTileReader]

    init(
        tileIDs: [TerrariumTileID],
        directory: URL = ElevationTileCache.defaultDirectory
    ) {
        readers = tileIDs.reduce(into: [:]) { result, tile in
            let url = directory.appendingPathComponent(tile.fileName)
            guard let reader = TerrariumTileReader(url: url) else { return }
            result[reader.id] = reader
        }
    }

    func elevation(at coordinate: CLLocationCoordinate2D) -> Int16? {
        readers[TerrariumTileID(coordinate: coordinate, zoom: RouteOverviewTilePlanner.zoom)]?
            .elevation(at: coordinate)
    }
}

private struct TerrariumTileReader: Sendable {
    let id: TerrariumTileID
    let width: Int
    let height: Int
    let rgba: [UInt8]

    init?(url: URL) {
        let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-")
        guard parts.count == 4,
              parts[0] == "terrarium",
              let zoom = Int(parts[1]), let x = Int(parts[2]), let y = Int(parts[3]),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        id = TerrariumTileID(zoom: zoom, x: x, y: y)
        width = image.width
        height = image.height
        var pixels = Array(repeating: UInt8(0), count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        rgba = pixels
    }

    func elevation(at coordinate: CLLocationCoordinate2D) -> Int16? {
        let scale = pow(2.0, Double(id.zoom))
        let latitude = min(max(coordinate.latitude, -85.05112878), 85.05112878)
        let radians = latitude * .pi / 180
        let globalX = (coordinate.longitude + 180) / 360 * scale
        let globalY = (1 - log(tan(radians) + 1 / cos(radians)) / .pi) / 2 * scale
        let pixelX = min(max(Int((globalX - Double(id.x)) * Double(width)), 0), width - 1)
        // CGContext output is bottom-up relative to XYZ tile rows.
        let pixelY = height - 1 - min(max(Int((globalY - Double(id.y)) * Double(height)), 0), height - 1)
        let offset = (pixelY * width + pixelX) * 4
        let value = TerrariumElevation.decode(
            red: rgba[offset], green: rgba[offset + 1], blue: rgba[offset + 2]
        )
        guard value.isFinite, value >= Double(Int16.min + 1), value <= Double(Int16.max) else {
            return nil
        }
        return Int16(value.rounded())
    }
}
