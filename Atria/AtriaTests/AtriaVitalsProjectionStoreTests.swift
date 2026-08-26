import Combine
import XCTest
@testable import Atria

@MainActor
final class AtriaVitalsProjectionStoreTests: XCTestCase {
    func testVitalsStressTimelineEndsAtNowAndKeepsRestoredCollectionGaps() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let history: [AtriaStressMonitorStore.StressHistoryPoint] = [
            .init(t: now.addingTimeInterval(-13 * 3_600), activation: 0.2, level: .low, hrvAvailable: true),
            .init(t: now.addingTimeInterval(-11 * 3_600), activation: 0.3, level: .low, hrvAvailable: true),
            .init(t: now.addingTimeInterval(-11 * 3_600 + 60), activation: 0.4, level: .medium, hrvAvailable: true),
            .init(t: now.addingTimeInterval(-5 * 3_600), activation: 0.8, level: .high, hrvAvailable: true),
            .init(t: now.addingTimeInterval(1), activation: 0.5, level: .medium, hrvAvailable: true),
        ]

        let points = AtriaVitalsStressTimelineProjection.points(
            history: history,
            referenceDate: now
        )

        XCTAssertEqual(points.map(\.reading.date), [
            now.addingTimeInterval(-11 * 3_600),
            now.addingTimeInterval(-11 * 3_600 + 60),
            now.addingTimeInterval(-5 * 3_600),
        ])
        XCTAssertEqual(points.map(\.segment), [0, 0, 1])
    }

    func testVitalsHROnlyHistoryUsesNumericStressScaleWithLowerConfidenceProvenance() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let history: [AtriaStressMonitorStore.StressHistoryPoint] = [
            .init(t: now.addingTimeInterval(-60),
                  activation: 0,
                  level: .calm,
                  hrvAvailable: false),
            .init(t: now.addingTimeInterval(-30),
                  activation: 0.3,
                  level: .low,
                  hrvAvailable: false),
            .init(t: now,
                  activation: AtriaStressMonitor.mediumUpperBound,
                  level: .medium,
                  hrvAvailable: false),
        ]

        let projection = AtriaVitalsStressTimelineProjection.evidence(
            history: history,
            referenceDate: now
        )

        XCTAssertEqual(projection.presentation, .physiologicalStress)
        XCTAssertEqual(projection.stressPoints.map(\.reading.date),
                       history.map(\.t))
        XCTAssertEqual(projection.stressPoints.map(\.segment), [0, 0, 0])
        XCTAssertEqual(projection.stressPoints[0].reading.score, 0, accuracy: 1e-12)
        XCTAssertEqual(projection.stressPoints[1].reading.score, 0.9, accuracy: 1e-12)
        XCTAssertEqual(projection.stressPoints[2].reading.score, 2, accuracy: 1e-12)
        XCTAssertEqual(projection.stressPoints.map(\.reading.evidenceMode),
                       [.cardiacArousal, .cardiacArousal, .cardiacArousal],
                       "legacy HR-only provenance remains available for lower-confidence copy")
        XCTAssertEqual(projection.cardiacArousalPoints.map(\.level),
                       [.calm, .low, .medium])
        XCTAssertEqual(projection.cardiacArousalPoints.map(\.reading.date),
                       history.map(\.t))
    }

    func testVitalsStressCopyNeverCallsAGappedTimelineContinuous() {
        // The visible note is deliberately shorter than it used to be. Handoff-12
        // CP3 moved provenance and confidence prose out of the chart footnote —
        // "a scored reading shows its zone word and nothing else … not in four
        // places per viewport" — so asserting the old wording
        // ("HR-only is lower confidence") pins a policy that was replaced.
        //
        // What must NOT change is the rule the test is named for: a gapped
        // timeline is never described as continuous, and a gap is disclosed as
        // MISSING rather than explained away.
        let note = AtriaVitalsStressTimelineCopy.gapNote
        XCTAssertTrue(note.localizedCaseInsensitiveContains("gap"),
                      "the note must still tell the reader gaps exist")
        XCTAssertTrue(note.localizedCaseInsensitiveContains("missing")
                        || note.localizedCaseInsensitiveContains("blank"),
                      "and that a gap is absent data, not a low reading")
        XCTAssertFalse(note.localizedCaseInsensitiveContains("continuous"),
                       "a gapped timeline is never continuous")
        XCTAssertFalse(note.contains("strap was not collecting"),
                       "never assert a CAUSE for a gap that was not observed")

        // The confidence disclosure did not disappear, it moved. VoiceOver is
        // the floor: it must still carry it even though the footnote no longer
        // does.
        XCTAssertTrue(AtriaVitalsStressTimelineCopy.accessibilityLabel
            .localizedCaseInsensitiveContains("lower confidence"),
                      "HR-only provenance must survive somewhere non-optional")
        XCTAssertFalse(AtriaVitalsStressTimelineCopy.accessibilityLabel
            .localizedCaseInsensitiveContains("continuous"))
        XCTAssertTrue(AtriaVitalsStressTimelineCopy.accessibilityLabel.contains(
            "Collection gaps remain blank"
        ))
        XCTAssertTrue(AtriaVitalsStressTimelineCopy.accessibilityLabel.contains(
            "High is 2 to 3"
        ))
    }

    func testNoOpRefreshDoesNotPublish() {
        let sessionStore = SessionStore()
        let projection = AtriaVitalsSessionProjectionStore(store: sessionStore)
        var publications = 0
        let cancellable = projection.objectWillChange.sink { publications += 1 }

        XCTAssertEqual(projection.refreshAttemptCount, 0,
                       "Seeded @Published values must not replay into full projection rebuilds")
        XCTAssertFalse(projection.refresh())
        XCTAssertEqual(projection.refreshAttemptCount, 1)
        XCTAssertEqual(publications, 0)
        withExtendedLifetime(cancellable) {}
    }

    func testUnrelatedBroadStoreSignalDoesNotPublishVitalsState() {
        let sessionStore = SessionStore()
        let projection = AtriaVitalsSessionProjectionStore(store: sessionStore)
        var publications = 0
        let cancellable = projection.objectWillChange.sink { publications += 1 }

        sessionStore.objectWillChange.send()

        XCTAssertEqual(publications, 0)
        XCTAssertFalse(projection.refresh())
        withExtendedLifetime(cancellable) {}
    }

    func testUnchangedDashboardRevisionPathSkipsSnapshotConstruction() {
        let sessionStore = SessionStore()
        let projection = AtriaVitalsSessionProjectionStore(store: sessionStore)

        XCTAssertFalse(projection.refreshForDashboardRevision())
        XCTAssertEqual(projection.refreshAttemptCount, 0,
                       "Unrelated dashboard changes must not traverse Vitals arrays or baseline samples")
    }

    func testRelevantProfileChangeRefreshesProjectedMaxHeartRate() async {
        let sessionStore = SessionStore()
        let originalProfile = sessionStore.profile
        let projection = AtriaVitalsSessionProjectionStore(store: sessionStore)
        let nextMeasuredMax = originalProfile.measuredMaxHR == 211 ? 210 : 211
        let updated = expectation(description: "Vitals projection receives committed profile")
        let cancellable = projection.$state
            .dropFirst()
            .filter { $0.maxHeartRate == nextMeasuredMax }
            .prefix(1)
            .sink { _ in updated.fulfill() }

        sessionStore.updateProfile {
            $0.maxHRSource = .measured
            $0.measuredMaxHR = nextMeasuredMax
        }

        await fulfillment(of: [updated], timeout: 1)
        XCTAssertEqual(projection.state.maxHeartRate, nextMeasuredMax)
        XCTAssertFalse(projection.refresh())

        sessionStore.updateProfile { $0 = originalProfile }
        withExtendedLifetime(cancellable) {}
    }
}
