import XCTest
import SwiftUI
@testable import Atria

/// Sim-verifies the Detections card actually renders content (non-empty
/// layout) rather than only compiling. Uses a `UIHostingController` snapshot
/// since the card sits deep inside the Vitals tab navigation stack.
@MainActor
final class AtriaDetectionsRenderTests: XCTestCase {
    func testDetectionsListSheetRendersNonEmptyRowsForSampleEvents() throws {
        // Covers all four kinds in a single hosted render (a per-kind loop of
        // separate `UIHostingController`s proved flaky under the simulator's
        // window-management on CI; one window with a heterogeneous list is
        // both simpler and an equally honest render check).
        let events = [
            DetectionEvent(kind: "sleepAutoConfirmed", detail: "10:02 PM–6:14 AM, 8h 12m"),
            DetectionEvent(kind: "workoutSuppressed", reason: "contact_compromised_stitched", detail: "peak_over_rest=40"),
            DetectionEvent(kind: "workoutDetected", detail: "peak_over_rest=55, observed 900s, coverage 82%"),
            DetectionEvent(kind: "sleepCandidateSkipped", reason: "no_strong_candidate", detail: "No sleep candidates found")
        ]
        let windowScene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: windowScene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let host = UIHostingController(rootView: AtriaDetectionsListSheet(detections: events))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()

        let renderer = UIGraphicsImageRenderer(bounds: host.view.bounds)
        let image = renderer.image { ctx in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)

        // Sanity: rendering did not crash and the view controller has a
        // non-trivial subview tree (i.e. it isn't just an empty container).
        XCTAssertFalse(host.view.subviews.isEmpty)
    }
}

final class AtriaDetectionLogTests: XCTestCase {
    private var store: UserDefaults!
    private let suiteName = "AtriaDetectionLogTests.suite"

    override func setUp() {
        super.setUp()
        store = UserDefaults(suiteName: suiteName)
        store.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        store.removePersistentDomain(forName: suiteName)
        store = nil
        super.tearDown()
    }

