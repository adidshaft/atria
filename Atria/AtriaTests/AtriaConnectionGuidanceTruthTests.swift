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
