import XCTest
import CoreBluetooth
@testable import Atria

final class AtriaWhoop4CommandResponseTests: XCTestCase {
    func testPhysical69FixturesAreUnsupportedNotSuccess() throws {
        for (index, bytes) in AtriaWhoop4CommandResponse.historicalIMUUnsupportedFixtures.enumerated() {
            let parsed = try XCTUnwrap(AtriaWhoop4CommandResponse.parsePayload(bytes))
            XCTAssertEqual(parsed.opcode, 0x69, "fixture \(index)")
            XCTAssertEqual(parsed.status, .unsupported)
            XCTAssertEqual(
                AtriaWhoop4CommandResponse.correlate(
                    submittedOpcode: 0x69,
                    submittedSequence: parsed.echoedRequestSequence,
                    response: parsed
                ),
                .firmwareUnsupported
            )
            XCTAssertFalse(
                AtriaWhoop4CommandResponse.mayMarkHistoricalIMUBankArmed(.firmwareUnsupported)
            )
            XCTAssertFalse(
                AtriaWhoop4CommandResponse.mayMarkSuccessfulStream(.firmwareUnsupported)
            )
        }
        XCTAssertEqual(
            AtriaWhoop4CommandResponse.parsePayload(
                AtriaWhoop4CommandResponse.historicalIMUUnsupportedFixtures[0]
            )?.echoedRequestSequence,
            0x0a
        )
    }

    func testPhysical6A01ResponseIsOther00NotAcceptedOrNativeStream() throws {
        let parsed = try XCTUnwrap(
            AtriaWhoop4CommandResponse.parsePayload(
                AtriaWhoop4CommandResponse.toggleIMUModeOther00Fixture
            )
        )
        XCTAssertEqual(parsed.opcode, 0x6A)
        XCTAssertEqual(parsed.echoedRequestSequence, 0x00)
        XCTAssertEqual(parsed.status, .other(0x00))
        XCTAssertEqual(
            AtriaWhoop4CommandResponse.correlate(
                submittedOpcode: 0x6A,
                submittedSequence: 0x00,
                response: parsed
            ),
            .firmwareOther
        )
        XCTAssertFalse(
            AtriaWhoop4CommandResponse.mayMarkSuccessfulStream(.firmwareOther)
        )
        XCTAssertFalse(
            AtriaWhoop4CommandResponse.mayMarkSuccessfulStream(.firmwareAccepted)
        )
    }

    func testSuccessful22AndPending16ShareTheSameLayout() {
        let rangeAccepted = AtriaWhoop4CommandResponse.parsePayload([
            0x24, 0x91, 0x22, 0x07, 0x01, 0x00, 0x00, 0x00,
        ])
        XCTAssertEqual(rangeAccepted?.opcode, 0x22)
        XCTAssertEqual(rangeAccepted?.echoedRequestSequence, 0x07)
        XCTAssertEqual(rangeAccepted?.status, .accepted)

        let historyPending = AtriaWhoop4CommandResponse.parsePayload([
            0x24, 0xa0, 0x16, 0x05, 0x02, 0x0b, 0x00, 0x00,
        ])
        XCTAssertEqual(historyPending?.opcode, 0x16)
        XCTAssertEqual(historyPending?.status, .pending)
        XCTAssertEqual(
            AtriaWhoop4CommandResponse.correlate(
                submittedOpcode: 0x16,
                submittedSequence: 0x05,
                response: historyPending
            ),
            .firmwarePending
        )
    }

    func testWriteSubmissionIsNotFirmwareSuccessOrNativeStream() {
        XCTAssertFalse(
            AtriaWhoop4CommandResponse.mayMarkHistoricalIMUBankArmed(.writeSubmitted)
        )
        XCTAssertFalse(
            AtriaWhoop4CommandResponse.mayMarkHistoricalIMUBankArmed(.writeCompleted)
        )
        XCTAssertFalse(
            AtriaWhoop4CommandResponse.mayMarkSuccessfulStream(.firmwareAccepted)
        )
        XCTAssertTrue(
            AtriaWhoop4CommandResponse.mayMarkSuccessfulStream(.nativeSamplesObserved)
        )
        XCTAssertEqual(
            AtriaWhoop4CommandResponse.correlate(
                submittedOpcode: 0x6A,
                submittedSequence: 0x01,
                response: nil
            ),
            .missingResponse
        )
        XCTAssertEqual(
            AtriaWhoop4CommandResponse.correlate(
                submittedOpcode: 0x6A,
                submittedSequence: 0x01,
                response: AtriaWhoop4CommandResponse.parsePayload([
                    0x24, 0x10, 0x69, 0x01, 0x03,
                ])
            ),
            .unmatchedResponse
        )
        XCTAssertEqual(
            AtriaWhoop4CommandResponse.correlate(
                submittedOpcode: 0x22,
                submittedSequence: 0x07,
                response: AtriaWhoop4CommandResponse.parsePayload([
                    0x24, 0x91, 0x22, 0x07,
                ])
            ),
            .responseReceived
        )
    }

    func testShouldNotRetryUnsupported() {
        XCTAssertFalse(
            AtriaWhoop4CommandResponse.shouldRetryAfter(.firmwareUnsupported)
        )
    }
}

final class AtriaIMUDiagnosticTransportTests: XCTestCase {
    private let quiet = [AtriaIMUDiagnosticTransport.quietLeaseArgument]
    private let single = [
        AtriaIMUDiagnosticTransport.quietLeaseArgument,
        AtriaIMUDiagnosticTransport.singleEnableArgument,
    ]

    override func setUp() {
        super.setUp()
        AtriaIMUDiagnosticTransport.resetForTesting()
        AtriaIMUDiagnosticTransport.documentsDirectoryOverride =
            FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(
            at: AtriaIMUDiagnosticTransport.documentsDirectoryOverride!,
            withIntermediateDirectories: true
        )
    }

    override func tearDown() {
        AtriaIMUDiagnosticTransport.resetForTesting()
        AtriaIMUDiagnosticTransport.documentsDirectoryOverride = nil
        super.tearDown()
    }

    func testQuietLeaseArmsFromConcatenatedDVTStringAndEnvironment() {
        XCTAssertTrue(
            AtriaIMUDiagnosticTransport.isQuietLeaseActive(
                arguments: ["--atria-imu-quiet-lease --atria-imu-record-seconds 240"]
            )
        )
        XCTAssertEqual(
            AtriaIMUDiagnosticTransport.recordDurationSeconds(
                arguments: ["--atria-imu-quiet-lease --atria-imu-record-seconds 240"]
            ),
            240
        )
        XCTAssertTrue(
            AtriaIMUDiagnosticTransport.isQuietLeaseActive(
                arguments: ["/usr/libexec/atria"],
                environment: ["ATRIA_IMU_QUIET_LEASE": "1"]
            )
        )
        XCTAssertFalse(
            AtriaIMUDiagnosticTransport.isQuietLeaseActive(
                arguments: ["/usr/libexec/atria"],
                environment: [:]
            )
        )
    }

    func testInhibitPredicateBlocksStandardHRConnectAndQuietLease() {
        XCTAssertTrue(
            AtriaIMUDiagnosticTransport.shouldInhibitAutomaticConnectIMUCommands(
                arguments: [],
                environment: [:],
                standardHROnlyMode: true
            ),
            "production standard-HR must not send 6A/3F/69 on connect/reseat"
        )
        XCTAssertTrue(
            AtriaIMUDiagnosticTransport.shouldInhibitAutomaticConnectIMUCommands(
                arguments: quiet,
                environment: [:],
                standardHROnlyMode: false
            )
        )
        XCTAssertFalse(
            AtriaIMUDiagnosticTransport.shouldInhibitAutomaticConnectIMUCommands(
                arguments: [],
                environment: [:],
                standardHROnlyMode: false
            )
        )
        AtriaIMUDiagnosticTransport.armQuietLease(arguments: quiet)
        XCTAssertFalse(
            AtriaIMUDiagnosticTransport.writeDecision(
                opcode: AtriaBLEManager.Cmd.toggleIMUMode,
                payload: [0x01],
                reason: "connect_recovery",
                arguments: quiet
            ).allow
        )
        XCTAssertFalse(
            AtriaIMUDiagnosticTransport.writeDecision(
                opcode: AtriaBLEManager.Cmd.sendR10R11Realtime,
                payload: [0x01],
                reason: "connect_3f",
                arguments: quiet
            ).allow
        )
    }

