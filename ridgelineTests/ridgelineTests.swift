//
//  ridgelineTests.swift
//  ridgelineTests
//
//  Created by ginsan on 2026/8/10.
//

import XCTest
@testable import ridgeline

final class ridgelineTests: XCTestCase {

    /// 在临时目录构造指定经纬度命名的 .hgt 测试文件（Int16 大端序）
    private func makeTestHGTFile(
        dimension: Int,
        values: [Int16],
        name: String = "N39E116.hgt"
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)

        var data = Data()
        data.reserveCapacity(values.count * 2)
        for value in values {
            withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
        }
        try data.write(to: url)
        return url
    }

    func testQueryTopLeftRegion() throws {
        // 3×3 矩阵，行 0 为最北端（SRTM 存储方向）
        let values: [Int16] = [
            100, 200, 300,   // 最北一行
            400, 500, 600,
            700, 800, 900,   // 最南一行（lat = 39.0）
        ]
        let url = try makeTestHGTFile(dimension: 3, values: values)
        let reader = HGTReader(dimension: 3, hgtFileURL: url)

        // 最南最西角（lat=39.0, lon=116.0）→ 第 2 行第 0 列 → 700
        XCTAssertEqual(reader.elevation(lat: 39.0, lon: 116.0), 700)
        // 中心（lat=39.5, lon=116.5）→ 第 1 行第 1 列 → 500
        XCTAssertEqual(reader.elevation(lat: 39.5, lon: 116.5), 500)
        // 最北最西角（lat=39.99, lon=116.01）→ 第 0 行第 0 列 → 100
        XCTAssertEqual(reader.elevation(lat: 39.99, lon: 116.01), 100)
    }

    func testInvalidValueReturnsNil() throws {
        var values = [Int16](repeating: 0, count: 9)
        values[0] = -32768   // SRTM 无效值（海洋/空洞）
        let url = try makeTestHGTFile(dimension: 3, values: values)
        let reader = HGTReader(dimension: 3, hgtFileURL: url)

        XCTAssertNil(reader.elevation(lat: 39.99, lon: 116.01))
    }

    func testOutOfRangeReturnsNil() throws {
        let values = [Int16](repeating: 100, count: 9)
        let url = try makeTestHGTFile(dimension: 3, values: values)
        let reader = HGTReader(dimension: 3, hgtFileURL: url)

        // 纬度超出 N39 覆盖范围
        XCTAssertNil(reader.elevation(lat: 41.0, lon: 116.0))
        // 经度超出 E116 覆盖范围
        XCTAssertNil(reader.elevation(lat: 39.5, lon: 117.999))
    }
}
