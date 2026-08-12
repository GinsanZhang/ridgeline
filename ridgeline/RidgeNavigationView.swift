import MapKit
import SwiftUI

struct RidgeNavigationView: View {
    @StateObject private var planner = RoutePlanningModel()
    @State private var progress = 0.37
    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 31.137, longitude: 102.916),
            span: MKCoordinateSpan(latitudeDelta: 0.11, longitudeDelta: 0.11)
        )
    )

    private var route: RidgeRoute {
        planner.route ?? .previewSiguniangshan
    }

    private var isPreview: Bool {
        planner.route == nil
    }

    private var hasElevationData: Bool {
        isPreview || planner.elevationSource.hasUsableElevation
    }

    private var currentPoint: RoutePoint {
        route.sample(at: progress)
    }

    private var currentBand: ElevationBand {
        ElevationBand.band(for: currentPoint.elevation)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            routeMap
                .ignoresSafeArea(edges: .top)

            VStack(spacing: 10) {
                routePlannerCard
                mapHeader
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)

            routeSheet
        }
        .background(Color(red: 0.86, green: 0.89, blue: 0.83))
    }

    private var routeMap: some View {
        Map(position: $cameraPosition, interactionModes: .all) {
            MapPolyline(coordinates: mapCoordinates)
                .stroke(.white.opacity(0.88), lineWidth: 10)

            ForEach(mapStrokes) { stroke in
                MapPolyline(coordinates: stroke.coordinates)
                    .stroke(stroke.elevationBand?.color ?? .blue, lineWidth: 6)
            }

            Annotation("当前位置", coordinate: currentPoint.coordinate, anchor: .bottom) {
                CurrentAltitudeMarker(color: hasElevationData ? currentBand.color : .blue)
            }
        }
        .mapStyle(.standard(elevation: .realistic, emphasis: .muted))
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            planner.updateMapLatitudeDelta(context.region.span.latitudeDelta)
        }
        .onAppear {
            planner.updateMapLatitudeDelta(0.11)
        }
    }

    private var routePlannerCard: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Label("起", systemImage: "circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.green)
                TextField("起点", text: $planner.originQuery)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.next)
                Button {
                    planner.originQuery = "当前位置"
                } label: {
                    Image(systemName: "location.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("使用当前位置")
            }
            HStack(spacing: 8) {
                Label("终", systemImage: "mappin.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.red)
                TextField("终点", text: $planner.destinationQuery)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.route)
                    .onSubmit { startPlanning() }
            }

            Picker("出行方式", selection: $planner.selectedTravelMode) {
                ForEach(RouteTravelMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.systemImage)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(planner.isLoading)

            Button(action: startPlanning) {
                HStack {
                    if planner.isLoading {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                    }
                    Text(planner.isLoading ? "正在规划…" : "规划\(planner.selectedTravelMode.title)路线")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.12, green: 0.32, blue: 0.25))
            .disabled(planner.isLoading)

            if let message = planner.elevationDownloadMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let error = planner.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var mapStrokes: [RouteMapLine] {
        isPreview
            ? RouteMapLineBuilder.lines(for: route.points, usesElevationBands: true)
            : planner.routeMapLines
    }

    private var mapCoordinates: [CLLocationCoordinate2D] {
        isPreview ? route.points.map(\.coordinate) : planner.routeCoordinates
    }

    private func startPlanning() {
        Task {
            let success = await planner.planRoute()
            guard success else { return }
            progress = 0
            focusOnRoute()
        }
    }

    private func focusOnRoute() {
        let latitudes = route.points.map(\.latitude)
        let longitudes = route.points.map(\.longitude)
        guard let minLatitude = latitudes.min(),
              let maxLatitude = latitudes.max(),
              let minLongitude = longitudes.min(),
              let maxLongitude = longitudes.max()
        else { return }

        let region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(
                    latitude: (minLatitude + maxLatitude) / 2,
                    longitude: (minLongitude + maxLongitude) / 2
                ),
                span: MKCoordinateSpan(
                    latitudeDelta: max((maxLatitude - minLatitude) * 1.35, 0.01),
                    longitudeDelta: max((maxLongitude - minLongitude) * 1.35, 0.01)
                )
        )
        cameraPosition = .region(region)
        planner.updateMapLatitudeDelta(region.span.latitudeDelta)
    }

    private var mapHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(planner.routeName)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                Text("\(isPreview ? "演示路线" : planner.selectedTravelMode.title + "路线") · 已完成 \(Int(progress * 100))%")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color(red: 0.25, green: 0.39, blue: 0.31))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 17))

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.35)) {
                    focusOnRoute()
                }
            } label: {
                Image(systemName: "location.fill")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("回到完整路线")
        }
    }

    private var routeSheet: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.secondary.opacity(0.25))
                .frame(width: 36, height: 4)
                .padding(.top, 9)

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("地图与山脊，同步向前")
                        .font(.system(size: 20, weight: .heavy, design: .rounded))
                    Text("拖动曲线游标，地图定位点同步移动 · \(isPreview ? "演示高程" : planner.elevationSource.title)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(hasElevationData ? "\(Int(currentPoint.elevation))" : "--")
                        .font(.system(size: 28, weight: .black, design: .monospaced))
                    Label(hasElevationData ? "\(currentBand.title) · 米" : "等待沿线高程", systemImage: "circle.fill")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(currentBand.color)
                }
            }
            .padding(.top, 10)

            Group {
                if hasElevationData {
                    ElevationProfileView(route: route, progress: $progress)
                } else {
                    ContentUnavailableView(
                        "沿线高程准备中",
                        systemImage: "mountain.2",
                        description: Text("联网时会自动临时缓存路线经过区域的高程")
                    )
                }
            }
            .frame(height: 112)
            .padding(.top, 6)

            ElevationLegend()
                .padding(.top, 4)

            Divider()
                .padding(.vertical, 10)

            HStack(spacing: 0) {
                RouteMetric(title: "剩余爬升", value: hasElevationData ? "+\(Int(route.remainingAscent(at: progress))) m" : "--")
                RouteMetric(title: "距终点", value: String(format: "%.1f km", route.remainingDistance(at: progress) / 1_000))
                RouteMetric(title: "当前坡度", value: hasElevationData ? String(format: "%.1f%%", route.slope(at: progress)) : "--")
            }

            HStack(spacing: 12) {
                Image(systemName: "arrow.up.right")
                    .font(.title3.bold())
                    .frame(width: 42, height: 42)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))

                VStack(alignment: .leading, spacing: 3) {
                    Text(isPreview ? "输入地点规划真实路线" : planner.primaryInstruction)
                        .font(.subheadline.bold())
                    Text(isPreview ? "当前显示方案 B 演示路线" : "Apple MapKit · \(planner.elevationSource.title)")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.75))
                }

                Spacer()
            }
            .foregroundStyle(.white)
            .padding(12)
            .background(Color(red: 0.12, green: 0.32, blue: 0.25), in: RoundedRectangle(cornerRadius: 17))
            .padding(.top, 12)
        }
        .foregroundStyle(Color(red: 0.10, green: 0.15, blue: 0.12))
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 620)
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .background(
            Color(red: 0.96, green: 0.97, blue: 0.93),
            in: UnevenRoundedRectangle(topLeadingRadius: 30, topTrailingRadius: 30)
        )
        .shadow(color: .black.opacity(0.16), radius: 20, y: -8)
    }
}

