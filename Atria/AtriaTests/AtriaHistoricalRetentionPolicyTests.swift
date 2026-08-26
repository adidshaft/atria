import XCTest
@testable import Atria

final class AtriaHistoricalRetentionPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testSelectsOnlySealedChunksWhollyOutsideRawHorizon() {
        // The horizon is FIXED BY THE FIXTURE on purpose. Building this from
        // `.production` silently pinned the product constant, so when the raw
        // horizon moved 14 -> 30 days (df11d6c5, 2026-08-19, "raw data
        // maintained only up to a week or month, but insights are persisted
        // all the time") the 20-day-old chunk fell INSIDE the horizon, nothing
        // was selected, and a boundary test went red for a reason that had
        // nothing to do with the boundary. The product value is pinned
        // separately below, so a future retune fails at a named site instead of
        // collaterally breaking this contract.
        let policy = AtriaHistoricalRetentionPolicy(rawHorizon: 14 * 86_400,
                                                    maximumRawBytes: 512 * 1024 * 1024)
        let old = chunk("old", daysAgoStart: 20, daysAgoEnd: 19, bytes: 10, sealed: true)
        let overlap = chunk("overlap", daysAgoStart: 15, daysAgoEnd: 13, bytes: 10, sealed: true)
        let activeOld = chunk("active", daysAgoStart: 30, daysAgoEnd: 29, bytes: 10, sealed: false)

        let plan = policy.plan(chunks: [overlap, activeOld, old], now: now)

        XCTAssertEqual(plan.candidates.map(\.chunk.identifier), ["old"])
        XCTAssertEqual(plan.candidates.map(\.reason), [.outsideRawHorizon])
        XCTAssertEqual(plan.rawBytesBefore, 30)
        XCTAssertEqual(plan.projectedRawBytes, 20)
    }

    func testProductionRetentionMatchesTheChosenThirtyDayRawTier() {
        // The product decision itself, pinned where a change to it is the
        // point rather than a side effect. 2026-08-19 directive: raw data is
        // kept for "a week or month"; insights are never pruned.
        XCTAssertEqual(AtriaHistoricalRetentionPolicy.production.rawHorizon,
                       30 * 24 * 60 * 60)
        XCTAssertEqual(AtriaHistoricalRetentionPolicy.production.maximumRawBytes,
                       512 * 1024 * 1024)
    }

    func testHardCapPressureChoosesOldestRemainingSealedChunks() {
        let policy = AtriaHistoricalRetentionPolicy(rawHorizon: 14 * 86_400,
                                                    maximumRawBytes: 100)
        let oldest = chunk("oldest", daysAgoStart: 10, daysAgoEnd: 9, bytes: 60, sealed: true)
        let middle = chunk("middle", daysAgoStart: 8, daysAgoEnd: 7, bytes: 60, sealed: true)
        let newest = chunk("newest", daysAgoStart: 2, daysAgoEnd: 1, bytes: 40, sealed: true)

        let plan = policy.plan(chunks: [newest, middle, oldest], now: now)

        XCTAssertEqual(plan.candidates.map(\.chunk.identifier), ["oldest"])
        XCTAssertEqual(plan.candidates.first?.reason, .hardCapPressure)
        XCTAssertEqual(plan.projectedRawBytes, 100)
        XCTAssertTrue(plan.hardCapSatisfied)
    }

    func testActiveWriterIsNeverSelectedEvenWhenItAloneExceedsCap() {
        let policy = AtriaHistoricalRetentionPolicy(rawHorizon: 0, maximumRawBytes: 100)
        let active = chunk("active", daysAgoStart: 2, daysAgoEnd: 1, bytes: 120, sealed: false)

        let plan = policy.plan(chunks: [active], now: now)

        XCTAssertTrue(plan.candidates.isEmpty)
        XCTAssertFalse(plan.hardCapSatisfied)
        XCTAssertEqual(plan.blockedActiveBytes, 120)
    }

    func testAgeSelectionRunsBeforeCapSelectionWithoutDuplicateCandidates() {
        let policy = AtriaHistoricalRetentionPolicy(rawHorizon: 14 * 86_400,
                                                    maximumRawBytes: 50)
        let expired = chunk("expired", daysAgoStart: 30, daysAgoEnd: 29, bytes: 50, sealed: true)
        let recentOldest = chunk("recent-oldest", daysAgoStart: 10, daysAgoEnd: 9, bytes: 50, sealed: true)
        let recentNewest = chunk("recent-newest", daysAgoStart: 2, daysAgoEnd: 1, bytes: 50, sealed: true)

        let plan = policy.plan(chunks: [recentNewest, expired, recentOldest], now: now)

        XCTAssertEqual(plan.candidates.map(\.chunk.identifier), ["expired", "recent-oldest"])
        XCTAssertEqual(plan.candidates.map(\.reason), [.outsideRawHorizon, .hardCapPressure])
        XCTAssertEqual(Set(plan.candidates.map(\.chunk.identifier)).count, 2)
    }

    func testRawStoragePlateausAtThirtyNinetyAndThreeHundredSixtyFiveDays() {
        let dailyBytes: UInt64 = 82 * 1024 * 1024
        for dayCount in [30, 90, 365] {
            let chunks = (0..<dayCount).map { dayOffset in
                let daysAgoEnd = Double(dayCount - dayOffset - 1)
                return chunk("day-\(dayOffset)",
                             daysAgoStart: daysAgoEnd + 1,
                             daysAgoEnd: daysAgoEnd,
                             bytes: dailyBytes,
                             sealed: dayOffset < dayCount - 1)
            }

            let plan = AtriaHistoricalRetentionPolicy.production.plan(chunks: chunks, now: now)

            XCTAssertTrue(plan.hardCapSatisfied, "\(dayCount)-day raw plan must satisfy the cap")
            XCTAssertLessThanOrEqual(plan.projectedRawBytes,
                                     AtriaHistoricalRetentionPolicy.production.maximumRawBytes)
            XCTAssertFalse(plan.candidates.contains(where: { !$0.chunk.isSealed }))
            XCTAssertEqual(plan.blockedActiveBytes, dailyBytes)
            XCTAssertGreaterThan(plan.candidates.count, 0)
        }
    }

    private func chunk(_ id: String,
                       daysAgoStart: Double,
                       daysAgoEnd: Double,
                       bytes: UInt64,
                       sealed: Bool) -> AtriaHistoricalRetentionPolicy.Chunk {
        AtriaHistoricalRetentionPolicy.Chunk(
            identifier: id,
            url: URL(fileURLWithPath: "/tmp/\(id).jsonl"),
            byteCount: bytes,
            earliestTimestamp: now.addingTimeInterval(-daysAgoStart * 86_400),
            latestTimestamp: now.addingTimeInterval(-daysAgoEnd * 86_400),
            isSealed: sealed
        )
    }
}
