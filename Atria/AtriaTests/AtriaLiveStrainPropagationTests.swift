import XCTest

final class AtriaLiveStrainPropagationTests: XCTestCase {
    func testAcceptedSamplesRefreshHeroStrainWithoutRequestingDiagnostics() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(contentsOf: testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaHomeView.swift"), encoding: .utf8)
        let bindStart = try XCTUnwrap(source.range(of: "private func bind()"))
        let publishStatus = try XCTUnwrap(source.range(of: "private func publishStatus()",
                                                       range: bindStart.upperBound..<source.endIndex))
        let bind = String(source[bindStart.lowerBound..<publishStatus.lowerBound])

        let sampleStart = try XCTUnwrap(bind.range(of: "ble.$sessionSampleCount\n            .removeDuplicates()\n            .dropFirst()"))
        let sampleEnd = try XCTUnwrap(bind.range(of: ".store(in: &cancellables)",
                                                 range: sampleStart.upperBound..<bind.endIndex))
        let samplePipeline = String(bind[sampleStart.lowerBound..<sampleEnd.upperBound])

        XCTAssertTrue(samplePipeline.contains(".throttle(for: .milliseconds(1500)"),
                      "Live load projection must be bounded instead of rebuilding on every beat")
        XCTAssertTrue(samplePipeline.contains("self?.refreshHeroSnapshot()"),
                      "Accepted samples must propagate live day strain into HeroStore")
        XCTAssertFalse(samplePipeline.contains("diagnosticsRefreshSubject"),
                       "Live strain refresh must not trigger heavyweight diagnostics")
        XCTAssertFalse(samplePipeline.contains("requestActivityProjectionRefresh"),
                       "Live strain refresh must not rebuild the Activity archive")
    }
}
