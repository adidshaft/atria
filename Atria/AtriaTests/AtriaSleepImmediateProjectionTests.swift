import XCTest
@testable import Atria

final class AtriaSleepImmediateProjectionTests: XCTestCase {
    func testConfirmedSleepSavePublishesLightweightSnapshotBeforeDeferredHistory() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/Sessions.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func saveConfirmedSleeps(_ sleeps:"))
        let end = try XCTUnwrap(
            source.range(of: "private func writeDutyCycleSleepWindow", range: start.upperBound..<source.endIndex)
        )
        let savePath = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(savePath.contains("setCachedConfirmedSleeps(sorted)"))
        XCTAssertTrue(savePath.contains("sleepHistorySnapshot = SleepHistorySnapshot("))
        XCTAssertTrue(savePath.contains("confirmedSleeps: sorted"))
        let publicationIndex = try XCTUnwrap(
            savePath.range(of: "sleepHistorySnapshot = SleepHistorySnapshot(")?.lowerBound
        )
        let deferredRefreshIndex = try XCTUnwrap(
            savePath.range(of: "refreshHistorySnapshotCache(deferred: true)")?.lowerBound
        )
        XCTAssertTrue(publicationIndex < deferredRefreshIndex)
    }
}
