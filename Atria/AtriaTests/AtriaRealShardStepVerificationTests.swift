import XCTest
@testable import Atria

/// END-TO-END verification against the OWNER'S REAL PULLED SHARDS.
///
/// Everything else about this change was checked with synthetic fixtures or a
/// Python model of the pipeline. This runs the SHIPPED code —
/// `AtriaWhoop4MotionTickCompactStore.motionTickDayEvidenceRead` — directly
/// over the four `.bin` day shards pulled off the device on 2026-08-25, whose
/// filenames already match the store's own `v1-<STRAP>-<bucket>.bin` format.
///
/// Skips (does not fail) when the pull directory is absent, so it stays green
/// on any machine that does not have the owner's data.
final class AtriaRealShardStepVerificationTests: XCTestCase {

    private static let pullDirectory =
        "/private/tmp/claude-501/-Users-amanpandey-projects-atria/"
        + "90cb7ac0-fd92-46ca-acf1-b136c273c440/scratchpad/pull"
    private static let strap = "C125C62E-C432-53E7-BD19-9761251B2C3E"

    private func store() throws -> AtriaWhoop4MotionTickCompactStore {
        let url = URL(fileURLWithPath: Self.pullDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("owner shard pull not present on this machine")
        }
        return AtriaWhoop4MotionTickCompactStore(directoryURL: url)
    }

    /// IST civil day. The shards are UTC-bucketed, so a civil day spans two.
    private func day(_ d: Int) -> (start: Date, end: Date) {
        var c = DateComponents()
        c.year = 2026; c.month = 8; c.day = d
        c.hour = 0; c.minute = 0
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let start = cal.date(from: c)!
        return (start, start.addingTimeInterval(86_400))
    }

    private func steps(forDay d: Int) throws -> (steps: Int, ticks: Int, known: Int)? {
        let store = try store()
        let window = day(d)
        var result: (Int, Int, Int)?
        let done = expectation(description: "read day \(d)")
        // The read asserts it is off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let read = store.motionTickDayEvidenceRead(
                start: window.start,
                end: window.end,
                // Deliberately EMPTY: the bank ledger is a 512-entry FIFO that
                // had already evicted these days. Passing nothing proves the
                // row-derived coverage carries them on its own.
                bankCoverage: [],
                strapIdentifier: Self.strap
            )
            if case .qualified(let evidence) = read {
                result = (evidence.steps,
                          evidence.motionTicks,
                          evidence.knownCoverageSeconds)
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 120)
        return result
    }

    func testRealShardsProduceCredibleDailyStepTotals() throws {
        // Owner's independent expectation: "yesterday my overall should have
        // been atleast 7-8k and 3 days ago, it should have been even more."
        // 08-24 is that "yesterday"; 08-22 is "3 days ago".
        var report: [String] = []
        for d in [22, 23, 24, 25] {
            guard let r = try steps(forDay: d) else {
                report.append("Aug \(d): NOT QUALIFIED")
                continue
            }
            report.append(
                "Aug \(d): steps=\(r.steps) ticks=\(r.ticks) "
                    + "known=\(r.known / 3600)h"
            )
        }
        // Surfaced in the failure message so the numbers are visible even
        // though XCTest swallows stdout.
        let summary = report.joined(separator: " | ")
        try? report.joined(separator: "\n").write(
            toFile: Self.pullDirectory + "/../real-shard-steps.txt",
            atomically: true,
            encoding: .utf8
        )

        guard let augustTwentyFour = try steps(forDay: 24) else {
            return XCTFail("08-24 must qualify. \(summary)")
        }
        XCTAssertGreaterThan(
            augustTwentyFour.steps, 5_000,
            "08-24 was a full active day (cycling + strength + a 21-minute "
                + "walk); it must not read as a few hundred steps. \(summary)"
        )
        XCTAssertLessThan(
            augustTwentyFour.steps, 20_000,
            "and it must not inflate past a believable day. \(summary)"
        )

        guard let augustTwentyTwo = try steps(forDay: 22) else {
            return XCTFail("08-22 must qualify. \(summary)")
        }
        XCTAssertGreaterThan(
            augustTwentyTwo.steps, 4_000,
            "08-22 previously scored ZERO because the ledger had evicted it. "
                + summary
        )
    }

    func testExcludingTheLabelledStrengthBlockLandsOnTheOwnersExpectation() throws {
        // 2026-08-24 as the app itself classified it:
        //   Cycling  21:05:18-21:23:24
        //   Strength 21:25:42-22:31:00   <- 5,232 ticks of pure arm motion
        //   Walking  22:32:00-22:53:16   <- kept; it produces real footfalls
        // Production passes exactly these non-gait spans as `excludedIntervals`.
        let store = try store()
        let window = day(24)
        func ist(_ h: Int, _ m: Int, _ sec: Int) -> Date {
            var c = DateComponents()
            c.year = 2026; c.month = 8; c.day = 24
            c.hour = h; c.minute = m; c.second = sec
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "Asia/Kolkata")!
            return cal.date(from: c)!
        }
        let nonGait = [
            DateInterval(start: ist(21, 5, 18), end: ist(21, 23, 24)),
            DateInterval(start: ist(21, 25, 42), end: ist(22, 31, 0)),
        ]
        var withExclusion: (steps: Int, ticks: Int)?
        let done = expectation(description: "excluded read")
        DispatchQueue.global(qos: .userInitiated).async {
            let read = store.motionTickDayEvidenceRead(
                start: window.start,
                end: window.end,
                bankCoverage: [],
                strapIdentifier: Self.strap,
                excludedIntervals: nonGait
            )
            if case .qualified(let e) = read {
                withExclusion = (e.steps, e.motionTicks)
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 120)

        guard let withExclusion else {
            return XCTFail("08-24 must still qualify after exclusion")
        }
        try? "Aug 24 EXCLUDING non-gait: steps=\(withExclusion.steps) ticks=\(withExclusion.ticks)"
            .write(toFile: Self.pullDirectory + "/../real-shard-excluded.txt",
                   atomically: true, encoding: .utf8)

        // The owner's independent expectation for that day was "at least 7-8k".
        XCTAssertGreaterThan(withExclusion.steps, 6_000,
                             "steps=\(withExclusion.steps)")
        XCTAssertLessThan(withExclusion.steps, 9_500,
                          "the strength block's arm motion must be gone; "
                              + "steps=\(withExclusion.steps)")
    }

    func testDaysTheLedgerForgotAreStillCreditedFromStoredRows() throws {
        // 08-22 and 08-23 held 88,973 and 53,246 decoded rows and scored
        // exactly 0 before row-derived coverage existed.
        for d in [22, 23] {
            guard let r = try steps(forDay: d) else {
                return XCTFail("Aug \(d) must qualify from stored rows alone")
            }
            XCTAssertGreaterThan(r.ticks, 1_000,
                                 "Aug \(d) must recover real counter ticks")
            XCTAssertGreaterThan(r.known, 3_600,
                                 "Aug \(d) must credit real covered time")
        }
    }
}
