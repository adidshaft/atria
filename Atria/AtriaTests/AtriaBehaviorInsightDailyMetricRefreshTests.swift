import Combine
import XCTest
@testable import Atria

@MainActor
final class AtriaBehaviorInsightDailyMetricRefreshTests: XCTestCase {
    func testAcceptedMorningMetricRefreshesBehaviorAndJournalCachesWithoutJournalMutation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        store.configureBehaviorInsightRefreshForTesting(
            journalEntries: fixture.behaviorEntries
        )

        let initialPublication = expectation(description: "initial insight cache")
        var initialCancellable: AnyCancellable? = store.$journalInsightsCache
            .dropFirst()
            .sink { _ in initialPublication.fulfill() }
        store.publishDailyMetricHistoryForInsightTesting(fixture.metricsWithoutMorning)
        await fulfillment(of: [initialPublication], timeout: 3)
        initialCancellable?.cancel()
        initialCancellable = nil

        XCTAssertTrue(store.journalInsightsCache.isEmpty)
        XCTAssertTrue(store.behaviorImpactSummariesCache.isEmpty)
        let journalRevision = store.journalAnswersRevision
        let firstInsightRevision = store.behaviorInsightsRevision

        let refreshedPublication = expectation(description: "morning metric insight refresh")
        var refreshedCancellable: AnyCancellable? = store.$journalInsightsCache
            .dropFirst()
            .sink { insights in
                if insights.contains(where: { $0.questionID == fixture.questionID }) {
                    refreshedPublication.fulfill()
                }
            }
        store.publishDailyMetricHistoryForInsightTesting(fixture.metricsWithMorning)
        await fulfillment(of: [refreshedPublication], timeout: 3)
        refreshedCancellable?.cancel()
        refreshedCancellable = nil

        XCTAssertEqual(store.journalAnswersRevision, journalRevision,
                       "a metric publication must refresh insights without pretending the journal changed")
        XCTAssertGreaterThan(store.behaviorInsightsRevision, firstInsightRevision)
        XCTAssertTrue(store.journalInsightsCache.contains {
            $0.questionID == fixture.questionID
        })
        XCTAssertTrue(store.behaviorImpactSummariesCache.contains {
            $0.tag == fixture.behaviorTag
        })
    }

    func testInsightPublicationRejectsSupersededGenerationOrDailyMetricRevision() {
        XCTAssertTrue(SessionStore.behaviorInsightPublicationIsCurrent(
            generation: 8,
            currentGeneration: 8,
            sourceDailyMetricRevision: 12,
            currentDailyMetricRevision: 12
        ))
        XCTAssertFalse(SessionStore.behaviorInsightPublicationIsCurrent(
            generation: 7,
            currentGeneration: 8,
            sourceDailyMetricRevision: 12,
            currentDailyMetricRevision: 12
        ))
        XCTAssertFalse(SessionStore.behaviorInsightPublicationIsCurrent(
            generation: 8,
            currentGeneration: 8,
            sourceDailyMetricRevision: 11,
            currentDailyMetricRevision: 12
        ))
    }

    func testSameValueReassignmentDoesNotInvalidateScheduledInsightPublication() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        store.configureBehaviorInsightRefreshForTesting(
            journalEntries: fixture.behaviorEntries
        )

        let publication = expectation(description: "same-value metric insight publication")
        var cancellable: AnyCancellable? = store.$journalInsightsCache
            .dropFirst()
            .sink { insights in
                if insights.contains(where: { $0.questionID == fixture.questionID }) {
                    publication.fulfill()
                }
            }

        store.publishDailyMetricHistoryForInsightTesting(fixture.metricsWithMorning)
        let contentRevision = store.dailyMetricHistoryRevision
        store.publishDailyMetricHistoryForInsightTesting(fixture.metricsWithMorning)

        XCTAssertEqual(store.dailyMetricHistoryRevision, contentRevision,
                       "an identical assignment must preserve the in-flight content revision")
        await fulfillment(of: [publication], timeout: 3)
        cancellable?.cancel()
        cancellable = nil

        XCTAssertTrue(store.journalInsightsCache.contains {
            $0.questionID == fixture.questionID
        })
        XCTAssertTrue(store.behaviorImpactSummariesCache.contains {
            $0.tag == fixture.behaviorTag
        })
    }
}

@MainActor
private struct Fixture {
    let directory: URL
    let answers: AtriaJournalAnswerStore
    let questionID = "test.daily-metric-refresh"
    let behaviorTag = BehaviorJournalEntry.Tag.alcohol
    let days: [Date]

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtriaBehaviorInsightRefresh-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        answers = AtriaJournalAnswerStore(directory: directory)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let reference = calendar.startOfDay(for: Date(timeIntervalSince1970: 2_000_000_000))
        days = (0..<10).map {
            calendar.date(byAdding: .day, value: $0 - 9, to: reference)!
        }
        for (index, day) in days.enumerated() {
            answers.record(questionID: questionID,
                           day: day,
                           value: index < 5 ? .yes : .no,
                           now: day,
                           calendar: calendar)
        }
    }

    var behaviorEntries: [BehaviorJournalEntry] {
        days.prefix(5).enumerated().map { index, day in
            BehaviorJournalEntry(id: "daily-metric-refresh-\(index)",
                                 day: day,
                                 createdAt: day,
                                 tags: [behaviorTag])
        }
    }

    var metricsWithoutMorning: [SavedDailyMetric] {
        days.dropLast().enumerated().map { index, day in
            metric(day: day, recovery: index < 5 ? 90 : 50)
        }
    }

    var metricsWithMorning: [SavedDailyMetric] {
        metricsWithoutMorning + [metric(day: days.last!, recovery: 50)]
    }

    func makeStore() -> SessionStore {
        SessionStore(
            restoreInitialization: .init(
                recover: { .retainedMarker },
                loadBaseline: { PersonalBaseline() },
                loadProfile: {
                    AthleteProfile(age: 30,
                                   measuredMaxHR: 190,
                                   maxHRSource: .measured,
                                   updated: nil,
                                   hasCompletedOnboarding: true)
                },
                loadDailyRollups: { DailyRollupStore(loadPersisted: false) }
            ),
            journalAnswers: answers
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func metric(day: Date, recovery: Int) -> SavedDailyMetric {
        SavedDailyMetric(day: day,
                         recoveryPercent: recovery,
                         recoveryConfidence: "local",
                         hrv: nil,
                         restingHR: nil,
                         respiratoryRate: nil,
                         sleepDuration: nil,
                         sleepSpan: nil,
                         sleepStart: nil,
                         sleepEnd: nil,
                         sleepSource: nil,
                         sleepStageSegments: [],
                         sleepConsistencyPercent: nil,
                         strain: nil)
    }
}
