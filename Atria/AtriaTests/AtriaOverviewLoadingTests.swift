import XCTest
@testable import Atria

final class AtriaOverviewLoadingTests: XCTestCase {
    func testCachedTrendContentDoesNotWaitForDiagnostics() {
        XCTAssertTrue(AtriaOverviewTrendPresentation.showsContent(cachedPointCount: 1,
                                                                  debugShowsTrendFixture: false))
        XCTAssertTrue(AtriaOverviewTrendPresentation.showsContent(cachedPointCount: 30,
                                                                  debugShowsTrendFixture: false))
    }

    func testTrendPlaceholderIsReservedForAnEmptyCache() {
        XCTAssertFalse(AtriaOverviewTrendPresentation.showsContent(cachedPointCount: 0,
                                                                   debugShowsTrendFixture: false))
        XCTAssertTrue(AtriaOverviewTrendPresentation.showsContent(cachedPointCount: 0,
                                                                  debugShowsTrendFixture: true))
    }

    func testMetricDetailColdPreparationStartsWithNoDisplayValue() {
        var state = AtriaStaleWhileRefreshState<String, Int>()

        state.begin("first")

        XCTAssertNil(state.value)
        XCTAssertEqual(state.requestedKey, "first")
    }

    func testMetricDetailPreparationKeepsStaleValueDuringRefresh() {
        var state = AtriaStaleWhileRefreshState<String, Int>()
        state.begin("first")
        XCTAssertTrue(state.accept(41, for: "first"))

        state.begin("second")

        XCTAssertEqual(state.value, 41)
        XCTAssertEqual(state.valueKey, "first")
        XCTAssertEqual(state.requestedKey, "second")
    }

    func testMetricDetailPreparationRejectsAnOldDetachedResult() {
        var state = AtriaStaleWhileRefreshState<String, Int>()
        state.begin("old")
        state.begin("current")

        XCTAssertFalse(state.accept(1, for: "old"))
        XCTAssertNil(state.value)
        XCTAssertTrue(state.accept(2, for: "current"))
        XCTAssertEqual(state.value, 2)
        XCTAssertEqual(state.valueKey, "current")
    }
}