    func testQuietLeaseBlocksBankingCatchUpRepeated6AAndWorkoutPayloads() {
        let blocked: [(UInt8, [UInt8])] = [
            (AtriaBLEManager.Cmd.toggleIMUModeHistorical, [0x01]),
            (AtriaBLEManager.Cmd.toggleIMUModeHistorical, [0x00]),
            (AtriaBLEManager.Cmd.sendHistoricalData, [0x00]),
            (AtriaBLEManager.Cmd.toggleIMUMode, [0x01]),
            (AtriaBLEManager.Cmd.startRawData, [0x01]),
            (AtriaBLEManager.Cmd.sendR10R11Realtime, [0x01]),
            (AtriaIMUDiagnosticTransport.softwareResetOpcode, AtriaIMUDiagnosticTransport.softwareResetPayload),
        ]
        for (opcode, payload) in blocked {
            let decision = AtriaIMUDiagnosticTransport.writeDecision(
                opcode: opcode,
                payload: payload,
                reason: "test",
                arguments: quiet
            )
            XCTAssertFalse(decision.allow, String(format: "%02x", opcode))
        }
    }

    func testQuietLeaseAllows2A37AndInitialStream5ButBlocksMidLinkRepair() {
        XCTAssertTrue(
            AtriaIMUDiagnosticTransport.notifyDecision(
                uuid: AtriaBLEManager.UUIDs.heartRateMeasure,
                enable: true,
                phase: .heartRate,
                arguments: quiet
            ).allow
        )
        XCTAssertTrue(
            AtriaIMUDiagnosticTransport.notifyDecision(
                uuid: AtriaBLEManager.UUIDs.heartRateMeasure,
                enable: false,
                phase: .heartRate,
                arguments: quiet
            ).allow
        )
        AtriaIMUDiagnosticTransport.armQuietLease(arguments: quiet)
        AtriaIMUDiagnosticTransport.noteNewConnectionEpoch(7)
        let first = AtriaIMUDiagnosticTransport.notifyDecision(
            uuid: AtriaBLEManager.UUIDs.strapStream5,
            enable: true,
            phase: .initialDiscovery,
            alreadyNotifying: false,
            arguments: quiet
        )
        XCTAssertTrue(first.allow)
        XCTAssertEqual(first.reason, "link_up_notify_once")
        AtriaIMUDiagnosticTransport.markInitialStream5Established(alreadyNotifying: false)
        XCTAssertFalse(
            AtriaIMUDiagnosticTransport.notifyDecision(
                uuid: AtriaBLEManager.UUIDs.strapStream5,
                enable: false,
                phase: .midLinkRepair,
                arguments: quiet
            ).allow
        )
        XCTAssertFalse(
            AtriaIMUDiagnosticTransport.notifyDecision(
                uuid: AtriaBLEManager.UUIDs.strapStream5,
                enable: true,
                phase: .midLinkRepair,
                arguments: quiet
            ).allow
        )
        XCTAssertTrue(AtriaIMUDiagnosticTransport.shouldBlockMidLinkNotifyRepair(arguments: quiet))
        AtriaIMUDiagnosticTransport.noteNewConnectionEpoch(8)
        XCTAssertFalse(
            AtriaIMUDiagnosticTransport.notifyDecision(
                uuid: AtriaBLEManager.UUIDs.strapStream5,
                enable: true,
                phase: .restoration,
                arguments: quiet
            ).allow,
            "mid-link restore must not rewrite stream-5 CCCD"
        )
        let secondConnect = AtriaIMUDiagnosticTransport.notifyDecision(
            uuid: AtriaBLEManager.UUIDs.strapStream5,
            enable: true,
            phase: .initialDiscovery,
            alreadyNotifying: false,
            arguments: quiet
        )
        XCTAssertTrue(secondConnect.allow)
        XCTAssertEqual(secondConnect.reason, "link_up_notify_once")
    }

    func testStream5CCCDWriteOncePerEpochSkipsAlreadyNotifyingAndRestoreRewrite() {
        AtriaIMUDiagnosticTransport.armQuietLease(arguments: quiet)
        AtriaIMUDiagnosticTransport.noteNewConnectionEpoch(1)
        let alreadyOn = AtriaIMUDiagnosticTransport.notifyDecision(
            uuid: AtriaBLEManager.UUIDs.strapStream5,
            enable: true,
            phase: .initialDiscovery,
            alreadyNotifying: true,
            arguments: quiet
        )
        XCTAssertFalse(alreadyOn.allow)
        XCTAssertEqual(alreadyOn.reason, "skip_already_notifying")
        XCTAssertEqual(
            AtriaIMUDiagnosticTransport.snapshot()["stream5_notify_write_consumed"] as? Bool,
            true
        )

        AtriaIMUDiagnosticTransport.resetForTesting()
        AtriaIMUDiagnosticTransport.documentsDirectoryOverride =
            FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        AtriaIMUDiagnosticTransport.armQuietLease(arguments: quiet)
        AtriaIMUDiagnosticTransport.noteNewConnectionEpoch(2)
        let restore = AtriaIMUDiagnosticTransport.notifyDecision(
            uuid: AtriaBLEManager.UUIDs.strapStream5,
            enable: true,
            phase: .restoration,
            alreadyNotifying: false,
            arguments: quiet
        )
        XCTAssertFalse(restore.allow)
        XCTAssertEqual(restore.reason, "quiet_lease_initial_or_restored")
        let linkUp = AtriaIMUDiagnosticTransport.notifyDecision(
            uuid: AtriaBLEManager.UUIDs.strapStream5,
            enable: true,
            phase: .initialDiscovery,
            alreadyNotifying: false,
            arguments: quiet
        )
        XCTAssertTrue(linkUp.allow)
        XCTAssertEqual(linkUp.reason, "link_up_notify_once")
        let second = AtriaIMUDiagnosticTransport.notifyDecision(
            uuid: AtriaBLEManager.UUIDs.strapStream5,
            enable: true,
            phase: .initialDiscovery,
            alreadyNotifying: false,
            arguments: quiet
        )
        XCTAssertFalse(second.allow, "at most one stream-5 CCCD write per epoch")
        AtriaIMUDiagnosticTransport.noteNewConnectionEpoch(3)
        XCTAssertFalse(
            AtriaIMUDiagnosticTransport.notifyDecision(
                uuid: AtriaBLEManager.UUIDs.strapStream5,
                enable: true,
                phase: .restoration,
                alreadyNotifying: false,
                arguments: quiet
            ).allow,
            "mid-link restore must not rewrite stream-5 CCCD"
        )
        XCTAssertFalse(
            AtriaIMUDiagnosticTransport.notifyDecision(
                uuid: AtriaBLEManager.UUIDs.strapStream5,
                enable: true,
                phase: .midLinkRepair,
                alreadyNotifying: false,
                arguments: quiet
            ).allow,
            "mid-link repair must not rewrite stream-5 CCCD"
        )
        let nextEpoch = AtriaIMUDiagnosticTransport.notifyDecision(
            uuid: AtriaBLEManager.UUIDs.strapStream5,
            enable: true,
            phase: .initialDiscovery,
            alreadyNotifying: false,
            arguments: quiet
        )
        XCTAssertTrue(nextEpoch.allow, "second connect gets notify ON")
        XCTAssertEqual(nextEpoch.reason, "link_up_notify_once")
    }

    func testSecondConnectGetsStream5NotifyOnMidLinkRestoreDoesNotRewrite() {
        AtriaIMUDiagnosticTransport.armQuietLease(arguments: quiet)
        AtriaIMUDiagnosticTransport.noteNewConnectionEpoch(1)
        let first = AtriaIMUDiagnosticTransport.notifyDecision(
            uuid: AtriaBLEManager.UUIDs.strapStream5,
            enable: true,
            phase: .initialDiscovery,
            alreadyNotifying: false,
            arguments: quiet
        )
        XCTAssertTrue(first.allow)
        XCTAssertEqual(first.reason, "link_up_notify_once")
        XCTAssertFalse(
            AtriaIMUDiagnosticTransport.notifyDecision(
                uuid: AtriaBLEManager.UUIDs.strapStream5,
                enable: true,
                phase: .restoration,
                alreadyNotifying: false,
                arguments: quiet
            ).allow
        )
        AtriaIMUDiagnosticTransport.noteNewConnectionEpoch(2)
        let secondConnect = AtriaIMUDiagnosticTransport.notifyDecision(
            uuid: AtriaBLEManager.UUIDs.strapStream5,
            enable: true,
            phase: .initialDiscovery,
            alreadyNotifying: false,
            arguments: quiet
        )
        XCTAssertTrue(secondConnect.allow, "second connect gets notify ON")
        XCTAssertEqual(secondConnect.reason, "link_up_notify_once")
        XCTAssertFalse(
            AtriaIMUDiagnosticTransport.notifyDecision(
                uuid: AtriaBLEManager.UUIDs.strapStream5,
                enable: true,
                phase: .restoration,
                alreadyNotifying: false,
                arguments: quiet
            ).allow,
            "mid-link restore does not rewrite"
        )
    }

