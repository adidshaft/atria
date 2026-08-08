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

    func testShippingTargetsShareANonInitialBuildNumber() throws {
        let projectDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let project = try String(
            contentsOf: projectDirectory
                .appendingPathComponent("Atria.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        let buildNumbers = project
            .split(separator: "\n")
            .compactMap { line -> Int? in
                let marker = "CURRENT_PROJECT_VERSION = "
                guard let range = line.range(of: marker) else { return nil }
                return Int(line[range.upperBound...].dropLast())
            }

        XCTAssertEqual(buildNumbers.count, 6)
        XCTAssertEqual(Set(buildNumbers).count, 1,
                       "app, widget, and tests must ship with one build number")
        XCTAssertGreaterThanOrEqual(buildNumbers.first ?? 0, 2,
                                    "build 1 has already been uploaded")
    }

    func testTestFlightReleaseDeclaresEncryptionAndExternalEligibility() throws {
        let projectDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let project = try String(
            contentsOf: projectDirectory
                .appendingPathComponent("Atria.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        let exportOptions = try String(
            contentsOf: projectDirectory
                .appendingPathComponent("ExportOptions-TestFlight.plist"),
            encoding: .utf8
        )

        XCTAssertEqual(
            project.components(separatedBy: "INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO;").count - 1,
            2,
            "both app configurations must answer export compliance in the archived Info.plist"
        )
        XCTAssertTrue(exportOptions.contains("<string>app-store-connect</string>"))
        XCTAssertTrue(exportOptions.contains("<key>testFlightInternalTestingOnly</key>\n\t<false/>"),
                      "the uploaded build must remain eligible for external beta groups")
    }
}
