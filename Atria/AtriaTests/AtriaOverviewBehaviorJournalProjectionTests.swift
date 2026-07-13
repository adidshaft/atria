import Combine
import XCTest
@testable import Atria

@MainActor
final class AtriaOverviewBehaviorJournalProjectionTests: XCTestCase {
    private func state(taggedDays: Int = 0) -> AtriaOverviewBehaviorJournalProjectionState {
        AtriaOverviewBehaviorJournalProjectionState(
            summaries: [],
            behaviorImpacts: [],
            taggedDays: taggedDays
        )
    }

    func testEqualProjectionDoesNotPublish() {
        let projection = AtriaOverviewBehaviorJournalProjectionStore(state: state())
        var publications = 0
        let cancellable = projection.objectWillChange.sink { publications += 1 }

        XCTAssertFalse(projection.refresh(state()))
        XCTAssertFalse(projection.refresh(state()))
        XCTAssertEqual(publications, 0)

        withExtendedLifetime(cancellable) {}
    }

    func testRelevantProjectionChangePublishesOnce() {
        let projection = AtriaOverviewBehaviorJournalProjectionStore(state: state())
        var publications = 0
        let cancellable = projection.objectWillChange.sink { publications += 1 }

        XCTAssertTrue(projection.refresh(state(taggedDays: 1)))
        XCTAssertFalse(projection.refresh(state(taggedDays: 1)))
        XCTAssertEqual(publications, 1)

        withExtendedLifetime(cancellable) {}
    }

    func testSectionUsesEqualityGatedProjectionInsteadOfSessionStoreObservation() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaOverviewSections.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let sectionStart = try XCTUnwrap(source.range(of: "struct AtriaOverviewBehaviorJournalSection: View"))
        let contentStart = try XCTUnwrap(
            source.range(of: "private struct AtriaOverviewBehaviorJournalContent", range: sectionStart.upperBound..<source.endIndex)
        )
        let sectionSource = String(source[sectionStart.lowerBound..<contentStart.lowerBound])

        XCTAssertFalse(sectionSource.contains("@ObservedObject var store: SessionStore"))
        XCTAssertTrue(sectionSource.contains("@StateObject private var projectionStore"))
        XCTAssertTrue(sectionSource.contains("guard next != state else { return false }"))
        XCTAssertTrue(sectionSource.contains("store.$dashboardRevision.dropFirst()"))
        XCTAssertTrue(sectionSource.contains("store.$behaviorCorrelationSummariesCache.dropFirst()"))
        XCTAssertTrue(sectionSource.contains("store.$behaviorImpactSummariesCache.dropFirst()"))
    }
}
