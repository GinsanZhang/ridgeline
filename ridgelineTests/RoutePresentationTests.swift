import XCTest
@testable import ridgeline

final class RoutePresentationTests: XCTestCase {
    func testElevationBandUsesMountainTerrainThresholds() {
        XCTAssertEqual(ElevationBand.band(for: 2_199), .forest)
        XCTAssertEqual(ElevationBand.band(for: 2_200), .meadow)
        XCTAssertEqual(ElevationBand.band(for: 2_600), .rock)
        XCTAssertEqual(ElevationBand.band(for: 3_000), .snow)
    }

    func testRouteInterpolatesPositionAndElevationAtProgress() {
        let route = RidgeRoute(points: [
            RoutePoint(latitude: 31.0, longitude: 102.0, elevation: 2_000),
            RoutePoint(latitude: 32.0, longitude: 104.0, elevation: 3_000)
        ])

        let sample = route.sample(at: 0.25)

        XCTAssertEqual(sample.latitude, 31.25, accuracy: 0.000_001)
        XCTAssertEqual(sample.longitude, 102.5, accuracy: 0.000_001)
        XCTAssertEqual(sample.elevation, 2_250, accuracy: 0.001)
    }

    func testRouteProgressClampsToAvailableRange() {
        let route = RidgeRoute(points: [
            RoutePoint(latitude: 31.0, longitude: 102.0, elevation: 2_000),
            RoutePoint(latitude: 32.0, longitude: 104.0, elevation: 3_000)
        ])

        XCTAssertEqual(route.sample(at: -1).elevation, 2_000)
        XCTAssertEqual(route.sample(at: 2).elevation, 3_000)
    }

    func testRouteProgressUsesGeographicDistanceInsteadOfPointIndex() {
        let route = RidgeRoute(points: [
            RoutePoint(latitude: 0, longitude: 0, elevation: 2_000),
            RoutePoint(latitude: 0, longitude: 0.001, elevation: 2_100),
            RoutePoint(latitude: 0, longitude: 0.011, elevation: 3_100)
        ])

        let midpoint = route.sample(at: 0.5)

        XCTAssertEqual(midpoint.longitude, 0.0055, accuracy: 0.0001)
        XCTAssertEqual(midpoint.elevation, 2_550, accuracy: 10)
    }

    func testRemainingAscentSumsOnlyUphillSections() {
        let route = RidgeRoute(points: [
            RoutePoint(latitude: 0, longitude: 0, elevation: 2_000),
            RoutePoint(latitude: 0, longitude: 0.001, elevation: 2_200),
            RoutePoint(latitude: 0, longitude: 0.002, elevation: 2_100),
            RoutePoint(latitude: 0, longitude: 0.003, elevation: 2_500)
        ])

        XCTAssertEqual(route.remainingAscent(at: 0), 600, accuracy: 0.1)
        XCTAssertEqual(route.remainingAscent(at: 1), 0, accuracy: 0.1)
    }
}
