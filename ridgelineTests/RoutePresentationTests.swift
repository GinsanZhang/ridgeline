import CoreLocation
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

    func testElevationProfileSamplesByDistanceAndPrefersOfflineElevation() {
        let coordinates = [
            CLLocationCoordinate2D(latitude: 0, longitude: 0),
            CLLocationCoordinate2D(latitude: 0, longitude: 0.01)
        ]
        let builder = ElevationProfileBuilder(sampleSpacing: 250)

        let result = builder.build(coordinates: coordinates) { coordinate in
            Int16((coordinate.longitude * 100_000).rounded())
        }

        XCTAssertGreaterThan(result.points.count, 3)
        XCTAssertEqual(result.source, .offlineDEM)
        XCTAssertEqual(result.points.first?.elevation, 0)
        XCTAssertEqual(result.points.last?.elevation, 1_000)
    }

    func testElevationProfileReportsUnavailableWhenNoHGTMatches() {
        let coordinates = [
            CLLocationCoordinate2D(latitude: 31, longitude: 102),
            CLLocationCoordinate2D(latitude: 31.001, longitude: 102.001)
        ]
        let builder = ElevationProfileBuilder(sampleSpacing: 50)

        let result = builder.build(coordinates: coordinates) { _ in nil }

        XCTAssertEqual(result.source, .unavailable)
        XCTAssertFalse(result.points.isEmpty)
    }

    func testPartialHGTIsNotCompleteElevation() {
        let coordinates = [
            CLLocationCoordinate2D(latitude: 0, longitude: 0),
            CLLocationCoordinate2D(latitude: 0, longitude: 0.001)
        ]
        let builder = ElevationProfileBuilder(sampleSpacing: 50)

        let result = builder.build(coordinates: coordinates) { coordinate in
            coordinate.longitude == 0 ? 100 : nil
        }

        XCTAssertEqual(result.source, .partialDEM)
        XCTAssertFalse(result.hasCompleteElevation)
    }

    func testHGTFileValidatorRejectsWrongNameAndSize() {
        XCTAssertTrue(HGTFileValidator.isValid(
            fileName: "N31E102.hgt",
            byteCount: HGTFileValidator.expectedByteCount
        ))
        XCTAssertFalse(HGTFileValidator.isValid(
            fileName: "mountain.hgt",
            byteCount: HGTFileValidator.expectedByteCount
        ))
        XCTAssertFalse(HGTFileValidator.isValid(
            fileName: "N31E102.hgt",
            byteCount: 42
        ))
    }

    func testBundledElevationTileIsDiscoverableAndReadable() throws {
        let bundleRoot = try XCTUnwrap(Bundle.main.resourceURL)
        let tile = try XCTUnwrap(
            HGTElevationStore.discoverFiles().first {
                $0.lastPathComponent == "N31E102.hgt"
                    && $0.standardizedFileURL.path.hasPrefix(
                        bundleRoot.standardizedFileURL.path + "/"
                    )
            }
        )
        let byteCount = try FileManager.default.attributesOfItem(
            atPath: tile.path
        )[.size] as? Int

        XCTAssertEqual(byteCount, HGTFileValidator.expectedByteCount)
        let reader = HGTReader(hgtFileURL: tile)
        XCTAssertEqual(reader.elevation(lat: 31.10, lon: 102.90), 5_257)
        XCTAssertEqual(reader.elevation(lat: 31.05, lon: 102.85), 4_687)
        XCTAssertEqual(reader.elevation(lat: 31.20, lon: 102.80), 4_342)
        XCTAssertEqual(reader.elevation(lat: 31.15, lon: 102.95), 4_503)
    }

    func testDuplicateTileNamesUseLastFileWithoutCrashing() {
        let bundled = URL(fileURLWithPath: "/Bundle/N31E102.hgt")
        let imported = URL(fileURLWithPath: "/Documents/N31E102.hgt")

        XCTAssertNoThrow(HGTElevationStore(fileURLs: [bundled, imported]))
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
