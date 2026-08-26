import Combine
import XCTest
@testable import Atria

@MainActor
final class AtriaJournalProjectionStoreTests: XCTestCase {
    private let day = Date(timeIntervalSince1970: 1_783_641_600)

    private func state(journalRevision: Int = 1,
                       answersRevision: Int = 1,
                       rollupRevision: Int = 1,
                       metricRevision: Int = 1,
                       insights: [JournalInsight] = []) -> AtriaJournalProjectionState {
        AtriaJournalProjectionState(
            behaviorJournalRevision: journalRevision,
            journalAnswersRevision: answersRevision,
            typedInsights: insights,
            dailyRollupHistoryRevision: rollupRevision,
            dailyMetricHistoryRevision: metricRevision,
            localDay: day
        )
    }

    func testNoOpRefreshDoesNotPublish() {
        let projection = AtriaJournalProjectionStore(state: state())
        var publications = 0
        let cancellable = projection.objectWillChange.sink { publications += 1 }

        XCTAssertFalse(projection.refresh(state()))
        XCTAssertFalse(projection.refresh(state()))
        XCTAssertEqual(publications, 0)

        withExtendedLifetime(cancellable) {}
    }

    func testRelevantJournalRevisionsPublishExactlyOnceEach() {
        let projection = AtriaJournalProjectionStore(state: state())
        var publications = 0
        let cancellable = projection.objectWillChange.sink { publications += 1 }

        XCTAssertTrue(projection.refresh(state(journalRevision: 2)))
        XCTAssertEqual(publications, 1)
        XCTAssertTrue(projection.refresh(state(journalRevision: 2, answersRevision: 2)))
        XCTAssertEqual(publications, 2)
        XCTAssertTrue(projection.refresh(state(journalRevision: 2,
                                               answersRevision: 2,
                                               rollupRevision: 2)))
        XCTAssertEqual(publications, 3)
        // Daily-metric history feeds the Behavior Impact / Impact map cards, so
        // it has to be able to move the projection on its own.
        XCTAssertTrue(projection.refresh(state(journalRevision: 2,
                                               answersRevision: 2,
                                               rollupRevision: 2,
                                               metricRevision: 2)))
        XCTAssertEqual(publications, 4)

        withExtendedLifetime(cancellable) {}
    }

    func testTypedInsightSlicePublishesButEqualSliceDoesNot() {
        let projection = AtriaJournalProjectionStore(state: state())
        let insight = JournalInsight(questionID: "mood.scale",
                                     label: "Mood",
                                     kind: .rankCorrelation(rho: 0.4, days: 14, pValue: 0.04))
        var publications = 0
        let cancellable = projection.objectWillChange.sink { publications += 1 }

        let populated = state(insights: [insight])
        XCTAssertTrue(projection.refresh(populated))
        XCTAssertFalse(projection.refresh(populated))
        XCTAssertEqual(publications, 1)

        withExtendedLifetime(cancellable) {}
    }

    func testLocalDayRefreshPublishesOnlyAcrossMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let initialDay = calendar.startOfDay(for: day)
        let projection = AtriaJournalProjectionStore(
            state: AtriaJournalProjectionState(
                behaviorJournalRevision: 1,
                journalAnswersRevision: 1,
                typedInsights: [],
                dailyRollupHistoryRevision: 1,
                dailyMetricHistoryRevision: 1,
                localDay: initialDay
            )
        )
        let sameDay = day.addingTimeInterval(12 * 60 * 60)
        let nextDay = day.addingTimeInterval(24 * 60 * 60)
        var publications = 0
        let cancellable = projection.objectWillChange.sink { publications += 1 }

        XCTAssertFalse(projection.refreshDayIfNeeded(now: sameDay, calendar: calendar))
        XCTAssertTrue(projection.refreshDayIfNeeded(now: nextDay, calendar: calendar))
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(projection.state.localDay, calendar.startOfDay(for: nextDay))

