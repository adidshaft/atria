import XCTest
@testable import Atria

final class AtriaMotionActivityContextTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testFreshMediumConfidenceAutomotiveEvidenceVetoesWorkout() {
        let context = makeContext(kind: .automotive,
                                  confidence: .medium,
                                  duration: 10 * 60,
                                  evidenceAge: 2)

        let decision = AtriaMotionActivityGate.evaluate(context, now: now)

        XCTAssertTrue(decision.vetoesWorkoutPrompt)
        XCTAssertNil(decision.suggestedActivityType)
    }

    func testLowConfidenceAutomotiveEvidenceAbstains() {
        let context = makeContext(kind: .automotive,
                                  confidence: .low,
                                  duration: 10 * 60,
                                  evidenceAge: 2)

        let decision = AtriaMotionActivityGate.evaluate(context, now: now)

        XCTAssertFalse(decision.vetoesWorkoutPrompt)
        XCTAssertNil(decision.suggestedActivityType)
    }

    func testStaleAutomotiveEvidenceCannotVetoLaterEpisode() {
        let context = makeContext(kind: .automotive,
                                  confidence: .high,
                                  duration: 10 * 60,
                                  evidenceAge: AtriaMotionActivityGate.maximumEvidenceAge + 1)

        let decision = AtriaMotionActivityGate.evaluate(context, now: now)

        XCTAssertFalse(decision.vetoesWorkoutPrompt)
        XCTAssertNil(decision.suggestedActivityType)
    }

    func testSustainedCurrentLocomotionProducesOnlyMatchingSuggestion() {
        let fixtures: [(AtriaMotionActivityContext.Kind, AtriaWorkoutActivityType)] = [
            (.walking, .walking),
            (.running, .running),
            (.cycling, .cycling)
        ]

        for (kind, expected) in fixtures {
            let context = makeContext(kind: kind,
                                      confidence: .medium,
                                      duration: AtriaMotionActivityGate.minimumSuggestionDuration,
                                      evidenceAge: 1)
            let decision = AtriaMotionActivityGate.evaluate(context, now: now)

            XCTAssertFalse(decision.vetoesWorkoutPrompt, "\(kind) must not veto")
            XCTAssertEqual(decision.suggestedActivityType, expected)
            XCTAssertNotEqual(decision.suggestedActivityType, .dance,
                              "native locomotion can never be relabeled as dance")
        }
    }

    func testBriefOrLowConfidenceLocomotionAbstains() {
        let brief = makeContext(kind: .running,
                                confidence: .high,
                                duration: AtriaMotionActivityGate.minimumSuggestionDuration - 1,
                                evidenceAge: 1)
        let uncertain = makeContext(kind: .walking,
                                    confidence: .low,
                                    duration: 10 * 60,
                                    evidenceAge: 1)

        XCTAssertNil(AtriaMotionActivityGate.evaluate(brief, now: now).suggestedActivityType)
        XCTAssertNil(AtriaMotionActivityGate.evaluate(uncertain, now: now).suggestedActivityType)
    }

    func testStationaryAndAmbiguousContextsAbstainWithoutBlockingStrength() {
        for kind in [AtriaMotionActivityContext.Kind.stationary, .unknown] {
            let decision = AtriaMotionActivityGate.evaluate(
                makeContext(kind: kind,
                            confidence: .high,
                            duration: 10 * 60,
                            evidenceAge: 1),
                now: now
            )

            XCTAssertFalse(decision.vetoesWorkoutPrompt)
            XCTAssertNil(decision.suggestedActivityType)
        }
    }

    func testFutureOrUnrefreshedEvidenceAbstains() {
        let future = AtriaMotionActivityContext(kind: .cycling,
                                                confidence: .high,
                                                startedAt: now.addingTimeInterval(10),
                                                observedAt: now.addingTimeInterval(10))
        let neverObserved = AtriaMotionActivityContext.unknown

        XCTAssertEqual(AtriaMotionActivityGate.evaluate(future, now: now),
                       .init(vetoesWorkoutPrompt: false, suggestedActivityType: nil))
        XCTAssertEqual(AtriaMotionActivityGate.evaluate(neverObserved, now: now),
                       .init(vetoesWorkoutPrompt: false, suggestedActivityType: nil))
    }

    func testDeniedPhoneContextFallbackCannotVetoOrInventAnActivityType() {
        let decision = AtriaMotionActivityGate.evaluate(.unknown, now: now)

        XCTAssertFalse(decision.vetoesWorkoutPrompt)
        XCTAssertNil(decision.suggestedActivityType)
    }

    @MainActor
    func testDiagnosticsThrottleUnchangedRefreshesButRetainLatestCheckpoint() throws {
        let defaults = try makeDefaults()
        let diagnostics = AtriaMotionActivityDiagnostics(defaults: defaults)
        let context = makeContext(kind: .walking,
                                  confidence: .medium,
                                  duration: 5 * 60,
                                  evidenceAge: 1)
        let decision = AtriaMotionActivityGate.evaluate(context, now: now)

        XCTAssertTrue(diagnostics.record(context: context,
                                         decision: decision,
                                         authorization: "authorized",
                                         now: now))
        let first = try XCTUnwrap(diagnostics.snapshot())
        XCTAssertFalse(diagnostics.record(context: context,
                                          decision: decision,
                                          authorization: "authorized",
                                          now: now.addingTimeInterval(30)))
        XCTAssertEqual(diagnostics.snapshot()?.persistedAt, first.persistedAt)

        let checkpointAt = now.addingTimeInterval(
            AtriaMotionActivityDiagnostics.minimumUnchangedWriteInterval
        )
        XCTAssertTrue(diagnostics.record(context: context,
                                         decision: decision,
                                         authorization: "authorized",
                                         now: checkpointAt))
        XCTAssertEqual(diagnostics.snapshot()?.persistedAt, checkpointAt)
    }

    @MainActor
    func testDiagnosticsPersistMeaningfulDecisionChangeWithoutWaitingForThrottle() throws {
        let defaults = try makeDefaults()
        let diagnostics = AtriaMotionActivityDiagnostics(defaults: defaults)
        let automotive = makeContext(kind: .automotive,
                                     confidence: .medium,
                                     duration: 5 * 60,
                                     evidenceAge: 1)
        XCTAssertTrue(diagnostics.record(context: automotive,
                                         decision: .init(vetoesWorkoutPrompt: false,
                                                         suggestedActivityType: nil),
                                         authorization: "authorized",
                                         now: now))

        XCTAssertTrue(diagnostics.record(context: automotive,
                                         decision: .init(vetoesWorkoutPrompt: true,
                                                         suggestedActivityType: nil),
                                         authorization: "authorized",
                                         now: now.addingTimeInterval(1)))
        let snapshot = try XCTUnwrap(diagnostics.snapshot())
        XCTAssertEqual(snapshot.decision, "veto_workout_prompt")
        XCTAssertEqual(snapshot.persistedAt, now.addingTimeInterval(1))
    }

    @MainActor
    func testStoppedDiagnosticsErasePriorEvidenceAndCannotLeakStaleVeto() throws {
        let defaults = try makeDefaults()
        let diagnostics = AtriaMotionActivityDiagnostics(defaults: defaults)
        let automotive = makeContext(kind: .automotive,
                                     confidence: .high,
                                     duration: 10 * 60,
                                     evidenceAge: 1)
        diagnostics.record(context: automotive,
                           decision: AtriaMotionActivityGate.evaluate(automotive, now: now),
                           authorization: "authorized",
                           now: now)

        diagnostics.recordStopped(authorization: "authorized",
                                  now: now.addingTimeInterval(2))
        let stopped = try XCTUnwrap(diagnostics.snapshot())
        XCTAssertEqual(stopped.monitorState, "stopped")
        XCTAssertEqual(stopped.kind, "unknown")
        XCTAssertEqual(stopped.confidence, "low")
        XCTAssertEqual(stopped.decision, "abstain")
        XCTAssertNil(stopped.startedAt)
        XCTAssertNil(stopped.observedAt)
    }

    @MainActor
    private func makeDefaults() throws -> UserDefaults {
        let name = "AtriaMotionActivityContextTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func makeContext(kind: AtriaMotionActivityContext.Kind,
                             confidence: AtriaMotionActivityContext.Confidence,
                             duration: TimeInterval,
                             evidenceAge: TimeInterval) -> AtriaMotionActivityContext {
        AtriaMotionActivityContext(kind: kind,
                                   confidence: confidence,
                                   startedAt: now.addingTimeInterval(-duration),
                                   observedAt: now.addingTimeInterval(-evidenceAge))
    }
}
