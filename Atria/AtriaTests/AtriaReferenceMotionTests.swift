import XCTest
@testable import Atria

final class AtriaReferenceMotionTests: XCTestCase {
    func testHealthspanOrbMatchesArchivedLayerTimelinesWithoutFrameClock() throws {
        let source = try source("AtriaHealthspanDetailView.swift")
        let start = try XCTUnwrap(source.range(of: "private var orb: some View"))
        let end = try XCTUnwrap(source.range(of: "private var ageComparisonText", range: start.upperBound..<source.endIndex))
        let orb = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(orb.contains("orbExpanded ? 1.06 : 0.96"))
        XCTAssertTrue(orb.contains("orbExpanded ? 1 : 0.55"))
        XCTAssertTrue(orb.contains("orbExpanded ? 1.03 : 0.98"))
        XCTAssertTrue(orb.contains("orbExpanded ? -6 : 4"))
        XCTAssertTrue(orb.contains("cycleDuration: 5,"))
        XCTAssertTrue(orb.contains("cycleDuration: 6.5,"))
        XCTAssertTrue(orb.contains("cycleDuration: 5.8,"))
        XCTAssertTrue(orb.contains("delay: 0.6"))
        XCTAssertTrue(orb.contains("delay: 1.2"))
        XCTAssertTrue(orb.contains("cycleDuration / 2"))
        XCTAssertTrue(orb.contains("repeatForever(autoreverses: true)"))
        XCTAssertTrue(orb.contains("reduceMotion ? 1"))
        XCTAssertFalse(orb.contains("TimelineView"),
                       "Decorative Healthspan motion must stay on compositor-friendly endpoints")
        XCTAssertFalse(orb.contains("Timer"))
    }

    func testBreathworkOrbMatchesArchivedScaleGlowAndPulseEndpoints() throws {
        let source = try source("AtriaBreathworkSession.swift")
        let start = try XCTUnwrap(source.range(of: "private func breathOrb"))
        let end = try XCTUnwrap(source.range(of: "private func resultView", range: start.upperBound..<source.endIndex))
        let motion = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(motion.contains("0.82 + 0.30 * clampedProgress"))
        XCTAssertTrue(motion.contains("0.8 + 0.35 * clampedProgress"))
        XCTAssertTrue(motion.contains("0.35 + 0.5 * clampedProgress"))
        XCTAssertTrue(motion.contains("0.86 + 0.22 * clampedProgress"))
        XCTAssertTrue(motion.contains("0.5 + 0.5 * clampedProgress"))
        XCTAssertTrue(motion.contains(".frame(width: 260, height: 260)"))
        XCTAssertTrue(motion.contains(".frame(width: 210, height: 210)"))
        XCTAssertTrue(motion.contains(".frame(width: 170, height: 170)"))
        XCTAssertTrue(motion.contains("animation = .easeInOut(duration: duration)"))
        XCTAssertTrue(motion.contains("Task.sleep(for: .seconds"))
        XCTAssertTrue(motion.contains("guard !reduceMotion, pausedAt == nil else { return }"))
        XCTAssertFalse(motion.contains("TimelineView(.animation"),
                       "The gradient and native-glass orb must not redraw at display cadence")
    }

    func testRecoveryMotionIsLocalCompositorWorkAndHonorsReduceMotion() throws {
        let source = try source("AtriaOverviewSections.swift")
        let start = try XCTUnwrap(source.range(of: "private struct AtriaRecoveryScoreHero"))
        let end = try XCTUnwrap(source.range(of: "private struct AtriaStrainScoreHero", range: start.upperBound..<source.endIndex))
        let hero = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(hero.contains("@Environment(\\.accessibilityReduceMotion)"))
        XCTAssertTrue(hero.contains("repeatForever(autoreverses: true)"))
        XCTAssertTrue(hero.contains(".timingCurve(0.22, 1, 0.36, 1, duration: 2.6)"))
        XCTAssertTrue(hero.contains("ringRevealed = reduceMotion"))
        XCTAssertTrue(hero.contains("guard !reduceMotion else { return }"))
        XCTAssertFalse(hero.contains("TimelineView"))
        XCTAssertFalse(hero.contains("Timer"))
    }

    private func source(_ name: String) throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fileURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria")
            .appendingPathComponent(name)
        return try String(contentsOf: fileURL, encoding: .utf8)
    }
}
