import XCTest
@testable import Atria

final class AtriaDeviceUseJournalTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "AtriaDeviceUseJournalTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func entry(_ t: TimeInterval,
                       _ event: AtriaDeviceUseJournal.Event) -> AtriaDeviceUseJournal.Entry {
        .init(t: t, event: event)
    }

    private func window(_ start: TimeInterval,
                        _ end: TimeInterval) -> DateInterval {
        DateInterval(start: Date(timeIntervalSince1970: start),
                     end: Date(timeIntervalSince1970: end))
    }

    func testUnlockedToLockedSpanIsDerived() {
        let intervals = AtriaDeviceUseJournal.sustainedUseIntervals(
            entries: [entry(1_000, .unlocked), entry(1_400, .locked)],
            window: window(0, 10_000),
            minimumDuration: 180
        )
        XCTAssertEqual(intervals, [window(1_000, 1_400)])
    }

    func testSpansWithSubMinuteGapMerge() {
        let intervals = AtriaDeviceUseJournal.sustainedUseIntervals(
            entries: [
                entry(1_000, .unlocked), entry(1_120, .locked),
                entry(1_150, .unlocked), entry(1_300, .locked),
            ],
            window: window(0, 10_000),
            minimumDuration: 180
        )
        XCTAssertEqual(intervals, [window(1_000, 1_300)])
    }

    func testSpansWithLongerGapStaySeparate() {
        let intervals = AtriaDeviceUseJournal.sustainedUseIntervals(
            entries: [
                entry(1_000, .unlocked), entry(1_200, .locked),
                entry(1_261, .unlocked), entry(1_500, .locked),
            ],
            window: window(0, 10_000),
            minimumDuration: 180
        )
        XCTAssertEqual(intervals, [window(1_000, 1_200), window(1_261, 1_500)])
        // The 200s first span survives the 180s floor; a 100s one would not.
        let filtered = AtriaDeviceUseJournal.sustainedUseIntervals(
            entries: [
                entry(1_000, .unlocked), entry(1_100, .locked),
                entry(1_261, .unlocked), entry(1_500, .locked),
            ],
            window: window(0, 10_000),
            minimumDuration: 180
        )
        XCTAssertEqual(filtered, [window(1_261, 1_500)])
    }

    func testSceneActiveOpensAndSceneBackgroundClosesRefinedSpan() {
        let intervals = AtriaDeviceUseJournal.sustainedUseIntervals(
            entries: [entry(2_000, .sceneActive), entry(2_400, .sceneBackground)],
            window: window(0, 10_000),
            minimumDuration: 180
        )
        XCTAssertEqual(intervals, [window(2_000, 2_400)])
    }

    func testSceneBackgroundDoesNotClosePrimaryUnlockedSpan() {
        // Device unlocked, Atria backgrounded, other apps in use, then lock.
        let intervals = AtriaDeviceUseJournal.sustainedUseIntervals(
            entries: [
                entry(1_000, .unlocked),
                entry(1_200, .sceneBackground),
                entry(2_000, .locked),
            ],
            window: window(0, 10_000),
            minimumDuration: 180
        )
        XCTAssertEqual(intervals, [window(1_000, 2_000)])
    }

    func testSceneActiveThenUnlockedKeepsEarlierStartAndLockAuthority() {
        let intervals = AtriaDeviceUseJournal.sustainedUseIntervals(
            entries: [
                entry(1_000, .sceneActive),
                entry(1_100, .unlocked),
                entry(1_200, .sceneBackground),
                entry(1_600, .locked),
            ],
            window: window(0, 10_000),
            minimumDuration: 180
        )
        XCTAssertEqual(intervals, [window(1_000, 1_600)])
    }

    func testUnclosedSpanTruncatesAtLastObservedEvent() {
        // The process died before observing `locked`: use must end at the last
        // recorded event, never extrapolate to the query window's end.
        let intervals = AtriaDeviceUseJournal.sustainedUseIntervals(
            entries: [
                entry(1_000, .unlocked),
                entry(1_500, .sceneBackground),
            ],
            window: window(0, 10_000),
            minimumDuration: 180
        )
        XCTAssertEqual(intervals, [window(1_000, 1_500)])
    }

    func testUnclosedSpanWithNoLaterObservationYieldsNothing() {
        let intervals = AtriaDeviceUseJournal.sustainedUseIntervals(
            entries: [entry(1_000, .unlocked)],
            window: window(0, 10_000),
            minimumDuration: 180
        )
        XCTAssertEqual(intervals, [])
    }

    func testEmptyJournalYieldsNoIntervals() {
        XCTAssertEqual(
            AtriaDeviceUseJournal.sustainedUseIntervals(
                entries: [],
                window: window(0, 10_000),
                minimumDuration: 180
            ),
            []
        )
        XCTAssertEqual(
            AtriaDeviceUseJournal.intervalsOfSustainedUse(
                in: window(0, 10_000),
                minimumDuration: 180,
                defaults: defaults
            ),
            []
        )
    }

    func testIntervalsAreClippedToQueryWindow() {
        let intervals = AtriaDeviceUseJournal.sustainedUseIntervals(
            entries: [entry(1_000, .unlocked), entry(2_000, .locked)],
            window: window(1_500, 1_800),
            minimumDuration: 180
        )
        XCTAssertEqual(intervals, [window(1_500, 1_800)])
    }

    func testNotePersistsAndDerivesThroughDefaults() {
        let t0 = Date(timeIntervalSince1970: 1_786_000_000)
        AtriaDeviceUseJournal.note(.unlocked, at: t0, defaults: defaults)
        AtriaDeviceUseJournal.note(.locked,
                                   at: t0.addingTimeInterval(600),
                                   defaults: defaults)
        let intervals = AtriaDeviceUseJournal.intervalsOfSustainedUse(
            in: DateInterval(start: t0.addingTimeInterval(-3_600),
                             end: t0.addingTimeInterval(3_600)),
            minimumDuration: 180,
            defaults: defaults
        )
        XCTAssertEqual(intervals,
                       [DateInterval(start: t0, end: t0.addingTimeInterval(600))])
    }

    func testRingCapDropsOldestEntries() {
        // 500 well-separated unlocked/locked pairs = 1_000 entries. The
        // 800-entry cap keeps only the newest 400 pairs (pairs 100...499).
        let base: TimeInterval = 1_786_000_000
        let pairSpacing: TimeInterval = 1_000
        for pair in 0..<500 {
            let start = base + Double(pair) * pairSpacing
            AtriaDeviceUseJournal.note(.unlocked,
                                       at: Date(timeIntervalSince1970: start),
                                       defaults: defaults)
            AtriaDeviceUseJournal.note(.locked,
                                       at: Date(timeIntervalSince1970: start + 300),
                                       defaults: defaults)
        }
        func pairIntervals(_ pair: Int) -> [DateInterval] {
            let start = base + Double(pair) * pairSpacing
            return AtriaDeviceUseJournal.intervalsOfSustainedUse(
                in: window(start - 10, start + 310),
                minimumDuration: 180,
                defaults: defaults
            )
        }
        XCTAssertEqual(pairIntervals(50), [], "evicted pair must be gone")
        XCTAssertEqual(pairIntervals(99), [], "last evicted pair must be gone")
        XCTAssertEqual(pairIntervals(100).count, 1, "oldest retained pair")
        XCTAssertEqual(pairIntervals(499).count, 1, "newest pair")
    }
}
