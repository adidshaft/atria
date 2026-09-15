import XCTest

final class AtriaAppReviewDemoUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testFreshInstallExploreSampleDataVisitsEveryTabThenReturnsToSetup() {
        let app = XCUIApplication()
        app.launchArguments.append("--atria-ui-fresh-install")
        app.launch()

        let explore = app.buttons["atria.onboarding.explore-sample-data"]
        XCTAssertTrue(explore.waitForExistence(timeout: 15))
        explore.tap()

        let badge = app.descendants(matching: .any)["atria.demo.sample-data-badge"]
        XCTAssertTrue(badge.waitForExistence(timeout: 10), "Demo banner should remain visible after entering sample data")

        for tab in ["Today", "Vitals", "Journal", "Activity", "Assistant", "Strap"] {
            let button = app.tabBars.buttons[tab]
            XCTAssertTrue(button.waitForExistence(timeout: 8), "Missing tab \(tab)")
            button.tap()
            XCTAssertTrue(
                badge.waitForExistence(timeout: 5)
                    || app.staticTexts["Sample data"].waitForExistence(timeout: 3),
                "\(tab) should keep the Sample data mark"
            )
            XCTAssertFalse(app.staticTexts["Unable to Load"].exists)
            XCTAssertFalse(app.staticTexts["Something went wrong"].exists)
        }

        let erase = app.buttons["atria.demo.erase-and-return"]
        XCTAssertTrue(erase.waitForExistence(timeout: 8))
        erase.tap()
        XCTAssertTrue(explore.waitForExistence(timeout: 15), "Exit should return to first-run setup")
    }
}
