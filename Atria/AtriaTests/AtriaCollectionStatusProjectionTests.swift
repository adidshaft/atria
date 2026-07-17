import XCTest
@testable import Atria

final class AtriaCollectionStatusProjectionTests: XCTestCase {
    func testStatusCardUsesEqualityGatedProjection() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaVitalsCollectionSections.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let stateStart = try XCTUnwrap(source.range(of: "struct AtriaCollectionStatusProjectionState: Equatable"))
        let warningStart = try XCTUnwrap(
            source.range(of: "private struct AtriaCollectionCoexistenceWarning: View", range: stateStart.upperBound..<source.endIndex)
        )
        let chain = String(source[stateStart.lowerBound..<warningStart.lowerBound])

        XCTAssertTrue(chain.contains("@StateObject private var projectionStore: AtriaCollectionStatusProjectionStore"))
        XCTAssertTrue(chain.contains("guard next != state else { return false }"))
        XCTAssertTrue(chain.contains("coreLiveStore.$state"))
        XCTAssertTrue(chain.contains("collectionLiveStore.$state"))
        XCTAssertTrue(chain.contains("homeStatsStore.$state"))
        XCTAssertTrue(chain.contains("snapshotStore.$state"))
        XCTAssertTrue(chain.contains("store.$historicalArchiveStatus"))
        XCTAssertFalse(chain.contains("@ObservedObject"))
        XCTAssertFalse(chain.contains("store.objectWillChange"))
    }
}
