import XCTest
@testable import Atria

/// Recovery-freeze staleness (2026-07-08 Scope 1): the frozen daily recovery is
/// preserved all day, but must RE-MINT when the scored night's inputs change
/// (sleep confirm / EXTEND / adjust) — otherwise the persisted recovery + trend
/// point outlive the night they describe. Locks the pure change-detector so a
/// night edit re-freezes while intra-day strain accrual never does.
final class AtriaRecoveryFreezeTests: XCTestCase {
    private func at(_ h: Double) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + h * 3600) }

    private func metric(sleepEnd: Date? = nil,
                        sleepDuration: TimeInterval? = 7 * 3600,
                        sleepSpan: TimeInterval? = 7.5 * 3600,
                        hrv: Int? = 45,
                        restingHR: Int? = 52,
                        respiratoryRate: Double? = 14,
                        recoveryPercent: Int? = 70,
                        strain: Double? = 5) -> SavedDailyMetric {
        SavedDailyMetric(day: at(0), recoveryPercent: recoveryPercent, recoveryConfidence: "local",
                         hrv: hrv, restingHR: restingHR, respiratoryRate: respiratoryRate,
                         sleepDuration: sleepDuration, sleepSpan: sleepSpan,
                         sleepStart: nil, sleepEnd: sleepEnd, sleepSource: "auto_sleep",
                         sleepStageSegments: [], sleepConsistencyPercent: nil, strain: strain)
    }

    func testUnchangedNightIsNotAChange() {
        let a = metric(sleepEnd: at(6))
        XCTAssertFalse(SessionStore.dailyRecoveryInputsChanged(frozen: a, fresh: a))
    }

    func testExtendedNightEndTriggersRemint() {
        // Wake-then-sleep-again grew the night 0h→6h into 0h→8h.
        let frozen = metric(sleepEnd: at(6), sleepDuration: 6 * 3600)
        let extended = metric(sleepEnd: at(8), sleepDuration: 8 * 3600)
        XCTAssertTrue(SessionStore.dailyRecoveryInputsChanged(frozen: frozen, fresh: extended))
    }

    func testChangedReadinessInputsTriggerRemint() {
        let frozen = metric(sleepEnd: at(6))
        XCTAssertTrue(SessionStore.dailyRecoveryInputsChanged(frozen: frozen, fresh: metric(sleepEnd: at(6), hrv: 52)))
        XCTAssertTrue(SessionStore.dailyRecoveryInputsChanged(frozen: frozen, fresh: metric(sleepEnd: at(6), restingHR: 48)))
        XCTAssertTrue(SessionStore.dailyRecoveryInputsChanged(frozen: frozen, fresh: metric(sleepEnd: at(6), respiratoryRate: 16)))
        XCTAssertTrue(SessionStore.dailyRecoveryInputsChanged(frozen: frozen, fresh: metric(sleepEnd: at(6), sleepSpan: 8 * 3600)))
    }

    func testStrainAccrualOrRecoveryOutputAloneIsNotANightChange() {
        // Strain accrues all day and recovery is the OUTPUT, not an input — a
        // difference in either must NOT re-mint, or the daily freeze is defeated.
        let frozen = metric(sleepEnd: at(6), recoveryPercent: 70, strain: 3)
        let laterInDay = metric(sleepEnd: at(6), recoveryPercent: 55, strain: 12)
        XCTAssertFalse(SessionStore.dailyRecoveryInputsChanged(frozen: frozen, fresh: laterInDay))
    }
}
