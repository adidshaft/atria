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
        XCTAssertTrue(explore.waitForExistence(timeout: 20))
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
