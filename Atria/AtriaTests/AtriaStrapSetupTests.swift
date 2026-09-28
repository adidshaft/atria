import CoreBluetooth
import XCTest
@testable import Atria

final class AtriaStrapSetupTests: XCTestCase {
    typealias S = AtriaStrapSetup

    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func snap(_ radio: S.Radio = .poweredOn, _ link: S.Link = .searching,
                      secure: S.SecureCheck = .notStarted, run: Int = 0,
                      errors: Int = 0, lastError: S.LinkError? = nil, seen: Int = 0,
                      hr: Int = 0, battery: Int? = nil, charging: Bool = false) -> S.Snapshot {
        S.Snapshot(radio: radio, link: link,
                   signals: S.TransportSignals(strapsSeen: seen, linkErrorCount: errors, lastLinkError: lastError,
                                               secureCheck: secure, secureCheckRun: run),
                   heartRate: hr, strapBattery: battery, strapCharging: charging)
    }

    /// Feeds snapshots at the given offsets (seconds) and returns the verdict at `at`.
    private func run(_ timeline: [(TimeInterval, S.Snapshot)], at: TimeInterval) -> (S.Tracker, S.Verdict) {
        var tracker = S.Tracker(now: t0, snapshot: timeline[0].1)
        for (offset, s) in timeline.dropFirst() { tracker.observe(s, now: t0 + offset) }
        return (tracker, S.evaluate(tracker.attempt, now: t0 + at))
    }

    func testBluetoothOffAndDeniedAreClassifiedWithTheRightAction() {
        let off = run([(0, snap(.poweredOff, .idle))], at: 1).1
        XCTAssertEqual(off.problem, .bluetoothOff)
        XCTAssertEqual(off.problem?.action, .wait, "turning Bluetooth on resumes setup by itself")
        XCTAssertEqual(off.state(.bluetooth), .problem)
        XCTAssertEqual(off.state(.find), .waiting)

        let denied = run([(0, snap(.unauthorized, .idle))], at: 1).1
        XCTAssertEqual(denied.problem, .bluetoothDenied)
        XCTAssertEqual(denied.problem?.action, .openSettings)
    }

    func testRadioStartupHasABudget() {
        XCTAssertNil(run([(0, snap(.unknown, .idle))], at: 3).1.problem)
        XCTAssertEqual(run([(0, snap(.unknown, .idle))], at: 3).1.state(.bluetooth), .working)
        XCTAssertEqual(run([(0, snap(.resetting, .idle))], at: S.radioBudget + 1).1.problem, .bluetoothUnavailable)
    }

    func testNotFoundAfterBudgetThenRecoversWhenTheStrapAppears() {
        let searching = run([(0, snap())], at: 10).1
        XCTAssertNil(searching.problem)
        XCTAssertEqual(searching.state(.find), .working)

        let (tracker, lost) = run([(0, snap())], at: S.findBudget + 1)
        XCTAssertEqual(lost.problem, .strapNotFound)
        XCTAssertEqual(lost.problem?.code, "AT-201")
        XCTAssertTrue(lost.detail.contains("Still looking"), "problem is advisory while scanning continues")

        var later = tracker
        later.observe(snap(.poweredOn, .connecting, seen: 1), now: t0 + S.findBudget + 2)
        let connecting = S.evaluate(later.attempt, now: t0 + S.findBudget + 3)
        XCTAssertNil(connecting.problem)
        XCTAssertEqual(connecting.state(.find), .done)
    }

    func testConnectHasABudget() {
        let v = run([(0, snap()), (2, snap(.poweredOn, .connecting))], at: 2 + S.connectBudget + 1).1
        XCTAssertEqual(v.problem, .connectTimedOut)
    }

