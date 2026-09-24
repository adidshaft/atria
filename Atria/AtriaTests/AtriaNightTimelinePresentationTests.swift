import XCTest
@testable import Atria

/// Night timeline view model + morning "what was it?" answers
/// (visual pass 2026-09-24). Synthetic minutes only — no user data.
final class AtriaNightTimelinePresentationTests: XCTestCase {
    typealias A = AtriaNightTimelineAnalyzer
    private let utc = TimeZone(identifier: "UTC")!
    private let posix24 = Locale(identifier: "en_GB")

    private func synthetic(_ count: Int) -> [A.Minute] {
        // 2026-09-23 23:00 UTC
        let t0 = Date(timeIntervalSince1970: 1_790_204_400)
        return (0..<count).map {
            A.Minute(start: t0.addingTimeInterval(Double($0) * 60), heartRate: 60, motion: 0.007,
                     steps: 0, rrIntervals: [], offWrist: false)
        }
    }

    private func walkNight() -> [A.Minute] {
        var m = synthetic(480)
        for i in 150..<170 { m[i].steps = 80; m[i].motion = 0.8; m[i].heartRate = 90 }
        return m
    }

    func testInsightsAreDerivedOnlyFromTheResultAndCapAtThree() {
        let result = A.analyze(walkNight())
        let lines = AtriaNightTimelinePresentation.insights(result, timeZone: utc, locale: posix24)
        XCTAssertLessThanOrEqual(lines.count, 3)
        XCTAssertEqual(lines.first, "Asleep 23:00 · woke 07:00")
        XCTAssertEqual(lines[1], "Up 01:30–01:50")
        XCTAssertTrue(lines[2].hasPrefix("Longest undisturbed stretch "))
    }

    func testNoStageWordsEverAppear() {
        let model = AtriaNightTimelineModel(minutes: walkNight(), timeZone: utc)
        let presentation = AtriaNightTimelinePresentation(model)
        let copy = (presentation?.insights ?? []) + AtriaNightTimelinePresentation.Lane.allCases.map(\.title)
        for word in ["Deep", "REM", "Light", "Core", "stage"] {
            XCTAssertFalse(copy.contains { $0.localizedCaseInsensitiveContains(word) }, word)
        }
    }

    func testNoSleepPlacedMeansNoTimeline() {
        var m = synthetic(120)
        for i in m.indices { m[i].motion = 0.3; m[i].steps = i % 2 == 0 ? 30 : 0 }
        XCTAssertNil(AtriaNightTimelinePresentation(AtriaNightTimelineModel(minutes: m)))
    }

    func testBandsStayInsideThePlottedWindow() throws {
        var m = walkNight()
        m += (0..<120).map { i in
            A.Minute(start: m.last!.start.addingTimeInterval(Double(i + 1) * 60), heartRate: 75,
                     motion: 0.4, steps: 20, rrIntervals: [], offWrist: false)
        }
        let p = try XCTUnwrap(AtriaNightTimelinePresentation(AtriaNightTimelineModel(minutes: m)))
        for band in p.bands {
            XCTAssertGreaterThanOrEqual(band.start, p.domain.lowerBound)
            XCTAssertLessThanOrEqual(band.end, p.domain.upperBound)
        }
        // The morning after wake is capped, not plotted for hours.
        let wake = try XCTUnwrap(A.analyze(m).wake)
        XCTAssertLessThanOrEqual(p.domain.upperBound.timeIntervalSince(wake),
                                 AtriaNightTimelinePresentation.awakeTailLimit)
    }

    // MARK: - Morning prompt answers

    private func freshDefaults() -> UserDefaults {
        let name = "atria.nightprompt.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testQuestionCopy() throws {
        let up = try XCTUnwrap(A.interruptionsToAsk(A.analyze(walkNight())).first)
        XCTAssertEqual(AtriaNightInterruptionPromptCard.question(for: up, timeZone: utc, locale: posix24),
                       "You were up 01:30–01:50 — what was it?")
    }

    func testAnswersAndSkipsClearThePendingQueue() throws {
        let defaults = freshDefaults()
        let asks = A.interruptionsToAsk(A.analyze(walkNight()))
        let up = try XCTUnwrap(asks.first)
        XCTAssertEqual(AtriaNightInterruptionAnswerStore.pending(asks, defaults: defaults).count, asks.count)
        AtriaNightInterruptionAnswerStore.record(.bathroom, for: up, defaults: defaults)
        XCTAssertEqual(AtriaNightInterruptionAnswerStore.answer(for: up, defaults: defaults)?.label, .bathroom)
        XCTAssertFalse(AtriaNightInterruptionAnswerStore.pending(asks, defaults: defaults).contains(up))
        // Re-answering replaces; a skip is stored as nil.
        AtriaNightInterruptionAnswerStore.record(nil, for: up, defaults: defaults)
        XCTAssertEqual(AtriaNightInterruptionAnswerStore.all(defaults: defaults).count, 1)
        XCTAssertTrue(AtriaNightInterruptionAnswerStore.all(defaults: defaults)[0].isSkipped)
    }

    func testSensitiveLabelsNeverLeaveTheDevice() {
        let defaults = freshDefaults()
        let t0 = Date(timeIntervalSince1970: 1_790_210_000)
        for (i, label) in AtriaNightInterruptionLabel.allCases.enumerated() {
            let episode = A.Episode(kind: .up, start: t0.addingTimeInterval(Double(i) * 3_600),
                                    end: t0.addingTimeInterval(Double(i) * 3_600 + 600))
            AtriaNightInterruptionAnswerStore.record(label, for: episode, defaults: defaults)
        }
        let skipped = A.Episode(kind: .restless, start: t0.addingTimeInterval(-3_600),
                                end: t0.addingTimeInterval(-3_000))
        AtriaNightInterruptionAnswerStore.record(nil, for: skipped, defaults: defaults)

        let all = AtriaNightInterruptionAnswerStore.all(defaults: defaults)
        XCTAssertTrue(all.contains { $0.label == .intimacy }, "stored locally")
        let outbound = AtriaNightInterruptionAnswerStore.offDeviceAnswers(all)
        XCTAssertFalse(outbound.contains { $0.label?.isSensitive ?? false })
        XCTAssertFalse(outbound.contains { $0.isSkipped })
        XCTAssertEqual(outbound.count,
                       AtriaNightInterruptionLabel.allCases.filter { !$0.isSensitive }.count)
    }
}
