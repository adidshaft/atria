import Combine
import XCTest
@testable import Atria

@MainActor
final class AtriaOverviewMorningJournalProjectionTests: XCTestCase {
    private func state(sleepRevision: Int = 0,
                       taggedDays: Int = 0) -> AtriaOverviewMorningJournalProjectionState {
        let day = Date(timeIntervalSinceReferenceDate: 800_000_000)
        return AtriaOverviewMorningJournalProjectionState(
            sleepHistory: .empty,
            sleepHistoryRevision: sleepRevision,
            todayEntry: BehaviorJournalEntry(id: "morning-journal-projection",
                                             day: day,
                                             createdAt: day,
                                             tags: []),
            taggedDays: taggedDays
        )
    }

    func testEqualMorningJournalProjectionDoesNotPublish() {
        let initial = state()
        let projection = AtriaOverviewMorningJournalProjectionStore(state: initial)
        var publications = 0
        let cancellable = projection.objectWillChange.sink { publications += 1 }

        XCTAssertFalse(projection.refresh(initial))
        XCTAssertEqual(publications, 0)
        withExtendedLifetime(cancellable) {}
    }

    func testRelevantMorningJournalProjectionPublishesExactlyOnce() {
        let projection = AtriaOverviewMorningJournalProjectionStore(state: state())
        var publications = 0
        let cancellable = projection.objectWillChange.sink { publications += 1 }

        XCTAssertTrue(projection.refresh(state(taggedDays: 1)))
        XCTAssertEqual(publications, 1)
        withExtendedLifetime(cancellable) {}
    }

    func testUnrelatedBroadSessionSignalDoesNotPublishMorningJournal() {
        let store = SessionStore()
        let projection = AtriaOverviewMorningJournalProjectionStore(store: store)
        var publications = 0
        let cancellable = projection.objectWillChange.sink { publications += 1 }

        store.objectWillChange.send()

        XCTAssertEqual(publications, 0)
        withExtendedLifetime(cancellable) {}
    }

    func testMorningJournalHostUsesProjectionAndPlainActionStore() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaOverviewSections.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let hostStart = try XCTUnwrap(source.range(of: "struct AtriaOverviewMorningJournalHost: View"))
        let hostEnd = try XCTUnwrap(source.range(of: "struct AtriaOverviewMorningJournalProjectionState"))
        let host = String(source[hostStart.lowerBound..<hostEnd.lowerBound])

        XCTAssertTrue(host.contains("let store: SessionStore"))
        XCTAssertFalse(host.contains("@ObservedObject var store"))
        XCTAssertTrue(host.contains("@StateObject private var projectionStore: AtriaOverviewMorningJournalProjectionStore"))
        XCTAssertTrue(host.contains("todayEntry: projection.todayEntry"))
        XCTAssertTrue(host.contains("taggedDays: projection.taggedDays"))
        XCTAssertTrue(host.contains("store.toggleBehaviorTag(tag)"))
    }
}