        withExtendedLifetime(cancellable) {}
    }

    func testDailyBriefProgressCountsYesNoAndScaleAnswersForToday() {
        let entry = BehaviorJournalEntry(id: "today",
                                         day: day,
                                         createdAt: day,
                                         tags: [.sleep])
        let answers = [
            AtriaJournalCheckInProgress.booleanQuestionID(for: .alcohol):
                AtriaJournalAnswer(questionID: AtriaJournalCheckInProgress.booleanQuestionID(for: .alcohol),
                                   day: day,
                                   value: .no,
                                   loggedAt: day,
                                   source: "user"),
            AtriaJournalTypedQuestion.moodScale.rawValue:
                AtriaJournalAnswer(questionID: AtriaJournalTypedQuestion.moodScale.rawValue,
                                   day: day,
                                   value: .scale(4),
                                   loggedAt: day,
                                   source: "user")
        ]

        let progress = AtriaJournalCheckInProgress.resolve(
            trackedTags: [.sleep, .alcohol],
            todayEntry: entry,
            answersByQuestion: answers
        )

        XCTAssertEqual(progress.answeredCount, 3)
        XCTAssertEqual(progress.totalCount, 7)
        XCTAssertTrue(progress.isStarted)
        XCTAssertFalse(progress.isComplete)
        // The Today card stacks actionLabel directly above statusLabel, so the
        // progress count must appear in exactly one of them — it used to be in
        // both, printing "3 of 7" twice one line apart.
        XCTAssertEqual(progress.actionLabel, "Resume check-in")
        XCTAssertEqual(progress.statusLabel, "3 of 7")
        XCTAssertFalse(progress.actionLabel.contains("3 of 7"),
                       "the count belongs to statusLabel alone")
    }

    func testDailyBriefProgressReportsCompletionOnlyWhenEveryCardIsAnswered() {
        let trackedTags: [BehaviorJournalEntry.Tag] = [.sleep]
        let entry = BehaviorJournalEntry(id: "complete",
                                         day: day,
                                         createdAt: day,
                                         tags: [.sleep])
        var answers: [String: AtriaJournalAnswer] = [:]
        for question in AtriaJournalCheckInProgress.scaleQuestions {
            answers[question.rawValue] = AtriaJournalAnswer(questionID: question.rawValue,
                                                            day: day,
                                                            value: .scale(3),
                                                            loggedAt: day,
                                                            source: "user")
        }

        let progress = AtriaJournalCheckInProgress.resolve(
            trackedTags: trackedTags,
            todayEntry: entry,
            answersByQuestion: answers
        )

        XCTAssertEqual(progress.answeredCount, progress.totalCount)
        XCTAssertTrue(progress.isComplete)
        XCTAssertEqual(progress.actionLabel, "Review check-in")
        XCTAssertEqual(progress.statusLabel, "Done")
    }

    func testJournalSourceUsesNarrowProjectionInsteadOfSessionStoreObservation() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaJournalTab.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("@ObservedObject var store: SessionStore"))
        XCTAssertFalse(source.contains("@ObservedObject var sessionStore: SessionStore"))
        XCTAssertTrue(source.contains("@StateObject private var projectionStore: AtriaJournalProjectionStore"))
        XCTAssertTrue(source.contains("store.$dashboardRevision.dropFirst()"))
        XCTAssertTrue(source.contains("store.$journalAnswersRevision.dropFirst()"))
        XCTAssertTrue(source.contains("store.$journalInsightsCache.dropFirst()"))
        XCTAssertTrue(source.contains("store.$dailyRollupHistory.dropFirst()"))
        XCTAssertTrue(source.contains("store.$dailyMetricHistory.dropFirst()"))
        XCTAssertTrue(source.contains("let localDay = projection.localDay"))
        XCTAssertTrue(source.contains("projectionStore.refreshDayIfNeeded()"))
        XCTAssertTrue(source.contains("revision: projection.behaviorJournalRevision"))
        XCTAssertTrue(source.contains("entryMemo.snapshot(revision: projection.behaviorJournalRevision"))
        XCTAssertTrue(source.contains("answerMemo.answers(revision: projection.journalAnswersRevision"))
        XCTAssertFalse(source.contains("entryMemo.snapshot(revision: store.behaviorJournalRevision"))
        XCTAssertFalse(source.contains("answerMemo.answers(revision: store.journalAnswersRevision"))
    }
}
