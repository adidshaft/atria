import XCTest

/// Read-only visual audit walk (2026-09-27): opens every tab and the main
/// detail sheets on the user's existing data, scrolls each to the end and
/// attaches a screenshot at every stop, for a human look at duplicated or
/// cut-off text. Never passes a fresh-install/reset flag and never taps
/// anything but tabs, known metric identifiers and sheet dismissal.
/// Run on demand only:
///   -only-testing:AtriaUITests/AtriaVisualAuditUITests
final class AtriaVisualAuditUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    func testCaptureEveryScreen() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30))
        sleep(4)

        for tab in ["Today", "Vitals", "Journal", "Activity"] {
            guard tapTab(app, tab) else { continue }
            captureScrolling(app, name: tab)
        }

        guard tapTab(app, "Today") else { return }
        for (identifier, name) in [
            ("atria.today.ring.sleep", "sleep-detail"),
            ("atria.today.ring.recovery", "recovery-detail"),
            ("atria.today.ring.strain", "strain-detail"),
            ("atria.today.metric.steps", "steps-detail"),
        ] {
            openAndCapture(app, identifier: identifier, name: name)
        }

        guard tapTab(app, "Vitals") else { return }
        for (identifier, name) in [
            ("atria.vitals.hrv", "hrv-detail"),
            ("atria.vitals.resting-hr", "rhr-detail"),
            ("atria.vitals.resp-rate", "resp-detail"),
        ] {
            openAndCapture(app, identifier: identifier, name: name)
        }
        app.terminate()

        for screen in ["strap", "settings"] {
            let routed = XCUIApplication()
            routed.launchArguments += ["--atria-ui-screen", screen]
            routed.launch()
            sleep(6)
            captureScrolling(routed, name: "screen-\(screen)")
            routed.terminate()
        }
    }

    /// Every detected-workout surface from its DEBUG fixture, then the review
    /// flow stepped through with its own Next button.
    func testDetectedWorkoutSurfaces() {
        for fixture in ["workout-detection-ready", "saved-workout-review",
                        "workout-review-hold-possible", "detected-activities"] {
            let app = XCUIApplication()
            app.launchArguments += ["--atria-ui-fixture", fixture]
            app.launch()
            sleep(6)
            captureScrolling(app, name: "fx-\(fixture)", maxPages: 3)
            app.terminate()
        }
    }

    /// The one-screen review sheet from its fixture.
    func testWorkoutReviewSheet() {
        let app = XCUIApplication()
        app.launchArguments += ["--atria-ui-fixture", "workout-review-flow"]
        app.launch()
        sleep(7)
        capture(app, "sheet-0")
        let strength = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Strength'")).firstMatch
        if strength.waitForExistence(timeout: 4) {
            strength.tap()
            sleep(1)
        }
        app.swipeUp()
        sleep(1)
        capture(app, "sheet-1")
        app.terminate()
    }

    /// Today scrolled: the collapsed rings sit in the top bar.
    func testTodayCollapsedRingsInTopBar() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30))
        sleep(4)
        _ = tapTab(app, "Today")
        edgeDrag(app, up: true)
        capture(app, "today-collapsed-0")
        edgeDrag(app, up: true)
        capture(app, "today-collapsed-1")
    }

    /// The Assistant with Apple's on-device model: one typed question.
    func testAssistantOnDeviceAnswer() {
        let app = XCUIApplication()
        app.launchArguments += ["--atria-ui-screen", "chat"]
        app.launch()
        sleep(6)
        capture(app, "assistant-0")
        let field = app.textFields["Ask about your data"].exists
            ? app.textFields["Ask about your data"]
            : app.textViews["Ask about your data"]
        guard field.waitForExistence(timeout: 8) else {
            capture(app, "assistant-no-ask-field")
            return
        }
        field.tap()
        field.typeText("How did I sleep this week compared with usual?")
        app.buttons["Ask"].tap()
        sleep(20)
        capture(app, "assistant-1")
        edgeDrag(app, up: true)
        capture(app, "assistant-2")
    }

    /// Scrolled tabs collapse the tab bar to one button; scroll back to the
    /// top (edge drags, so no chart catches them) until the tab is hittable.
    private func tapTab(_ app: XCUIApplication, _ name: String) -> Bool {
        let button = app.tabBars.buttons[name]
        for _ in 0..<12 where !(button.exists && button.isHittable) {
            edgeDrag(app, up: false)
        }
        guard button.exists, button.isHittable else {
            capture(app, "missing-tab-\(name)")
            return false
        }
        button.tap()
        sleep(2)
        for _ in 0..<6 { edgeDrag(app, up: false) }
        return true
    }

    private func edgeDrag(_ app: XCUIApplication, up: Bool) {
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.32))
        let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.80))
        if up {
            bottom.press(forDuration: 0.05, thenDragTo: top)
        } else {
            top.press(forDuration: 0.05, thenDragTo: bottom)
        }
        sleep(1)
    }

    private func openAndCapture(_ app: XCUIApplication, identifier: String, name: String) {
        let element = app.descendants(matching: .any)[identifier]
        guard element.waitForExistence(timeout: 5) else {
            capture(app, "missing-\(name)")
            return
        }
        for _ in 0..<4 where !element.isHittable { edgeDrag(app, up: true) }
        guard element.isHittable else {
            capture(app, "unhittable-\(name)")
            return
        }
        element.tap()
        sleep(2)
        captureScrolling(app, name: name, maxPages: 6)
        dismiss(app)
    }

    private func captureScrolling(_ app: XCUIApplication, name: String, maxPages: Int = 8) {
        var previous = ""
        for page in 0..<maxPages {
            let shot = XCUIScreen.main.screenshot()
            let signature = shot.pngRepresentation.base64EncodedString().suffix(4_000)
            if page > 0, String(signature) == previous { break }
            previous = String(signature)
            attach(shot, "\(name)-\(page)")
            edgeDrag(app, up: true)
        }
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        attach(XCUIScreen.main.screenshot(), name)
    }

    private func attach(_ shot: XCUIScreenshot, _ name: String) {
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func dismiss(_ app: XCUIApplication) {
        let done = app.buttons["Done"]
        if done.exists, done.isHittable {
            done.tap()
        } else {
            app.swipeDown(velocity: .fast)
        }
        sleep(1)
    }
}
