//
//  ContentView.swift
//  ridgeline
//
//  Created by ginsan on 2026/8/10.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            NavigationStack {
                RidgeNavigationView()
            }
            .tabItem {
                Label("导航", systemImage: "map.fill")
            }

            NavigationStack {
                ElevationView()
            }
            .tabItem {
                Label("海拔", systemImage: "arrow.up.and.down")
            }

            NavigationStack {
                Text("设置（待建设）")
                    .navigationTitle("设置")
            }
            .tabItem {
                Label("设置", systemImage: "gearshape.fill")
            }
        }
    }
}

/// 海拔实时监测页（用于验证传感器融合，后续会升级为导航 HUD）
struct ElevationView: View {
    @StateObject private var monitor = AltitudeMonitor.shared

    var body: some View {
        VStack(spacing: 20) {
            Text("当前海拔")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(monitor.currentAltitude.map { String(format: "%.0f m", $0) } ?? "--")
                .font(.system(size: 64, weight: .bold, design: .rounded))
                .monospacedDigit()

            HStack(spacing: 20) {
                MetricView(
                    title: "垂直速度",
                    value: monitor.verticalSpeed.map { String(format: "%.1f m/min", $0) })
                MetricView(
                    title: "坡度",
                    value: monitor.slope.map { String(format: "%.1f %%", $0) })
                MetricView(
                    title: "水平速度",
                    value: monitor.horizontalSpeed.map { String(format: "%.1f m/s", $0) })
            }

            Button {
                monitor.isTracking ? monitor.stop() : monitor.start()
            } label: {
                Label(monitor.isTracking ? "停止追踪" : "开始追踪",
                      systemImage: monitor.isTracking ? "stop.circle.fill" : "play.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(monitor.isTracking ? .red : .green)

            if monitor.isAuthorizationDenied {
                Text("定位权限被拒绝，请在系统设置中开启")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .navigationTitle("海拔")
    }
}

private struct MetricView: View {
    let title: String
    let value: String?

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value ?? "--")
                .font(.headline)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    ContentView()
}