    func testExtraNotifyLinkUpAllowsOtherUUIDsOnceAndBlocksMidLinkAnd6A() {
        let extra = quiet + [AtriaIMUDiagnosticTransport.extraNotifyLinkUpArgument]
        AtriaIMUDiagnosticTransport.armQuietLease(arguments: extra)
        AtriaIMUDiagnosticTransport.noteNewConnectionEpoch(1)
        for uuid in AtriaIMUDiagnosticTransport.extraNotifyUUIDs {
            let first = AtriaIMUDiagnosticTransport.notifyDecision(
                uuid: uuid,
                enable: true,
                phase: .initialDiscovery,
                alreadyNotifying: false,
                arguments: extra
            )
            XCTAssertTrue(first.allow, uuid.uuidString)
            XCTAssertEqual(first.reason, "extra_notify_link_up_once")
            let second = AtriaIMUDiagnosticTransport.notifyDecision(
                uuid: uuid,
                enable: true,
                phase: .initialDiscovery,
                alreadyNotifying: false,
                arguments: extra
            )
            XCTAssertFalse(second.allow, uuid.uuidString)
            XCTAssertFalse(
                AtriaIMUDiagnosticTransport.notifyDecision(
                    uuid: uuid,
                    enable: true,
                    phase: .midLinkRepair,
                    alreadyNotifying: false,
                    arguments: extra
                ).allow
            )
        }
        XCTAssertFalse(
            AtriaIMUDiagnosticTransport.notifyDecision(
                uuid: AtriaBLEManager.UUIDs.strapStream4,
                enable: true,
                phase: .initialDiscovery,
                alreadyNotifying: false,
                arguments: quiet
            ).allow,
            "extra CCCD stays off without the link-up flag"
        )
        XCTAssertFalse(
            AtriaIMUDiagnosticTransport.writeDecision(
                opcode: AtriaBLEManager.Cmd.toggleIMUMode,
                payload: [0x01],
                reason: "test",
                arguments: extra
            ).allow
        )
        XCTAssertTrue(
            AtriaIMUDiagnosticTransport.shouldInhibitAutomaticConnectIMUCommands(
                arguments: extra,
                environment: [:],
                standardHROnlyMode: true
            )
        )
        XCTAssertEqual(
            AtriaIMUDiagnosticTransport.durableCompactIMUSource(
                characteristic: AtriaBLEManager.UUIDs.strapStream4,
                stream5Label: "stream5"
            ),
            AtriaIMUDiagnosticTransport.liveOtherUUIDSource
        )
    }

    func testExtraNotifyOncePerNewEpochDoesNotRewriteMidLinkStream5() {
        let extra = quiet + [AtriaIMUDiagnosticTransport.extraNotifyLinkUpArgument]
        AtriaIMUDiagnosticTransport.armQuietLease(arguments: extra)
        AtriaIMUDiagnosticTransport.noteNewConnectionEpoch(1)
        let first07 = AtriaIMUDiagnosticTransport.notifyDecision(
            uuid: AtriaBLEManager.UUIDs.strapStream7,
            enable: true,
            phase: .initialDiscovery,
            alreadyNotifying: false,
            arguments: extra
        )
        XCTAssertTrue(first07.allow)
        XCTAssertEqual(first07.reason, "extra_notify_link_up_once")
        XCTAssertFalse(
            AtriaIMUDiagnosticTransport.notifyDecision(
                uuid: AtriaBLEManager.UUIDs.strapStream7,
                enable: true,
                phase: .initialDiscovery,
                alreadyNotifying: false,
                arguments: extra
            ).allow,
            "same epoch does not rewrite 07"
        )
        XCTAssertFalse(
            AtriaIMUDiagnosticTransport.notifyDecision(
                uuid: AtriaBLEManager.UUIDs.strapStream5,
                enable: true,
                phase: .restoration,
                alreadyNotifying: false,
                arguments: extra
            ).allow
        )
        XCTAssertFalse(
            AtriaIMUDiagnosticTransport.notifyDecision(
                uuid: AtriaBLEManager.UUIDs.strapStream5,
                enable: true,
                phase: .midLinkRepair,
                alreadyNotifying: false,
                arguments: extra
            ).allow
        )
        AtriaIMUDiagnosticTransport.noteNewConnectionEpoch(3)
        let next07 = AtriaIMUDiagnosticTransport.notifyDecision(
            uuid: AtriaBLEManager.UUIDs.strapStream7,
            enable: true,
            phase: .initialDiscovery,
            alreadyNotifying: false,
            arguments: extra
        )
        XCTAssertFalse(next07.allow, "250 extra 03/04/07 is once per process")
        XCTAssertEqual(next07.reason, "extra_notify_link_up_consumed")
        XCTAssertFalse(
            AtriaIMUDiagnosticTransport.notifyDecision(
                uuid: AtriaBLEManager.UUIDs.strapStream7,
                enable: true,
                phase: .initialDiscovery,
                alreadyNotifying: true,
                arguments: extra
            ).allow,
            "already notifying 07 is not rewritten"
        )
        let stream5 = AtriaIMUDiagnosticTransport.notifyDecision(
            uuid: AtriaBLEManager.UUIDs.strapStream5,
            enable: true,
            phase: .initialDiscovery,
            alreadyNotifying: false,
            arguments: extra
        )
        XCTAssertTrue(stream5.allow)
        XCTAssertEqual(stream5.reason, "link_up_notify_once")
        XCTAssertEqual(
            AtriaIMUDiagnosticTransport.durableCompactIMUSource(
                characteristic: AtriaBLEManager.UUIDs.strapStream5,
                stream5Label: "stream5"
            ),
            "stream5"
        )
        XCTAssertFalse(
            AtriaIMUDiagnosticTransport.notifyDecision(
                uuid: AtriaBLEManager.UUIDs.strapStream5,
                enable: true,
                phase: .midLinkRepair,
                arguments: extra
            ).allow
        )
    }

    func testStream5CooldownSkipAfterLeftoverThenEnableAfter15m() throws {
        let frame = try Self.imu241LastPacketFixture()
        AtriaIMUDiagnosticTransport.monotonicNowOverride = 1_000
        AtriaIMUDiagnosticTransport.armQuietLease(arguments: quiet)
        AtriaIMUDiagnosticTransport.noteNewConnectionEpoch(1)
        let first = AtriaIMUDiagnosticTransport.notifyDecision(
            uuid: AtriaBLEManager.UUIDs.strapStream5,
            enable: true,
            phase: .initialDiscovery,
            alreadyNotifying: false,
            arguments: quiet
        )
        XCTAssertTrue(first.allow)
        XCTAssertEqual(first.reason, "link_up_notify_once")
        AtriaIMUDiagnosticTransport.recordAssembledFrame(
            frame,
            connectionEpoch: 1,
            historyActive: false
        )
        XCTAssertEqual(
            AtriaIMUDiagnosticTransport.snapshot()["stream5_cooldown_skip_count"] as? Int,
            0
        )

        AtriaIMUDiagnosticTransport.noteNewConnectionEpoch(2)
        let skip = AtriaIMUDiagnosticTransport.notifyDecision(
            uuid: AtriaBLEManager.UUIDs.strapStream5,
            enable: true,
            phase: .initialDiscovery,
            alreadyNotifying: false,
            arguments: quiet
        )
        XCTAssertFalse(skip.allow)
        XCTAssertEqual(skip.reason, AtriaIMUDiagnosticTransport.stream5CooldownSkipReason)
        XCTAssertEqual(
            AtriaIMUDiagnosticTransport.snapshot()["stream5_cooldown_skip_count"] as? Int,
            1
        )
        XCTAssertTrue(
            AtriaIMUDiagnosticTransport.notifyDecision(
                uuid: AtriaBLEManager.UUIDs.heartRateMeasure,
                enable: true,
                phase: .heartRate,
                arguments: quiet
            ).allow,
            "2A37 stays allowed during stream-5 cooldown"
        )
        XCTAssertFalse(
            AtriaIMUDiagnosticTransport.notifyDecision(
                uuid: AtriaBLEManager.UUIDs.strapStream5,
                enable: true,
                phase: .midLinkRepair,
                alreadyNotifying: false,
                arguments: quiet
            ).allow,
            "mid-link stream-5 CCCD stays banned during cooldown"
        )
        XCTAssertFalse(
            AtriaIMUDiagnosticTransport.notifyDecision(
                uuid: AtriaBLEManager.UUIDs.strapStream5,
                enable: true,
                phase: .initialDiscovery,
                alreadyNotifying: false,
                arguments: quiet
            ).allow,
            "same epoch does not enable after a cooldown skip"
        )

        AtriaIMUDiagnosticTransport.monotonicNowOverride = 1_000 + 901
        AtriaIMUDiagnosticTransport.noteNewConnectionEpoch(3)
        let hunt = AtriaIMUDiagnosticTransport.notifyDecision(
            uuid: AtriaBLEManager.UUIDs.strapStream5,
            enable: true,
            phase: .initialDiscovery,
            alreadyNotifying: false,
            arguments: quiet
        )
        XCTAssertTrue(hunt.allow, "next new-link after 15 min may hunt 0x33")
        XCTAssertEqual(hunt.reason, "link_up_notify_once")
        XCTAssertEqual(
            AtriaIMUDiagnosticTransport.snapshot()["stream5_cooldown_skip_count"] as? Int,
            1
        )
    }

