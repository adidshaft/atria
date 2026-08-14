import XCTest
@testable import Atria

/// WP-0 safety rails: pins the central MetricAuthority contract so later work
/// cannot silently regress the single-authority and fail-closed rules.
final class AtriaMetricAuthorityGuardTests: XCTestCase {
    private var appDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria")
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AtriaTests
            .deletingLastPathComponent()   // Atria (project dir)
            .deletingLastPathComponent()   // repo root
    }

    func testCentralMetricAuthorityBlockExists() throws {
        let source = try String(contentsOf: appDirectory.appendingPathComponent("Metrics.swift"),
                                encoding: .utf8)
        XCTAssertTrue(source.contains("enum MetricAuthority {}"),
                      "Metrics.swift must carry the central MetricAuthority policy block")
        XCTAssertTrue(source.contains("One authority per concept."))
        XCTAssertTrue(source.contains("Fail-closed rules."))
        XCTAssertTrue(source.contains("Never promote HRV from heart-rate-only data."))
        XCTAssertTrue(source.contains("Never substitute population averages"))
        XCTAssertTrue(source.contains("docs/16-metric-authority-and-confidence-policy.md"))
    }

    /// The deprecated ungated recovery estimators must never gain a new caller.
    /// Allowed sites: their definitions/wrappers in AtriaAnalytics.swift and
    /// Metrics.swift (which includes the startup CalibrationExamples self-check
    /// that consumes the legacy math as a pass/fail log line, never a UI value).
    func testDeprecatedUngatedRecoveryEstimatorsHaveNoNewCallers() throws {
        let allowed: Set<String> = ["Metrics.swift", "AtriaAnalytics.swift"]
        let forbiddenTokens = ["Recovery.restingOnly(",
                               "estimate(hrvNow:",
                               "Metrics.recovery(restingNow:",
                               "Metrics.recovery(hrvNow:"]
        let files = try FileManager.default.contentsOfDirectory(at: appDirectory,
                                                                includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 100, "app source enumeration should see the full module")
        for file in files where !allowed.contains(file.lastPathComponent) {
            let source = try String(contentsOf: file, encoding: .utf8)
            for token in forbiddenTokens where source.contains(token) {
                XCTFail("\(file.lastPathComponent) calls deprecated ungated estimator via `\(token)` — production surfaces must use recoveryV2")
            }
        }
    }

    /// The forward-looking policy doc (confidence tier + provenance declaration
    /// for every new metric) must exist and keep its binding language.
    func testConfidencePolicyDocumentAnchorsHonestyRule() throws {
        let doc = repoRoot
            .appendingPathComponent("docs")
            .appendingPathComponent("16-metric-authority-and-confidence-policy.md")
        let text = try String(contentsOf: doc, encoding: .utf8)
        XCTAssertTrue(text.contains("No fabricated data. Estimates are labeled estimates."))
        XCTAssertTrue(text.contains("Confidence tier"))
        XCTAssertTrue(text.contains("Provenance"))
        XCTAssertTrue(text.contains("Freeze semantics"))
        XCTAssertTrue(text.contains("never a population average"))
    }
}
