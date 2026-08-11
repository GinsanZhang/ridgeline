import Combine
import CoreLocation
import Foundation
import MapKit

enum RouteTravelMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case automobile
    case walking

    static let defaultMode: RouteTravelMode = .automobile

    var id: Self { self }

    var title: String {
        switch self {
        case .automobile: "驾车"
        case .walking: "徒步"
        }
    }

    var systemImage: String {
        switch self {
        case .automobile: "car.fill"
        case .walking: "figure.walk"
        }
    }

    var transportType: MKDirectionsTransportType {
        switch self {
        case .automobile: .automobile
        case .walking: .walking
        }
    }
}

@MainActor
final class RoutePlanningModel: ObservableObject {
    @Published var originQuery = "四姑娘山镇"
    @Published var destinationQuery = "双桥沟"
    @Published var selectedTravelMode = RouteTravelMode.defaultMode {
        didSet {
            guard selectedTravelMode != oldValue else { return }
            clearRoute()
            errorMessage = nil
        }
    }
    @Published private(set) var route: RidgeRoute?
    @Published private(set) var routeName = "规划真实路线"
    @Published private(set) var elevationSource: ElevationDataSource = .unavailable
    @Published private(set) var primaryInstruction = "输入起点和终点后开始规划"
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var elevationDownloadMessage: String?
    @Published private(set) var routeCoordinates: [CLLocationCoordinate2D] = []
    @Published private(set) var routeMapLines: [RouteMapLine] = []

    private var elevationStore: HGTElevationStore
    private let profileBuilder: ElevationProfileBuilder
    private let elevationTileCache: ElevationTileCache
    private var elevationTask: Task<Void, Never>?
    private var routeGeneration = UUID()
    private let routeCacheWriter = RouteCacheWriter()
    private var persistenceVersion = 0

    init(
        elevationStore: HGTElevationStore = HGTElevationStore(),
        profileBuilder: ElevationProfileBuilder = ElevationProfileBuilder(),
        elevationTileCache: ElevationTileCache = ElevationTileCache()
    ) {
        self.elevationStore = elevationStore
        self.profileBuilder = profileBuilder
        self.elevationTileCache = elevationTileCache
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
        elevationDownloadMessage = nil
        clearRoute()
        defer { isLoading = false }

        do {
            async let originItem = searchMapItem(query: origin)
            async let destinationItem = searchMapItem(query: destination)
            let (start, end) = try await (originItem, destinationItem)

            let request = MKDirections.Request()
            request.source = start
            request.destination = end
            request.transportType = selectedTravelMode.transportType
            request.requestsAlternateRoutes = false

            let response = try await MKDirections(request: request).calculate()
            guard let mapRoute = response.routes.first else {
                throw PlanningError.noRoute
            }

            let coordinates = mapRoute.polyline.coordinates
            guard !coordinates.isEmpty else {
                throw PlanningError.noRoute
            }
            let initialRoute = RidgeRoute(points: coordinates.map {
                RoutePoint(latitude: $0.latitude, longitude: $0.longitude, elevation: 0)
            })

            let name = "\(start.name ?? origin) → \(end.name ?? destination)"
            let instruction = mapRoute.steps
                .first(where: { !$0.instructions.isEmpty })?.instructions
                ?? "沿路线前进"
            let generation = UUID()
            routeGeneration = generation
            let initialSavedRoute = SavedRoute(
                route: initialRoute,
                name: name,
                source: .unavailable,
                instruction: instruction,
                originQuery: origin,
                destinationQuery: destination,
                travelMode: selectedTravelMode
            )
            apply(initialSavedRoute)
            startElevationLoading(
                coordinates: coordinates,
                routeMetadata: initialSavedRoute,
                generation: generation
            )
            saveCurrentRoute()
            return true
        } catch {
            if shouldUseSavedRoute(for: error),
               let saved = try? loadSavedRoute(),
               saved.matches(
                   originQuery: origin,
                   destinationQuery: destination,
                   travelMode: selectedTravelMode
               ) {
                apply(saved)
                errorMessage = "在线规划失败，已加载上次保存路线"
                return true
            }
            errorMessage = localizedMessage(for: error)
            return false
        }
    }

