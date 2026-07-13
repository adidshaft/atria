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
}
