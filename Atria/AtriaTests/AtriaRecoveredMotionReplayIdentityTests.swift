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

    private func makeIdentity(
        source: String = "whoop4-history",
        payload: String
    ) -> AtriaRecoveredMotionReplayIdentity {
        AtriaRecoveredMotionReplayIdentity(source: source,
                                           layoutVersion: "whoop4_0x2f_openstrap_v1_v24",
                                           flashCounter: 123,
                                           unixSeconds: 1_721_234_567,
                                           subsecond: 456,
                                           rawPayloadHex: payload)
    }
}
