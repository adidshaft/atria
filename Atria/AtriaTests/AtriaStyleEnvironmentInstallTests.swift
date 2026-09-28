import XCTest

/// 2026-09-28: every launch logged "Accessing Environment<Bool>'s value outside
/// of being installed on a View" twice. AtriaHeaderActionButtonStyle called
/// `AtriaGlassIconButtonStyle(...).makeBody(configuration:)` directly, so that
/// style's @Environment(\.accessibilityReduceMotion) was never installed and
/// always read the default. A style whose makeBody is invoked by hand must keep
/// its environment reads inside a View it returns, not on the style itself.
final class AtriaStyleEnvironmentInstallTests: XCTestCase {

    private var appSourceDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria")
    }

    func testStylesWhoseMakeBodyIsCalledDirectlyDeclareNoEnvironment() throws {
        let files = try FileManager.default
            .contentsOfDirectory(at: appSourceDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        let sources = try files.map { try String(contentsOf: $0, encoding: .utf8) }
        let all = sources.joined(separator: "\n")

        // Names of styles constructed and then asked for makeBody by hand.
        let call = try NSRegularExpression(pattern: #"(\w+Style)\([^)]*\)\s*\.makeBody\(configuration"#)
        let names = Set(call.matches(in: all, range: NSRange(all.startIndex..., in: all)).compactMap {
            Range($0.range(at: 1), in: all).map { String(all[$0]) }
        })
        XCTAssertTrue(names.contains("AtriaGlassIconButtonStyle"),
                      "The header style still composes the glass icon style; keep this test pointed at it")

        for name in names {
            guard let start = all.range(of: "struct \(name):") else { continue }
            let rest = all[start.upperBound...]
            let end = rest.range(of: "\n}\n")?.lowerBound ?? rest.endIndex
            XCTAssertFalse(rest[..<end].contains("@Environment("),
                           "\(name) is invoked via makeBody directly, so its @Environment is never installed")
        }
    }

    func testGlassIconBodyStillHonoursReduceMotion() throws {
        let chrome = try String(contentsOf: appSourceDirectory.appendingPathComponent("AtriaSharedChrome.swift"),
                                encoding: .utf8)
        guard let start = chrome.range(of: "struct AtriaGlassIconButtonBody") else {
            return XCTFail("Missing AtriaGlassIconButtonBody")
        }
        let body = chrome[start.lowerBound...]
        XCTAssertTrue(body.contains("@Environment(\\.accessibilityReduceMotion)"))
        XCTAssertTrue(body.contains("reduceMotion ? nil : .snappy"))
    }
}