    private func startElevationLoading(
        coordinates: [CLLocationCoordinate2D],
        routeMetadata: SavedRoute,
        generation: UUID
    ) {
        elevationTask?.cancel()
        let tileNames = RouteElevationTilePlanner.tileNames(for: coordinates)
        let overviewTiles = RouteOverviewTilePlanner.tileIDs(for: coordinates)
        let missing = tileNames.filter { !elevationStore.availableTileNames.contains($0) }
        elevationDownloadMessage = "正在加载概览高程"

        elevationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await elevationTileCache.prepareOverviewTiles(overviewTiles)
                guard !Task.isCancelled, routeGeneration == generation else { return }
                let overviewBuilder = ElevationProfileBuilder(sampleSpacing: 300)
                let overview = await Task.detached(priority: .userInitiated) {
                    let overviewStore = TerrariumElevationStore(tileIDs: overviewTiles)
                    return overviewBuilder.build(coordinates: coordinates) { coordinate in
                        overviewStore.elevation(at: coordinate)
                    }
                }.value
                if overview.source == .offlineDEM,
                   let overviewRoute = overview.route,
                   routeGeneration == generation {
                    apply(SavedRoute(
                        route: overviewRoute,
                        name: routeMetadata.name,
                        source: .overviewDEM,
                        instruction: routeMetadata.instruction,
                        originQuery: routeMetadata.originQuery,
                        destinationQuery: routeMetadata.destinationQuery,
                        travelMode: routeMetadata.travelMode
                    ))
                    elevationDownloadMessage = missing.isEmpty
                        ? "概览高程已就绪，正在校验精细高程"
                        : "概览高程已就绪，正在升级30米精细高程（\(missing.count)块）"
                    saveCurrentRoute()
                }
            } catch {
                guard routeGeneration == generation else { return }
                elevationDownloadMessage = "概览高程暂不可用，继续加载精细高程"
            }

