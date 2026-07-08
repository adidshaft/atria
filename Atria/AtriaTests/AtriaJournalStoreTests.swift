import XCTest
import UIKit
@testable import Atria

final class AtriaJournalStoreTests: XCTestCase {
    private var directory: URL!
    private var calendar: Calendar!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "GMT")!
    }

    override func tearDown() {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        calendar = nil
        super.tearDown()
    }

    private func makeStore() -> AtriaJournalAnswerStore {
        AtriaJournalAnswerStore(directory: directory)
    }

    private func decodeValue(_ json: String) throws -> AtriaJournalValue {
        try JSONDecoder.atriaJournal.decode(AtriaJournalValue.self, from: Data(json.utf8))
    }

    private func roundTrip(_ value: AtriaJournalValue) throws -> AtriaJournalValue {
        let data = try JSONEncoder.atriaJournal.encode(value)
        return try JSONDecoder.atriaJournal.decode(AtriaJournalValue.self, from: data)
    }

    // MARK: - 0. Typed questions

    func testSubjectiveScaleQuestionsAreWellFormed() throws {
        // Energy + focus (2026-07-08) join the daily journal as scale questions.
        for q in [AtriaJournalTypedQuestion.energyScale, .focusScale] {
            XCTAssertTrue(AtriaJournalTypedQuestion.allCases.contains(q))
            XCTAssertFalse(q.title.isEmpty)
            XCTAssertFalse(q.symbolName.isEmpty)
            XCTAssertFalse(q.insightLabel.isEmpty)
            XCTAssertNil(q.linkedTag, "subjective scales refine no legacy boolean tag")
        }
        // Their answers persist + round-trip via the generic scale value.
        XCTAssertEqual(try roundTrip(.scale(4)), .scale(4))
        // Every question keeps a distinct rawValue so answer series never collide.
        let ids = AtriaJournalTypedQuestion.allCases.map(\.rawValue)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    // MARK: - 1. Codable round-trips and decode-side clamping

    func testJournalValueCodableRoundTripsAndClampsOnDecode() throws {
        // In-range values round-trip unchanged for all five cases.
        let values: [AtriaJournalValue] = [.yes, .no, .timeOfDay(minutes: 930), .quantity(3), .scale(4)]
        for value in values {
            XCTAssertEqual(try roundTrip(value), value)
        }

        // Clamping happens on DECODE, not encode.
        XCTAssertEqual(try decodeValue(#"{"kind":"time","minutes":2000}"#), .timeOfDay(minutes: 1439))
        XCTAssertEqual(try decodeValue(#"{"kind":"time","minutes":-5}"#), .timeOfDay(minutes: 0))
        XCTAssertEqual(try decodeValue(#"{"kind":"quantity","count":99}"#), .quantity(20))
        XCTAssertEqual(try decodeValue(#"{"kind":"quantity","count":-1}"#), .quantity(0))
        XCTAssertEqual(try decodeValue(#"{"kind":"scale","level":9}"#), .scale(5))
        XCTAssertEqual(try decodeValue(#"{"kind":"scale","level":0}"#), .scale(1))
    }

    // MARK: - 2. Unknown kind: strict single-value decode, lossy file load

    func testUnknownKindThrowsOnSingleDecodeButFileLoadIsLossy() throws {
        XCTAssertThrowsError(try decodeValue(#"{"kind":"future"}"#))

        let json = """
        [
          {"questionID":"alcohol.drinks","day":"2026-01-01T00:00:00Z","value":{"kind":"quantity","count":2},"loggedAt":"2026-01-01T20:00:00Z","source":"user"},
          {"questionID":"mystery.q","day":"2026-01-02T00:00:00Z","value":{"kind":"future"},"loggedAt":"2026-01-02T20:00:00Z","source":"user"},
          {"questionID":"mood.scale","day":"2026-01-03T00:00:00Z","value":{"kind":"scale","level":4},"loggedAt":"2026-01-03T20:00:00Z","source":"user"}
        ]
        """
        let fileURL = directory.appendingPathComponent(AtriaJournalAnswerStore.fileName)
        try Data(json.utf8).write(to: fileURL)

        let store = makeStore()
        let history = store.answerHistory(questionID: "alcohol.drinks")
        XCTAssertEqual(store.answers.count, 2, "bad record dropped, good ones kept")
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.value, .quantity(2))
        XCTAssertEqual(store.answerHistory(questionID: "mood.scale").first?.value, .scale(4))
        XCTAssertTrue(store.answerHistory(questionID: "mystery.q").isEmpty)
    }

    // MARK: - 3. record replaces same question+day

    func testRecordReplacesSameQuestionAndDay() {
        let store = makeStore()
        let day = Date(timeIntervalSince1970: 1_750_000_000)
        let now = Date(timeIntervalSince1970: 1_750_050_000)

        store.record(questionID: "mood.scale", day: day, value: .scale(2), now: now, calendar: calendar)
        store.record(questionID: "mood.scale", day: day, value: .scale(5), now: now, calendar: calendar)

        let history = store.answerHistory(questionID: "mood.scale")
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.value, .scale(5))
        XCTAssertEqual(history.first?.day, calendar.startOfDay(for: day))
    }

    // MARK: - 4. removeAnswer removes only the matching day

    func testRemoveAnswerRemovesOnlyMatchingDay() {
        let store = makeStore()
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let dayA = Date(timeIntervalSince1970: 1_750_000_000)
        let dayB = Date(timeIntervalSince1970: 1_750_000_000 + 86_400)

        store.record(questionID: "stress.scale", day: dayA, value: .scale(3), now: now, calendar: calendar)
        store.record(questionID: "stress.scale", day: dayB, value: .scale(4), now: now, calendar: calendar)

        store.removeAnswer(questionID: "stress.scale", day: dayA, calendar: calendar)

        let history = store.answerHistory(questionID: "stress.scale")
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.day, calendar.startOfDay(for: dayB))
        XCTAssertNil(store.answer(questionID: "stress.scale", day: dayA, calendar: calendar))
    }

    // MARK: - 5. latestActivityDay is the max day

    func testLatestActivityDayReturnsMaxDay() {
        let store = makeStore()
        XCTAssertNil(store.latestActivityDay())

        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let earlier = Date(timeIntervalSince1970: 1_750_000_000 - 3 * 86_400)
        let later = Date(timeIntervalSince1970: 1_750_000_000)

        store.record(questionID: "mood.scale", day: later, value: .scale(3), now: now, calendar: calendar)
        store.record(questionID: "alcohol.drinks", day: earlier, value: .quantity(1), now: now, calendar: calendar)

        XCTAssertEqual(store.latestActivityDay(), calendar.startOfDay(for: later))
    }

    // MARK: - 6. prune drops answers older than 400 days on record

    func testRecordPrunesAnswersOlderThan400Days() {
        let store = makeStore()
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let old = calendar.date(byAdding: .day, value: -401, to: now)!
        let recent = calendar.date(byAdding: .day, value: -10, to: now)!

        store.record(questionID: "mood.scale", day: old, value: .scale(2), now: old, calendar: calendar)
        XCTAssertEqual(store.answers.count, 1)

        store.record(questionID: "mood.scale", day: recent, value: .scale(4), now: now, calendar: calendar)

        let history = store.answerHistory(questionID: "mood.scale")
        XCTAssertEqual(history.count, 1, "answer older than 400 days is pruned")
        XCTAssertEqual(history.first?.day, calendar.startOfDay(for: recent))
    }

    // MARK: - 7. answerHistory sorted ascending

    func testAnswerHistoryIsSortedAscendingByDay() {
        let store = makeStore()
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let days = [2, 0, 1].map { Date(timeIntervalSince1970: 1_750_000_000 - Double(86_400 * (5 - $0))) }
        for day in days {
            store.record(questionID: "caffeine.lastTime", day: day, value: .timeOfDay(minutes: 900), now: now, calendar: calendar)
        }

        let history = store.answerHistory(questionID: "caffeine.lastTime")
        XCTAssertEqual(history.count, 3)
        XCTAssertEqual(history.map(\.day), history.map(\.day).sorted())
    }

    // MARK: - 8. persistence round-trip across store instances

    func testPersistenceRoundTripAcrossStoreInstances() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let day = Date(timeIntervalSince1970: 1_750_000_000 - 86_400)

        let first = makeStore()
        first.record(questionID: "alcohol.drinks", day: day, value: .quantity(2), source: "user", now: now, calendar: calendar)
        first.record(questionID: "mood.scale", day: day, value: .scale(4), source: "auto", now: now, calendar: calendar)

        let second = makeStore()
        let drinks = second.answer(questionID: "alcohol.drinks", day: day, calendar: calendar)
        let mood = second.answer(questionID: "mood.scale", day: day, calendar: calendar)

        XCTAssertEqual(drinks?.value, .quantity(2))
        XCTAssertEqual(drinks?.source, "user")
        XCTAssertEqual(mood?.value, .scale(4))
        XCTAssertEqual(mood?.source, "auto")
        XCTAssertEqual(second.answers.count, 2)
    }
}
