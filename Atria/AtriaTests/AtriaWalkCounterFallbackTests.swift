import XCTest
@testable import Atria

/// Device 2026-08-24: a workout the app itself classified as Walking
/// (22:32–22:53, 21 minutes) carried 1,457 strap counter ticks across 1,308
/// rows — and the gait model published **0 steps**.
///
/// Cause: drained rows sample at ~1.04 Hz (Nyquist 0.52 Hz) while walking runs
/// at 1.7–2.2 Hz, so the alias is not recoverable and
/// `estimateAlignedWindow` correctly declines. Publishing 0 for a real walk is
/// the wrong answer when the counter is present and its scale is validated.
///
/// The fallback is gated on the user's own Walking label because
/// `evidence/2026-07-27-gate4-arm-control-failure` is a physical run where the
/// feet stayed planted and only the strap arm swung — a tick-driven scorer
/// published 166 steps there. Tick rate cannot separate the two shapes.
final class AtriaWalkCounterFallbackTests: XCTestCase {

    private typealias Model = AtriaWhoop4MotionTickStepModel

    // MARK: - The scale is the one the physical corpus counted

    func testPublishedScaleMatchesTheCountedPhysicalCorpus() {
        // evidence/2026-07-27-gate4-prearmed-walk/acceptance.md:
        //   training walk  — 132 counted steps, 155 ticks
        //   held-out walk  — 136 counted steps, 160 ticks (0.0% error)
        let training = Model.publishedSteps(
            motionTicks: 155,
            validation: Model.physicallyValidatedWhoop4V24
        )
        XCTAssertEqual(training, 132,
                       "155 ticks is the counted 132-step training walk")

        let heldOut = Model.publishedSteps(
            motionTicks: 160,
            validation: Model.physicallyValidatedWhoop4V24
        )
        XCTAssertEqual(heldOut, 136,
                       "160 ticks is the counted 136-step held-out walk")
    }

    func testTheRealDeviceWalkWouldPublishAPlausibleCount() {
        // 1,457 gate-passed ticks over 21 minutes.
        let steps = Model.publishedSteps(
            motionTicks: 1_457,
            validation: Model.physicallyValidatedWhoop4V24
        )
        let published = try? XCTUnwrap(steps)
        XCTAssertNotNil(published)
        guard let published else { return }
        XCTAssertGreaterThan(published, 1_000,
                             "a 21-minute walk must not publish ~0")
        XCTAssertLessThan(published, 2_000,
                          "and must not inflate beyond the counted scale")
        // Sanity: the implied cadence must look like walking, not sprinting.
        let cadencePerMinute = Double(published) / 21.0
        XCTAssertGreaterThan(cadencePerMinute, 40)
        XCTAssertLessThan(cadencePerMinute, 140)
    }

    // MARK: - The gate

    func testFallbackIsOffByDefaultSoOnlyAConfirmedWalkCanUseIt() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Atria/AtriaWhoop4MotionTickCompactStore.swift"
            )
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains(
            "allowCounterFallbackForConfirmedWalk: Bool = false"
        ), "the fallback must default OFF")
        XCTAssertTrue(source.contains("guard enabled else { return .completeNoQualifiedEvidence }"),
                      "a disabled fallback must publish nothing at all")

        // And the one production caller must be the walking-filtered path.
        let sessions = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Atria/Sessions.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            sessions.contains("allowCounterFallbackForConfirmedWalk: true"),
            "the walking path opts in explicitly"
        )
        XCTAssertEqual(
            sessions.components(
                separatedBy: "allowCounterFallbackForConfirmedWalk: true"
            ).count - 1,
            1,
            "exactly one caller may enable the fallback"
        )
    }

    func testARestingCounterPublishesNothing() {
        // The corpus's zero-motion rest windows must stay at zero.
        XCTAssertEqual(
            Model.publishedSteps(
                motionTicks: 0,
                validation: Model.physicallyValidatedWhoop4V24
            ),
            0
        )
    }

    func testAnUnmatchedValidationFailsClosed() {
        XCTAssertNil(
            Model.publishedSteps(motionTicks: 1_457, validation: nil),
            "no frozen validation means no published count"
        )
    }
}