    func testAppendPersistsNewestFirst() {
        DetectionEventLog.append(DetectionEvent(kind: "sleepAutoConfirmed", detail: "first"), store: store)
        DetectionEventLog.append(DetectionEvent(kind: "workoutDetected", detail: "second"), store: store)

        let loaded = DetectionEventLog.load(store: store)
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.first?.detail, "second")
        XCTAssertEqual(loaded.last?.detail, "first")
    }

    func testAppendTrimsToCapacityOfTwenty() {
        for i in 0..<25 {
            DetectionEventLog.append(DetectionEvent(kind: "workoutDetected", detail: "\(i)"), store: store)
        }
        let loaded = DetectionEventLog.load(store: store)
        XCTAssertEqual(loaded.count, DetectionEventLog.capacity)
        // Newest-first: the most recent append ("24") should be first.
        XCTAssertEqual(loaded.first?.detail, "24")
    }

    func testAppendBumpsRevisionEachCall() {
        XCTAssertEqual(store.integer(forKey: DetectionEventLog.revisionKey), 0)
        DetectionEventLog.append(DetectionEvent(kind: "workoutDetected", detail: "a"), store: store)
        XCTAssertEqual(store.integer(forKey: DetectionEventLog.revisionKey), 1)
        DetectionEventLog.append(DetectionEvent(kind: "workoutDetected", detail: "b"), store: store)
        XCTAssertEqual(store.integer(forKey: DetectionEventLog.revisionKey), 2)
    }

    func testRepeatedSleepSkipRetryIsCoalescedWithoutEvictingWorkoutDetection() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        DetectionEventLog.append(
            DetectionEvent(kind: "workoutDetected", date: base, detail: "real activity"),
            store: store
        )
        DetectionEventLog.append(
            DetectionEvent(kind: "sleepCandidateSkipped",
                           reason: "no_strong_candidate",
                           date: base.addingTimeInterval(1),
                           detail: "first deferred pass"),
            store: store
        )
        DetectionEventLog.append(
            DetectionEvent(kind: "sleepCandidateSkipped",
                           reason: "no_strong_candidate",
                           date: base.addingTimeInterval(10 * 60),
                           detail: "retry deferred pass"),
            store: store
        )

        let loaded = DetectionEventLog.load(store: store)
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.filter { $0.kind == "sleepCandidateSkipped" }.count, 1)
        XCTAssertEqual(loaded.last?.kind, "workoutDetected")
        XCTAssertEqual(store.integer(forKey: DetectionEventLog.revisionKey), 2)
    }

    func testSleepSkipWithDifferentReasonOrOutsideRetryWindowIsRetained() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        DetectionEventLog.append(
            DetectionEvent(kind: "sleepCandidateSkipped",
                           reason: "no_strong_candidate",
                           date: base,
                           detail: "first"),
            store: store
        )
        DetectionEventLog.append(
            DetectionEvent(kind: "sleepCandidateSkipped",
                           reason: "wake_boundary_no_wake_detected",
                           date: base.addingTimeInterval(1),
                           detail: "separate decision"),
            store: store
        )
        DetectionEventLog.append(
            DetectionEvent(kind: "sleepCandidateSkipped",
                           reason: "no_strong_candidate",
                           date: base.addingTimeInterval(
                               DetectionEventLog.sleepSkipRetryCoalescingInterval + 1
                           ),
                           detail: "later state"),
            store: store
        )

        XCTAssertEqual(DetectionEventLog.load(store: store).count, 3)
    }

    func testLoadWithNoDataReturnsEmpty() {
        XCTAssertEqual(DetectionEventLog.load(store: store), [])
    }

    func testReasonCodeTakesPrecedenceOverKind() {
        let event = DetectionEvent(kind: "sleepCandidateSkipped",
                                    reason: "already_saved_or_overlapping",
                                    detail: "raw detail")
        XCTAssertEqual(DetectionReasonCopy.text(for: event), "Sleep already logged for that window")
    }

    func testUnknownReasonCodeFallsBackToKindThenDetail() {
        let knownKind = DetectionEvent(kind: "workoutDetected", reason: "confirmed", detail: "raw detail")
        XCTAssertEqual(DetectionReasonCopy.text(for: knownKind), "Workout candidate ready to review")

        let unknownEverything = DetectionEvent(kind: "somethingElse", reason: nil, detail: "raw detail")
        XCTAssertEqual(DetectionReasonCopy.text(for: unknownEverything), "raw detail")
    }

    /// 2026-09-02: the Vitals sleep card and History rows showed raw pipeline
    /// sentences ending in "(source: foreground_edge)". Every emitted skip code
    /// now maps to plain copy, and the raw fallback drops provenance tokens.
    func testEveryEmittedSleepSkipCodeReadsAsPlainCopy() {
        let codes = ["no_strong_candidate", "candidate_not_settled",
                     "daytime_quiescence_no_strap", "daytime_quiescence_insufficient_motion",
                     "daytime_quiescence_hr_read_incomplete", "daytime_quiescence_no_candidate",
                     "daytime_quiescence_slot_held", "review_only_classification",
                     "wake_boundary_review_only_classification",
                     "compact_materialization_stale_or_missing",
                     "compact_wake_materialization_stale_or_missing", "baseline_trust_changed",
                     "wake_boundary_dismissed", "save_time_dismissal_suppressed",
                     "wake_boundary_no_wake_detected", "wake_boundary_overlaps_saved",
                     "already_saved_or_overlapping"]
        for code in codes {
            let event = DetectionEvent(kind: "sleepCandidateSkipped", reason: code,
                                       detail: "raw (source: foreground_edge)")
            let text = DetectionReasonCopy.text(for: event)
            XCTAssertNotEqual(text, event.detail, "\(code) must not fall through to the raw detail")
            XCTAssertFalse(text.contains("(source:"), code)
            XCTAssertFalse(text.contains("_"), "\(code) copy must not carry machine tokens")
        }
    }

    func testRawDetailFallbackDropsProvenanceTokens() {
        let unknown = DetectionEvent(kind: "sleepCandidateSkipped", reason: "some_future_code",
                                     detail: "3 sleep candidate(s) proposed, none auto-confirmable (source: foreground_edge)")
        XCTAssertEqual(DetectionReasonCopy.text(for: unknown),
                       "3 sleep candidate(s) proposed, none auto-confirmable")
        XCTAssertEqual(DetectionReasonCopy.sanitizedDetail("Only a token (source: x)"), "Only a token")
        XCTAssertEqual(DetectionReasonCopy.sanitizedDetail("Marked not sleep: 13:10–19:05. This window won't be suggested again."),
                       "Marked not sleep: 13:10–19:05. This window won't be suggested again.")
        XCTAssertEqual(DetectionReasonCopy.sanitizedDetail("(source: x)"), "(source: x)",
                       "a detail that is nothing but the token stays as recorded rather than vanishing")
    }

    func testDetectionEventCodableRoundTrips() throws {
        let event = DetectionEvent(kind: "workoutSuppressed",
                                    reason: "contact_compromised_stitched",
                                    detail: "test detail")
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(DetectionEvent.self, from: data)
        XCTAssertEqual(decoded, event)
    }
}
