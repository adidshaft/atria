import XCTest
@testable import Atria

/// Scenario tests for the lossless live/history coordinator. Sequences mirror the
/// Mac-validated behaviour (flush4 and the overnight capture, 2026-09-23).
final class AtriaWhoop4LiveFlushPlannerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_160_000)
    private let deviceSecond0: UInt32 = 1_790_160_000

    private func v24Row(second: UInt32) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 100)
        p[0] = 0x2F
        p[1] = 0x18
        p[7] = UInt8(second & 0xFF)
        p[8] = UInt8((second >> 8) & 0xFF)
        p[9] = UInt8((second >> 16) & 0xFF)
        p[10] = UInt8((second >> 24) & 0xFF)
        return p
    }

    private func historyEnd(token: [UInt8]) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 28)
        p[0] = 0x31
        p[2] = 2
        p.replaceSubrange(13..<21, with: token)
        return p
    }

    /// Feeds live frames 1/s from `start` and returns the planner after `count` frames.
    @discardableResult
    private func feed(_ planner: inout AtriaWhoop4LiveFlushPlanner, counter: inout UInt16,
                      second: inout UInt32, steps: UInt16 = 100, from start: Date,
                      count: Int) -> [AtriaWhoop4LiveFlushPlanner.Command] {
        var all: [AtriaWhoop4LiveFlushPlanner.Command] = []
        for i in 0..<count {
            let now = start.addingTimeInterval(Double(i))
            all += planner.r10(counter: counter, deviceSecond: second, subsecondTicks: 0,
                               firmwareSteps: steps, now: now).commands
            all += planner.tick(now: now).commands
            counter &+= 1
            second += 1
        }
        return all
    }

    func testFirstConnectStartsLiveAndPeriodicDrainCatchesUpLosslessly() {
        var planner = AtriaWhoop4LiveFlushPlanner()
        XCTAssertEqual(planner.linkReady(now: t0), [.liveOn])
        var counter: UInt16 = 10
        var second = deviceSecond0
        // 300 s of live frames → exactly one periodic drain request at the end.
        let commands = feed(&planner, counter: &counter, second: &second, from: t0, count: 301)
        XCTAssertEqual(commands, [.liveOff, .historyStart])
        XCTAssertEqual(planner.state, .draining)

        let now = t0.addingTimeInterval(302)
        // Chunk end is ACKed with its token; rows below the target do not end the drain.
        let token: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        XCTAssertEqual(planner.historyFrame(payload: historyEnd(token: token), now: now).commands,
                       [.historyAck(token: token)])
        XCTAssertEqual(planner.historyFrame(payload: v24Row(second: deviceSecond0 + 10), now: now).commands, [])
        // A row reaching the target (device-now − 1) ends it: abort history, resume live.
        let end = planner.historyFrame(payload: v24Row(second: deviceSecond0 + 400), now: now)
        XCTAssertEqual(end.commands, [.historyAbort, .liveOn])
        guard case let .drainFinished(reason, why, rows, first, last)? = end.events.first else {
            return XCTFail("expected drainFinished")
        }
        XCTAssertEqual(reason, .periodic)
        XCTAssertEqual(why, .caughtUp)
        XCTAssertEqual(rows, 2)
        XCTAssertEqual(first, deviceSecond0 + 10)
        XCTAssertEqual(last, deviceSecond0 + 400)
        XCTAssertEqual(planner.state, .live)
    }

    func testFramesSkippedDuringDrainPauseAreNotCountedAsLoss() {
        var planner = AtriaWhoop4LiveFlushPlanner()
        _ = planner.linkReady(now: t0)
        var counter: UInt16 = 0
        var second = deviceSecond0
        feed(&planner, counter: &counter, second: &second, from: t0, count: 301)
        _ = planner.historyFrame(payload: v24Row(second: deviceSecond0 + 999), now: t0.addingTimeInterval(302))
        // Live resumes 20 frames later (paused for the drain).
        counter &+= 20
        second += 20
        feed(&planner, counter: &counter, second: &second, from: t0.addingTimeInterval(322), count: 5)
        XCTAssertEqual(planner.accounting.drainPausedFrames, 20)
        XCTAssertEqual(planner.accounting.missingFrames, 0)
        // A later skip while live is a real transit loss.
        counter &+= 3
        second += 3
        feed(&planner, counter: &counter, second: &second, from: t0.addingTimeInterval(330), count: 2)
        XCTAssertEqual(planner.accounting.missingFrames, 3)
    }

    func testReconnectBridgesFirmwareStepsWithWrapAndDrainsTheGapBeforeLive() {
        var planner = AtriaWhoop4LiveFlushPlanner()
        _ = planner.linkReady(now: t0)
        var counter: UInt16 = 65_530
        var second = deviceSecond0
        feed(&planner, counter: &counter, second: &second, steps: 65_530, from: t0, count: 3)
        planner.linkLost()
        XCTAssertEqual(planner.state, .disconnected)

        // 70 s later the link returns; the strap's 3F latch resumes live frames.
        let back = t0.addingTimeInterval(73)
        XCTAssertEqual(planner.linkReady(now: back), [], "reconnect waits for a frame before acting")
        let result = planner.r10(counter: counter &+ 69, deviceSecond: second + 69, subsecondTicks: 0,
                                 firmwareSteps: 45, now: back)
        XCTAssertEqual(result.commands, [.liveOff, .historyStart])
        guard case let .gapBridged(from, to, steps, notReceived)? = result.events.first else {
            return XCTFail("expected gapBridged")
        }
        XCTAssertEqual(from, deviceSecond0 + 2)
        XCTAssertEqual(to, second + 69)
        XCTAssertEqual(steps, 51, "65,532 → 45 wraps through 65,535")
        XCTAssertEqual(notReceived, 69)
        XCTAssertEqual(planner.accounting.bridgedFirmwareSteps, 51)
        XCTAssertEqual(planner.accounting.missingFrames, 0, "gap frames are bridged, not counted as loss")
        guard case .drainStarted(.reconnect, _)? = result.events.last else {
            return XCTFail("expected a reconnect drain")
        }
    }

    func testDrainTimesOutSafelyAndResumesLive() {
        var planner = AtriaWhoop4LiveFlushPlanner()
        _ = planner.linkReady(now: t0)
        var counter: UInt16 = 0
        var second = deviceSecond0
        feed(&planner, counter: &counter, second: &second, from: t0, count: 301)
        XCTAssertEqual(planner.state, .draining)
        // Rows keep arriving (no stall) but the drain never reaches its target.
        var now = t0.addingTimeInterval(301)
        while now < t0.addingTimeInterval(300 + AtriaWhoop4LiveFlushPlanner.maximumDrainDuration + 2) {
            now = now.addingTimeInterval(10)
            _ = planner.historyFrame(payload: v24Row(second: deviceSecond0 + 5), now: now)
            let result = planner.tick(now: now)
            if !result.commands.isEmpty {
                XCTAssertEqual(result.commands, [.historyAbort, .liveOn])
                guard case .drainFinished(_, .timeout, _, _, _)? = result.events.first else {
                    return XCTFail("expected timeout")
                }
                return
            }
        }
        XCTFail("drain never timed out")
    }

    func testStalledDrainResumesLiveQuicklyAndRetries() {
        var planner = AtriaWhoop4LiveFlushPlanner()
        _ = planner.linkReady(now: t0)
        var counter: UInt16 = 0
        var second = deviceSecond0
        feed(&planner, counter: &counter, second: &second, from: t0, count: 301)
        XCTAssertEqual(planner.state, .draining)
        // No history rows at all: after the stall timeout live resumes (not 600 s later).
        let stall = t0.addingTimeInterval(300 + AtriaWhoop4LiveFlushPlanner.drainStallTimeout + 1)
        let result = planner.tick(now: stall)
        XCTAssertEqual(result.commands, [.historyAbort, .liveOn])
        guard case .drainFinished(_, .stalled, _, _, _)? = result.events.first else {
            return XCTFail("expected stalled")
        }
        XCTAssertEqual(planner.state, .live)
        // A retry drain follows after the retry delay.
        XCTAssertEqual(planner.tick(now: stall.addingTimeInterval(30)).commands, [])
        XCTAssertEqual(planner.tick(now: stall.addingTimeInterval(AtriaWhoop4LiveFlushPlanner.stallRetryDelay)).commands,
                       [.liveOff, .historyStart])
    }

    func testReconnectWithoutLiveFramesRetriesLiveOnce() {
        var planner = AtriaWhoop4LiveFlushPlanner()
        _ = planner.linkReady(now: t0)
        var counter: UInt16 = 0
        var second = deviceSecond0
        feed(&planner, counter: &counter, second: &second, from: t0, count: 2)
        planner.linkLost()
        let back = t0.addingTimeInterval(60)
        _ = planner.linkReady(now: back)
        XCTAssertEqual(planner.tick(now: back.addingTimeInterval(2)).commands, [])
        XCTAssertEqual(planner.tick(now: back.addingTimeInterval(5)).commands, [.liveOn])
        XCTAssertEqual(planner.tick(now: back.addingTimeInterval(9)).commands, [], "only one retry")
    }

    func testDisconnectMidDrainDropsTheDrainAndBridgesOnReturn() {
        var planner = AtriaWhoop4LiveFlushPlanner()
        _ = planner.linkReady(now: t0)
        var counter: UInt16 = 0
        var second = deviceSecond0
        feed(&planner, counter: &counter, second: &second, steps: 500, from: t0, count: 301)
        XCTAssertEqual(planner.state, .draining)
        planner.linkLost()
        XCTAssertEqual(planner.state, .disconnected)
        let back = t0.addingTimeInterval(400)
        _ = planner.linkReady(now: back)
        let result = planner.r10(counter: counter &+ 90, deviceSecond: second + 90, subsecondTicks: 0,
                                 firmwareSteps: 520, now: back)
        XCTAssertEqual(result.commands, [.liveOff, .historyStart])
        guard case let .gapBridged(_, _, steps, _)? = result.events.first else {
            return XCTFail("expected gapBridged")
        }
        XCTAssertEqual(steps, 20)
    }

    // MARK: Power policy integration

    private func decision(live: Bool, flush: AtriaWhoop4PowerPolicy.Flush) -> AtriaWhoop4PowerPolicy.Decision {
        AtriaWhoop4PowerPolicy.Decision(liveMotionAllowed: live, flush: flush, reason: "test")
    }

    func testLowBatteryStopsLiveAndDrainsWithoutRestartingLive() {
        var planner = AtriaWhoop4LiveFlushPlanner()
        _ = planner.linkReady(now: t0)
        var counter: UInt16 = 0
        var second = deviceSecond0
        feed(&planner, counter: &counter, second: &second, from: t0, count: 10)
        XCTAssertEqual(planner.applyPower(decision(live: false, flush: .periodic(interval: 300))), [.liveOff])
        // Next periodic drain: pause is implicit, drain ends without re-enabling live.
        let drainStart = planner.tick(now: t0.addingTimeInterval(300))
        XCTAssertEqual(drainStart.commands, [.liveOff, .historyStart])
        let end = planner.historyFrame(payload: v24Row(second: deviceSecond0 + 999), now: t0.addingTimeInterval(305))
        XCTAssertEqual(end.commands, [.historyAbort], "live stays off while not allowed")
        // Power recovers: live resumes.
        XCTAssertEqual(planner.applyPower(decision(live: true, flush: .periodic(interval: 300))), [.liveOn])
    }

    func testPausedFlushNeverDrainsAndChargingDrainsEveryMinute() {
        var planner = AtriaWhoop4LiveFlushPlanner()
        _ = planner.linkReady(now: t0)
        var counter: UInt16 = 0
        var second = deviceSecond0
        feed(&planner, counter: &counter, second: &second, from: t0, count: 5)
        _ = planner.applyPower(decision(live: false, flush: .paused))
        XCTAssertEqual(planner.tick(now: t0.addingTimeInterval(3_600)).commands, [], "paused: history waits on the strap")
        _ = planner.applyPower(decision(live: false, flush: .asap))
        XCTAssertEqual(planner.tick(now: t0.addingTimeInterval(3_600)).commands, [.liveOff, .historyStart])
        _ = planner.historyFrame(payload: v24Row(second: deviceSecond0 + 9_999), now: t0.addingTimeInterval(3_610))
        XCTAssertEqual(planner.tick(now: t0.addingTimeInterval(3_650)).commands, [])
        XCTAssertEqual(planner.tick(now: t0.addingTimeInterval(3_671)).commands, [.liveOff, .historyStart],
                       "asap: next drain one minute after the last")
    }

    func testReconnectWithLiveOffDrainsImmediatelyWithoutWaitingForFrames() {
        var planner = AtriaWhoop4LiveFlushPlanner()
        _ = planner.linkReady(now: t0)
        var counter: UInt16 = 0
        var second = deviceSecond0
        feed(&planner, counter: &counter, second: &second, from: t0, count: 5)
        _ = planner.applyPower(decision(live: false, flush: .periodic(interval: 300)))
        planner.linkLost()
        let back = t0.addingTimeInterval(120)
        XCTAssertEqual(planner.linkReady(now: back), [])
        let result = planner.tick(now: back.addingTimeInterval(1))
        XCTAssertEqual(result.commands, [.liveOff, .historyStart])
        guard case .drainStarted(.reconnect, _)? = result.events.first else {
            return XCTFail("expected a reconnect drain")
        }
    }
}
