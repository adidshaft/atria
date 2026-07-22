import XCTest
@testable import Atria

final class AtriaHistoryProjectionBoundaryTests: XCTestCase {
    func testHistoryViewUsesNarrowProjectionAndPlainActionStore() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/Sessions.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let projectionStart = try XCTUnwrap(source.range(of: "final class AtriaHistoryProjectionStore: ObservableObject"))
        let snapshotStart = try XCTUnwrap(
            source.range(of: "struct HistorySnapshot {", range: projectionStart.upperBound..<source.endIndex)
        )
        let chain = String(source[projectionStart.lowerBound..<snapshotStart.lowerBound])

        XCTAssertTrue(chain.contains("@StateObject private var projectionStore: AtriaHistoryProjectionStore"))
        XCTAssertTrue(chain.contains("let store: SessionStore"))
        XCTAssertFalse(chain.contains("@ObservedObject var store: SessionStore"))
        XCTAssertTrue(chain.contains("store.$historySnapshot"))
        XCTAssertTrue(chain.contains("store.$pendingSleepReviewNightForUI"))
        XCTAssertTrue(chain.contains("store.$sleepHistorySnapshot"))
        XCTAssertTrue(chain.contains("store.$baseline"))
        XCTAssertFalse(chain.contains("store.$dashboardRevision"))
        XCTAssertFalse(chain.contains("store.objectWillChange"))
    }

    func testVerifiedCanonicalPagingExpandsEveryAffectedHistoryList() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/Sessions.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let historyStart = try XCTUnwrap(source.range(of: "struct HistoryView: View"))
        let historyEnd = try XCTUnwrap(
            source.range(of: "struct HistorySessionRowSnapshot", range: historyStart.upperBound..<source.endIndex)
        )
        let history = String(source[historyStart.lowerBound..<historyEnd.lowerBound])

        XCTAssertTrue(history.contains("snapshot.rollups.prefix(visibleCanonicalDayLimit)"))
        XCTAssertTrue(history.contains("snapshot.verifiedHistoricalStepEvidenceDays.prefix(visibleCanonicalDayLimit)"))
        XCTAssertTrue(history.contains("snapshot.detections.prefix(visibleDetectionLimit)"))
        XCTAssertTrue(history.contains("let loaded = await store.loadNextVerifiedCanonicalHistoryPage()"))
        XCTAssertTrue(history.contains("visibleCanonicalDayLimit += 14"))
        XCTAssertTrue(history.contains("visibleDetectionLimit += 10"))
        XCTAssertTrue(history.contains("&& snapshot.detections.isEmpty"))
    }
}
