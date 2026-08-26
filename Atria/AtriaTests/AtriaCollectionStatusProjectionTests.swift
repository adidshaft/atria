import XCTest
@testable import Atria

final class AtriaCollectionStatusProjectionTests: XCTestCase {
    /// REPLACED 2026-08-27. This asserted that the collection status card used
    /// an equality-gated projection store — a genuinely good invariant, on a
    /// card the user could never open. `AtriaCollectionStatusCardHost` was one
    /// of 51 View types in the app with no construction site of any kind, and
    /// removing it orphaned `AtriaCollectionStatusProjectionState` and
    /// `AtriaCollectionStatusProjectionStore` too — both now removed.
    ///
    /// That is the second test suite found guarding unreachable UI in two days
    /// (see AtriaSleepReviewCacheTests), which is the argument for checking
    /// REACHABILITY, not just presence, when a test scans source.
    func testTheDeadCollectionStatusProjectionStaysRemoved() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(
            contentsOf: testsDirectory.deletingLastPathComponent()
                .appendingPathComponent("Atria/AtriaVitalsCollectionSections.swift"),
            encoding: .utf8
        )
        for dead in ["AtriaCollectionStatusCardHost",
                     "AtriaCollectionStatusProjectionStore",
                     "AtriaCollectionStatusProjectionState"] {
            XCTAssertFalse(source.contains(dead),
                           "\(dead) had no reachable consumer; reviving it "
                               + "would re-create UI that reads as live")
        }
    }
}
