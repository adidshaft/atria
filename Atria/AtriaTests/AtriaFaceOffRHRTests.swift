import XCTest
@testable import Atria

/// Face-Off RHR row (2026-07-07): the payload's optional `h` field must
/// round-trip through the link encoding, clamp against crafted values, and
/// stay compatible with links minted before the field existed.
final class AtriaFaceOffRHRTests: XCTestCase {
    private func makePayload(h: Int?) -> AtriaFaceOffPayload {
        AtriaFaceOffPayload(v: AtriaFaceOffPayload.currentVersion,
                            name: "Sam",
                            endEpochDay: 20_600,
                            days: [.init(o: 0, r: 70, s: 8.5, z: 7.2, h: h)])
    }

    func testRestingHRRoundTripsThroughLink() throws {
        let encoded = try XCTUnwrap(AtriaFaceOff.encode(makePayload(h: 55)))
        let decoded = try XCTUnwrap(AtriaFaceOff.decode(encoded))
        XCTAssertEqual(decoded.days.first?.h, 55)
        XCTAssertEqual(decoded.averageRestingHR, 55)
    }

    func testLinkWithoutRestingHRStillDecodes() throws {
        let encoded = try XCTUnwrap(AtriaFaceOff.encode(makePayload(h: nil)))
        let decoded = try XCTUnwrap(AtriaFaceOff.decode(encoded))
        XCTAssertNil(decoded.days.first?.h)
        XCTAssertNil(decoded.averageRestingHR)
        XCTAssertEqual(decoded.averageRecovery, 70)
    }

    func testCraftedRestingHRIsClamped() throws {
        let encoded = try XCTUnwrap(AtriaFaceOff.encode(makePayload(h: 9999)))
        let decoded = try XCTUnwrap(AtriaFaceOff.decode(encoded))
        XCTAssertEqual(decoded.days.first?.h, 120)
    }
}
