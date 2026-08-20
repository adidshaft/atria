import XCTest
import SwiftUI
import UIKit
@testable import Atria

/// P4 palette consolidation (2026-08-20): `AtriaSleepStagePalette` is the one
/// shared stage-color token — the design file's stage table (Awake #FFB340,
/// REM #64D2FF, Light #4C8DFF, Deep #7B6CF0) with the SWS band folding into
/// Deep. The hypnogram card delegates to it, and the Vitals stage summary's
/// chips key it too, so a chip can never disagree with the plot it captions.
/// `AtriaSleepStageGlyph` and AtriaManualSleepSheet.swift are deliberately
/// NOT migrated — they are source-scanned by AtriaSleepStageIntegrityTests.
final class AtriaSleepStagePaletteTests: XCTestCase {

    // MARK: - Exact design hues

    private func assertComponents(_ stage: SleepStageKind,
                                  red: CGFloat,
                                  green: CGFloat,
                                  blue: CGFloat,
                                  file: StaticString = #filePath,
                                  line: UInt = #line) {
        var r: CGFloat = -1
        var g: CGFloat = -1
        var b: CGFloat = -1
        var a: CGFloat = -1
        XCTAssertTrue(UIColor(AtriaSleepStagePalette.color(for: stage))
                        .getRed(&r, green: &g, blue: &b, alpha: &a),
                      "palette colors must resolve to RGB", file: file, line: line)
        XCTAssertEqual(r, red, accuracy: 0.005, "\(stage) red", file: file, line: line)
        XCTAssertEqual(g, green, accuracy: 0.005, "\(stage) green", file: file, line: line)
        XCTAssertEqual(b, blue, accuracy: 0.005, "\(stage) blue", file: file, line: line)
        XCTAssertEqual(a, 1.0, accuracy: 0.001, "\(stage) alpha", file: file, line: line)
    }

    func testPaletteMatchesDesignStageTable() {
        assertComponents(.awake, red: 1.0, green: 0.702, blue: 0.251)   // #FFB340
        assertComponents(.rem, red: 0.392, green: 0.824, blue: 1.0)     // #64D2FF
        assertComponents(.light, red: 0.298, green: 0.553, blue: 1.0)   // #4C8DFF
        assertComponents(.deep, red: 0.482, green: 0.424, blue: 0.941)  // #7B6CF0
    }

    func testSWSFoldsToTheDeepHue() {
        XCTAssertEqual(AtriaSleepStagePalette.color(for: .sws),
                       AtriaSleepStagePalette.color(for: .deep),
                       "SWS is N3/deep for display — one hue, never a fifth color")
    }

    // MARK: - Delegation

    func testHypnogramCardDelegatesToTheSharedToken() {
        for stage in SleepStageKind.allCases {
            XCTAssertEqual(AtriaSleepHypnogramCard.color(for: stage),
                           AtriaSleepStagePalette.color(for: stage),
                           "\(stage): the card and the token must be one palette")
        }
    }

    // MARK: - Source pins (migrated surfaces key the token; pinned ones stay)

    private func source(_ fileName: String) throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/\(fileName)")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    func testVitalsStageSummaryChipsKeyTheSharedPalette() throws {
        let vitals = try source("AtriaVitalsCollectionSections.swift")
        let start = try XCTUnwrap(vitals.range(of: "struct AtriaSleepStageSummary: View"))
        let end = try XCTUnwrap(vitals.range(of: "struct AtriaSleepStageBuildingSummary",
                                             range: start.lowerBound..<vitals.endIndex))
        let summary = String(vitals[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(summary.contains("AtriaSleepStagePalette.color(for: stage)"),
                      "the Vitals chips must draw from the shared token")
        XCTAssertFalse(summary.contains("case .awake: return .orange"),
                       "the ad-hoc system-color mapping is retired from this surface")
        XCTAssertFalse(summary.contains("case .light: return .cyan"))
    }

    /// Updated for P5 (2026-08-20): the review sheet's per-stage pixels moved
    /// into `AtriaSleepStageRowStrip` (AtriaSleepStageRows.swift); the sheet
    /// mounts the strip, and the strip's dots and occurrence lanes key the
    /// shared token — never an ad-hoc color mapping.
    func testReviewSheetBarsKeyTheSharedPalette() throws {
        let monitor = try source("AtriaActivityMonitor.swift")
        let start = try XCTUnwrap(monitor.range(of: "private var stageBreakdown: some View"))
        let end = try XCTUnwrap(monitor.range(of: "private var nightVitals: some View",
                                              range: start.lowerBound..<monitor.endIndex))
        let breakdown = String(monitor[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(breakdown.contains("AtriaSleepStageRowStrip(segments: night.displayStageSegments"),
                      "the sheet mounts the row strip on the honesty-gated display segments")

        let strip = try source("AtriaSleepStageRows.swift")
        XCTAssertTrue(strip.contains("AtriaSleepStagePalette.color(for: row.stage)"),
                      "the strip's stage pixels must draw from the shared token")
        XCTAssertFalse(strip.contains("case .awake: return .orange"),
                       "no ad-hoc system-color mapping may appear in the strip")
    }
}
