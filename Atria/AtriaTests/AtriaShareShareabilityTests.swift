import XCTest
import UIKit
@testable import Atria

/// 2026-09-02 owner directive: nobody posts "--", "No sleep yet" or "Learning"
/// on a story. A share card carries only real readings, and a sheet with
/// nothing real to show says so instead of rendering a card of dashes.
final class AtriaShareShareabilityTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    private func dailySnapshot(recovery: String, sleep: String, strain: String,
                               hrv: String = "--", rhr: String = "--") -> AtriaShareSnapshot {
        AtriaShareSnapshot(
            date: Date(timeIntervalSince1970: 1_800_000_000),
            recovery: .init(title: "Recovery", value: recovery, detail: "no sleep yet",
                            tintHex: "#42f59b", fill: nil),
            sleep: .init(title: "Sleep", value: sleep, detail: "No sleep this cycle",
                         tintHex: "#56d7ff", fill: nil),
            strain: .init(title: "Strain", value: strain, detail: "learning",
                          tintHex: "#ff8a3d", fill: nil),
            stats: [
                .init(id: "hrv", title: "HRV", value: hrv, detail: "learning"),
                .init(id: "rhr", title: "RHR", value: rhr, detail: "learning")
            ])
    }

    func testPlaceholdersAndNotReadyWordsAreNeverShareable() {
        for value in ["", "   ", "--", "Learning", "learning", "Building", "\n--\n"] {
            XCTAssertFalse(AtriaShareSnapshot.valueIsShareable(value), "\"\(value)\" must not reach a story")
        }
        for value in ["82%", "7h 42m", "11.4", "45 ms", "0.0", "Tue 3"] {
            XCTAssertTrue(AtriaShareSnapshot.valueIsShareable(value), "\"\(value)\" is a real reading")
        }
    }

    func testDailySnapshotWithoutAnyReadingHasNothingToShare() {
        let empty = dailySnapshot(recovery: "--", sleep: "--", strain: "--")
        XCTAssertFalse(empty.hasShareableContent)
        XCTAssertTrue(empty.shareableRings.isEmpty)
        XCTAssertTrue(empty.defaultStats.isEmpty)
    }

    func testOneRealRingOrStatMakesTheDailyCardShareable() {
        XCTAssertTrue(dailySnapshot(recovery: "--", sleep: "7h 12m", strain: "--").hasShareableContent)
        XCTAssertTrue(dailySnapshot(recovery: "--", sleep: "--", strain: "--", rhr: "52").hasShareableContent)
        let sleepOnly = dailySnapshot(recovery: "--", sleep: "7h 12m", strain: "--")
        XCTAssertEqual(sleepOnly.shareableRings.map(\.title), ["Sleep"])
    }

    func testWeeklySnapshotSharesOnlyWithARealNumber() {
        let building = AtriaWeeklyShareSnapshot(date: Date(), title: "My week on Atria",
                                                recoveryAverage: "--", recoveryDelta: "",
                                                sleepConsistency: "--", bestDay: "--",
                                                hardestDay: "--", note: nil)
        XCTAssertFalse(building.hasShareableContent)
        let partial = AtriaWeeklyShareSnapshot(date: Date(), title: "My week on Atria",
                                               recoveryAverage: "--", recoveryDelta: "",
                                               sleepConsistency: "64%", bestDay: "--",
                                               hardestDay: "--", note: nil)
        XCTAssertTrue(partial.hasShareableContent)
    }

    @MainActor
    func testEmptyDailyCardStillRendersWithoutPlaceholders() throws {
        // The renderer must not crash on an all-placeholder snapshot (tracks
        // only); the composer never shows it, but the PNG path is shared.
        let empty = dailySnapshot(recovery: "--", sleep: "--", strain: "--")
        let png = try AtriaShareCardRenderer.renderPNGData(snapshot: empty,
                                                          format: .story,
                                                          selectedStatIDs: ["recovery", "strain", "sleep"],
                                                          lightCanvas: false)
        XCTAssertNotNil(UIImage(data: png))
    }

    func testCardAndSheetsGateOnShareability() throws {
        let share = try source("Atria/Atria/AtriaShareCard.swift")
        // Daily card: chips only for real values; ring labels only with a value;
        // the concentric centre reads the first ring that has one.
        XCTAssertTrue(share.contains("].filter { AtriaShareSnapshot.valueIsShareable($0.value) }"))
        XCTAssertTrue(share.contains("if AtriaShareSnapshot.valueIsShareable(ringData.value) {"))
        XCTAssertTrue(share.contains("if let hero = concentricHero {"))
        XCTAssertFalse(share.contains("Text(recoveryHeroValue)"),
                       "the concentric centre must not print a placeholder recovery value")
        // Sheets: an honest empty state replaces the composer when nothing is real.
        XCTAssertTrue(share.contains("struct AtriaShareEmptyStateView: View"))
        XCTAssertTrue(share.contains("Nothing to share yet"))
        XCTAssertEqual(share.components(separatedBy: "if snapshot.hasShareableContent {").count - 1, 2,
                       "daily and weekly sheets both gate their composer")
        // Weekly card: rows and hero only with real numbers; no building copy.
        XCTAssertTrue(share.contains("ForEach(weeklyStatRows, id: \\.title)"))
        XCTAssertTrue(share.contains("if !snapshot.recoveryDelta.isEmpty {"))
        let overview = try source("Atria/Atria/AtriaOverviewSections.swift")
        XCTAssertTrue(overview.contains("recoveryDelta: displayedReport.recoveryDeltaVsPriorWeek == nil ? \"\" : recoveryDeltaText,"),
                      "the weekly card never carries the 'comparison building' line")
    }
}
