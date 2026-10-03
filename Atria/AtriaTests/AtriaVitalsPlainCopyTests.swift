import XCTest
@testable import Atria

/// 2026-09-02 fixture pass: two Vitals lines still spoke engineering. The
/// motion-quiet skip said it was "waiting for a strap identity", and the
/// detected-activities subtitle's second sentence restated the Confirm and
/// Dismiss buttons under every card.
final class AtriaVitalsPlainCopyTests: XCTestCase {
    func testMotionQuietSkipNamesThePairedStrapInPlainWords() {
        let event = DetectionEvent(kind: "sleepCandidateSkipped", reason: "daytime_quiescence_no_strap",
                                   detail: "raw (source: foreground_edge)")
        XCTAssertEqual(DetectionReasonCopy.text(for: event), "Motion-quiet check needs a paired strap first")
    }

    func testDetectedActivitiesSubtitleIsOneSentence() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaHistorySection.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("subtitle: \"Heart-rate windows Atria noticed but has not counted.\")"))
        XCTAssertFalse(source.contains("Confirm what happened, or dismiss"), "the buttons say it")
    }
}
