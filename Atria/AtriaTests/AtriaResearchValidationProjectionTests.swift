import XCTest
@testable import Atria

final class AtriaResearchValidationProjectionTests: XCTestCase {
    func testValidationContainerScopesObservationToLeafHosts() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaVitalsCollectionSections.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let contentStart = try XCTUnwrap(source.range(of: "struct AtriaCollectionResearchValidationContent: View"))
        let dutyCycleStart = try XCTUnwrap(
            source.range(of: "private struct AtriaDutyCycleToggleCard: View", range: contentStart.upperBound..<source.endIndex)
        )
        let chain = String(source[contentStart.lowerBound..<dutyCycleStart.lowerBound])
        let containerEnd = try XCTUnwrap(
            chain.range(of: "struct AtriaCollectionResearchEvidenceState: Equatable")
        )
        let container = String(chain[..<containerEnd.lowerBound])

        XCTAssertFalse(container.contains("@ObservedObject"))
        XCTAssertTrue(container.contains("AtriaCollectionResearchEvidenceHost(store: store, ble: ble)"))
        XCTAssertTrue(container.contains("AtriaCollectionProfilePickerHost("))
        XCTAssertTrue(chain.contains("@StateObject private var projectionStore: AtriaCollectionResearchEvidenceProjectionStore"))
        XCTAssertTrue(chain.contains("store.$imuAuditSummary"))
        XCTAssertTrue(chain.contains("store.$sleepHistorySnapshot"))
        XCTAssertTrue(chain.contains("store.$researchManeuverProbeCorrelationSummary"))
        XCTAssertTrue(chain.contains("ble.$strapModel"))
        XCTAssertFalse(chain.contains("store.objectWillChange"))
        XCTAssertFalse(chain.contains("store.$dashboardRevision"))
    }
}
