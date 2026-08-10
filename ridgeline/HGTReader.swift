import Foundation

/// Reads elevation samples from one SRTM `.hgt` tile.
struct HGTReader {
    private let dimension: Int
    private let hgtFileURL: URL
    private let tileOrigin: (latitude: Int, longitude: Int)?

    init(dimension: Int = 3601, hgtFileURL: URL) {
        self.dimension = dimension
        self.hgtFileURL = hgtFileURL
        self.tileOrigin = Self.parseTileOrigin(from: hgtFileURL.deletingPathExtension().lastPathComponent)
    }

    func elevation(lat: Double, lon: Double) -> Int16? {
        guard dimension > 1,
              lat.isFinite,
              lon.isFinite,
              let tileOrigin,
              lat >= Double(tileOrigin.latitude),
              lat < Double(tileOrigin.latitude + 1),
              lon >= Double(tileOrigin.longitude),
              lon < Double(tileOrigin.longitude + 1)
        else {
            return nil
        }

        let latitudeFraction = lat - Double(tileOrigin.latitude)
        let longitudeFraction = lon - Double(tileOrigin.longitude)
        let row = Int((1 - latitudeFraction) * Double(dimension - 1))
        let column = Int(longitudeFraction * Double(dimension - 1))
        let byteOffset = (row * dimension + column) * MemoryLayout<Int16>.size

        guard let fileHandle = try? FileHandle(forReadingFrom: hgtFileURL) else {
            return nil
        }
        defer { try? fileHandle.close() }

        do {
            try fileHandle.seek(toOffset: UInt64(byteOffset))
            guard let data = try fileHandle.read(upToCount: 2), data.count == 2 else {
                return nil
            }

            let unsignedValue = (UInt16(data[data.startIndex]) << 8)
                | UInt16(data[data.index(after: data.startIndex)])
            let value = Int16(bitPattern: unsignedValue)
            return value == Int16.min ? nil : value
        } catch {
            return nil
        }
    }

    private static func parseTileOrigin(from fileName: String) -> (latitude: Int, longitude: Int)? {
        let pattern = #"^([NS])(\d{2})([EW])(\d{3})$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: fileName.uppercased(),
                  range: NSRange(fileName.startIndex..., in: fileName)
              ),
              match.numberOfRanges == 5,
              let latitudeHemisphereRange = Range(match.range(at: 1), in: fileName),
              let latitudeRange = Range(match.range(at: 2), in: fileName),
              let longitudeHemisphereRange = Range(match.range(at: 3), in: fileName),
              let longitudeRange = Range(match.range(at: 4), in: fileName),
              let latitudeMagnitude = Int(fileName[latitudeRange]),
              let longitudeMagnitude = Int(fileName[longitudeRange])
        else {
            return nil
        }

        let latitude = fileName[latitudeHemisphereRange].uppercased() == "S"
            ? -latitudeMagnitude
            : latitudeMagnitude
        let longitude = fileName[longitudeHemisphereRange].uppercased() == "W"
            ? -longitudeMagnitude
            : longitudeMagnitude
        return (latitude, longitude)
    }
}
