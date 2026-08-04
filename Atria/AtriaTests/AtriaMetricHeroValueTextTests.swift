import XCTest
@testable import Atria

/// Pins the conservative split rules for the hero value/unit rendering
/// (2026-08-05 design-language pass): a wrong split would shrink part of a
/// real value (e.g. the "24m" of "6h 24m"), so every no-split case here is
/// an honesty guard, not a style preference.
final class AtriaMetricHeroValueTextTests: XCTestCase {
    func testUnitTokensSplit() {
        XCTAssertEqual(AtriaMetricHeroValueText.split("54 ms").value, "54")
        XCTAssertEqual(AtriaMetricHeroValueText.split("54 ms").unit, "ms")
        XCTAssertEqual(AtriaMetricHeroValueText.split("58 bpm").unit, "bpm")
        XCTAssertEqual(AtriaMetricHeroValueText.split("16.2 /min").unit, "/min")
        XCTAssertEqual(AtriaMetricHeroValueText.split("7.4 h").unit, "h")
    }

    func testGluedPercentSplits() {
        let parts = AtriaMetricHeroValueText.split("91%")
        XCTAssertEqual(parts.value, "91")
        XCTAssertEqual(parts.unit, "%")
    }

    func testCompoundDurationsAndWordsNeverSplit() {
        XCTAssertNil(AtriaMetricHeroValueText.split("6h 24m").unit)
        XCTAssertNil(AtriaMetricHeroValueText.split("Live read").unit)
        XCTAssertNil(AtriaMetricHeroValueText.split("Learning").unit)
        XCTAssertNil(AtriaMetricHeroValueText.split("--").unit)
        XCTAssertNil(AtriaMetricHeroValueText.split("%").unit)
        XCTAssertNil(AtriaMetricHeroValueText.split("12.4").unit)
    }
}
