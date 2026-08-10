
技术设计文档 (TDD)2.1 整体技术架构采用 SwiftUI + Swift Concurrency (async/await) 响应式架构，iOS 作为计算与 3D 地图渲染中心，watchOS 作为轻量化仪表盘。┌────────────────────────────────────────────────────────────────────────┐
│                        Apple Watch (watchOS)                           │
│  ┌───────────────────────┐   ┌───────────────────┐   ┌──────────────┐  │
│  │ CoreMotion (气压计)   │   │ CoreLocation(GPS) │   │  Digital     │  │
│  │ 实时相对高度/垂直速度  │   │ 实时坐标/绝对海拔  │   │  Crown (缩放)│  │
│  └───────────┬───────────┘   └─────────┬─────────┘   ───────┬───────┘  │
└──────────────┼─────────────────────────┼────────────────────┼──────────┘
               │ (WatchConnectivity / WCSession 双向同步)      │
┌──────────────▼─────────────────────────▼────────────────────▼──────────┐
│                          iPhone App (iOS)                              │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │                     Data & Navigation Engine                     │  │
│  │ ┌──────────────────┐   ┌───────────────────┐  ┌───────────────┐ │  │
│  │ │  AMapNaviKit     │   │  Local DEM (.hgt) │  │ CoreMotion /  │ │  │
│  │ │ (高德路线/导航)  │   │ (30m离线高程索引) │  │ Barometer     │ │  │
│  │ └─────────┬────────┘   └─────────┬─────────┘  └───────┬───────┘ │  │
│  └───────────┼──────────────────────┼────────────────────┼──────────┘  │
│              ▼                      ▼                    ▼             │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │                        UI Layer (SwiftUI)                        │  │
│  │  [ MAMapView 3D 倾角视图 ]  +  [ Swift Charts 实时海拔剖面图 ]     │  │
│  └──────────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────────┘
2.2 核心模块与代码实现设计1. 离线 DEM (.hgt) 高程检索模块 (HGTReader)原理：SRTM1 文件为 $3601 \times 3601$ 的二字节大端序（Big-Endian）矩阵，通过文件偏移量直接读取：$$\text{Offset} = (\text{Row} \times 3601 + \text{Col}) \times 2$$Swiftimport Foundation

struct HGTReader {
    static func getElevation(lat: Double, lon: Double, hgtFileURL: URL) -> Int16? {
        let dimension = 3601
        let latFrac = lat - floor(lat)
        let lonFrac = lon - floor(lon)
        
        let row = Int((1.0 - latFrac) * Double(dimension - 1))
        let col = Int(lonFrac * Double(dimension - 1))
        let offset = (row * dimension + col) * 2
        
        guard let fileHandle = try? FileHandle(forReadingFrom: hgtFileURL) else { return nil }
        defer { try? fileHandle.close() }
        
        fileHandle.seek(toFileOffset: UInt64(offset))
        let data = fileHandle.readData(ofLength: 2)
        guard data.count == 2 else { return nil }
        
        let rawValue = data.withUnsafeBytes { $0.load(as: Int16.self).bigEndian }
        return rawValue == -32768 ? nil : rawValue // -32768 为无效值
    }
}
2. 高德路线与高程剖面绑定 (AMapNaviManager)降采样与抽样：在 onCalculateRouteSuccess 回调中拿到路线点，每隔 50-100 米等距抽样，批量传入 HGTReader 提取高程，构建 [AltitudePoint] 数组供 Swift Charts 绘制。3. iOS 与 watchOS 通信 (WatchSessionManager)传输协议：使用 WatchConnectivity 的 updateApplicationContext（传递导航状态）与 sendMessage（传递实时高频气压变化）。三、 工程配置与开发准备清单3.1 基础信息App 名字：RidgeLine（手机端显示 RidgeLine 山脊线）Bundle Identifier：com.yourname.RidgeLine（需严格与高德 Key 保持一致）支持平台：iOS 16.0+ / watchOS 9.0+开发环境：Mac + Xcode + CocoaPods (pod 'AMapNavi')3.2 隐私与后台权限配置 (Info.plist)NSLocationWhenInUseUsageDescription（前台定位权限）NSLocationAlwaysAndWhenInUseUsageDescription（后台导航定位权限）NSMotionUsageDescription（气压计/运动传感器权限）UIBackgroundModes：勾选 location（保证后台导航与高程追踪不被系统挂起）
