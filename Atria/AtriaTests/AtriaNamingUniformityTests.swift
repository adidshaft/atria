import XCTest

/// One concept, one user-visible name. The 2026-08-28 uniformity audit found
/// eight metrics wearing two to four names across live screens — a user
/// reading "Wrist temp" on Overview and "Skin temp" in Vitals reasonably
/// concludes the strap reports two different temperatures.
///
/// These pins are deliberately narrow: they forbid the *card and tile titles*
/// that drifted, not every appearance of a word. Spelled-out About-sheet
/// headings and in-sentence prose keep their own register.
final class AtriaNamingUniformityTests: XCTestCase {
    private func source(_ name: String) throws -> String {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria")
        return try String(contentsOf: app.appendingPathComponent(name), encoding: .utf8)
    }

    /// The sensor measures one thing; "wrist" and "skin" are two anatomical
    /// claims about it. Vitals, Overview and Settings converged on "skin".
    func testTemperatureIsCalledSkinEverywhereItIsTitled() throws {
        for file in ["AtriaOverviewSections.swift",
                     "AtriaVitalsCollectionSections.swift",
                     "AtriaSettingsView.swift"] {
            let text = try source(file)
            XCTAssertFalse(text.contains("\"Wrist temp\""),
                           "\(file) still titles the sensor 'Wrist temp'")
            XCTAssertFalse(text.contains("\"Wrist temperature signal\""),
                           "\(file) still titles the sensor 'Wrist temperature'")
        }
    }

    /// The tile the user taps and the sheet it opens must name the same metric.
    func testVitalsTilesUseTheSameNamesAsTheirDetailSheets() throws {
        let vitals = try source("AtriaHealthScreen.swift")
        XCTAssertFalse(vitals.contains("AtriaHealthMetricRow(title: \"SpO2\","),
                       "the tile said SpO2 while every other surface said Blood oxygen")
        XCTAssertFalse(vitals.contains("AtriaHealthMetricRow(title: \"VO2 max\","),
                       "spaced 'VO2 max' was a fourth spelling of VO2max")
        XCTAssertFalse(vitals.contains("AtriaHealthMetricRow(title: \"Respiration\","),
                       "the card feeding it is titled 'Resp rate'")
        XCTAssertTrue(vitals.contains("AtriaHealthMetricRow(title: \"Blood oxygen\","))
        XCTAssertTrue(vitals.contains("AtriaHealthMetricRow(title: \"VO2max\","))
    }

    /// One number, one name: the About sheet opened over the Fitness age hero
    /// used to be titled "Body Age".
    func testFitnessAgeIsNeverCalledBodyAge() throws {
        for file in ["AtriaAboutMetricSheet.swift",
                     "AtriaHealthspanDetailView.swift",
                     "AtriaVitalsCollectionSections.swift"] {
            let text = try source(file)
            XCTAssertFalse(text.contains("Body Age"), "\(file) still says Body Age")
            XCTAssertFalse(text.contains("Body age"), "\(file) still says Body age")
            XCTAssertFalse(text.contains("BODY AGE"), "\(file) still says BODY AGE")
        }
    }

    /// The button promised an "activity" and opened a sheet titled "workout".
    func testTheSessionEntryPointsSayWorkout() throws {
        let today = try source("AtriaTodayScreen.swift")
        XCTAssertFalse(today.contains("Text(\"Start activity\")"))
        XCTAssertTrue(today.contains("Text(\"Start workout\")"))
        let home = try source("AtriaHomeView.swift")
        XCTAssertFalse(home.contains("Label(\"Start Activity\""))
        XCTAssertFalse(home.contains("Label(\"Add Activity\""))
    }

    /// Connected-but-no-pulse read "Pending" on the pill and "Waiting" one tap
    /// away on Today.
    func testConnectedWithoutPulseUsesOneWord() throws {
        let home = try source("AtriaHomeView.swift")
        XCTAssertFalse(home.contains("? \"Live\" : \"Pending\""),
                       "the pill said Pending where Today said Waiting")
        XCTAssertTrue(home.contains("? \"Live\" : \"Waiting\""))
    }

    /// "Decoder not verified" is the canonical wording; "Decoder unavailable"
    /// read as a hardware limitation rather than unfinished app work.
    func testUnverifiedDecoderHasOneWording() throws {
        for file in ["AtriaTodayScreen.swift", "AtriaOverviewSections.swift"] {
            XCTAssertFalse(try source(file).contains("\"Decoder unavailable\""),
                           "\(file) still carries a second decoder wording")
        }
    }

    /// The canonical absent token must reach the surface: rewriting "--" into
    /// prose made one card disagree with the same number one scroll away.
    func testThePlanCardDoesNotRewriteTheAbsentToken() throws {
        let overview = try source("AtriaOverviewSections.swift")
        XCTAssertFalse(overview.contains("debt == \"--\" ? \"Building\" : debt"))
        XCTAssertFalse(overview.contains("\"Routine consistency building\""))
        XCTAssertFalse(overview.contains("return \"Debt building\""))
    }

    /// A recording with no zone breakdown will never grow one, so "building"
    /// claimed a calibration that is not happening — and the bar itself must
    /// not paint a distribution that does not exist.
    func testWorkoutZonesAreBlankRatherThanInvented() throws {
        let overview = try source("AtriaOverviewSections.swift")
        XCTAssertTrue(overview.contains("private var hasZoneTime: Bool"),
                      "the bar must gate on real zone time")
        XCTAssertTrue(overview.contains("} else if hasZoneTime {"))
        XCTAssertTrue(overview.contains("\"Zone distribution unavailable for this recording\""))
        XCTAssertFalse(overview.contains("\"Zones building\""))
    }
}
