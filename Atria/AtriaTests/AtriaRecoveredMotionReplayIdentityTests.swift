import XCTest
@testable import Atria

final class AtriaRecoveredMotionReplayIdentityTests: XCTestCase {
    func testExactPayloadReplayIgnoresHexFormattingDifferences() {
        let compact = makeIdentity(payload: "A10bFF")
        let formatted = makeIdentity(payload: " a1 0B\nff ")

        XCTAssertEqual(compact, formatted)
        XCTAssertEqual(Set([compact, formatted]).count, 1)
    }

    func testDifferentPayloadDoesNotCollapseClockAndCounterCollision() {
        let first = makeIdentity(payload: "a10bff")
        let second = makeIdentity(payload: "a10bfe")

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(Set([first, second]).count, 2)
    }

    func testProvenanceRemainsPartOfReplayIdentity() {
        let historical = makeIdentity(source: "whoop4-history", payload: "a10bff")
        let realtime = makeIdentity(source: "whoop4-realtime", payload: "a10bff")

        XCTAssertNotEqual(historical, realtime)
    }

    func testMalformedPayloadNeverMergesWithWellFormedBytesOfIdenticalDigestInput() {
        // "616263" decodes to the bytes of UTF-8 "abc"; "abc" itself is
        // odd-length and stays malformed. Both digest exactly the bytes
        // [0x61, 0x62, 0x63] — only the domain tag may separate them.
        let wellFormed = makeIdentity(payload: "616263")
        let malformed = makeIdentity(payload: "abc")

        XCTAssertNotEqual(wellFormed, malformed)
        XCTAssertEqual(Set([wellFormed, malformed]).count, 2)
    }

    func testReplayDedupSurvivesProjectedTimestampPrune() {
        // The recovered cache prunes this set by projectedTimestamp while
        // equality stays anchored to the raw frame: a surviving row replayed
        // by the oldest-first drain under a newer clock projection must still
        // match its retained identity, never re-count.
        let retained = makeIdentity(payload: "a10bff",
                                    projectedTimestamp: 1_721_234_567)
        let old = makeIdentity(flashCounter: 122,
                               unixSeconds: 1_721_100_000,
                               payload: "a10bff",
                               projectedTimestamp: 1_721_100_000)
        var identities: Set = [retained, old]

        identities = Set(identities.filter { $0.projectedTimestamp >= 1_721_200_000 })
        XCTAssertEqual(identities.count, 1)

        let replayed = makeIdentity(payload: "a10bff",
                                    projectedTimestamp: 1_721_234_999)
        XCTAssertFalse(identities.insert(replayed).inserted)
        XCTAssertEqual(identities.count, 1)
    }

    private func makeIdentity(
        source: String = "whoop4-history",
        flashCounter: UInt32 = 123,
        unixSeconds: UInt32 = 1_721_234_567,
        payload: String,
        projectedTimestamp: TimeInterval? = nil
    ) -> AtriaRecoveredMotionReplayIdentity {
        AtriaRecoveredMotionReplayIdentity(source: source,
                                           layoutVersion: "whoop4_0x2f_openstrap_v1_v24",
                                           flashCounter: flashCounter,
                                           unixSeconds: unixSeconds,
                                           subsecond: 456,
                                           rawPayloadHex: payload,
                                           projectedTimestamp: projectedTimestamp)
    }
}