    func testStream5CooldownSkipAfterTimeoutThenEnableAfter15m() {
        AtriaIMUDiagnosticTransport.monotonicNowOverride = 500
        AtriaIMUDiagnosticTransport.armQuietLease(arguments: quiet)
        AtriaIMUDiagnosticTransport.noteNewConnectionEpoch(1)
        XCTAssertTrue(
            AtriaIMUDiagnosticTransport.notifyDecision(
                uuid: AtriaBLEManager.UUIDs.strapStream5,
                enable: true,
                phase: .initialDiscovery,
                alreadyNotifying: false,
                arguments: quiet
            ).allow
        )
        AtriaIMUDiagnosticTransport.noteStream5DrivenConnectionTimeout(
            domain: CBErrorDomain,
            code: CBError.connectionTimeout.rawValue,
            now: 512
        )
        AtriaIMUDiagnosticTransport.noteNewConnectionEpoch(2)
        let skip = AtriaIMUDiagnosticTransport.notifyDecision(
            uuid: AtriaBLEManager.UUIDs.strapStream5,
            enable: true,
            phase: .initialDiscovery,
            alreadyNotifying: false,
            arguments: quiet
        )
        XCTAssertFalse(skip.allow)
        XCTAssertEqual(skip.reason, AtriaIMUDiagnosticTransport.stream5CooldownSkipReason)

        AtriaIMUDiagnosticTransport.noteStream5DrivenConnectionTimeout(
            domain: CBErrorDomain,
            code: CBError.connectionTimeout.rawValue,
            now: 520
        )
        AtriaIMUDiagnosticTransport.monotonicNowOverride = 520 + 901
        AtriaIMUDiagnosticTransport.noteNewConnectionEpoch(3)
        let hunt = AtriaIMUDiagnosticTransport.notifyDecision(
            uuid: AtriaBLEManager.UUIDs.strapStream5,
            enable: true,
            phase: .initialDiscovery,
            alreadyNotifying: false,
            arguments: quiet
        )
        XCTAssertTrue(hunt.allow)
        XCTAssertEqual(hunt.reason, "link_up_notify_once")
    }

    func testTimeoutWithoutStream5DoesNotArmCooldown() {
        AtriaIMUDiagnosticTransport.monotonicNowOverride = 10
        AtriaIMUDiagnosticTransport.armQuietLease(arguments: quiet)
        AtriaIMUDiagnosticTransport.noteNewConnectionEpoch(1)
        AtriaIMUDiagnosticTransport.noteStream5DrivenConnectionTimeout(
            domain: CBErrorDomain,
            code: CBError.connectionTimeout.rawValue,
            now: 22
        )
        AtriaIMUDiagnosticTransport.noteNewConnectionEpoch(2)
        let next = AtriaIMUDiagnosticTransport.notifyDecision(
            uuid: AtriaBLEManager.UUIDs.strapStream5,
            enable: true,
            phase: .initialDiscovery,
            alreadyNotifying: false,
            arguments: quiet
        )
        XCTAssertTrue(next.allow)
        XCTAssertEqual(next.reason, "link_up_notify_once")
        XCTAssertEqual(
            AtriaIMUDiagnosticTransport.snapshot()["stream5_cooldown_skip_count"] as? Int,
            0
        )
    }

    func testOfficialGen4CompactAllowsDocumentedSequenceInOrder() {
        let official = [
            AtriaIMUDiagnosticTransport.quietLeaseArgument,
            AtriaIMUDiagnosticTransport.officialGen4CompactArgument,
        ]
        AtriaIMUDiagnosticTransport.armQuietLease(arguments: official)
        AtriaIMUDiagnosticTransport.armOfficialGen4Compact()
        for body in AtriaBLEManager.Cmd.officialGen4CompactMotionBodies {
            let decision = AtriaIMUDiagnosticTransport.writeDecision(
                opcode: body[0],
                payload: Array(body.dropFirst()),
                reason: "trial",
                arguments: official
            )
            XCTAssertTrue(decision.allow)
            XCTAssertTrue(decision.reason.hasPrefix("explicit_official_gen4_"))
        }
        XCTAssertFalse(
            AtriaIMUDiagnosticTransport.writeDecision(
                opcode: AtriaBLEManager.Cmd.toggleRealtimeHR,
                payload: [0x01],
                reason: "trial",
                arguments: official
            ).allow
        )
        let snapshot = AtriaIMUDiagnosticTransport.snapshot()
        XCTAssertEqual(snapshot["official_gen4_consumed"] as? Bool, true)
        XCTAssertEqual(snapshot["official_gen4_step"] as? Int, 3)
    }

    func testAllDayRecoveryAllowsAbortThen6AOnce() {
        let recovery = [
            AtriaIMUDiagnosticTransport.quietLeaseArgument,
            AtriaIMUDiagnosticTransport.allDayRecoveryArgument,
        ]
        AtriaIMUDiagnosticTransport.armQuietLease(arguments: recovery)
        AtriaIMUDiagnosticTransport.armAllDayAbortThen6A()
        XCTAssertTrue(
            AtriaIMUDiagnosticTransport.writeDecision(
                opcode: AtriaBLEManager.Cmd.abortHistoricalTransmits,
                payload: [0x00],
                reason: "trial",
                arguments: recovery
            ).allow
        )
        XCTAssertTrue(
            AtriaIMUDiagnosticTransport.writeDecision(
                opcode: AtriaBLEManager.Cmd.toggleIMUMode,
                payload: [0x01],
                reason: "trial",
                arguments: recovery
            ).allow
        )
        XCTAssertFalse(
            AtriaIMUDiagnosticTransport.writeDecision(
                opcode: AtriaBLEManager.Cmd.toggleIMUMode,
                payload: [0x01],
                reason: "trial",
                arguments: recovery
            ).allow
        )
    }

    func testSingleEnableAllowsExactlyOne6A01ThenBlocks() {
        XCTAssertFalse(
            AtriaIMUDiagnosticTransport.writeDecision(
                opcode: AtriaBLEManager.Cmd.toggleIMUMode,
                payload: [0x01],
                reason: "trial",
                arguments: single
            ).allow,
            "launch --atria-imu-single-6a must not spend the permit on connect"
        )
        AtriaIMUDiagnosticTransport.armQuietLease(arguments: quiet)
        AtriaIMUDiagnosticTransport.armSingleEnable()
        XCTAssertTrue(
            AtriaIMUDiagnosticTransport.writeDecision(
                opcode: AtriaBLEManager.Cmd.toggleIMUMode,
                payload: [0x01],
                reason: "trial",
                arguments: quiet,
                consumeSingleEnable: false
            ).allow,
            "peek must see the armed permit"
        )
        XCTAssertTrue(
            AtriaIMUDiagnosticTransport.writeDecision(
                opcode: AtriaBLEManager.Cmd.toggleIMUMode,
                payload: [0x01],
                reason: "trial",
                arguments: quiet
            ).allow
        )
        XCTAssertFalse(
            AtriaIMUDiagnosticTransport.writeDecision(
                opcode: AtriaBLEManager.Cmd.toggleIMUMode,
                payload: [0x01],
                reason: "trial",
                arguments: quiet
            ).allow
        )
        XCTAssertFalse(
            AtriaIMUDiagnosticTransport.writeDecision(
                opcode: AtriaBLEManager.Cmd.toggleIMUMode,
                payload: [0x00],
                reason: "trial",
                arguments: quiet
            ).allow
        )
    }

    func testRecordSecondsAcceptsEqualsForm() {
        XCTAssertEqual(
            AtriaIMUDiagnosticTransport.recordDurationSeconds(
                arguments: ["--atria-imu-record-seconds=180"]
            ),
            180
        )
        XCTAssertEqual(
            AtriaIMUDiagnosticTransport.recordDurationSeconds(
                arguments: ["--atria-imu-record-seconds", "240"]
            ),
            240
        )
    }

