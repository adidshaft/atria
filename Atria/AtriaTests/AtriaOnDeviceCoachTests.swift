import XCTest
@testable import Atria

/// Apple's on-device model as the coach (2026-09-27): replies are shown only
/// when every figure is in the data Atria sent, written as digits.
final class AtriaOnDeviceCoachTests: XCTestCase {
    private func payload() -> AtriaCoachPayload {
        let context = AtriaCoachContext(guidance: Coach.guide(recovery: 38, strain: 2),
                                        strain: 0.1, recoveryText: "38%", hrvText: "54 ms",
                                        stressText: "--", baselineSamples: 3, sessionsCount: 4)
        return AtriaCoachPayload.legacy(context: context)
    }

    func testSpelledOutNumbersAreRejected() {
        XCTAssertTrue(AtriaOnDeviceModel.spellsOutNumbers("Recovery is thirty-eight today."),
                      "device 2026-09-27: 'thirty-eight' dodged the digit audit")
        XCTAssertTrue(AtriaOnDeviceModel.spellsOutNumbers("one-thousand-one-hundred seconds"))
        XCTAssertFalse(AtriaOnDeviceModel.spellsOutNumbers("One thing to try: an earlier night."))
        XCTAssertFalse(AtriaOnDeviceModel.spellsOutNumbers("Recovery is 38% today."))
    }

    func testAuditRejectsInventedFigures() {
        let data = payload()
        XCTAssertFalse(AtriaOnDeviceModel.passesAudit("Your resting HR was 49 bpm.", payload: data))
        XCTAssertFalse(AtriaOnDeviceModel.passesAudit("Recovery is thirty-eight.", payload: data))
        XCTAssertTrue(AtriaOnDeviceModel.passesAudit("Take it easy and get to bed early.", payload: data))
    }

    func testReplySplitsIntoTitleAndDetail() {
        let split = AtriaOnDeviceModel.splitTitle("**Ease into today**\nKeep effort light.")
        XCTAssertEqual(split.title, "Ease into today")
        XCTAssertEqual(split.detail, "Keep effort light.")
        XCTAssertEqual(AtriaOnDeviceModel.splitTitle("Just one line.").detail, "Just one line.")
    }

    func testDataBlockIsReadableNotRawSeconds() {
        let block = AtriaOnDeviceModel.dataBlock(for: payload())
        XCTAssertTrue(block.hasPrefix("DATA"))
        XCTAssertFalse(block.contains("sleepSeconds"), "no raw JSON keys")
    }

    func testOnDeviceIsTheDefaultMode() {
        XCTAssertEqual(AtriaAICoachSettings().mode, .local)
        XCTAssertTrue(AtriaCoachProviderFactory.make(settings: AtriaAICoachSettings(), hasAPIKey: false)
                      is AtriaOnDeviceCoachProvider)
    }
}
