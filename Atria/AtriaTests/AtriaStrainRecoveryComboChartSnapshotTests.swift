import XCTest
import SwiftUI
@testable import Atria

/// Renders the G1 Strain & Recovery combo to a PNG for visual verification when
/// the on-device mirror can't scroll to the card. Not an assertion test — it
/// proves the chart composes and writes an image whose path is printed for review.
final class AtriaStrainRecoveryComboChartSnapshotTests: XCTestCase {
    @MainActor
    func testRenderComboForVisualReview() throws {
        let base = Date(timeIntervalSince1970: 1_785_000_000)
        func point(_ dayOffset: Int, _ value: Double) -> AtriaDetailChartPoint {
            AtriaDetailChartPoint(day: base.addingTimeInterval(Double(dayOffset) * 86_400),
                                  value: value,
                                  tint: .primary)
        }
        // A week with a realistic strain/recovery inverse relationship + one
        // red-band day, so every dot color path (green/yellow/red) is exercised.
        let strainVals: [Double] = [8, 12, 15, 10, 17, 6, 13]
        let recoveryVals: [Double] = [90, 69, 65, 63, 45, 82, 75]
        let strain = strainVals.enumerated().map { point($0.offset, $0.element) }
        let recovery = recoveryVals.enumerated().map { point($0.offset, $0.element) }

        let content = AtriaStrainRecoveryComboChart(strain: strain,
                                                    recovery: recovery,
                                                    rangeLabel: "This week")
            .frame(width: 360, height: 230)
            .padding(16)
            .background(Color.black)
            .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 3
        guard let image = renderer.uiImage, let data = image.pngData() else {
            XCTFail("ImageRenderer produced no image")
            return
        }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = "strain_recovery_combo.png"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertGreaterThan(data.count, 1000, "expected a non-trivial PNG")
    }
}