    func testSecureCheckPromptsForPairThenReadyLatchesThroughDrops() {
        let timeline: [(TimeInterval, S.Snapshot)] = [
            (0, snap()),
            (2, snap(.poweredOn, .connecting)),
            (3, snap(.poweredOn, .connected, secure: .running, run: 1)),
        ]
        let early = run(timeline, at: 5).1
        XCTAssertEqual(early.headline, "Pairing securely…")
        XCTAssertEqual(early.state(.pair), .working)
        let prompt = run(timeline, at: 3 + S.pairPromptHint + 1).1
        XCTAssertEqual(prompt.headline, "Tap Pair on your iPhone")

        var (tracker, _) = run(timeline, at: 3)
        tracker.observe(snap(.poweredOn, .connected, secure: .confirmed, run: 1), now: t0 + 12)
        XCTAssertTrue(S.evaluate(tracker.attempt, now: t0 + 12).isReady)
        for i in 0..<5 {
            tracker.observe(snap(.poweredOn, .searching), now: t0 + 13 + Double(i) * 2)
            tracker.observe(snap(.poweredOn, .connected), now: t0 + 14 + Double(i) * 2)
        }
        let after = S.evaluate(tracker.attempt, now: t0 + 200)
        XCTAssertTrue(after.isReady, "verification latches; later link blips never un-verify setup")
        XCTAssertNil(after.problem)
    }

    func testVerifyBudget() {
        let v = run([(0, snap(.poweredOn, .connected, secure: .running, run: 1))], at: S.verifyBudget + 1).1
        XCTAssertEqual(v.problem, .verifyTimedOut)
        let stuck = run([(0, snap(.poweredOn, .connected))], at: S.verifyBudget + 1).1
        XCTAssertEqual(stuck.problem, .verifyTimedOut, "a check that never starts cannot spin forever either")
    }

    func testClassifiedLinkErrorsNameTheExactFix() {
        let bond = run([(0, snap()), (3, snap(errors: 1, lastError: .bondRemoved))], at: 4).1
        XCTAssertEqual(bond.problem, .pairedElsewhere)
        XCTAssertEqual(bond.state(.pair), .problem)
        XCTAssertTrue(bond.problem!.steps[0].contains("Forget This Device"))
        XCTAssertTrue(S.Problem.pairingNotCompleted.steps[0].contains("Forget This Device"),
                      "the stale-key fix comes first (first iPhone run took four blind retries)")

        let declined = run([(0, snap(.poweredOn, .connected)),
                            (1, snap(.poweredOn, .connected, secure: .running, run: 1)),
                            (20, snap(.poweredOn, .connected, secure: .securityRequired, run: 1))], at: 21).1
        XCTAssertEqual(declined.problem, .pairingNotCompleted)

        let full = run([(0, snap()), (1, snap(errors: 1, lastError: .tooManyPairedDevices))], at: 2).1
        XCTAssertEqual(full.problem, .tooManyPairedDevices)
    }

    func testRetryIgnoresStaleVerdictsButNotNewOnes() {
        var (tracker, v) = run([(0, snap(.poweredOn, .connected, secure: .securityRequired, run: 1,
                                          errors: 2, lastError: .bondRemoved))], at: 1)
        // Verdicts that existed before this attempt began do not count.
        XCTAssertNil(v.problem)
        tracker.observe(snap(.poweredOn, .connected, secure: .securityRequired, run: 1, errors: 2, lastError: .bondRemoved),
                        now: t0 + 5)
        XCTAssertNil(S.evaluate(tracker.attempt, now: t0 + 5).problem)
        // A new run that fails again does count.
        tracker.observe(snap(.poweredOn, .connected, secure: .running, run: 2, errors: 2), now: t0 + 6)
        tracker.observe(snap(.poweredOn, .connected, secure: .securityRequired, run: 2, errors: 2), now: t0 + 20)
        XCTAssertEqual(S.evaluate(tracker.attempt, now: t0 + 20).problem, .pairingNotCompleted)
        // Try again: fresh attempt, the failure clears until a newer run fails.
        tracker.restart(now: t0 + 21, snapshot: snap(.poweredOn, .connected, secure: .securityRequired, run: 2, errors: 2))
        v = S.evaluate(tracker.attempt, now: t0 + 22)
        XCTAssertNil(v.problem)
        XCTAssertEqual(tracker.effective(snap(.poweredOn, .connected, secure: .securityRequired, run: 2)).signals.secureCheck,
                       .notStarted)
    }

