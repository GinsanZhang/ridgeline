import Combine
import CoreLocation
import Foundation
import MapKit

@MainActor
final class RoutePlanningModel: ObservableObject {
    @Published var originQuery = "四姑娘山镇"
    @Published var destinationQuery = "双桥沟"
    @Published private(set) var route: RidgeRoute?
    @Published private(set) var routeName = "规划真实路线"
    @Published private(set) var elevationSource: ElevationDataSource = .unavailable
    @Published private(set) var primaryInstruction = "输入起点和终点后开始规划"
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var importedTileMessage: String?

    private var elevationStore: HGTElevationStore
    private let profileBuilder: ElevationProfileBuilder

    init(
        elevationStore: HGTElevationStore = HGTElevationStore(),
        profileBuilder: ElevationProfileBuilder = ElevationProfileBuilder()
    ) {
        self.elevationStore = elevationStore
        self.profileBuilder = profileBuilder
    }

    @discardableResult
    func planRoute() async -> Bool {
        guard !isLoading else { return false }
        let origin = originQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = destinationQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !origin.isEmpty, !destination.isEmpty else {
            errorMessage = "请输入起点和终点"
            return false
        }

        isLoading = true
        errorMessage = nil
        importedTileMessage = nil
        clearRoute()
        defer { isLoading = false }

        do {
            async let originItem = searchMapItem(query: origin)
            async let destinationItem = searchMapItem(query: destination)
            let (start, end) = try await (originItem, destinationItem)

            let request = MKDirections.Request()
            request.source = start
            request.destination = end
            request.transportType = .walking
            request.requestsAlternateRoutes = false

            let response = try await MKDirections(request: request).calculate()
            guard let mapRoute = response.routes.first else {
                throw PlanningError.noRoute
            }

            let coordinates = mapRoute.polyline.coordinates
            let builder = profileBuilder
            let store = elevationStore
            let profile = await Task.detached(priority: .userInitiated) {
                builder.build(coordinates: coordinates) { coordinate in
                    store.elevation(at: coordinate)
                }
            }.value
            guard let builtRoute = profile.route else {
                throw PlanningError.noRoute
            }

            let name = "\(start.name ?? origin) → \(end.name ?? destination)"
            let instruction = mapRoute.steps
                .first(where: { !$0.instructions.isEmpty })?.instructions
                ?? "沿路线前进"
            apply(
                SavedRoute(
                    route: builtRoute,
                    name: name,
                    source: profile.source,
                    instruction: instruction,
                    originQuery: origin,
                    destinationQuery: destination
                )
            )
            try? saveCurrentRoute()
            return true
        } catch {
            if let saved = try? loadSavedRoute(),
               saved.originQuery == origin,
               saved.destinationQuery == destination {
                apply(saved)
                errorMessage = "在线规划失败，已加载上次保存路线"
                return true
            }
            errorMessage = localizedMessage(for: error)
            return false
        }
    }

    func importHGT(from sourceURL: URL) async {
        importedTileMessage = nil
        errorMessage = nil
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { sourceURL.stopAccessingSecurityScopedResource() }
        }

        do {
            let destination = try await Task.detached(priority: .userInitiated) {
                let fileManager = FileManager.default
                guard let documents = fileManager.urls(
                    for: .documentDirectory,
                    in: .userDomainMask
                ).first else {
                    throw PlanningError.documentsUnavailable
                }
                let data = try Data(contentsOf: sourceURL)
                guard HGTFileValidator.isValid(
                    fileName: sourceURL.lastPathComponent,
                    byteCount: data.count
                ) else {
                    throw PlanningError.invalidHGT
                }
                let destination = documents.appendingPathComponent(sourceURL.lastPathComponent)
                try data.write(to: destination, options: .atomic)
                return destination
            }.value
            elevationStore = HGTElevationStore()
            importedTileMessage = "已导入 \(destination.lastPathComponent)，请重新规划路线"
        } catch PlanningError.invalidHGT {
            errorMessage = "HGT 文件无效：需要 N31E102.hgt 格式的 SRTM1 文件"
        } catch {
            errorMessage = "HGT 导入失败：\(error.localizedDescription)"
        }
    }

    private func searchMapItem(query: String) async throws -> MKMapItem {
        if query == "当前位置" {
            return .forCurrentLocation()
        }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.address, .pointOfInterest]
        let response = try await MKLocalSearch(request: request).start()
        guard let item = response.mapItems.first else {
            throw PlanningError.placeNotFound(query)
        }
        return item
    }

    private func clearRoute() {
        route = nil
        routeName = "规划真实路线"
        elevationSource = .unavailable
        primaryInstruction = "输入起点和终点后开始规划"
    }

    private func apply(_ saved: SavedRoute) {
        route = saved.route
        routeName = saved.name
        elevationSource = saved.source
        primaryInstruction = saved.instruction
    }

    private func saveCurrentRoute() throws {
        guard let route else { return }
        let saved = SavedRoute(
            route: route,
            name: routeName,
            source: elevationSource,
            instruction: primaryInstruction,
            originQuery: originQuery.trimmingCharacters(in: .whitespacesAndNewlines),
            destinationQuery: destinationQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let data = try JSONEncoder().encode(saved)
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: Self.savedRouteURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: Self.savedRouteURL, options: .atomic)
    }

    private func loadSavedRoute() throws -> SavedRoute {
        let data = try Data(contentsOf: Self.savedRouteURL)
        return try JSONDecoder().decode(SavedRoute.self, from: data)
    }

    private static var savedRouteURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("last-route.json")
    }

    private func localizedMessage(for error: Error) -> String {
        switch error {
        case PlanningError.placeNotFound(let query): "找不到地点：\(query)"
        case PlanningError.noRoute: "Apple 地图没有返回可用路线"
        default: "路线规划失败：\(error.localizedDescription)"
        }
    }

    private struct SavedRoute: Codable, Sendable {
        let route: RidgeRoute
        let name: String
        let source: ElevationDataSource
        let instruction: String
        let originQuery: String
        let destinationQuery: String
    }

    private enum PlanningError: Error {
        case placeNotFound(String)
        case noRoute
        case documentsUnavailable
        case invalidHGT
    }
}

private extension MKPolyline {
    var coordinates: [CLLocationCoordinate2D] {
        var result = Array(
            repeating: CLLocationCoordinate2D(),
            count: pointCount
        )
        getCoordinates(&result, range: NSRange(location: 0, length: pointCount))
        return result
    }
}