            do {
                try await elevationTileCache.prepareTiles(
                    named: tileNames,
                    excluding: elevationStore.bundledTileNames
                )
                guard !Task.isCancelled, routeGeneration == generation else { return }
                let refreshedStore = HGTElevationStore()
                elevationStore = refreshedStore
                let builder = profileBuilder
                let profile = await Task.detached(priority: .userInitiated) {
                    builder.build(coordinates: coordinates) { coordinate in
                        refreshedStore.elevation(at: coordinate)
                    }
                }.value
                guard !Task.isCancelled, routeGeneration == generation else { return }
                if ElevationUpgradePolicy.shouldReplaceOverview(with: profile.source),
                   let completedRoute = profile.route {
                    apply(SavedRoute(
                        route: completedRoute,
                        name: routeMetadata.name,
                        source: profile.source,
                        instruction: routeMetadata.instruction,
                        originQuery: routeMetadata.originQuery,
                        destinationQuery: routeMetadata.destinationQuery,
                        travelMode: routeMetadata.travelMode
                    ))
                    elevationDownloadMessage = "30米精细高程已就绪（临时缓存）"
                    saveCurrentRoute()
                } else {
                    elevationDownloadMessage = elevationSource == .overviewDEM
                        ? "30米数据覆盖不完整，继续使用概览高程"
                        : "部分沿线高程暂不可用"
                }
            } catch {
                guard routeGeneration == generation else { return }
                elevationDownloadMessage = "沿线高程下载失败，地图路线仍可使用"
            }
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
        elevationTask?.cancel()
        routeGeneration = UUID()
        route = nil
        routeCoordinates = []
        routeMapLines = []
        routeName = "规划真实路线"
        elevationSource = .unavailable
        primaryInstruction = "输入起点和终点后开始规划"
        elevationDownloadMessage = nil
    }

    private func apply(_ saved: SavedRoute) {
        route = saved.route
        routeCoordinates = saved.route.points.map(\.coordinate)
        routeMapLines = RouteMapLineBuilder.lines(
            for: saved.route.points,
            usesElevationBands: saved.source.hasUsableElevation
        )
        routeName = saved.name
        elevationSource = saved.source
        primaryInstruction = saved.instruction
    }

    private func saveCurrentRoute() {
        guard let route else { return }
        let saved = SavedRoute(
            route: route,
            name: routeName,
            source: elevationSource,
            instruction: primaryInstruction,
            originQuery: originQuery.trimmingCharacters(in: .whitespacesAndNewlines),
            destinationQuery: destinationQuery.trimmingCharacters(in: .whitespacesAndNewlines),
            travelMode: selectedTravelMode
        )
        persistenceVersion += 1
        let version = persistenceVersion
        let writer = routeCacheWriter
        Task {
            await writer.save(saved, to: Self.savedRouteURL, version: version)
        }
    }

    private func loadSavedRoute() throws -> SavedRoute {
        let data = try Data(contentsOf: Self.savedRouteURL)
        return try JSONDecoder().decode(SavedRoute.self, from: data)
    }

    nonisolated private static var savedRouteURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("last-route.json")
    }

    private func shouldUseSavedRoute(for error: Error) -> Bool {
        if error is URLError { return true }
        guard let mapError = error as? MKError else { return false }
        return mapError.code == .serverFailure || mapError.code == .loadingThrottled
    }

    private func localizedMessage(for error: Error) -> String {
        if let mapError = error as? MKError {
            switch mapError.code {
            case .directionsNotFound:
                return noRouteMessage
            case .placemarkNotFound:
                return "Apple 地图无法识别起点或终点，请填写更具体的地点"
            case .serverFailure:
                return "Apple 地图服务暂时不可用，请稍后重试"
            case .loadingThrottled:
                return "路线请求过于频繁，请稍后再试"
            default:
                return "Apple 地图规划失败：\(mapError.localizedDescription)"
            }
        }

        return switch error {
        case PlanningError.placeNotFound(let query): "找不到地点：\(query)"
        case PlanningError.noRoute: noRouteMessage
        default: "路线规划失败：\(error.localizedDescription)"
        }
    }

    private var noRouteMessage: String {
        "Apple 地图未提供从该起点到终点的\(selectedTravelMode.title)路线；可尝试切换出行方式或填写更具体的地点"
    }

    struct SavedRoute: Codable, Sendable {
        let route: RidgeRoute
        let name: String
        let source: ElevationDataSource
        let instruction: String
        let originQuery: String
        let destinationQuery: String
        let travelMode: RouteTravelMode

        init(
            route: RidgeRoute,
            name: String,
            source: ElevationDataSource,
            instruction: String,
            originQuery: String,
            destinationQuery: String,
            travelMode: RouteTravelMode
        ) {
            self.route = route
            self.name = name
            self.source = source
            self.instruction = instruction
            self.originQuery = originQuery
            self.destinationQuery = destinationQuery
            self.travelMode = travelMode
        }

        func matches(
            originQuery: String,
            destinationQuery: String,
            travelMode: RouteTravelMode
        ) -> Bool {
            self.originQuery == originQuery
                && self.destinationQuery == destinationQuery
                && self.travelMode == travelMode
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            route = try container.decode(RidgeRoute.self, forKey: .route)
            name = try container.decode(String.self, forKey: .name)
            source = try container.decode(ElevationDataSource.self, forKey: .source)
            instruction = try container.decode(String.self, forKey: .instruction)
            originQuery = try container.decode(String.self, forKey: .originQuery)
            destinationQuery = try container.decode(String.self, forKey: .destinationQuery)
            // All caches from the previous release were produced by the
            // formerly hard-coded walking request.
            travelMode = try container.decodeIfPresent(
                RouteTravelMode.self,
                forKey: .travelMode
            ) ?? .walking
        }
    }

    private enum PlanningError: Error {
        case placeNotFound(String)
        case noRoute
    }
}

private actor RouteCacheWriter {
    private var latestVersion = 0

    func save(
        _ route: RoutePlanningModel.SavedRoute,
        to url: URL,
        version: Int
    ) {
        guard version >= latestVersion else { return }
        latestVersion = version
        guard let data = try? JSONEncoder().encode(route) else { return }
        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
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