private struct CurrentAltitudeMarker: View {
    let color: Color

    var body: some View {
        VStack(spacing: 0) {
            Circle()
                .fill(color)
                .frame(width: 22, height: 22)
                .overlay(Circle().stroke(.white, lineWidth: 5))
                .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
            Image(systemName: "triangle.fill")
                .font(.system(size: 9))
                .foregroundStyle(color)
                .rotationEffect(.degrees(180))
                .offset(y: -2)
        }
    }
}

private struct ElevationProfileView: View {
    let route: RidgeRoute
    @Binding var progress: Double

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let minimum = route.points.map(\.elevation).min() ?? 0
            let maximum = route.points.map(\.elevation).max() ?? 1
            let range = max(maximum - minimum, 1)

            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    guard route.points.count > 1 else { return }

                    var fillPath = Path()
                    fillPath.move(to: CGPoint(x: 0, y: size.height))
                    for (index, point) in route.points.enumerated() {
                        let x = CGFloat(index) / CGFloat(route.points.count - 1) * size.width
                        let y = size.height - CGFloat((point.elevation - minimum) / range) * (size.height - 12)
                        fillPath.addLine(to: CGPoint(x: x, y: y))
                    }
                    fillPath.addLine(to: CGPoint(x: size.width, y: size.height))
                    fillPath.closeSubpath()
                    context.fill(
                        fillPath,
                        with: .linearGradient(
                            Gradient(colors: [
                                ElevationBand.forest.color.opacity(0.18),
                                ElevationBand.meadow.color.opacity(0.20),
                                ElevationBand.rock.color.opacity(0.22),
                                ElevationBand.snow.color.opacity(0.28)
                            ]),
                            startPoint: CGPoint(x: 0, y: size.height),
                            endPoint: CGPoint(x: 0, y: 0)
                        )
                    )

