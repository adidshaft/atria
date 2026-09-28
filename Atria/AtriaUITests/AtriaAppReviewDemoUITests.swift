import XCTest

final class AtriaAppReviewDemoUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testFreshInstallExploreSampleDataVisitsEveryTabThenReturnsToSetup() {
        let app = XCUIApplication()
        let explore = launchAtFirstRunSetup(app)
        explore.tap()

        let badge = app.descendants(matching: .any)["atria.demo.sample-data-badge"]
        XCTAssertTrue(badge.waitForExistence(timeout: 15), "Demo banner should remain visible after entering sample data")

        let today = app.tabBars.buttons["Today"]
        XCTAssertTrue(today.waitForExistence(timeout: 12))
        today.tap()
        assertDemoSurfaceAlive(in: app, badge: badge, name: "Today")

        openMetric(in: app, identifier: "atria.today.ring.sleep", detail: "atria.metric.detail.sleep")
        assertDemoSurfaceAlive(in: app, badge: badge, name: "Sleep detail")
        dismissOpenSheet(in: app)

        openMetric(in: app, identifier: "atria.today.ring.recovery", detail: "atria.metric.detail.recovery")
        assertDemoSurfaceAlive(in: app, badge: badge, name: "Recovery detail")
        dismissOpenSheet(in: app)

        openMetric(in: app, identifier: "atria.today.ring.strain", detail: "atria.metric.detail.strain")
        assertDemoSurfaceAlive(in: app, badge: badge, name: "Strain detail")
        dismissOpenSheet(in: app)

        if app.descendants(matching: .any)["atria.today.weekly-plan"].waitForExistence(timeout: 3) {
            app.descendants(matching: .any)["atria.today.weekly-plan"].tap()
            assertNoDeadEnd(in: app, name: "Weekly plan")
            dismissOpenSheet(in: app)
        }

        openMetric(in: app, identifier: "atria.today.metric.steps", detail: "atria.metric.detail.steps")
        assertDemoSurfaceAlive(in: app, badge: badge, name: "Steps detail")
        dismissOpenSheet(in: app)

        let todayRead = app.descendants(matching: .any)["atria.today.read"]
        XCTAssertFalse(
            todayRead.waitForExistence(timeout: 2),
            "Today must not clone Sleep / Recovery / Strain as a second ring set"
        )
        let insightsGlance = app.descendants(matching: .any)["atria.today.metric.insights"]
        if insightsGlance.waitForExistence(timeout: 2) {
            insightsGlance.tap()
            XCTAssertTrue(
                app.descendants(matching: .any)["atria.insights.lookback"].waitForExistence(timeout: 6),
                "Insights must expose Day/Week/Month"
            )
            assertDemoSurfaceAlive(in: app, badge: badge, name: "Today's read")
            dismissOpenSheet(in: app)
        }

        // The tab bar is Today, Vitals, Journal, Activity (Assistant and Strap
        // moved into Today's actions menu).
        for tab in ["Vitals", "Journal", "Activity"] {
            let button = app.tabBars.buttons[tab]
            XCTAssertTrue(button.waitForExistence(timeout: 8), "Missing tab \(tab)")
            button.tap()
            assertDemoSurfaceAlive(in: app, badge: badge, name: tab)
        }

        app.tabBars.buttons["Vitals"].tap()
        openMetric(in: app, identifier: "atria.vitals.hrv", detail: "atria.metric.detail.hrv")
        assertDemoSurfaceAlive(in: app, badge: badge, name: "HRV detail")
        dismissOpenSheet(in: app)
        openMetric(in: app, identifier: "atria.vitals.resting-hr", detail: "atria.metric.detail.restingHeartRate")
        assertDemoSurfaceAlive(in: app, badge: badge, name: "Resting HR detail")
        dismissOpenSheet(in: app)
        openMetric(in: app, identifier: "atria.vitals.resp-rate", detail: "atria.metric.detail.respiratoryRate")
        assertDemoSurfaceAlive(in: app, badge: badge, name: "Respiratory detail")
        dismissOpenSheet(in: app)