    func testRepeatedDropsBeforeVerificationAreUnstable() {
        var timeline: [(TimeInterval, S.Snapshot)] = [(0, snap())]
        for i in 0..<S.maxDrops {
            timeline.append((Double(i * 4 + 1), snap(.poweredOn, .connected)))
            timeline.append((Double(i * 4 + 3), snap(.poweredOn, .searching)))
        }
        let (tracker, v) = run(timeline, at: 20)
        XCTAssertEqual(tracker.attempt.drops, S.maxDrops)
        XCTAssertEqual(v.problem, .linkUnstable)
    }

    /// 2026-09-24 iPhone run: the transport rebuilt its Bluetooth manager
    /// (radio briefly unknown) while the user re-paired; that is not a drop.
    func testRadioResetDropsDoNotCountAsUnstable() {
        var timeline: [(TimeInterval, S.Snapshot)] = [(0, snap())]
        for i in 0..<(S.maxDrops + 2) {
            timeline.append((Double(i * 4 + 1), snap(.poweredOn, .connected)))
            timeline.append((Double(i * 4 + 2), snap(.unknown, .connecting)))
        }
        let (tracker, v) = run(timeline, at: Double((S.maxDrops + 2) * 4))
        XCTAssertEqual(tracker.attempt.drops, 0)
        XCTAssertNotEqual(v.problem, .linkUnstable)
    }

    func testOrphanedStrapHistoryAbortOnlyWhenSafe() {
        typealias B = AtriaBLEManager
        XCTAssertTrue(B.shouldAbortOrphanedStrapHistory(linkConnected: true, heartRateThisConnection: false,
                                                        appOwnsHistoryTransfer: false, pairingCheckInFlight: false))
        XCTAssertFalse(B.shouldAbortOrphanedStrapHistory(linkConnected: true, heartRateThisConnection: true,
                                                         appOwnsHistoryTransfer: false, pairingCheckInFlight: false),
                       "HR flowing: nothing is orphaned")
        XCTAssertFalse(B.shouldAbortOrphanedStrapHistory(linkConnected: true, heartRateThisConnection: false,
                                                         appOwnsHistoryTransfer: true, pairingCheckInFlight: false),
                       "never abort the app's own transfer")
        XCTAssertFalse(B.shouldAbortOrphanedStrapHistory(linkConnected: true, heartRateThisConnection: false,
                                                         appOwnsHistoryTransfer: false, pairingCheckInFlight: true))
        XCTAssertFalse(B.shouldAbortOrphanedStrapHistory(linkConnected: false, heartRateThisConnection: false,
                                                         appOwnsHistoryTransfer: false, pairingCheckInFlight: false))
    }

    func testHeartRateIsShownButNeverAGate() {
        let noHR = run([(0, snap(.poweredOn, .connected, secure: .confirmed, run: 1))], at: 1).1
        XCTAssertTrue(noHR.isReady)
        XCTAssertEqual(noHR.state(.heartRate), .working)
        XCTAssertNil(noHR.heartRate)
        XCTAssertTrue(noHR.detail.contains("wrist"))

        XCTAssertEqual(noHR.scene, .wear)
        let loose = run([(0, snap(.poweredOn, .connected, secure: .confirmed, run: 1))],
                        at: S.heartRateHintAfter + 1).1
        XCTAssertTrue(loose.isReady, "fit advice never blocks setup")
        XCTAssertEqual(loose.state(.heartRate), .problem)
        XCTAssertTrue(loose.detail.contains("wrist bone"))

        let live = run([(0, snap(.poweredOn, .connected, secure: .confirmed, run: 1, hr: 64))], at: 1).1
        XCTAssertEqual(live.headline, "64 bpm")
        XCTAssertEqual(live.state(.heartRate), .done)
        XCTAssertEqual(live.heartRate, 64)
    }

