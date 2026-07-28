import XCTest
@testable import Atria

final class AtriaConnectionGuidanceTruthTests: XCTestCase {
    private func appSource() throws -> String {
        let testsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appURL = testsURL.deletingLastPathComponent().appendingPathComponent("Atria")
        return try String(contentsOf: appURL.appendingPathComponent("AtriaHomeView.swift"),
                          encoding: .utf8)
    }

    func testOnlyRealLinkRepairDomainsOfferConnectionGuide() {
        XCTAssertTrue(AtriaConnectionGuidanceDomain.bluetoothLink.offersConnectionGuide)
        XCTAssertTrue(AtriaConnectionGuidanceDomain.appCoexistence.offersConnectionGuide)

        XCTAssertFalse(AtriaConnectionGuidanceDomain.strapPower.offersConnectionGuide)
        XCTAssertFalse(AtriaConnectionGuidanceDomain.wearSignal.offersConnectionGuide)
        XCTAssertFalse(AtriaConnectionGuidanceDomain.metricAcquisition.offersConnectionGuide)
    }

    func testConnectedHRVSettlingIsInformationalAndCannotOpenReconnectGuide() throws {
        let source = try appSource()
        let branchStart = try XCTUnwrap(
            source.range(of: "case .connected where live.needsRRQualityCoach && hasLivePulseSignal:")
        )
        let branchEnd = try XCTUnwrap(
            source.range(of: "case _ where live.batteryLevel",
                         range: branchStart.upperBound..<source.endIndex)
        )
        let hrvBranch = String(source[branchStart.lowerBound..<branchEnd.lowerBound])

        XCTAssertTrue(hrvBranch.contains("title: \"HRV settling\""))
        XCTAssertTrue(hrvBranch.contains("Heart rate is live. HRV needs steady beat-to-beat windows"))
        XCTAssertTrue(hrvBranch.contains("guidanceDomain: .metricAcquisition"))
        XCTAssertFalse(hrvBranch.localizedCaseInsensitiveContains("reconnect"))
        XCTAssertFalse(hrvBranch.localizedCaseInsensitiveContains("Bluetooth"))

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
            "title: \"Beat-to-beat waiting\"",
            "title: \"Strap battery low\"",
        ] {
            let title = try XCTUnwrap(source.range(of: expected))
            let following = String(source[title.lowerBound..<source.index(
                title.lowerBound,
                offsetBy: min(520, source.distance(from: title.lowerBound, to: source.endIndex))
            )])
            XCTAssertTrue(
                following.contains("guidanceDomain: .strapPower")
                    || following.contains("guidanceDomain: .wearSignal")
                    || following.contains("guidanceDomain: .metricAcquisition"),
                "\(expected) must remain informational instead of routing to reconnect help"
            )
        }
    }
}
