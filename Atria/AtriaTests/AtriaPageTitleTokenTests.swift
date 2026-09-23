import XCTest
@testable import Atria

/// 2026-09-02: onboarding page titles were hand-set at 28pt on two pages and
/// 30pt on four, so a swipe through the flow changed title size, and none
/// scaled with Dynamic Type. One page-title token now carries them.
final class AtriaPageTitleTokenTests: XCTestCase {
    private static let appDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Atria")

    private func source(_ file: String) throws -> String {
        try String(contentsOf: Self.appDirectory.appendingPathComponent(file), encoding: .utf8)
    }

    func testPageTitleIsATextStyleSoItScales() throws {
        let tokens = try source("AtriaDesignTokens.swift")
        XCTAssertTrue(tokens.contains("static let pageTitle = Font.system(.title, design: .rounded, weight: .bold)"))
    }

    func testEveryOnboardingPageTitleUsesTheToken() throws {
        let flow = try source("AtriaOnboardingFlow.swift")
        XCTAssertEqual(flow.components(separatedBy: ".font(AtriaDesignTokens.Typography.pageTitle)").count - 1, 5)
        XCTAssertFalse(flow.contains("size: 28, weight: .bold, design: .rounded"))
        XCTAssertFalse(flow.contains("size: 30, weight: .bold, design: .rounded"))

        let content = try source("ContentView.swift")
        XCTAssertEqual(content.components(separatedBy: ".font(AtriaDesignTokens.Typography.pageTitle)").count - 1, 1,
                       "the sharing page title joins the flow")
        XCTAssertEqual(content.components(separatedBy: "size: 30, weight: .bold, design: .rounded").count - 1, 1,
                       "the live heart-rate number is a metric hero, not a page title, and keeps its size")
    }
}