    func testLowStrapBatteryWarnsUnlessCharging() {
        XCTAssertNotNil(run([(0, snap(battery: 9))], at: 1).1.batteryWarning)
        XCTAssertNil(run([(0, snap(battery: 9, charging: true))], at: 1).1.batteryWarning)
        XCTAssertNil(run([(0, snap(battery: 60))], at: 1).1.batteryWarning)
    }

    func testCoreBluetoothErrorClassification() {
        XCTAssertEqual(S.LinkError.classify(domain: CBErrorDomain, code: 14), .bondRemoved)
        XCTAssertEqual(S.LinkError.classify(domain: CBErrorDomain, code: 15), .pairingNotCompleted)
        XCTAssertEqual(S.LinkError.classify(domain: CBATTErrorDomain, code: 0x05), .pairingNotCompleted)
        XCTAssertEqual(S.LinkError.classify(domain: CBErrorDomain, code: 6), .connectionTimedOut)
        XCTAssertEqual(S.LinkError.classify(domain: CBErrorDomain, code: 16), .tooManyPairedDevices)
        XCTAssertNil(S.LinkError.classify(domain: CBErrorDomain, code: 7), "range loss is a drop, not an error")
        XCTAssertNil(S.LinkError.classify(domain: NSPOSIXErrorDomain, code: 14))
    }

    func testEveryProblemIsCodedConciseAndActionable() {
        let codes = S.Problem.allCases.map(\.code)
        XCTAssertEqual(Set(codes).count, codes.count, "codes are unique")
        for p in S.Problem.allCases {
            XCTAssertTrue(p.code.hasPrefix("AT-"))
            XCTAssertFalse(p.title.isEmpty)
            XCTAssertTrue((1...3).contains(p.steps.count), "\(p.code): 1–3 short steps, not a wall of text")
            XCTAssertTrue(p.steps.allSatisfy { $0.count <= 110 }, "\(p.code): steps stay short")
        }
    }

    /// Every reachable state resolves to ready or a coded problem within the
    /// longest budget: the screen can never spin without an explanation.
    func testNoStateSpinsPastTheLongestBudget() {
        let horizon = max(S.findBudget, S.connectBudget, S.verifyBudget, S.radioBudget) + 1
        let radios: [S.Radio] = [.unknown, .resetting, .unsupported, .unauthorized, .poweredOff, .poweredOn]
        let links: [S.Link] = [.idle, .searching, .connecting, .connected]
        let checks: [S.SecureCheck] = [.notStarted, .running, .confirmed, .securityRequired, .failed,
                                       .timedOut, .interrupted, .skipped]
        for radio in radios {
            for link in links {
                for check in checks {
                    let v = run([(0, snap(radio, link, secure: check, run: 0)),
                                 (1, snap(radio, link, secure: check, run: 1))], at: horizon).1
                    XCTAssertTrue(v.isReady || v.problem != nil,
                                  "\(radio)/\(link)/\(check) still spinning after \(horizon)s: \(v.headline)")
                }
            }
        }
    }

    func testOnboardingIsAFourPageFlowWithoutSwipePaging() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaOnboardingFlow.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains(".tabViewStyle(.page"), "a paged TabView lets a swipe skip strap setup")
        XCTAssertTrue(source.contains("case welcome\n        case strap\n        case you\n        case tonight"))
        XCTAssertTrue(source.contains("StrapSetupPanel(setup: strapSetup"))
    }
}

final class AtriaR10LiveControlTests: XCTestCase {
    private func cmd(enabled: Bool = true, connected: Bool = true, hr: Bool = true, history: Bool = false,
                     pairing: Bool = false, power: Bool = true, frames: Bool = false,
                     since: TimeInterval? = nil, offSent: Bool = false) -> AtriaBLEManager.R10LiveCommand? {
        AtriaBLEManager.r10LiveCommand(enabled: enabled, linkConnected: connected, heartRateFresh: hr,
                                       appOwnsHistoryTransfer: history, pairingCheckInFlight: pairing,
                                       liveAllowedByPower: power, r10FramesFresh: frames,
                                       secondsSinceLastOn: since, offAlreadySent: offSent)
    }

