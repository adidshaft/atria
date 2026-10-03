import XCTest
@testable import Atria

final class AtriaConnectionGuidanceTruthTests: XCTestCase {
    private func appSource() throws -> String {
        let testsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appURL = testsURL.deletingLastPathComponent().appendingPathComponent("Atria")
        return try String(contentsOf: appURL.appendingPathComponent("AtriaHomeView.swift"),
                          encoding: .utf8)
    }

    // 2026-10-03 device after an iOS update: ~8 s of data, then CBError 6,
    // every ~12 s, until the iPhone was restarted. The card said "re-pair".
    func testWedgedBluetoothStackIsDetectedFromTheShortTimeoutRhythm() {
        var detector = AtriaBluetoothWedgeDetector()
        let start = Date(timeIntervalSince1970: 1_791_000_000)
        for cycle in 0..<4 {
            XCTAssertFalse(detector.recordDisconnect(
                at: start.addingTimeInterval(Double(cycle) * 12),
                connectedFor: 11, timedOut: true))
        }
        XCTAssertTrue(detector.recordDisconnect(
            at: start.addingTimeInterval(48), connectedFor: 11, timedOut: true),
            "five answered-then-timed-out links in three minutes")
        detector.recordHealthyConnection()
        XCTAssertFalse(detector.suspected)

        var walkingAway = AtriaBluetoothWedgeDetector()
        for cycle in 0..<6 {
            XCTAssertFalse(walkingAway.recordDisconnect(
                at: start.addingTimeInterval(Double(cycle) * 60),
                connectedFor: 300, timedOut: true),
                "links that held for minutes are range, not the wedge")
        }
        var userCancels = AtriaBluetoothWedgeDetector()
        for cycle in 0..<6 {
            XCTAssertFalse(userCancels.recordDisconnect(
                at: start.addingTimeInterval(Double(cycle) * 12),
                connectedFor: 11, timedOut: false))
        }
        var slow = AtriaBluetoothWedgeDetector()
        for cycle in 0..<6 {
            XCTAssertFalse(slow.recordDisconnect(
                at: start.addingTimeInterval(Double(cycle) * 50),
                connectedFor: 11, timedOut: true),
                "spread over more than three minutes is not the rhythm")
        }
    }

    func testWedgedStackAdvisesRestartBeforeRePairing() throws {
        let source = try appSource()
        let derive = try XCTUnwrap(source.range(of: "static func derive(live: AtriaHomeModel.CoreLiveState,"))
        let body = String(source[derive.lowerBound...].prefix(2_400))
        let wedge = try XCTUnwrap(body.range(of: "live.bluetoothStackWedgeSuspected"))
        let statusSwitch = try XCTUnwrap(body.range(of: "switch live.status {"))
        XCTAssertLessThan(wedge.lowerBound, statusSwitch.lowerBound)
        XCTAssertTrue(body.contains("imperative: \"Restart your iPhone\""))
        XCTAssertTrue(source.contains("title == Self.restartIPhoneTitle"),
                      "the detector is already debounced; show at once")
    }

    func testOnlyRealLinkRepairDomainsOfferConnectionGuide() {
        XCTAssertTrue(AtriaConnectionGuidanceDomain.bluetoothLink.offersConnectionGuide)
        XCTAssertTrue(AtriaConnectionGuidanceDomain.appCoexistence.offersConnectionGuide)

        XCTAssertFalse(AtriaConnectionGuidanceDomain.strapPower.offersConnectionGuide)
        XCTAssertFalse(AtriaConnectionGuidanceDomain.wearSignal.offersConnectionGuide)
    }

    func testConnectedMetricAcquisitionNeverBecomesAGlobalConnectionBanner() throws {
        let source = try appSource()
        let diagnosisStart = try XCTUnwrap(
            source.range(of: "private struct AtriaConnectionDiagnosis: Equatable")
        )
        let diagnosisEnd = try XCTUnwrap(
            source.range(of: "private struct AtriaConnectionDiagnosisBanner: View, Equatable",
                         range: diagnosisStart.upperBound..<source.endIndex)
        )
        let diagnosisSource = String(
            source[diagnosisStart.lowerBound..<diagnosisEnd.lowerBound]
        )

        XCTAssertFalse(diagnosisSource.contains("title: \"HRV settling\""))
        XCTAssertFalse(diagnosisSource.contains("title: \"Beat-to-beat waiting\""))
        XCTAssertFalse(diagnosisSource.contains("live.needsRRQualityCoach"))

        let bannerStart = try XCTUnwrap(
            source.range(of: "private struct AtriaConnectionDiagnosisBanner: View, Equatable")
        )
        let bannerSource = String(source[bannerStart.lowerBound...])
        XCTAssertTrue(
            bannerSource.contains("if diagnosis.guidanceDomain.offersConnectionGuide")
        )
    }

    func testOtherConnectedNonLinkStatesDoNotOfferReconnectGuide() throws {
        let source = try appSource()
        for expected in [
            "title: \"Strap battery too low\"",
            "title: \"Fit check needed\"",
            "title: \"Strap battery low\"",
        ] {
            let title = try XCTUnwrap(source.range(of: expected))
            let following = String(source[title.lowerBound..<source.index(
                title.lowerBound,
                offsetBy: min(520, source.distance(from: title.lowerBound, to: source.endIndex))
            )])
            XCTAssertTrue(
                following.contains("guidanceDomain: .strapPower")
                    || following.contains("guidanceDomain: .wearSignal"),
                "\(expected) must remain informational instead of routing to reconnect help"
            )
        }
    }
}
