import XCTest
@testable import Atria

/// Assessment §13.5 (2026-08-14): the two provisional composites on Health —
/// the Sleep Score blend and the Fitness Age card — mount only behind
/// default-collapsed disclosures. Measured components keep the lead. These are
/// source-scan pins in the repo's migration culture: if placement changes,
/// migrate the pin with a dated comment, never delete it.
final class AtriaHealthProvisionalPlacementTests: XCTestCase {
    private func healthScreenSource() throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Atria/AtriaHealthScreen.swift"),
            encoding: .utf8
        )
    }

    func testSleepScoreMountsOnlyBehindTheProvisionalDisclosure() throws {
        let source = try healthScreenSource()
        XCTAssertTrue(source.contains("@State private var showsProvisionalSleepScore = false"),
                      "the disclosure must default collapsed on every mount")
        let disclosure = try XCTUnwrap(
            source.range(of: "DisclosureGroup(isExpanded: $showsProvisionalSleepScore)")
        )
        let card = try XCTUnwrap(
            source.range(of: "AtriaSleepScoreCard(score: provisionalSleepScore)")
        )
        XCTAssertLessThan(disclosure.lowerBound, card.lowerBound,
                          "the provisional card renders inside the disclosure, not before it")
        let strip = try XCTUnwrap(source.range(of: "AtriaSleepConsistencyStrip("))
        XCTAssertLessThan(strip.lowerBound, card.lowerBound,
                          "measured components still lead the Sleep scope")
        XCTAssertEqual(source.components(separatedBy: "AtriaSleepScoreCard(").count - 1, 1,
                       "exactly one Sleep Score mount — no second hero path")
    }

    func testFitnessAgeMountsOnlyInsideTheCollapsedLabSection() throws {
        let source = try healthScreenSource()
        XCTAssertTrue(source.contains("@State private var showsLabSection = false"))
        let lab = try XCTUnwrap(source.range(of: "private var labSection: some View"))
        let labBodyEnd = try XCTUnwrap(
            source.range(of: "private var fitnessAgeCard: some View",
                         range: lab.upperBound..<source.endIndex)
        )
        let labBody = String(source[lab.upperBound..<labBodyEnd.lowerBound])
        XCTAssertTrue(labBody.contains("DisclosureGroup(isExpanded: $showsLabSection)"))
        XCTAssertTrue(labBody.contains("fitnessAgeCard"),
                      "the Lab disclosure is the only production route to Fitness Age")

        let scopeStart = try XCTUnwrap(source.range(of: "switch scope {"))
        let scopeEnd = try XCTUnwrap(
            source.range(of: ".task(id:", range: scopeStart.upperBound..<source.endIndex)
        )
        let scopeBody = String(source[scopeStart.upperBound..<scopeEnd.lowerBound])
        XCTAssertEqual(scopeBody.components(separatedBy: "labSection").count - 1, 2,
                       "both Trends branches mount the collapsed Lab section")
        XCTAssertFalse(scopeBody.contains("fitnessAgeCard"),
                       "no scope branch mounts the Fitness Age card directly anymore")
    }
}
