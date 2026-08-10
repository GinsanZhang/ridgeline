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

struct RoutePoint: Equatable, Identifiable {
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

struct RidgeRoute {
    let points: [RoutePoint]

    init(points: [RoutePoint]) {
        precondition(!points.isEmpty, "A ridge route requires at least one point.")
        self.points = points
    }

    var totalDistance: CLLocationDistance {
        segmentDistances.reduce(0, +)
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

        if position.segmentIndex + 1 < points.count - 1 {
            for index in (position.segmentIndex + 1)..<(points.count - 1) {
                ascent += max(0, points[index + 1].elevation - points[index].elevation)
            }
        }
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

    private var segmentDistances: [CLLocationDistance] {
        points.indices.dropLast().map { points[$0].distance(to: points[$0 + 1]) }
    }

    private func interpolationPosition(at progress: Double) -> (segmentIndex: Int, fraction: Double) {
        let distances = segmentDistances
        let targetDistance = totalDistance * clamped(progress)
        var traversed: CLLocationDistance = 0

        for (index, distance) in distances.enumerated() {
            if targetDistance <= traversed + distance || index == distances.count - 1 {
                let fraction = distance > 0 ? (targetDistance - traversed) / distance : 0
                return (index, min(max(fraction, 0), 1))
            }
            traversed += distance
        }
        return (max(0, points.count - 2), 1)
    }

    private func clamped(_ progress: Double) -> Double {
        min(max(progress, 0), 1)
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
