import XCTest
@testable import Atria

/// Device 2026-09-02: the confirmed night's 504 motion-receipted stage
/// segments vanished between two pulls with every other field of the record
/// identical, and Today swung between the staged 9h 49m and the gross
/// 11h 22m as the backfill re-added them and the next save erased them
/// again. Every writer passes through the save preparation, so stages are
/// monotonic there: a record re-saved without its stages takes back the
/// authoritative copy's motion-receipted stages when they still validate
/// for the incoming window.
final class AtriaConfirmedSleepStageGuardTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return calendar
    }()

    private var start: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 15, minute: 38))!
    }
    private let spanHours = 8.0

    /// Forty-eight contiguous ten-minute segments; every eighth is awake, so
    /// the staged non-awake time is seven hours of an eight-hour window.
    private func motionStages(prefix: String = SleepStageSegment.motionReceiptIDPrefix) -> [SleepStageSegment] {
        (0..<48).map { index in
            let stage: SleepStageKind = index.isMultiple(of: 8) ? .awake : [.light, .deep, .rem, .sws][index % 4]
            return SleepStageSegment(id: "\(prefix)\(index)",
                                     start: start.addingTimeInterval(Double(index) * 600),
                                     end: start.addingTimeInterval(Double(index + 1) * 600),
                                     stage: stage)
        }
    }

    private func record(stages: [SleepStageSegment]?, endOffset: TimeInterval = 0,
                        motionValidated: Bool = true) -> UserConfirmedSleep {
        let end = start.addingTimeInterval(spanHours * 3_600 + endOffset)
        return UserConfirmedSleep(id: "night",
                                  createdAt: end,
                                  start: start,
                                  end: end,
                                  source: "validated_sleep_window",
                                  confidence: "user_confirmed_motion_validated",
                                  sessions: 1,
                                  samples: 28_000,
                                  avgHR: 58,
                                  peakHR: 90,
                                  restingHR: 54,
                                  hrv: 61,
                                  hrvWindowCount: 12,
                                  duration: 7 * 3_600,
                                  span: spanHours * 3_600 + endOffset,
                                  reason: "test",
                                  motionSource: motionValidated ? "strap_compact_motion" : "none",
                                  motionValidated: motionValidated,
                                  stageSegments: stages,
                                  eventTimeZoneIdentifier: calendar.timeZone.identifier)
    }

    func testStagesValidateAsBuilt() {
        XCTAssertTrue(AtriaSleepStageIntegrity.validates(motionStages(), for: record(stages: nil)))
    }

    func testAStrippedResaveTakesBackValidatedMotionStages() {
        let authoritative = record(stages: motionStages())
        let restored = SessionStore.preservingValidatedMotionStages(record(stages: nil, motionValidated: false),
                                                                    authoritative: authoritative)
        XCTAssertEqual(restored.stageSegments?.count, 48)
        XCTAssertTrue(restored.motionValidated)
        XCTAssertEqual(restored.motionSource, "strap_compact_motion")
        XCTAssertEqual(restored.id, "night")
        XCTAssertEqual(restored.duration, 7 * 3_600, "the record's own fields are untouched")
        let emptied = SessionStore.preservingValidatedMotionStages(record(stages: []), authoritative: authoritative)
        XCTAssertEqual(emptied.stageSegments?.count, 48, "an empty timeline is absent too")
    }

    func testHREstimatesAreNotResurrected() {
        let authoritative = record(stages: motionStages(prefix: "research-hr-estimate-v1-"))
        let kept = SessionStore.preservingValidatedMotionStages(record(stages: nil), authoritative: authoritative)
        XCTAssertNil(kept.stageSegments, "the backfill clears HR estimates on purpose to re-mint them")
    }

    func testAChangedWindowDropsTheOldStages() {
        let authoritative = record(stages: motionStages())
        let grown = SessionStore.preservingValidatedMotionStages(record(stages: nil, endOffset: 3 * 3_600),
                                                                 authoritative: authoritative)
        XCTAssertNil(grown.stageSegments, "stages that no longer validate for the window are not carried")
    }

    func testARecordWithItsOwnStagesAndANewRecordPassThrough() {
        let own = motionStages().prefix(24).map { $0 }
        let incoming = record(stages: own)
        let kept = SessionStore.preservingValidatedMotionStages(incoming, authoritative: record(stages: motionStages()))
        XCTAssertEqual(kept.stageSegments?.count, 24, "an incoming timeline is never overwritten")
        let fresh = SessionStore.preservingValidatedMotionStages(record(stages: nil), authoritative: nil)
        XCTAssertNil(fresh.stageSegments)
    }

    func testGuardSitsInsideTheSavePreparation() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/Sessions.swift"), encoding: .utf8)
        let loop = try XCTUnwrap(source.range(of: "let stagePreserved = Self.preservingValidatedMotionStages("))
        let window = String(source[loop.lowerBound...].prefix(200))
        XCTAssertTrue(window.contains("preserved, authoritative: existingMotionStagedByID[preserved.id])"))
        XCTAssertTrue(window.contains("needPreservingRebase.append(stagePreserved)"),
                      "the stage-preserved record is what the save persists")
        XCTAssertTrue(source.contains("existingMotionStagedByID[sleep.id] = sleep"),
                      "the authoritative index is built from the on-disk records")
    }
}