        // The tab bar minimizes after scrolling; scroll back to expand it.
        let todayTab = app.tabBars.buttons["Today"]
        for _ in 0..<4 where !todayTab.waitForExistence(timeout: 1) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
                .press(forDuration: 0.05,
                       thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        }
        todayTab.tap()
        let erase = app.buttons["atria.demo.erase-and-return"]
        XCTAssertTrue(erase.waitForExistence(timeout: 8))
        erase.tap()
        XCTAssertTrue(explore.waitForExistence(timeout: 20), "Exit should return to first-run setup")
    }

    /// App Review: sample data must never reach HealthKit. From a fresh
    /// install, enter sample data, confirm the Settings Health controls cannot
    /// authorize, visit every tab, then exit back to onboarding.
    func testFreshInstallSampleDataCannotAuthorizeHealthKit() {
        let app = XCUIApplication()
        let explore = launchAtFirstRunSetup(app)
        explore.tap()
        let badge = app.descendants(matching: .any)["atria.demo.sample-data-badge"]
        XCTAssertTrue(badge.waitForExistence(timeout: 15), "Sample data banner should appear")

        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 8), "Missing Settings button")
        settings.tap()
        let data = app.buttons["Data"].firstMatch
        XCTAssertTrue(data.waitForExistence(timeout: 8), "Missing Settings > Data")
        data.tap()

        let nutrition = app.switches["atria.settings.health-nutrition"]
        var swipes = 0
        while !nutrition.waitForExistence(timeout: swipes == 0 ? 4 : 1), swipes < 4 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(nutrition.exists, "Missing Apple Health nutrition toggle")
        XCTAssertFalse(nutrition.isEnabled, "Health toggle must be disabled with sample data")
        XCTAssertEqual(nutrition.value as? String, "0")
        XCTAssertTrue(app.staticTexts["atria.settings.health-demo-note"].exists
                      || app.descendants(matching: .any)["atria.settings.health-demo-note"].exists,
                      "Sample data should explain why Apple Health is off")
        let export = app.buttons["atria.settings.health-export"]
        if export.exists {
            XCTAssertFalse(export.isEnabled, "Apple Health export must be disabled with sample data")
        }
        // A tap on the disabled control must not raise the Health access sheet.
        nutrition.tap()
        XCTAssertFalse(app.navigationBars["Health Access"].waitForExistence(timeout: 3),
                       "HealthKit authorization must never appear with sample data")
        XCTAssertFalse(app.staticTexts["Turn On All"].exists)
        XCTAssertEqual(nutrition.value as? String, "0")

        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 4), "Missing Settings Close")
        close.tap()

        for tab in ["Today", "Vitals", "Journal", "Activity"] {
            let button = app.tabBars.buttons[tab]
            XCTAssertTrue(button.waitForExistence(timeout: 8), "Missing tab \(tab)")
            button.tap()
            assertDemoSurfaceAlive(in: app, badge: badge, name: tab)
        }

        app.tabBars.buttons["Today"].tap()
        let erase = app.buttons["atria.demo.erase-and-return"]
        XCTAssertTrue(erase.waitForExistence(timeout: 8))
        erase.tap()
        XCTAssertTrue(explore.waitForExistence(timeout: 20), "Exit should return to first-run setup")
    }

    /// Launches at the welcome page. The runner kills the previous test's app
    /// the moment it returns to setup, which can leave sample data active on
    /// the next launch; a reviewer who force-quits after erasing lands on
    /// setup, so undo that runner artifact here rather than in the app.
    private func launchAtFirstRunSetup(_ app: XCUIApplication) -> XCUIElement {
        app.launchArguments.append("--atria-ui-fresh-install")
        app.launch()
        let explore = app.buttons["atria.onboarding.explore-sample-data"]
        if !explore.waitForExistence(timeout: 12) {
            let erase = app.buttons["atria.demo.erase-and-return"]
            if erase.waitForExistence(timeout: 5) { erase.tap() }
        }
        XCTAssertTrue(explore.waitForExistence(timeout: 20), "First-run setup should offer Explore sample data")
        return explore
    }

    private func assertDemoSurfaceAlive(in app: XCUIApplication, badge: XCUIElement, name: String) {
        XCTAssertTrue(
            badge.waitForExistence(timeout: 5)
                || app.staticTexts["Sample data"].waitForExistence(timeout: 3)
                || app.staticTexts["Demo data · not from a live strap"].waitForExistence(timeout: 3),
            "\(name) should keep the Sample data mark"
        )
        assertNoDeadEnd(in: app, name: name)
    }

    private func assertNoDeadEnd(in app: XCUIApplication, name: String) {
        XCTAssertFalse(app.staticTexts["Unable to Load"].exists, "\(name) empty/error")
        XCTAssertFalse(app.staticTexts["Something went wrong"].exists, "\(name) error")
        XCTAssertFalse(app.staticTexts["An error occurred"].exists, "\(name) error")
        let loading = app.staticTexts["Loading activity"]
        if loading.exists {
            XCTAssertTrue(loading.waitForNonExistence(timeout: 12), "\(name) stuck loading")
        }
    }

    private func openMetric(in app: XCUIApplication, identifier: String, detail: String) {
        let control = app.descendants(matching: .any)[identifier]
        // Lower tiles live in lazy grids and only exist once scrolled to.
        var swipes = 0
        while !control.waitForExistence(timeout: swipes == 0 ? 4 : 1), swipes < 4 {
            // Scroll from below the charts: a swipe through a chart scrubs it.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.78))
                .press(forDuration: 0.05,
                       thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)))
            swipes += 1
        }
        XCTAssertTrue(control.exists, "Missing control \(identifier)")
        control.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)[detail].waitForExistence(timeout: 8),
            "Missing detail \(detail)"
        )
    }

    private func dismissOpenSheet(in app: XCUIApplication) {
        if app.buttons["Close"].waitForExistence(timeout: 1) {
            app.buttons["Close"].tap()
            return
        }
        if app.navigationBars.buttons["Close"].waitForExistence(timeout: 1) {
            app.navigationBars.buttons["Close"].tap()
            return
        }
        // Detail sheets have no Close button. A swipe in the middle scrolls
        // the sheet's content instead of dismissing it, so drag from the
        // grabber the way a person would, and wait for the sheet to go.
        let tabBar = app.tabBars.firstMatch
        for _ in 0..<3 {
            let grabber = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08))
            grabber.press(forDuration: 0.05,
                          thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
            if tabBar.isHittable { return }
            _ = tabBar.waitForExistence(timeout: 1)
            if tabBar.isHittable { return }
        }
    }
}
