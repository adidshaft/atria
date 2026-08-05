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
        // 2026-08-05 audit: respiratory stays on the canonical "/min" label
        // ("rpm" reads as revolutions per minute); the space-separated form is
        // what AtriaMetricFormat.respiratory emits for the detail hero.
        XCTAssertEqual(AtriaMetricHeroValueText.split("16.2 /min").unit, "/min")
        XCTAssertEqual(AtriaMetricHeroValueText.split("7.4 h").unit, "h")
        // 2026-08-06 audit: fitness-age deltas render signed with a spaced
        // "yr" token, so the split styles it like "54 ms".
        XCTAssertEqual(AtriaMetricHeroValueText.split("+3 yr").value, "+3")
        XCTAssertEqual(AtriaMetricHeroValueText.split("+3 yr").unit, "yr")
        XCTAssertEqual(AtriaMetricHeroValueText.split("\u{2212}2 yr").unit, "yr")
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

/// Pins the fitness-age years formatter (2026-08-06 audit fix): "y" summaries
/// used to fall through to the strain formatter, which clamped every value to
/// 0-21, stripped the sign (a younger −3 rendered "0.0"), and dropped the
/// unit. Each assertion here guards a piece of that honesty repair, mirroring
/// the respiratory "/min" precedent above.
final class AtriaMetricFormatYearsTests: XCTestCase {
    func testYearsValueIsSignedWholeYears() {
        XCTAssertEqual(AtriaMetricFormat.value(3, metric: .years), "+3 yr")
        XCTAssertEqual(AtriaMetricFormat.value(-2, metric: .years), "\u{2212}2 yr")
        XCTAssertEqual(AtriaMetricFormat.value(0, metric: .years), "0 yr")
        XCTAssertEqual(AtriaMetricFormat.value(nil, metric: .years), "--")
    }

    func testYearsValueIsNotClampedToStrainRange() {
        // The old strain fallthrough would have rendered these "21.0" and
        // "0.0" — clamp-fabricated numbers.
        XCTAssertEqual(AtriaMetricFormat.value(34, metric: .years), "+34 yr")
        XCTAssertEqual(AtriaMetricFormat.value(-34, metric: .years), "\u{2212}34 yr")
    }

    func testYearsChangeKeepsSignAndUnit() {
        XCTAssertEqual(AtriaMetricFormat.change(2, metric: .years), "+2 yr")
        XCTAssertEqual(AtriaMetricFormat.change(-1.4, metric: .years), "\u{2212}1 yr")
        XCTAssertEqual(AtriaMetricFormat.change(0, metric: .years), "0 yr")
    }

    func testYearsRangeUsesSignedToSeparator() {
        // "−2-+1 yr" would be unreadable; the signed range mirrors the About
        // sheet's vo2max "to" precedent.
        XCTAssertEqual(AtriaMetricFormat.range(low: -2, high: 1, metric: .years), "\u{2212}2 to +1 yr")
        XCTAssertEqual(AtriaMetricFormat.range(low: 0, high: 34, metric: .years), "0 to +34 yr")
    }
}