                    for index in route.points.indices.dropLast() {
                        let start = route.points[index]
                        let end = route.points[index + 1]
                        let startPoint = CGPoint(
                            x: CGFloat(index) / CGFloat(route.points.count - 1) * size.width,
                            y: size.height - CGFloat((start.elevation - minimum) / range) * (size.height - 12)
                        )
                        let endPoint = CGPoint(
                            x: CGFloat(index + 1) / CGFloat(route.points.count - 1) * size.width,
                            y: size.height - CGFloat((end.elevation - minimum) / range) * (size.height - 12)
                        )
                        var segment = Path()
                        segment.move(to: startPoint)
                        segment.addLine(to: endPoint)
                        let band = ElevationBand.band(for: (start.elevation + end.elevation) / 2)
                        context.stroke(segment, with: .color(band.color), lineWidth: 4)
                    }
                }

                let markerX = size.width * progress
                Rectangle()
                    .fill(currentBand.color)
                    .frame(width: 1, height: size.height - 4)
                    .position(x: markerX, y: size.height / 2)

                Circle()
                    .fill(currentBand.color)
                    .frame(width: 13, height: 13)
                    .overlay(Circle().stroke(Color(red: 0.96, green: 0.97, blue: 0.93), lineWidth: 3))
                    .position(x: markerX, y: markerY(size: size, minimum: minimum, range: range))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        progress = min(max(value.location.x / max(size.width, 1), 0), 1)
                    }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("路线海拔剖面")
            .accessibilityValue("进度 \(Int(progress * 100))%，海拔 \(Int(route.sample(at: progress).elevation)) 米")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: progress = min(progress + 0.05, 1)
                case .decrement: progress = max(progress - 0.05, 0)
                @unknown default: break
                }
            }
        }
    }

    private var currentBand: ElevationBand {
        ElevationBand.band(for: route.sample(at: progress).elevation)
    }

    private func markerY(size: CGSize, minimum: Double, range: Double) -> CGFloat {
        let elevation = route.sample(at: progress).elevation
        return size.height - CGFloat((elevation - minimum) / range) * (size.height - 12)
    }
}

private struct ElevationLegend: View {
    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 2) {
                ForEach(ElevationBand.allCases, id: \.self) { band in
                    Capsule()
                        .fill(band.color)
                        .frame(height: 5)
                }
            }
            HStack {
                ForEach(ElevationBand.allCases, id: \.self) { band in
                    Text("\(band.title) \(band.lowerBoundLabel)")
                        .font(.system(size: 7, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

private struct RouteMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .monospaced))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    RidgeNavigationView()
        .frame(width: 393, height: 852)
        .preferredColorScheme(.light)
}
