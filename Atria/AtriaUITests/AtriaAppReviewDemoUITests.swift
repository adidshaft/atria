import XCTest

final class AtriaAppReviewDemoUITests: XCTestCase {
    private var openDetailIdentifier: String?

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

    func testSampleDataIsImmediatelyAccessibleAndAvailableFromUnpairedSetup() {
        let app = XCUIApplication()
        let explore = launchAtFirstRunSetup(app)
        XCTAssertTrue(explore.isHittable, "Demo access must be visible without scrolling, including on iPad")
        XCTAssertTrue(app.staticTexts["Demo mode · No hardware or sign-in required"].exists)
        XCTAssertFalse(app.alerts.firstMatch.exists, "First launch must not block demo with a permission alert")

        app.buttons["atria.onboarding.primary"].tap()
        XCTAssertTrue(explore.waitForExistence(timeout: 5))
        XCTAssertTrue(explore.isHittable, "Unpaired strap setup must keep a hardware-free exit into demo")
        explore.tap()
        XCTAssertTrue(app.descendants(matching: .any)["atria.demo.sample-data-badge"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.tabBars.buttons["Vitals"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Vitals"].tap()
        XCTAssertFalse(app.staticTexts["Rhythm"].exists, "Standard demo must not expose clinical rhythm research")
        XCTAssertFalse(app.staticTexts["Irregular rhythm"].exists)
        let erase = app.buttons["atria.demo.erase-and-return"]
        if !erase.isHittable { app.tabBars.buttons["Today"].tap() }
        erase.tap()
        XCTAssertTrue(explore.waitForExistence(timeout: 20))
    }

    /// App Review: sample data must never reach HealthKit. From a fresh
    /// install, enter sample data, confirm Settings > Apple Health cannot
    /// authorize, visit every tab, then exit back to onboarding.
    func testFreshInstallSampleDataCannotAuthorizeHealthKit() {
        let app = XCUIApplication()
        let explore = launchAtFirstRunSetup(app)
        explore.tap()
        let badge = app.descendants(matching: .any)["atria.demo.sample-data-badge"]
        XCTAssertTrue(badge.waitForExistence(timeout: 15), "Sample data banner should appear")

        let settings = app.buttons["atria.home.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8), "Missing Settings button")
        settings.tap()
        let health = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Apple Health'")).firstMatch
        XCTAssertTrue(health.waitForExistence(timeout: 8), "Missing Settings > Apple Health")
        health.tap()
        XCTAssertTrue(app.descendants(matching: .any)["atria.settings.health-disclosure"].waitForExistence(timeout: 8),
                      "The Apple Health destination must identify HealthKit integration")

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

        // Back from Apple Health to the Settings hub, where Close lives.
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.waitForExistence(timeout: 3), !app.buttons["Close"].exists { back.tap() }
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

    /// Each Release test uses the real erase flow. Relaunch first so a failed
    /// prior test cannot leave an in-memory sheet covering the erase control.
    /// Release intentionally has no launch-argument reset backdoor.
    private func launchAtFirstRunSetup(_ app: XCUIApplication) -> XCUIElement {
        openDetailIdentifier = nil
        app.terminate()
        app.launchArguments = []
        app.launch()
        let explore = app.buttons["atria.onboarding.explore-sample-data"]
        if !explore.waitForExistence(timeout: 4) {
            let erase = app.buttons["atria.demo.erase-and-return"]
            XCTAssertTrue(erase.waitForExistence(timeout: 12), "An existing demo must provide its erase control")
            if !erase.isHittable {
                let today = app.tabBars.buttons["Today"]
                XCTAssertTrue(today.waitForExistence(timeout: 5))
                today.tap()
            }
            XCTAssertTrue(erase.isHittable, "Erase must be accessible before resetting the next test")
            erase.tap()
        }
        XCTAssertTrue(explore.waitForExistence(timeout: 20), "First-run setup should offer Explore sample data")
        XCTAssertTrue(explore.isHittable, "Setup must be ready for interaction after sample data is erased")
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
        while (!control.waitForExistence(timeout: swipes == 0 ? 4 : 1) || !control.isHittable), swipes < 4 {
            // Scroll from below the charts: a swipe through a chart scrubs it.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.78))
                .press(forDuration: 0.05,
                       thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)))
            swipes += 1
        }
        XCTAssertTrue(control.exists, "Missing control \(identifier)")
        XCTAssertTrue(control.isHittable, "Metric \(identifier) must be visible and uncovered")
        control.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)[detail].waitForExistence(timeout: 8),
            "Missing detail \(detail)"
        )
        openDetailIdentifier = detail
    }

    private func dismissOpenSheet(in app: XCUIApplication) {
        for title in ["Close", "Done"] {
            let close = app.buttons[title].firstMatch
            if close.exists, close.isHittable {
                close.tap()
                if waitForSheetDismissal(in: app) { return }
            }
        }

        // iPad sheets are centered rather than starting at 8% of the display.
        // Locate the presented sheet (or its known detail ScrollView) and drag
        // its top chrome, never an unrelated point on the underlying screen.
        for attempt in 0..<3 {
            let sheet = app.sheets.firstMatch
            let detail = openDetailIdentifier.map { app.descendants(matching: .any)[$0] }
            let frame: CGRect
            let topInset: CGFloat
            if sheet.exists {
                frame = sheet.frame
                topInset = 10
            } else if let detail, detail.exists {
                frame = detail.frame
                topInset = -24 + CGFloat(attempt) * 12
            } else if let scroll = app.scrollViews.allElementsBoundByIndex.last(where: { $0.isHittable }) {
                // Weekly-plan and insights sheets do not carry a metric ID.
                // Their frontmost hittable scroll view still supplies the
                // centered presentation's real bounds.
                frame = scroll.frame
                topInset = -24 + CGFloat(attempt) * 12
            } else {
                XCTFail("Cannot locate the presented sheet for dismissal")
                return
            }
            let appFrame = app.frame
            let startY = max(appFrame.minY + 12, frame.minY + topInset)
            let endY = min(appFrame.maxY - 16, frame.maxY + 80)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let grabber = origin.withOffset(CGVector(dx: frame.midX - appFrame.minX,
                                                    dy: startY - appFrame.minY))
            let destination = origin.withOffset(CGVector(dx: frame.midX - appFrame.minX,
                                                        dy: endY - appFrame.minY))
            grabber.press(forDuration: 0.1, thenDragTo: destination)
            if waitForSheetDismissal(in: app) { return }
        }
        XCTFail("Presented sheet must dismiss before the next interaction")
    }

    private func waitForSheetDismissal(in app: XCUIApplication) -> Bool {
        if let openDetailIdentifier {
            let detail = app.descendants(matching: .any)[openDetailIdentifier]
            if detail.waitForNonExistence(timeout: 3) {
                self.openDetailIdentifier = nil
                return true
            }
            return false
        }
        let tab = app.tabBars.buttons.firstMatch
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == true"), object: tab
        )
        return XCTWaiter.wait(for: [expectation], timeout: 3) == .completed
    }
}