    func testTurnsOnOnlyOnASettledBondedLinkWithoutFrames() {
        XCTAssertEqual(cmd(), .on)
        XCTAssertNil(cmd(hr: false), "no HR yet: link not proven")
        XCTAssertNil(cmd(frames: true), "3F latches on the strap; frames already flowing")
        XCTAssertNil(cmd(since: 30), "at most one on-command per resend window")
        XCTAssertEqual(cmd(since: AtriaBLEManager.r10LiveResendAfter + 1), .on,
                       "after a history transfer quiets R10, live comes back")
    }

    /// Review 2026-09-24: a strap that never answers 3F/01 got a write every
    /// 120 s all day. Unanswered resends now double up to 30 min.
    func testUnansweredOnBacksOffToACeiling() {
        typealias B = AtriaBLEManager
        XCTAssertEqual(B.r10LiveResendInterval(unansweredOnAttempts: 0), 120)
        XCTAssertEqual(B.r10LiveResendInterval(unansweredOnAttempts: 1), 120)
        XCTAssertEqual(B.r10LiveResendInterval(unansweredOnAttempts: 2), 240)
        XCTAssertEqual(B.r10LiveResendInterval(unansweredOnAttempts: 4), 960)
        XCTAssertEqual(B.r10LiveResendInterval(unansweredOnAttempts: 40), B.r10LiveResendCeiling)
        XCTAssertNil(B.r10LiveCommand(enabled: true, linkConnected: true, heartRateFresh: true,
            appOwnsHistoryTransfer: false, pairingCheckInFlight: false, liveAllowedByPower: true,
            r10FramesFresh: false, secondsSinceLastOn: 200, offAlreadySent: false,
            unansweredOnAttempts: 2), "second unanswered resend waits 240 s")
    }

    /// 2026-09-28: R10 streamed all night and the strap ran flat; steps are
    /// the only thing it serves. Pause it when nothing needs it.
    func testIdlePausePausesStillnessAndChargingButNeverTheForegroundOrARise() {
        typealias B = AtriaBLEManager
        let quiet = B.r10IdleQuietAfter
        XCTAssertTrue(B.r10IdlePause(appForeground: false, strapCharging: false,
                                     stepsQuietFor: quiet, heartRate: 58, restingHeartRate: 55),
                      "asleep: no steps for 20 min, HR near resting")
        XCTAssertFalse(B.r10IdlePause(appForeground: false, strapCharging: false,
                                      stepsQuietFor: quiet - 60, heartRate: 58, restingHeartRate: 55))
        XCTAssertFalse(B.r10IdlePause(appForeground: false, strapCharging: false,
                                      stepsQuietFor: quiet * 3, heartRate: 80, restingHeartRate: 55),
                       "a heart-rate rise means something is happening")
        XCTAssertTrue(B.r10IdlePause(appForeground: false, strapCharging: true,
                                     stepsQuietFor: 0, heartRate: 0, restingHeartRate: 55),
                      "no steps on a charger")
        XCTAssertFalse(B.r10IdlePause(appForeground: true, strapCharging: true,
                                      stepsQuietFor: quiet * 3, heartRate: 58, restingHeartRate: 55),
                       "the app on screen always streams")
    }

    func testNeverDuringHistoryOrPairingOrWhenDisconnected() {
        XCTAssertNil(cmd(history: true), "live 3F freezes the history read cursor")
        XCTAssertNil(cmd(pairing: true))
        XCTAssertNil(cmd(connected: false))
    }

    func testPowerPolicyOrUserTurnsItOffOnce() {
        XCTAssertEqual(cmd(power: false, frames: true), .off)
        XCTAssertNil(cmd(power: false, frames: true, offSent: true))
        XCTAssertNil(cmd(power: false, frames: false), "nothing streaming: nothing to stop")
        XCTAssertEqual(cmd(enabled: false, frames: true), .off)
    }
}
