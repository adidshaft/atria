import XCTest
@testable import Atria

final class AtriaMainThreadWatchdogTests: XCTestCase {
    func testStallsAreReportedOnlyAtOrAboveTheThreshold() {
        XCTAssertNil(AtriaMainThreadWatchdog.stallDuration(sentUptime: 10, answeredUptime: 10.249))
        XCTAssertEqual(AtriaMainThreadWatchdog.stallDuration(sentUptime: 10, answeredUptime: 10.25) ?? 0,
                       0.25, accuracy: 0.0001)
        XCTAssertEqual(AtriaMainThreadWatchdog.stallDuration(sentUptime: 10, answeredUptime: 11.5) ?? 0,
                       1.5, accuracy: 0.0001)
    }

    func testMetricKitDirectoryKeepsOnlyTheNewestPayloads() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("metrickit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for stamp in 1_800_000_000..<1_800_000_005 {
            try Data("{}".utf8).write(to: directory.appendingPathComponent("diagnostic-\(stamp)-x.json"))
        }
        AtriaMainThreadWatchdog.pruneMetricKitDirectory(directory, keepNewest: 2)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(names, ["diagnostic-1800000003-x.json", "diagnostic-1800000004-x.json"])
    }
}
