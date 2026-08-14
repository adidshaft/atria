import XCTest
@testable import Atria

/// WP-6 / GAP-06 — the composite Sleep Score stays provisional, component-
/// honest, and structurally unable to consume the unvalidated overnight-load
/// projection.
final class AtriaSleepScoreProvisionalTests: XCTestCase {
    func testProvisionalEntryPointPinsOvernightLoadMissing() {
        let score = AtriaSleepScore.provisional(sufficiencyPercent: 90,
                                                consistencyPercent: 80,
                                                efficiencyPercent: 88)
        XCTAssertTrue(score.isProvisional)
        XCTAssertTrue(score.missingComponents.contains(.overnightLoad),
                      "the production entry point cannot even offer overnight load")
        XCTAssertNotNil(score.score)

        // Renormalized provisional weights over the three present components.
        let expected = (90 * 0.50 + 80 * 0.25 + 88 * 0.15) / 0.90
        XCTAssertEqual(score.score, Int(expected.rounded()))
    }

    func testCompositeWithheldBelowMinimumComponentsAndNeverSubstitutes() {
        let single = AtriaSleepScore.provisional(sufficiencyPercent: 90,
                                                 consistencyPercent: nil,
                                                 efficiencyPercent: nil)
        XCTAssertNil(single.score,
                     "one component is Sufficiency on its own, never a relabeled composite")
        XCTAssertEqual(single.missingComponents.count, 3)

        let two = AtriaSleepScore.provisional(sufficiencyPercent: 90,
                                              consistencyPercent: 70,
                                              efficiencyPercent: nil)
        XCTAssertNotNil(two.score)
        XCTAssertEqual(two.presentComponents, [.sufficiency, .consistency])
    }

    func testScoreAndComponentsRoundTripForFuturePersistence() throws {
        let original = AtriaSleepScore.provisional(sufficiencyPercent: 84,
                                                   consistencyPercent: 76,
                                                   efficiencyPercent: 91)
        let restored = try JSONDecoder().decode(AtriaSleepScore.self,
                                                from: JSONEncoder().encode(original))
        XCTAssertEqual(restored, original,
                       "the receipt (components + score + provisional flag) must survive storage")
        XCTAssertTrue(restored.isProvisional)
    }

    /// No production call site may reach `make(validatedOvernightLoadPercent:)`
    /// directly — the pin lives at the API, and this keeps it there.
    func testProductionCallSitesUseTheProvisionalEntryPoint() throws {
        let appDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria")
        let files = try FileManager.default.contentsOfDirectory(at: appDirectory,
                                                                includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "AtriaSleepBudget.swift" }
        XCTAssertGreaterThan(files.count, 100)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(source.contains("validatedOvernightLoadPercent:"),
                           "\(file.lastPathComponent) bypasses AtriaSleepScore.provisional — the overnight-load slot is validation-gated")
        }
    }
}