    func testEnableAfterSecondsParsesEqualsAndSplitForms() {
        XCTAssertEqual(
            AtriaIMUDiagnosticTransport.enableAfterSeconds(
                arguments: ["--atria-imu-enable-after-seconds=180"]
            ),
            180
        )
        XCTAssertEqual(
            AtriaIMUDiagnosticTransport.enableAfterSeconds(
                arguments: ["--atria-imu-enable-after-seconds", "90"]
            ),
            90
        )
        XCTAssertNil(
            AtriaIMUDiagnosticTransport.enableAfterSeconds(arguments: quiet)
        )
    }

    func testBlockedWriteIsNotUnexpectedAndLeaseArmIsIdempotent() {
        AtriaIMUDiagnosticTransport.armQuietLease(arguments: quiet)
        let frame = encodeFrame([
            AtriaBLEManager.Packet.command,
            0x0A,
            AtriaBLEManager.Cmd.sendHistoricalData,
            0x00,
        ])
        AtriaIMUDiagnosticTransport.recordTX(
            allowed: false,
            reason: "quiet_lease_blocks_proprietary_tx:sendCommand:22",
            frame: frame
        )
        AtriaIMUDiagnosticTransport.armQuietLease(arguments: quiet)
        let snapshot = AtriaIMUDiagnosticTransport.snapshot()
        XCTAssertEqual(snapshot["blocked_writes"] as? Int, 1)
        XCTAssertEqual(snapshot["unexpected_writes"] as? Int, 0)
        XCTAssertEqual(snapshot["allowed_writes"] as? Int, 0)
    }

    func testExplicit6AWriteIsAllowedAndNotUnexpected() {
        AtriaIMUDiagnosticTransport.armQuietLease(arguments: quiet)
        AtriaIMUDiagnosticTransport.armSingleEnable()
        let frame = encodeFrame([
            AtriaBLEManager.Packet.command,
            0x0B,
            AtriaBLEManager.Cmd.toggleIMUMode,
            0x01,
        ])
        AtriaIMUDiagnosticTransport.recordTX(
            allowed: true,
            reason: "explicit_single_6a01",
            frame: frame
        )
        let snapshot = AtriaIMUDiagnosticTransport.snapshot()
        XCTAssertEqual(snapshot["allowed_writes"] as? Int, 1)
        XCTAssertEqual(snapshot["unexpected_writes"] as? Int, 0)
        XCTAssertEqual(snapshot["blocked_writes"] as? Int, 0)
    }

    func testSoftwareResetAllowsExactlyOne1D00ThenBlocksAndDoesNotSpend6A() {
        let resetArgs = [
            AtriaIMUDiagnosticTransport.quietLeaseArgument,
            AtriaIMUDiagnosticTransport.softwareResetArgument,
        ]
        AtriaIMUDiagnosticTransport.armQuietLease(arguments: resetArgs)
        XCTAssertFalse(
            AtriaIMUDiagnosticTransport.writeDecision(
                opcode: AtriaIMUDiagnosticTransport.softwareResetOpcode,
                payload: AtriaIMUDiagnosticTransport.softwareResetPayload,
                reason: "trial",
                arguments: resetArgs
            ).allow,
            "launch must not spend 0x1D on connect"
        )
        AtriaIMUDiagnosticTransport.noteNewConnectionEpoch(3)
        AtriaIMUDiagnosticTransport.armSoftwareReset()
        XCTAssertTrue(
            AtriaIMUDiagnosticTransport.writeDecision(
                opcode: AtriaIMUDiagnosticTransport.softwareResetOpcode,
                payload: AtriaIMUDiagnosticTransport.softwareResetPayload,
                reason: "trial",
                arguments: resetArgs,
                consumeSingleEnable: false
            ).allow
        )
        XCTAssertTrue(
            AtriaIMUDiagnosticTransport.writeDecision(
                opcode: AtriaIMUDiagnosticTransport.softwareResetOpcode,
                payload: AtriaIMUDiagnosticTransport.softwareResetPayload,
                reason: "trial",
                arguments: resetArgs
            ).allow
        )
        XCTAssertFalse(
            AtriaIMUDiagnosticTransport.writeDecision(
                opcode: AtriaIMUDiagnosticTransport.softwareResetOpcode,
                payload: AtriaIMUDiagnosticTransport.softwareResetPayload,
                reason: "trial",
                arguments: resetArgs
            ).allow
        )
        XCTAssertFalse(
            AtriaIMUDiagnosticTransport.shouldScheduleSingleEnableAfterSoftwareReset()
        )
        XCTAssertTrue(AtriaIMUDiagnosticTransport.softwareResetStillOnSameEpoch())
        AtriaIMUDiagnosticTransport.noteNewConnectionEpoch(4)
        XCTAssertTrue(AtriaIMUDiagnosticTransport.shouldScheduleSingleEnableAfterSoftwareReset())
        XCTAssertFalse(
            AtriaIMUDiagnosticTransport.writeDecision(
                opcode: AtriaBLEManager.Cmd.toggleIMUMode,
                payload: [0x01],
                reason: "trial",
                arguments: resetArgs
            ).allow,
            "post-reset 6A still requires armSingleEnable"
        )
        AtriaIMUDiagnosticTransport.armSingleEnable()
        XCTAssertTrue(
            AtriaIMUDiagnosticTransport.writeDecision(
                opcode: AtriaBLEManager.Cmd.toggleIMUMode,
                payload: [0x01],
                reason: "trial",
                arguments: resetArgs
            ).allow
        )
        XCTAssertFalse(
            AtriaIMUDiagnosticTransport.shouldScheduleSingleEnableAfterSoftwareReset()
        )
        XCTAssertFalse(AtriaIMUDiagnosticTransport.softwareResetStillOnSameEpoch())
    }

    func testExplicitSoftwareResetWriteIsAllowedAndNotUnexpected() {
        AtriaIMUDiagnosticTransport.armQuietLease(arguments: quiet)
        AtriaIMUDiagnosticTransport.armSoftwareReset()
        let frame = encodeFrame([
            AtriaBLEManager.Packet.command,
            0x0C,
            AtriaIMUDiagnosticTransport.softwareResetOpcode,
            0x00,
        ])
        AtriaIMUDiagnosticTransport.recordTX(
            allowed: true,
            reason: "explicit_software_reset",
            frame: frame
        )
        let snapshot = AtriaIMUDiagnosticTransport.snapshot()
        XCTAssertEqual(snapshot["allowed_writes"] as? Int, 1)
        XCTAssertEqual(snapshot["unexpected_writes"] as? Int, 0)
        XCTAssertEqual(snapshot["blocked_writes"] as? Int, 0)
    }

    func testResetAfterSecondsParsesEqualsAndSplitForms() {
        XCTAssertEqual(
            AtriaIMUDiagnosticTransport.resetAfterSeconds(
                arguments: ["--atria-imu-reset-after-seconds=45"]
            ),
            45
        )
        XCTAssertEqual(
            AtriaIMUDiagnosticTransport.resetAfterSeconds(
                arguments: ["--atria-imu-reset-after-seconds", "20"]
            ),
            20
        )
        XCTAssertNil(
            AtriaIMUDiagnosticTransport.resetAfterSeconds(arguments: quiet)
        )
    }

    func testSetupFailureDoesNotFireAfterRestoredStream5() {
        AtriaIMUDiagnosticTransport.armQuietLease(arguments: quiet)
        AtriaIMUDiagnosticTransport.noteNewConnectionEpoch(1)
        AtriaIMUDiagnosticTransport.markInitialStream5Established(alreadyNotifying: true)
        AtriaIMUDiagnosticTransport.recordSetupFailureIfStream5Missing(
            hasStream5: false,
            arguments: quiet
        )
        let snapshot = AtriaIMUDiagnosticTransport.snapshot()
        XCTAssertEqual(snapshot["setup_failure"] as? Bool, false)
        XCTAssertEqual(snapshot["initial_stream5_established"] as? Bool, true)
    }

