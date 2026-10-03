import XCTest
@testable import Atria

final class AtriaWhoop4CompactIMUCoverageGateTests: XCTestCase {
    /// Physical inrange-38 last-notify compact `0x33` (not 0x34).
    private let liveStationaryFrame = Data(hex:
        "aa9400b5330100006d8ce1018840580695010100030568000a000a00" +
        "3dfa23fa30fa3cfa37fa2dfa30fa39fa2ffa25fac0f7c3f7bff7c7f7" +
        "b5f7b1f7a9f7a8f7bff7bbf785f38ff38bf390f39af392f39af38df3" +
        "95f395f30a000b000800040002000e000900050004000800fdfffcff" +
        "fdfff9fff9ff0000fdfffcfffbfffcfffefffefffdfffffffffffeff" +
        "fffffffffeffffff6b07b094"
    )

    func testHistLastNotifyTrailCannotPassContinuity() {
        let stamps = Self.histLastNotifyDeviceTimestamps
        XCTAssertEqual(stamps.count, 169)
        let verdict = AtriaWhoop4CompactIMUCoverageGate.evaluateContinuity(
            deviceTimestamps: stamps,
            provenance: .histLastNotify
        )
        XCTAssertFalse(verdict.passed)
        XCTAssertEqual(verdict.pairsWithinOneSecond, 0)
        XCTAssertEqual(verdict.medianDeltaSeconds, 824.5)
        XCTAssertEqual(verdict.reason, "provenance_hist_lastNotify_not_live")
    }

    func testLiveSparseStampsStillFailCountAndSpacing() {
        let verdict = AtriaWhoop4CompactIMUCoverageGate.evaluateContinuity(
            deviceTimestamps: Self.histLastNotifyDeviceTimestamps,
            provenance: .live
        )
        XCTAssertFalse(verdict.passed)
        XCTAssertEqual(verdict.reason, "live_frame_count_below_6000")
        XCTAssertEqual(verdict.pairsWithinOneSecond, 0)
    }

    func testSixThousandLiveOneSecondStampsPass() {
        let stamps = (0..<6_000).map { UInt32($0) }
        let verdict = AtriaWhoop4CompactIMUCoverageGate.evaluateContinuity(
            deviceTimestamps: stamps,
            provenance: .live
        )
        XCTAssertTrue(verdict.passed)
        XCTAssertEqual(verdict.frameCount, 6_000)
        XCTAssertEqual(verdict.adjacentPairs, 5_999)
        XCTAssertEqual(verdict.pairsWithinOneSecond, 5_999)
        XCTAssertEqual(verdict.reason, "pass")
    }

    func testLiveSixThousandWithOneGapFails() {
        var stamps = (0..<5_999).map { UInt32($0) }
        stamps.append(5_999 + 40)
        let verdict = AtriaWhoop4CompactIMUCoverageGate.evaluateContinuity(
            deviceTimestamps: stamps,
            provenance: .live
        )
        XCTAssertFalse(verdict.passed)
        XCTAssertEqual(verdict.reason, "adjacent_device_delta_exceeds_1s")
        // Δt = 41 between 5998 and 6039 → 40 missing device-time seconds.
        XCTAssertEqual(verdict.missingCount, 40)
        XCTAssertEqual(verdict.maxDeltaSeconds, 41)
    }

    func testContinuousStampsRecordZeroMissingCount() {
        let stamps = (0..<100).map { UInt32($0) }
        let verdict = AtriaWhoop4CompactIMUCoverageGate.evaluateContinuity(
            deviceTimestamps: stamps,
            provenance: .live
        )
        XCTAssertEqual(verdict.missingCount, 0)
        XCTAssertEqual(verdict.pairsWithinOneSecond, 99)
        XCTAssertEqual(verdict.dictionary["missing_count"] as? Int, 0)
    }

    func testEqualQualityDetectorRejectsLive33AndLeftover2B() {
        XCTAssertNil(
            AtriaWhoop4CompactIMUCoverageGate.equalQualityHistoricalIMUFrame(
                from: liveStationaryFrame
            )
        )
        var leftover = [UInt8](repeating: 0, count: 1932)
        leftover[0] = 0xAA
        leftover[1] = 0x88
        leftover[2] = 0x07
        leftover[4] = 0x2B
        leftover[5] = 0x0B
        XCTAssertNil(
            AtriaWhoop4CompactIMUCoverageGate.equalQualityHistoricalIMUFrame(
                from: Data(leftover)
            )
        )
        XCTAssertFalse(
            AtriaWhoop4CompactIMUCoverageGate.evaluateBackfill(equalQuality34Count: 0).passed
        )
    }

    func testEqualQualityDetectorAcceptsCompactShaped34() {
        var bytes = [UInt8](liveStationaryFrame)
        bytes[4] = 0x34
        let frame = Data(bytes)
        XCTAssertNotNil(
            AtriaWhoop4CompactIMUCoverageGate.equalQualityHistoricalIMUFrame(from: frame)
        )
        XCTAssertTrue(
            AtriaWhoop4CompactIMUCoverageGate.evaluateBackfill(equalQuality34Count: 1).passed
        )
    }

    /// 169 last-notify device timestamps (median Δt 824.5 s, pairs ≤1 s = 0).
    private static let histLastNotifyDeviceTimestamps: [UInt32] = [
        31558765, 31559946, 31561334, 31561474, 31562625, 31563386, 31563454,
        31564535, 31564641, 31565813, 31566676, 31567666, 31567755, 31568036,
        31569075, 31569165, 31570156, 31570215, 31571326, 31572155, 31572716,
        31572805, 31573436, 31574025, 31575015, 31575685, 31679309, 31679869,
        31680429, 31680479, 31681029, 31681129, 31681989, 31682039, 31682519,
        31683359, 31683849, 31684689, 31684769, 31685789, 31685899, 31686029,
        31687012, 31688659, 31689459, 31689731, 31754509, 31756640, 31758275,
        31758956, 31760749, 31763781, 31764569, 31765039, 31765148, 31766453,
        31766613, 31767268, 31769577, 31770418, 31770549, 31772108, 31772169,
        31772278, 31772499, 31773448, 31774338, 31774808, 31775658, 31775888,
        31777589, 31778199, 31778549, 31780920, 31781898, 31783006, 31783995,
        31784848, 31785529, 31785909, 31786048, 31788409, 31789298, 31789439,
        31790838, 31791519, 31795379, 31795599, 31795869, 31795909, 31797027,
        31797209, 31798399, 31798618, 31804811, 31805838, 31805931, 31806966,
        31807269, 31808026, 31808159, 31808467, 31808520, 31809809, 31809945,
        31810279, 31810588, 31810669, 31812409, 31813407, 31815488, 31823938,
        31848913, 31850238, 31851349, 31853918, 31856739, 31859369, 31860939,
        31861929, 31862738, 31862799, 31864069, 31865079, 31865138, 31866168,
        31869648, 31870438, 31871038, 31871858, 31872389, 31872939, 31873468,
        31874018, 31874678, 31875798, 31876618, 31877498, 31883352, 31884429,
        31885399, 31886058, 31886549, 31887169, 31887998, 31890408, 31892398,
        31892568, 31893168, 31893379, 31894028, 31895618, 31919319, 31920436,
        31931799, 31932658, 31933018, 31934688, 31934758, 31935268, 31936248,
        31937379, 31937488, 31938238, 31940018, 31941289, 31945121, 31946165,
        31952676,
    ]
}

private extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        self.init(bytes)
    }
}
