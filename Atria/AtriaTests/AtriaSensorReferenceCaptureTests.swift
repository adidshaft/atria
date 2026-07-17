import XCTest
@testable import Atria

@MainActor
final class AtriaSensorReferenceCaptureTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AtriaSensorReferenceCaptureTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testCaptureUsesTapTimeAndPersistsCanonicalSpO2Reference() throws {
        let timestamp = Date(timeIntervalSince1970: 1_720_000_000.125)
        let store = AtriaSensorReferenceStore(defaults: defaults, now: { timestamp })

        let entry = try store.capture(kind: .oxygenReference,
                                      value: 97,
                                      label: " seated, baseline\n",
                                      referenceDevice: "Independent Oximeter",
                                      measurementSite: "fingertip",
                                      contactState: "stable-contact",
                                      notes: "display stable")

        XCTAssertEqual(entry.capturedAt, timestamp)
        XCTAssertEqual(entry.referenceSpO2Percent, 97)
        XCTAssertNil(entry.referenceSkinTemperatureC)
        XCTAssertEqual(entry.inputUnit, "percent")
        XCTAssertEqual(entry.label, "seated, baseline")

        let restored = AtriaSensorReferenceStore(defaults: defaults, now: { timestamp })
        XCTAssertEqual(restored.entries, [entry])
    }

    func testFahrenheitInputExportsCanonicalCelsiusAndOriginalUnit() throws {
        let timestamp = Date(timeIntervalSince1970: 1_720_000_001.5)
        let entry = try AtriaSensorReferenceEntry(capturedAt: timestamp,
                                                  kind: .skinTemperature,
                                                  value: 91.4,
                                                  temperatureUnit: .fahrenheit,
                                                  label: "mild-warm",
                                                  referenceDevice: "Contact Probe",
                                                  measurementSite: "adjacent-wrist",
                                                  contactState: "stable-contact",
                                                  notes: "next to strap")

        XCTAssertEqual(entry.referenceSkinTemperatureC!, 33, accuracy: 0.000_001)
        XCTAssertEqual(entry.inputValue, 91.4)
        XCTAssertEqual(entry.inputUnit, "degF")

        let csv = AtriaSensorReferenceStore.csv(entries: [entry])
        XCTAssertTrue(csv.contains("\"reference_skin_temp_c\""))
        XCTAssertTrue(csv.contains("\"33\""))
        XCTAssertTrue(csv.contains("\"91.4\",\"degF\""))
        XCTAssertTrue(csv.contains("\"decoder_validated\",\"metric_promotions\""))
        XCTAssertTrue(csv.hasSuffix("\"0\",\"0\"\n"))
    }

    func testCSVMatchesReplayColumnsAndEscapesContext() throws {
        let entry = try AtriaSensorReferenceEntry(capturedAt: Date(timeIntervalSince1970: 1_720_000_002),
                                                  kind: .oxygenReference,
                                                  value: 98,
                                                  label: "recovery, seated",
                                                  referenceDevice: "Model \"A\"",
                                                  measurementSite: "right fingertip",
                                                  contactState: "stable-contact",
                                                  notes: "one, two")
        let csv = AtriaSensorReferenceStore.csv(entries: [entry])
        let header = csv.split(separator: "\n").first.map(String.init) ?? ""

        XCTAssertTrue(header.contains("\"timestamp\",\"reference_spo2_percent\",\"reference_skin_temp_c\",\"label\""))
        XCTAssertTrue(csv.contains("\"recovery, seated\""))
        XCTAssertTrue(csv.contains("\"Model \"\"A\"\"\""))
        XCTAssertTrue(csv.contains("\"local_only\",\"research_only\",\"decoder_validated\",\"metric_promotions\""))
    }

    func testClockMarkerContainsNoInventedMeasurement() throws {
        let entry = try AtriaSensorReferenceEntry(capturedAt: Date(),
                                                  kind: .clockMarker,
                                                  value: 99,
                                                  label: "clock-sync",
                                                  referenceDevice: "",
                                                  measurementSite: "",
                                                  contactState: "",
                                                  notes: "")

        XCTAssertNil(entry.referenceSpO2Percent)
        XCTAssertNil(entry.referenceSkinTemperatureC)
        XCTAssertNil(entry.inputValue)
        XCTAssertNil(entry.inputUnit)
        XCTAssertTrue(AtriaSensorReferenceStore.csv(entries: [entry]).contains("\"clock_marker\""))
    }

    func testImplausibleReferenceTyposFailClosed() {
        XCTAssertThrowsError(try AtriaSensorReferenceEntry(capturedAt: Date(),
                                                           kind: .oxygenReference,
                                                           value: 980,
                                                           label: "",
                                                           referenceDevice: "",
                                                           measurementSite: "",
                                                           contactState: "",
                                                           notes: ""))
        XCTAssertThrowsError(try AtriaSensorReferenceEntry(capturedAt: Date(),
                                                           kind: .skinTemperature,
                                                           value: 98.6,
                                                           temperatureUnit: .celsius,
                                                           label: "",
                                                           referenceDevice: "",
                                                           measurementSite: "",
                                                           contactState: "",
                                                           notes: ""))
    }

    func testMeasuredReferenceRequiresIndependentDeviceAndSite() {
        XCTAssertThrowsError(try AtriaSensorReferenceEntry(capturedAt: Date(),
                                                           kind: .oxygenReference,
                                                           value: 98,
                                                           label: "baseline",
                                                           referenceDevice: "",
                                                           measurementSite: "fingertip",
                                                           contactState: "stable-contact",
                                                           notes: "")) { error in
            XCTAssertEqual(error as? AtriaSensorReferenceEntry.ValidationError,
                           .referenceDeviceRequired)
        }
        XCTAssertThrowsError(try AtriaSensorReferenceEntry(capturedAt: Date(),
                                                           kind: .skinTemperature,
                                                           value: 33,
                                                           label: "baseline",
                                                           referenceDevice: "Contact Probe",
                                                           measurementSite: "  ",
                                                           contactState: "stable-contact",
                                                           notes: "")) { error in
            XCTAssertEqual(error as? AtriaSensorReferenceEntry.ValidationError,
                           .measurementSiteRequired)
        }
    }

    func testClearRemovesOnlyLocalReferenceRows() throws {
        let store = AtriaSensorReferenceStore(defaults: defaults)
        _ = try store.capture(kind: .clockMarker,
                              value: nil,
                              label: "clock-sync",
                              referenceDevice: "",
                              measurementSite: "",
                              contactState: "",
                              notes: "")
        XCTAssertEqual(store.entries.count, 1)

        store.clear()

        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertNil(defaults.data(forKey: AtriaSensorReferenceStore.defaultsKey))
    }

    func testSensorReferenceCardUsesCompactNonTruncatingGlassRows() throws {
        let source = try sensorReferenceSource()
        let start = try XCTUnwrap(source.range(of: "struct AtriaSensorReferenceCaptureCard: View"))
        let end = try XCTUnwrap(source.range(of: "private struct AtriaSensorReferenceCaptureSheet: View",
                                             range: start.upperBound..<source.endIndex))
        let card = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(card.contains(".frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)"))
        XCTAssertTrue(card.contains(".frame(maxWidth: .infinity, minHeight: 44)"))
        XCTAssertTrue(card.contains(".buttonBorderShape(.roundedRectangle(radius: 14))"))
        XCTAssertTrue(card.contains(".lineLimit(2)"))
        XCTAssertTrue(card.contains(".layoutPriority(1)"))
        XCTAssertFalse(card.contains(".minimumScaleFactor("),
                       "Reference titles should wrap at a consistent font instead of shrinking")
        XCTAssertFalse(card.contains("LazyVGrid"),
                       "Reference actions should be aligned rows, not uneven adaptive capsules")
        XCTAssertFalse(card.contains("AtriaStatusChip"),
                       "The record count should not be nested in another oversized capsule")
        XCTAssertFalse(card.contains(".atriaInsetCard"),
                       "The latest record should remain a simple row inside the quiet outer card")
    }

    func testSensorReferenceCardStacksHeaderAndExportAtAccessibilitySizes() throws {
        let source = try sensorReferenceSource()
        let start = try XCTUnwrap(source.range(of: "struct AtriaSensorReferenceCaptureCard: View"))
        let end = try XCTUnwrap(source.range(of: "private struct AtriaSensorReferenceCaptureSheet: View",
                                             range: start.upperBound..<source.endIndex))
        let card = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(card.contains("@Environment(\\.dynamicTypeSize) private var dynamicTypeSize"))
        XCTAssertGreaterThanOrEqual(card.components(separatedBy: "if dynamicTypeSize.isAccessibilitySize").count - 1, 2)
        XCTAssertTrue(card.contains("private var exportActions: some View"))
        XCTAssertTrue(card.contains("VStack(spacing: 8)"))
        XCTAssertTrue(card.contains(".fixedSize(horizontal: false, vertical: true)"))
    }

    private func sensorReferenceSource() throws -> String {
        let testsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appURL = testsURL.deletingLastPathComponent().appendingPathComponent("Atria")
        return try String(contentsOf: appURL.appendingPathComponent("AtriaSensorReferenceCapture.swift"),
                          encoding: .utf8)
    }
}