    func testSendCommandPeeksWithoutConsumingTheSingleEnable() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func sendCommand(_ cmd: UInt8,"))
        let end = try XCTUnwrap(source.range(
            of: "private func closeWorkoutHistoricalMotionBankForHistoryServeCutover(",
            range: start.upperBound..<source.endIndex
        ))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("consumeSingleEnable: false"))
        XCTAssertTrue(body.contains("writeProprietaryWithoutResponse("))
        XCTAssertTrue(body.contains("consumeSingleEnable: true"))
        XCTAssertTrue(body.contains("explicitDiagnosticIMUEnable: diagnosticWrite.reason == \"explicit_single_6a01\""))
        XCTAssertTrue(body.contains("explicitDiagnosticSoftwareReset: diagnosticWrite.reason == \"explicit_software_reset\""))
    }

    func testInitArmsQuietLeaseBeforeCentralAndSchedulesOne6A() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "init(startsBluetooth: Bool)"))
        let end = try XCTUnwrap(source.range(
            of: "func applyLaunchAutomation(",
            range: start.upperBound..<source.endIndex
        ))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("AtriaIMUDiagnosticTransport.armQuietLease"))
        XCTAssertTrue(body.contains("scheduleDiagnosticSoftwareResetIfRequested"))
        XCTAssertTrue(body.contains("scheduleDiagnosticSingleIMUEnableIfRequested"))
        XCTAssertTrue(source.contains("sendCommand(Cmd.toggleIMUMode, [0x01]"))
        XCTAssertTrue(source.contains("AtriaIMUDiagnosticTransport.armSingleEnable()"))
        XCTAssertTrue(source.contains("noteNewConnectionEpoch(bleCallbackEpochFence.epoch)"))
        XCTAssertTrue(source.contains("link_up_notify_once"))
        XCTAssertTrue(source.contains("quiet_lease_initial_or_restored"))
        XCTAssertTrue(source.contains("skip_already_notifying"))
        XCTAssertTrue(source.contains("noteStream5DrivenConnectionTimeout"))
        let transportURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaIMUDiagnosticTransport.swift")
        let transport = try String(contentsOf: transportURL, encoding: .utf8)
        XCTAssertTrue(transport.contains("stream5_cooldown_skip"))
        XCTAssertTrue(transport.contains("stream5CooldownSeconds"))
        XCTAssertFalse(source.contains("quiet_lease_no_unarmed_cccd"))
        XCTAssertFalse(source.contains("diagnostic_restore_subscribe"))
    }

    func testZombiePredicatesStayOffWhenLeaseActive() {
        XCTAssertFalse(
            AtriaBLEManager.shouldToggleZombieProprietaryCCCD(
                connected: true,
                heartRateNotifying: true,
                packetsThisConnection: 0,
                connectedAge: 30,
                alreadyToggledThisConnection: false,
                diagnosticQuietLeaseActive: true
            )
        )
        XCTAssertFalse(
            AtriaBLEManager.shouldRefreshZombieProprietaryCCCD(
                connected: true,
                heartRateNotifying: true,
                packetsThisConnection: 0,
                connectedAge: 20,
                lastRefreshAge: nil,
                diagnosticQuietLeaseActive: true
            )
        )
        XCTAssertFalse(
            AtriaBLEManager.shouldRepairR10Notification(
                expected: true,
                connected: true,
                isNotifying: false,
                lastRepairAt: nil,
                now: Date(),
                diagnosticQuietLeaseActive: true
            )
        )
    }

    func testHarvardCommandRoundTripAndNativeTypeCount() throws {
        let frame = encodeFrame([
            AtriaBLEManager.Packet.command,
            0x0A,
            AtriaBLEManager.Cmd.toggleIMUMode,
            0x01,
        ])
        let parsed = try XCTUnwrap(AtriaIMUDiagnosticTransport.commandFromHarvardFrame(frame))
        XCTAssertEqual(parsed.sequence, 0x0A)
        XCTAssertEqual(parsed.opcode, AtriaBLEManager.Cmd.toggleIMUMode)
        XCTAssertEqual(parsed.payload, [0x01])

        AtriaIMUDiagnosticTransport.armQuietLease(arguments: quiet)
        let compact = encodeFrame([AtriaBLEManager.Packet.imu, 0x01])
        AtriaIMUDiagnosticTransport.recordAssembledFrame(
            compact,
            connectionEpoch: 1,
            historyActive: false
        )
        AtriaIMUDiagnosticTransport.recordRX(
            characteristic: AtriaBLEManager.UUIDs.strapStream5,
            bytes: Data([0x17, 0x01, 0xfb, 0x00]),
            connectionEpoch: 1
        )
        let snapshot = AtriaIMUDiagnosticTransport.snapshot()
        XCTAssertEqual(snapshot["native_33"] as? Int, 1)
        XCTAssertEqual(snapshot["compact_33"] as? Int, 1)
        XCTAssertEqual(snapshot["native_34"] as? Int, 0)
        XCTAssertEqual(snapshot["native_r10"] as? Int, 0)
        XCTAssertEqual(snapshot["native_2b"] as? Int, 0)
        XCTAssertFalse(AtriaWhoop4CommandResponse.mayMarkSuccessfulStream(.firmwareAccepted))
    }

    func testUniqueRunFilesAndStaleSummaryAreNotCurrentEvidence() throws {
        AtriaIMUDiagnosticTransport.armQuietLease(arguments: quiet)
        let first = AtriaIMUDiagnosticTransport.snapshot()
        let firstRun = try XCTUnwrap(first["run_id"] as? String)
        XCTAssertFalse(firstRun.isEmpty)
        XCTAssertNotEqual(first["started_at"] as? Double, 1_789_907_899.5349011)
        let firstRaw = try XCTUnwrap(first["raw_file"] as? String)
        let firstSummary = try XCTUnwrap(first["summary_file"] as? String)
        XCTAssertTrue(firstRaw.contains(firstRun))
        XCTAssertTrue(firstSummary.contains(firstRun))
        XCTAssertNotNil(first["pid"] as? Int)
        XCTAssertNotNil(first["monotonic_origin"] as? Double)
        XCTAssertNotNil(first["started_at_utc"] as? String)

        let documents = try XCTUnwrap(AtriaIMUDiagnosticTransport.documentsDirectoryOverride)
        let stale = documents.appendingPathComponent(
            AtriaIMUDiagnosticTransport.currentRunPointerFilename
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: stale.path))
        let staleSummary = documents.appendingPathComponent(
            "atria-imu-diagnostic-summary-v1.json"
        )
        try JSONSerialization.data(
            withJSONObject: [
                "started_at": 1_789_907_899.5349011,
                "native_2b": 0,
                "native_r10": 0,
            ],
            options: [.sortedKeys]
        ).write(to: staleSummary)

        AtriaIMUDiagnosticTransport.resetForTesting()
        AtriaIMUDiagnosticTransport.documentsDirectoryOverride = documents
        AtriaIMUDiagnosticTransport.armQuietLease(
            arguments: quiet,
            now: Date(timeIntervalSince1970: 1_790_000_000)
        )
        let second = AtriaIMUDiagnosticTransport.snapshot()
        let secondRun = try XCTUnwrap(second["run_id"] as? String)
        XCTAssertNotEqual(secondRun, firstRun)
        XCTAssertNotEqual(second["raw_file"] as? String, firstRaw)
        XCTAssertEqual(second["started_at"] as? Double, 1_790_000_000)
        XCTAssertNotEqual(second["started_at"] as? Double, 1_789_907_899.5349011)
        let staleBytes = try Data(contentsOf: staleSummary)
        let staleObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: staleBytes) as? [String: Any]
        )
        XCTAssertEqual(staleObject["started_at"] as? Double, 1_789_907_899.5349011)
        XCTAssertEqual(staleObject["native_2b"] as? Int, 0)
        XCTAssertEqual(second["native_r10"] as? Int, 0)
        XCTAssertNotEqual(second["run_id"] as? String, "quiet-lease-stale")
    }

    func testDurationExpiryRotatesRecorderAndContinuesRX() throws {
        AtriaIMUDiagnosticTransport.armQuietLease(
            arguments: quiet + [
                AtriaIMUDiagnosticTransport.recordSecondsArgument,
                "1",
            ],
            now: Date().addingTimeInterval(-5)
        )
        let firstRun = try XCTUnwrap(
            AtriaIMUDiagnosticTransport.snapshot()["run_id"] as? String
        )
        let documents = try XCTUnwrap(AtriaIMUDiagnosticTransport.documentsDirectoryOverride)
        let firstRaw = documents.appendingPathComponent(
            "atria-imu-diagnostic-raw-v1-\(firstRun).jsonl"
        )
        let firstSummary = documents.appendingPathComponent(
            "atria-imu-diagnostic-summary-v1-\(firstRun).json"
        )

        AtriaIMUDiagnosticTransport.recordRX(
            characteristic: AtriaBLEManager.UUIDs.strapStream5,
            bytes: Data([0x17]),
            connectionEpoch: 1
        )

        let second = AtriaIMUDiagnosticTransport.snapshot()
        let secondRun = try XCTUnwrap(second["run_id"] as? String)
        XCTAssertNotEqual(secondRun, firstRun)
        XCTAssertEqual(second["stop_reason"] as? String, "")
        XCTAssertFalse(
            AtriaIMUDiagnosticTransport.writeDecision(
                opcode: AtriaBLEManager.Cmd.toggleIMUMode,
                payload: [0x01],
                reason: "expired_recorder",
                arguments: quiet
            ).allow
        )
        XCTAssertTrue(UserDefaults.standard.bool(
            forKey: AtriaBLEManager.RadioDefaults.imuQuietLeaseArmed
        ))
        XCTAssertEqual(
            UserDefaults.standard.string(
                forKey: AtriaBLEManager.RadioDefaults.imuQuietLeaseRunID
            ),
            secondRun
        )

        let firstLines = try String(contentsOf: firstRaw, encoding: .utf8)
            .split(separator: "\n")
            .map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        XCTAssertTrue(firstLines.contains { $0["kind"] as? String == "overflow" })
        let firstSummaryObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: firstSummary)) as? [String: Any]
        )
        XCTAssertEqual(firstSummaryObject["stop_reason"] as? String, "recorder_duration_elapsed")

        let secondRaw = documents.appendingPathComponent(
            "atria-imu-diagnostic-raw-v1-\(secondRun).jsonl"
        )
        let secondLines = try String(contentsOf: secondRaw, encoding: .utf8)
            .split(separator: "\n")
            .map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        XCTAssertTrue(secondLines.contains { $0["kind"] as? String == "recorder_rotated" })
        XCTAssertTrue(secondLines.contains {
            $0["kind"] as? String == "rx" && ($0["hex"] as? String) == "17"
        })
    }

    func testAssembled241FixtureCountsNativeR10NotCompact33() throws {
        let frame = try Self.imu241LastPacketFixture()
        XCTAssertEqual(frame.count, 1_928)
        AtriaIMUDiagnosticTransport.armQuietLease(arguments: quiet)
        AtriaIMUDiagnosticTransport.recordRX(
            characteristic: AtriaBLEManager.UUIDs.strapStream5,
            bytes: Data(frame.prefix(244)),
            connectionEpoch: 4
        )
        AtriaIMUDiagnosticTransport.recordAssembledFrame(
            frame,
            connectionEpoch: 4,
            historyActive: false
        )
        let snapshot = AtriaIMUDiagnosticTransport.snapshot()
        XCTAssertEqual(snapshot["native_r10"] as? Int, 1)
        XCTAssertEqual(snapshot["compact_33"] as? Int, 0)
        XCTAssertEqual(snapshot["native_33"] as? Int, 0)
        XCTAssertEqual(snapshot["native_r11"] as? Int, 0)
        XCTAssertEqual(snapshot["withheld_history"] as? Int, 0)

        AtriaIMUDiagnosticTransport.recordAssembledFrame(
            frame,
            connectionEpoch: 4,
            historyActive: true
        )
        XCTAssertEqual(
            AtriaIMUDiagnosticTransport.snapshot()["withheld_history"] as? Int,
            1
        )
    }

    func testCoverageGatesStayFailWithoutLiveCompact33() {
        AtriaIMUDiagnosticTransport.armQuietLease(arguments: quiet)
        let snapshot = AtriaIMUDiagnosticTransport.snapshot()
        let live = snapshot["live_continuity_gate"] as? [String: Any]
        XCTAssertEqual(live?["passed"] as? Bool, false)
        XCTAssertEqual(live?["frame_count"] as? Int, 0)
        XCTAssertEqual(live?["missing_count"] as? Int, 0)
        XCTAssertEqual(snapshot["corrupt_count"] as? Int, 0)
        let backfill = snapshot["equal_quality_backfill_gate"] as? [String: Any]
        XCTAssertEqual(backfill?["passed"] as? Bool, false)
        XCTAssertEqual(backfill?["equal_quality_34"] as? Int, 0)
        let hist = snapshot["hist_lastNotify_continuity_gate"] as? [String: Any]
        XCTAssertEqual(hist?["passed"] as? Bool, false)
        XCTAssertEqual(hist?["provenance"] as? String, "hist_lastNotify")
    }

    /// Sep 15 152-byte fixture stores a device stamp; a typed-but-undecodable
    /// `0x33` increments corrupt_count so a 10-minute stretch is not silent.
    func testCompact33FixtureRecordsStampAndCorruptCountSeparately() {
        let liveStationaryFrame = Data(hex:
            "aa9400b5330100006d8ce1018840580695010100030568000a000a00" +
            "3dfa23fa30fa3cfa37fa2dfa30fa39fa2ffa25fac0f7c3f7bff7c7f7" +
            "b5f7b1f7a9f7a8f7bff7bbf785f38ff38bf390f39af392f39af38df3" +
            "95f395f30a000b000800040002000e000900050004000800fdfffcff" +
            "fdfff9fff9ff0000fdfffcfffbfffcfffefffefffdfffffffffffeff" +
            "fffffffffeffffff6b07b094"
        )
        AtriaIMUDiagnosticTransport.armQuietLease(arguments: quiet)
        AtriaIMUDiagnosticTransport.recordAssembledFrame(
            liveStationaryFrame,
            connectionEpoch: 1,
            historyActive: false
        )
        var stamp = liveStationaryFrame
        // Device time +41s so missing_count = Δt − 1 = 40.
        stamp[8] = 0x96  // 31_558_765 + 41 = 31_558_806
        stamp[9] = 0x8c
        stamp[10] = 0xe1
        stamp[11] = 0x01
        AtriaIMUDiagnosticTransport.recordAssembledFrame(
            stamp,
            connectionEpoch: 1,
            historyActive: false
        )
        let undecodable = encodeFrame([AtriaBLEManager.Packet.imu, 0x01])
        AtriaIMUDiagnosticTransport.recordAssembledFrame(
            undecodable,
            connectionEpoch: 1,
            historyActive: false
        )
        let snapshot = AtriaIMUDiagnosticTransport.snapshot()
        XCTAssertEqual(snapshot["compact_33"] as? Int, 3)
        XCTAssertEqual(snapshot["corrupt_count"] as? Int, 1)
        let live = snapshot["live_continuity_gate"] as? [String: Any]
        XCTAssertEqual(live?["frame_count"] as? Int, 2)
        XCTAssertEqual(live?["missing_count"] as? Int, 40)
        XCTAssertEqual(live?["passed"] as? Bool, false)
    }

    func testPersistedLeaseIntentRearmsWithoutArgvAndBlocks6A() {
        UserDefaults.standard.set(
            true,
            forKey: AtriaBLEManager.RadioDefaults.imuQuietLeaseArmed
        )
        XCTAssertTrue(
            AtriaIMUDiagnosticTransport.isQuietLeaseActive(
                arguments: [],
                environment: [:]
            )
        )
        AtriaIMUDiagnosticTransport.armQuietLease(
            arguments: [],
            now: Date(timeIntervalSince1970: 1_790_100_000)
        )
        let snapshot = AtriaIMUDiagnosticTransport.snapshot()
        XCTAssertEqual(snapshot["started_at"] as? Double, 1_790_100_000)
        XCTAssertEqual(snapshot["recorder_loss"] as? Bool, false)
        XCTAssertEqual(snapshot["pid"] as? Int, snapshot["live_pid"] as? Int)
        XCTAssertFalse((snapshot["run_id"] as? String ?? "").isEmpty)
        XCTAssertFalse(
            AtriaIMUDiagnosticTransport.writeDecision(
                opcode: AtriaBLEManager.Cmd.toggleIMUMode,
                payload: [0x01],
                reason: "connect_recovery",
                arguments: []
            ).allow
        )
        XCTAssertFalse(
            AtriaIMUDiagnosticTransport.writeDecision(
                opcode: AtriaBLEManager.Cmd.sendR10R11Realtime,
                payload: [0x01],
                reason: "connect_3f",
                arguments: []
            ).allow
        )
        XCTAssertTrue(
            AtriaIMUDiagnosticTransport.shouldInhibitAutomaticConnectIMUCommands(
                arguments: [],
                environment: [:],
                standardHROnlyMode: false
            )
        )
    }

    func testPidMismatchOpensNewRunWithoutInheritingStaleStartedAt() throws {
        AtriaIMUDiagnosticTransport.armQuietLease(
            arguments: quiet,
            now: Date(timeIntervalSince1970: 1_790_000_000)
        )
        AtriaIMUDiagnosticTransport.recordRX(
            characteristic: AtriaBLEManager.UUIDs.heartRateMeasure,
            bytes: Data([0x16, 0x40]),
            connectionEpoch: 1
        )
        let first = AtriaIMUDiagnosticTransport.snapshot()
        let firstRun = try XCTUnwrap(first["run_id"] as? String)
        let firstRaw = try XCTUnwrap(first["raw_file"] as? String)
        let firstPID = try XCTUnwrap(first["pid"] as? Int)
        XCTAssertEqual(first["started_at"] as? Double, 1_790_000_000)
        XCTAssertEqual(first["recorder_loss"] as? Bool, false)

        AtriaIMUDiagnosticTransport.processIdentifierOverride = Int32(firstPID + 9)
        AtriaIMUDiagnosticTransport.armQuietLease(
            arguments: [],
            now: Date(timeIntervalSince1970: 1_790_000_100)
        )
        let second = AtriaIMUDiagnosticTransport.snapshot()
        let secondRun = try XCTUnwrap(second["run_id"] as? String)
        XCTAssertNotEqual(secondRun, firstRun)
        XCTAssertNotEqual(second["raw_file"] as? String, firstRaw)
        XCTAssertEqual(second["started_at"] as? Double, 1_790_000_100)
        XCTAssertNotEqual(second["started_at"] as? Double, 1_790_000_000)
        XCTAssertEqual(second["pid"] as? Int, firstPID + 9)
        XCTAssertEqual(second["live_pid"] as? Int, firstPID + 9)
        XCTAssertEqual(second["recorder_pid"] as? Int, firstPID + 9)
        XCTAssertEqual(second["recorder_loss"] as? Bool, false)
        XCTAssertEqual(second["stop_reason"] as? String, "recorder_rebound_live_pid")

        let documents = try XCTUnwrap(AtriaIMUDiagnosticTransport.documentsDirectoryOverride)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: documents.appendingPathComponent(firstRaw).path
            )
        )
        let pointer = try JSONSerialization.jsonObject(
            with: Data(
                contentsOf: documents.appendingPathComponent(
                    AtriaIMUDiagnosticTransport.currentRunPointerFilename
                )
            )
        ) as? [String: Any]
        XCTAssertEqual(pointer?["run_id"] as? String, secondRun)
        XCTAssertEqual(pointer?["pid"] as? Int, firstPID + 9)
        XCTAssertEqual(pointer?["recorder_loss"] as? Bool, false)
        XCTAssertNotNil(pointer?["raw_file_sha256"] as? String)
    }

    func testRecorderLossWhenOwnerPidDiffersFromLivePid() {
        AtriaIMUDiagnosticTransport.armQuietLease(arguments: quiet)
        let owner = AtriaIMUDiagnosticTransport.snapshot()["pid"] as? Int ?? 0
        AtriaIMUDiagnosticTransport.processIdentifierOverride = Int32(owner + 1)
        let snapshot = AtriaIMUDiagnosticTransport.snapshot()
        XCTAssertEqual(snapshot["recorder_loss"] as? Bool, true)
        XCTAssertEqual(snapshot["recorder_pid"] as? Int, owner)
        XCTAssertEqual(snapshot["live_pid"] as? Int, owner + 1)
        XCTAssertNotEqual(snapshot["run_id"] as? String, "")
    }

    func testArmAndSnapshotDoNotDeadlockOnFileURL() {
        AtriaIMUDiagnosticTransport.armQuietLease(arguments: quiet)
        let snapshot = AtriaIMUDiagnosticTransport.snapshot()
        XCTAssertEqual(snapshot["recorder_loss"] as? Bool, false)
        XCTAssertFalse((snapshot["raw_file_sha256"] as? String ?? "").isEmpty)
        AtriaIMUDiagnosticTransport.persistSummary()
        let pointer = AtriaIMUDiagnosticTransport.documentsDirectoryOverride!
            .appendingPathComponent(AtriaIMUDiagnosticTransport.currentRunPointerFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pointer.path))
    }

    func testHeartRateRXIsSampledNotLoggedEveryNotification() throws {
        AtriaIMUDiagnosticTransport.armQuietLease(arguments: quiet)
        let hr = AtriaBLEManager.UUIDs.heartRateMeasure
        AtriaIMUDiagnosticTransport.recordRX(
            characteristic: hr,
            bytes: Data([0x00, 0x48]),
            connectionEpoch: 1,
            monotonic: 100
        )
        for offset in 1..<10 {
            AtriaIMUDiagnosticTransport.recordRX(
                characteristic: hr,
                bytes: Data([0x00, 0x48]),
                connectionEpoch: 1,
                monotonic: 100 + Double(offset)
            )
        }
        AtriaIMUDiagnosticTransport.recordRX(
            characteristic: AtriaBLEManager.UUIDs.strapStream5,
            bytes: Data([0xAA, 0x01]),
            connectionEpoch: 1,
            monotonic: 110
        )
        let snapshot = AtriaIMUDiagnosticTransport.snapshot()
        XCTAssertEqual(snapshot["heart_rate_rx_total"] as? Int, 10)
        let rawName = try XCTUnwrap(snapshot["raw_file"] as? String)
        let documents = try XCTUnwrap(AtriaIMUDiagnosticTransport.documentsDirectoryOverride)
        let lines = try String(
            contentsOf: documents.appendingPathComponent(rawName),
            encoding: .utf8
        )
        .split(separator: "\n")
        .map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        let hrUUID = hr.uuidString
        XCTAssertTrue(
            lines.filter {
                ($0["kind"] as? String) == "rx" && ($0["ch"] as? String) == hrUUID
            }.isEmpty,
            "2A37 must not emit full-rate rx hex"
        )
        let hrSummaries = lines.filter { ($0["kind"] as? String) == "hr_summary" }
        XCTAssertEqual(hrSummaries.count, 1)
        XCTAssertEqual(hrSummaries[0]["hex"] as? String, "0048")
        XCTAssertEqual(hrSummaries[0]["bpm"] as? Int, 72)
        let stream5UUID = AtriaBLEManager.UUIDs.strapStream5.uuidString
        let stream5Rx = lines.filter {
            ($0["kind"] as? String) == "rx" && ($0["ch"] as? String) == stream5UUID
        }
        XCTAssertEqual(stream5Rx.count, 1)
        XCTAssertEqual(stream5Rx[0]["hex"] as? String, "aa01")
    }

    func testHeartRateSummaryEmitsOnBPMChange() throws {
        AtriaIMUDiagnosticTransport.armQuietLease(arguments: quiet)
        let hr = AtriaBLEManager.UUIDs.heartRateMeasure
        AtriaIMUDiagnosticTransport.recordRX(
            characteristic: hr,
            bytes: Data([0x00, 0x48]),
            connectionEpoch: 2,
            monotonic: 200
        )
        AtriaIMUDiagnosticTransport.recordRX(
            characteristic: hr,
            bytes: Data([0x00, 0x50]),
            connectionEpoch: 2,
            monotonic: 201
        )
        let snapshot = AtriaIMUDiagnosticTransport.snapshot()
        XCTAssertEqual(snapshot["heart_rate_rx_total"] as? Int, 2)
        let rawName = try XCTUnwrap(snapshot["raw_file"] as? String)
        let documents = try XCTUnwrap(AtriaIMUDiagnosticTransport.documentsDirectoryOverride)
        let summaries = try String(
            contentsOf: documents.appendingPathComponent(rawName),
            encoding: .utf8
        )
        .split(separator: "\n")
        .compactMap { line -> [String: Any]? in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["kind"] as? String == "hr_summary" else { return nil }
            return object
        }
        XCTAssertEqual(summaries.count, 2)
        XCTAssertEqual(summaries[0]["bpm"] as? Int, 72)
        XCTAssertNil(summaries[1]["hex"])
        XCTAssertEqual(summaries[1]["bpm"] as? Int, 80)
    }

    func testSameProcessRearmKeepsRunIdAndStartedAt() {
        AtriaIMUDiagnosticTransport.armQuietLease(
            arguments: quiet,
            now: Date(timeIntervalSince1970: 1_790_200_000)
        )
        let first = AtriaIMUDiagnosticTransport.snapshot()
        AtriaIMUDiagnosticTransport.armQuietLease(
            arguments: quiet,
            now: Date(timeIntervalSince1970: 1_790_200_500)
        )
        let second = AtriaIMUDiagnosticTransport.snapshot()
        XCTAssertEqual(second["run_id"] as? String, first["run_id"] as? String)
        XCTAssertEqual(second["started_at"] as? Double, 1_790_200_000)
        XCTAssertEqual(second["raw_file"] as? String, first["raw_file"] as? String)
        XCTAssertEqual(second["recorder_loss"] as? Bool, false)
    }

    private static func imu241LastPacketFixture() throws -> Data {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 {
            url.deleteLastPathComponent()
        }
        url.appendPathComponent(
            "evidence/2026-09-20-imu-241-lastpacket-1924/lastPacketHex.bin"
        )
        return try Data(contentsOf: url)
    }
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
