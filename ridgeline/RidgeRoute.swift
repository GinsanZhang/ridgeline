import CoreLocation
import SwiftUI

enum ElevationBand: String, CaseIterable, Equatable {
    case forest
    case meadow
    case rock
    case snow

    static func band(for elevation: Double) -> ElevationBand {
        switch elevation {
        case ..<2_200: .forest
        case ..<2_600: .meadow
        case ..<3_000: .rock
        default: .snow
        }
    }

    var title: String {
        switch self {
        case .forest: "针叶林带"
        case .meadow: "高山草甸"
        case .rock: "裸岩地带"
        case .snow: "高山雪线"
        }
    }

    var color: Color {
        switch self {
        case .forest: Color(red: 0.18, green: 0.42, blue: 0.31)
        case .meadow: Color(red: 0.54, green: 0.66, blue: 0.36)
        case .rock: Color(red: 0.78, green: 0.58, blue: 0.33)
        case .snow: Color(red: 0.55, green: 0.72, blue: 0.78)
        }
    }

    var lowerBoundLabel: String {
        switch self {
        case .forest: "2,000m"
        case .meadow: "2,200m"
        case .rock: "2,600m"
        case .snow: "3,000m+"
        }
    }
}

struct RoutePoint: Codable, Equatable, Identifiable, Sendable {
    let latitude: Double
    let longitude: Double
    let elevation: Double

    var id: String {
        "\(latitude),\(longitude),\(elevation)"
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    func distance(to other: RoutePoint) -> CLLocationDistance {
        CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: CLLocation(latitude: other.latitude, longitude: other.longitude))
    }
}

struct RouteMapLine: Identifiable {
    let id: Int
    let coordinates: [CLLocationCoordinate2D]
    let elevationBand: ElevationBand?
}

enum RouteMapLineBuilder {
    static func lines(
        for points: [RoutePoint],
        usesElevationBands: Bool
    ) -> [RouteMapLine] {
        guard !points.isEmpty else { return [] }
        guard usesElevationBands, points.count > 1 else {
            return [RouteMapLine(
                id: 0,
                coordinates: points.map(\.coordinate),
                elevationBand: nil
            )]
        }

        var lines: [RouteMapLine] = []
        var coordinates = [points[0].coordinate]
        var currentBand = ElevationBand.band(for: points[0].elevation)
        for point in points.dropFirst() {
            let band = ElevationBand.band(for: point.elevation)
            coordinates.append(point.coordinate)
            if band != currentBand {
                lines.append(RouteMapLine(
                    id: lines.count,
                    coordinates: coordinates,
                    elevationBand: currentBand
                ))
                coordinates = [point.coordinate]
                currentBand = band
            }
        }
        if coordinates.count == 1, let last = lines.last?.coordinates.last {
            coordinates.insert(last, at: 0)
        }
        lines.append(RouteMapLine(
            id: lines.count,
            coordinates: coordinates,
            elevationBand: currentBand
        ))
        return lines
    }
}

struct RidgeRoute: Codable, Sendable {
    let points: [RoutePoint]
    private let segmentDistances: [CLLocationDistance]
    private let cumulativeDistances: [CLLocationDistance]
    private let ascentFromPoint: [Double]

    init(points: [RoutePoint]) {
        precondition(!points.isEmpty, "A ridge route requires at least one point.")
        self.points = points
        segmentDistances = points.indices.dropLast().map {
            points[$0].distance(to: points[$0 + 1])
        }
        var cumulative: [CLLocationDistance] = [0]
        cumulative.reserveCapacity(points.count)
        for distance in segmentDistances {
            cumulative.append(cumulative.last! + distance)
        }
        cumulativeDistances = cumulative

        var ascents = Array(repeating: 0.0, count: points.count)
        if points.count > 1 {
            for index in stride(from: points.count - 2, through: 0, by: -1) {
                ascents[index] = ascents[index + 1]
                    + max(0, points[index + 1].elevation - points[index].elevation)
            }
        }
        ascentFromPoint = ascents
    }

    var totalDistance: CLLocationDistance {
        cumulativeDistances.last ?? 0
    }

    func sample(at progress: Double) -> RoutePoint {
        guard points.count > 1 else { return points[0] }

        let position = interpolationPosition(at: progress)
        let lower = points[position.segmentIndex]
        let upper = points[position.segmentIndex + 1]

        return RoutePoint(
            latitude: lower.latitude + (upper.latitude - lower.latitude) * position.fraction,
            longitude: lower.longitude + (upper.longitude - lower.longitude) * position.fraction,
            elevation: lower.elevation + (upper.elevation - lower.elevation) * position.fraction
        )
    }

    func remainingDistance(at progress: Double) -> CLLocationDistance {
        totalDistance * (1 - clamped(progress))
    }

    func remainingAscent(at progress: Double) -> Double {
        guard points.count > 1, progress < 1 else { return 0 }

        let position = interpolationPosition(at: progress)
        let current = sample(at: progress)
        var ascent = max(0, points[position.segmentIndex + 1].elevation - current.elevation)

        ascent += ascentFromPoint[position.segmentIndex + 1]
        return ascent
    }

    func slope(at progress: Double) -> Double {
        guard points.count > 1 else { return 0 }
        let position = interpolationPosition(at: progress)
        let distance = segmentDistances[position.segmentIndex]
        guard distance > 0 else { return 0 }
        let elevationGain = points[position.segmentIndex + 1].elevation
            - points[position.segmentIndex].elevation
        return elevationGain / distance * 100
    }

    private func interpolationPosition(at progress: Double) -> (segmentIndex: Int, fraction: Double) {
        let targetDistance = totalDistance * clamped(progress)
        var lower = 0
        var upper = max(0, cumulativeDistances.count - 2)
        while lower < upper {
            let middle = (lower + upper) / 2
            if cumulativeDistances[middle + 1] < targetDistance {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        let distance = segmentDistances[lower]
        let fraction = distance > 0
            ? (targetDistance - cumulativeDistances[lower]) / distance
            : 0
        return (lower, min(max(fraction, 0), 1))
    }

    private func clamped(_ progress: Double) -> Double {
        min(max(progress, 0), 1)
    }

    private enum CodingKeys: String, CodingKey {
        case points
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(points: try container.decode([RoutePoint].self, forKey: .points))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(points, forKey: .points)
    }

    static let previewSiguniangshan = RidgeRoute(points: [
        RoutePoint(latitude: 31.092, longitude: 102.884, elevation: 2_030),
        RoutePoint(latitude: 31.102, longitude: 102.891, elevation: 2_148),
        RoutePoint(latitude: 31.112, longitude: 102.899, elevation: 2_290),
        RoutePoint(latitude: 31.124, longitude: 102.906, elevation: 2_480),
        RoutePoint(latitude: 31.137, longitude: 102.913, elevation: 2_650),
        RoutePoint(latitude: 31.151, longitude: 102.924, elevation: 2_810),
        RoutePoint(latitude: 31.166, longitude: 102.935, elevation: 3_040),
        RoutePoint(latitude: 31.181, longitude: 102.947, elevation: 3_251)
    ])
}
