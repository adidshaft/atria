import XCTest
@testable import Atria

final class AtriaPhysiologicalStrainTargetTests: XCTestCase {
    private func defaults() throws -> (UserDefaults, String) {
        let name = "AtriaPhysiologicalStrainTargetTests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: name)), name)
    }

    func testTargetPersistsAcrossCivilMidnightWithinSameWakeCycle() throws {
        let (defaults, name) = try defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let wake = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2034, month: 1, day: 4, hour: 19
        )))

        let beforeMidnight = try XCTUnwrap(AtriaDailyStrainTargetStore.resolve(
            recovery: 70,
            load: .learning,
            cycleStart: wake,
            now: wake.addingTimeInterval(60),
            calendar: calendar,
            defaults: defaults
        ))
        let afterMidnight = try XCTUnwrap(AtriaDailyStrainTargetStore.resolve(
            recovery: 70,
            load: .learning,
            cycleStart: wake,
            now: wake.addingTimeInterval(6 * 3_600),
            calendar: calendar,
            defaults: defaults
        ))

        XCTAssertEqual(afterMidnight, beforeMidnight)
        XCTAssertEqual(afterMidnight.day, wake)
    }

    func testNewWakeOrChangedRecoveryRemintsTarget() throws {
        let (defaults, name) = try defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let wake = Date(timeIntervalSince1970: 2_020_000_000)
        let first = try XCTUnwrap(AtriaDailyStrainTargetStore.resolve(
            recovery: 40,
            load: .learning,
            cycleStart: wake,
            now: wake,
            defaults: defaults
        ))
        let changedRecovery = try XCTUnwrap(AtriaDailyStrainTargetStore.resolve(
            recovery: 80,
            load: .learning,
            cycleStart: wake,
            now: wake.addingTimeInterval(60),
            defaults: defaults
        ))
        XCTAssertNotEqual(changedRecovery.target, first.target)
        XCTAssertEqual(changedRecovery.recovery, 80)

        let nextWake = wake.addingTimeInterval(24 * 3_600)
        let nextCycle = try XCTUnwrap(AtriaDailyStrainTargetStore.resolve(
            recovery: 80,
            load: .learning,
            cycleStart: nextWake,
            now: nextWake,
            defaults: defaults
        ))
        XCTAssertEqual(nextCycle.day, nextWake)
        XCTAssertNotEqual(nextCycle.createdAt, changedRecovery.createdAt)
    }

    func testUnattributedRecoveryInvalidatesStaleTargetButHydrationDoesNot() throws {
        let (defaults, name) = try defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let wake = Date(timeIntervalSince1970: 2_030_000_000)
        let target = try XCTUnwrap(AtriaDailyStrainTargetStore.resolve(
            recovery: 60,
            load: .learning,
            cycleStart: wake,
            now: wake,
            defaults: defaults
        ))

        XCTAssertEqual(AtriaDailyStrainTargetStore.resolve(
            recovery: nil,
            load: .learning,
            recoveryIsAttributedToCurrentDay: true,
            cycleStart: wake,
            now: wake.addingTimeInterval(30),
            defaults: defaults
        ), target, "temporary hydration must not make an established target flicker")

        XCTAssertNil(AtriaDailyStrainTargetStore.resolve(
            recovery: nil,
            load: .learning,
            recoveryIsAttributedToCurrentDay: false,
            cycleStart: wake,
            now: wake.addingTimeInterval(60),
            defaults: defaults
        ))
        XCTAssertNil(AtriaDailyStrainTargetStore.loadSnapshot(defaults: defaults))
    }
}
