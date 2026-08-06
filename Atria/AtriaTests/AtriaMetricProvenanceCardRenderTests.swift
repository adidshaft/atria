import XCTest
import SwiftUI
@testable import Atria

/// Renders the provenance card to a real image.
///
/// This exists because the card ships BELOW THE FOLD inside a sheet, and the
/// simulator on this machine cannot be scrolled or tapped (its Xcode is missing
/// SimulatorKit.framework). Every other check -- build, static gate, unit tests
/// -- can pass while the card lays out wrongly, overflows, or renders unreadable
/// text, and nobody would know. Rendering it standalone sidesteps the fold
/// entirely: the view is laid out at full height with no scroll view involved.
///
/// The PNGs land in the simulator's own tmp, which is readable from the host at
/// ~/Library/Developer/CoreSimulator/Devices/<UDID>/data/tmp.
/// `@MainActor` because ImageRenderer is main-actor isolated -- rendering a view
/// is UI work even when no window is involved.
@MainActor
final class AtriaMetricProvenanceCardRenderTests: XCTestCase {

    /// The first ImageRenderer call in a process is materially slower than the
    /// rest (~12s vs ~0.02s here) and can return nil before it is warm, which
    /// failed whichever test happened to run first. Warm it once up front so the
    /// suite measures the card rather than the renderer's cold start.
    override func setUp() {
        super.setUp()
        _ = ImageRenderer(content: Text("warmup")).uiImage
    }

    @discardableResult
    private func render(_ provenance: AtriaMetricProvenance,
                        named name: String,
                        colorScheme: ColorScheme = .light) throws -> CGSize {
        let card = AtriaMetricProvenanceCard(provenance: provenance)
            .frame(width: 340)
            .padding(16)
            .background(Color(uiColor: .systemGroupedBackground))
            .environment(\.colorScheme, colorScheme)

        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.uiImage, "renderer produced no image")

        // Attached rather than written to disk: these run on an EPHEMERAL clone
        // of the simulator, whose tmp is destroyed with the clone, so anything
        // written there vanishes before it can be looked at. Attachments persist
        // into the .xcresult bundle and survive the clone.
        let attachment = XCTAttachment(image: image)
        attachment.name = "provenance-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)

        return image.size
    }

    /// Strain with partial wear: the case that exercises the most rows at once --
    /// lower bound, measured coverage, an amber confidence dot, and both notes.
    func testPartialStrainCardRenders() throws {
        let presentation = AtriaCompactMetricPresentation.strain(
            strain: 14.8,
            confidence: "local · partial-day wear"
        )
        let provenance = AtriaMetricProvenance(
            displayValue: presentation.displayValue,
            level: presentation.level,
            isLowerBound: presentation.isLowerBound,
            usesHRV: nil,
            hrCoverageFraction: 0.68,
            sourceLabel: "Strap heart rate",
            observedAt: nil,
            valueStatusTint: AtriaMetricZoneLevel.yellow.tint
        )

        let size = try render(provenance, named: "strain-partial")
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertGreaterThan(size.height, 0)
    }

    /// Recovery with a real score, HRV missing, and a carried-over timestamp --
    /// the combination that produces the "prev. sleep" wording plus a dated stamp.
    func testRecoveryCardRendersWithTimestampAndStatus() throws {
        let presentation = AtriaCompactMetricPresentation.recovery(
            percent: 75,
            confidence: .unverified,
            usesHRV: false,
            isProvisional: false,
            isFromPreviousSleep: false
        )
        let provenance = AtriaMetricProvenance(
            displayValue: presentation.displayValue,
            level: presentation.level,
            isLowerBound: presentation.isLowerBound,
            usesHRV: false,
            hrCoverageFraction: nil,
            sourceLabel: "Strap sleep",
            observedAt: Date(timeIntervalSince1970: 1_700_000_000),
            valueStatusTint: AtriaMetricZoneLevel.green.tint
        )

        _ = try render(provenance, named: "recovery-hrv-missing")
    }

    /// The honesty case: no computable value, so the value row must render
    /// neutral rather than picking up a colour it has not earned.
    func testUngradedCardRendersNeutral() throws {
        let provenance = AtriaMetricProvenance(
            displayValue: AtriaCompactMetricPresentation.noValue,
            level: .limited,
            isLowerBound: false,
            usesHRV: nil,
            hrCoverageFraction: nil,
            sourceLabel: "Strap heart rate",
            observedAt: nil,
            valueStatusTint: nil
        )

        _ = try render(provenance, named: "ungraded-neutral")
    }

    /// Dark mode gets its own render: the status dots and tinted values are the
    /// part most likely to lose contrast on a dark surface.
    func testPartialStrainCardRendersInDarkMode() throws {
        let presentation = AtriaCompactMetricPresentation.strain(
            strain: 14.8,
            confidence: "local · partial-day wear"
        )
        let provenance = AtriaMetricProvenance(
            displayValue: presentation.displayValue,
            level: presentation.level,
            isLowerBound: presentation.isLowerBound,
            usesHRV: nil,
            hrCoverageFraction: 0.68,
            sourceLabel: "Strap heart rate",
            observedAt: nil,
            valueStatusTint: AtriaMetricZoneLevel.yellow.tint
        )

        _ = try render(provenance, named: "strain-partial-dark", colorScheme: .dark)
    }
}
