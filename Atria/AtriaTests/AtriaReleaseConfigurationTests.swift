import XCTest

final class AtriaReleaseConfigurationTests: XCTestCase {
    func testShippingTargetsAreExplicitlyIPhoneOnly() throws {
        let projectDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let project = try String(
            contentsOf: projectDirectory
                .appendingPathComponent("Atria.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )

        XCTAssertFalse(project.contains("TARGETED_DEVICE_FAMILY = \"1,2\";"))
        XCTAssertEqual(
            project.components(separatedBy: "TARGETED_DEVICE_FAMILY = 1;").count - 1,
            6,
            "app, widget, and test targets must agree on the supported device family"
        )
    }

    func testAlarmKitAuthorizationPurposeIsDeclared() throws {
        let projectDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let info = try String(
            contentsOf: projectDirectory.appendingPathComponent("Info.plist"),
            encoding: .utf8
        )

        XCTAssertTrue(info.contains("<key>NSAlarmKitUsageDescription</key>"))
        XCTAssertTrue(info.contains("only when you choose a wake time"))
    }
}
