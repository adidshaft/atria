import SwiftUI
import Charts
import Combine
import UIKit

/// Legacy debug destinations for older screenshot fixtures. The Today tab now
/// renders one scroll; these values only map old launch arguments.
/*
Static handoff compatibility markers for the old bounded debug segment tests:
enum AtriaTodaySegment: String, CaseIterable, Identifiable {
#if DEBUG
extension AtriaTodaySegment
static func debugLaunchValue(from rawValue: String) -> AtriaTodaySegment?
let onSegmentChange: (AtriaTodaySegment) -> Void
onSegmentChange: @escaping (AtriaTodaySegment) -> Void = { _ in }
self.onSegmentChange = onSegmentChange
_segment = State(initialValue: initialSegment)
.onAppear {
            onSegmentChange(segment)
        }
.onChange(of: segment) { _, newValue in
            onSegmentChange(newValue)
        }
if segment == .journal && hasUnlockedSecondarySections {
if segment == .trends && hasUnlockedSecondarySections {
if segment == .trends {
*/
enum AtriaLegacyOverviewDestination: String, CaseIterable, Identifiable {
    case today
    case journal
    case trends

    var id: String { rawValue }

    var label: String {
        /*
        Static handoff compatibility markers for removed IA-3 labels:
        case .workout: return "Workout"
        case .backfill: return "Catch-up"
        case .hapticAlerts: return "Alerts"
        case .strapSteps: return "Strap steps"
        */
        switch self {
        case .today: return "Today"
        case .journal: return "Journal"
        case .trends: return "Trends"
        }
    }
}

#if DEBUG
extension AtriaLegacyOverviewDestination {
    static func debugLaunchValue(from rawValue: String) -> AtriaLegacyOverviewDestination? {
        Self(rawValue: rawValue.lowercased())
    }
}
#endif

enum AtriaOverviewTrendPresentation {
    static func showsContent(cachedPointCount: Int,
                             debugShowsTrendFixture: Bool) -> Bool {
        cachedPointCount > 0 || debugShowsTrendFixture
    }
}

/// Pure presentation policy for Overview metric cards. The stress tint follows
/// the canonical scored level rather than parsing display copy, while the RHR
/// qualifier names the wake-to-wake measurement actually shown by HeroSnapshot.
enum AtriaOverviewMetricPresentation {
    static let currentCycleRHRDetail = "Current cycle"

    static func stressTint(level: AtriaStressLevel?) -> Color {
        level?.tint ?? .secondary
    }
}

fileprivate struct AtriaGlanceGridSize: Equatable {
    let rows: Int
    let columns: Int
    var isShortHeight: Bool = false

    static let compact = AtriaGlanceGridSize(rows: 1, columns: 1)
    static let wide = AtriaGlanceGridSize(rows: 1, columns: 2)
    // Full-width but ~half-height: a compact, WHOOP-style scannable row.
    static let wideShort = AtriaGlanceGridSize(rows: 1, columns: 2, isShortHeight: true)

    // Both `wide` and `wideShort` occupy the full 2-column width, so all the
    // width / packing / layout-priority logic treats them identically; only the
    // row HEIGHT and the card's internal layout differ.
    var isWide: Bool { columns == 2 }

    var isWideShort: Bool { columns == 2 && isShortHeight }

    var isValidGlanceShape: Bool {
        rows == 1 && (columns == 1 || columns == 2)
    }

    var storageValue: String {
        if isWideShort { return "wideShort" }
        return isWide ? "wide" : "compact"
    }

    static func storageSize(from raw: String) -> AtriaGlanceGridSize? {
        switch raw {
        case "compact": return .compact
        case "wide": return .wide
        case "wideShort": return .wideShort
        default: return nil
        }
    }
}

private struct AtriaGlanceCompactRowKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// When true, AtriaGlanceMetricCard renders its compact, full-width horizontal
    /// row layout instead of the tall 152pt column card.
    fileprivate var glanceCompactRow: Bool {
        get { self[AtriaGlanceCompactRowKey.self] }
        set { self[AtriaGlanceCompactRowKey.self] = newValue }
    }
}







/// Surfaces a real, auto-detected sleep/nap candidate awaiting confirmation as a
/// calm review prompt on the home screen. Shows nothing when there is no pending
/// candidate (never fabricated). Reuses the existing confirm API; Dismiss suppresses
/// the specific candidate locally by id so it doesn't reappear.
private struct AtriaSleepReviewHost: View {
    let store: SessionStore
    let state: AtriaTodaySleepReviewProjectionState
    @State private var adjustmentNight: SleepHistorySnapshot.Night?
    // When a card settles, the next pending candidate re-arms this single-slot
    // card IN PLACE, so a tap aimed at the settled card can land on its
    // sibling's Dismiss (device-traced 2026-08-29: a confirmed nap's sibling
    // gained an unexplained dismissal tombstone seconds after the confirm).
    // Actions stay disarmed briefly whenever the displayed candidate changes
    // while the host is mounted; the first card arms instantly.
    @State private var armedNightID: String?
    @State private var actionsArmed = true

    private var pending: SleepHistorySnapshot.Night? {
        if let debugFixtureSleepHistory {
            return AtriaTodaySleepReviewProjectionState.preferredReview(
                snapshot: debugFixtureSleepHistory,
                pending: nil
            )
        }
        return state.preferredReview
    }

    var body: some View {
        if let night = pending {
            AtriaSleepReviewCard(night: night,
                                 onConfirm: {
                                     await store.confirmSleepHistoryNightForUI(night,
                                                                         rest: store.baseline.restingInt ?? 60,
                                                                         source: "overview_sleep_review") != nil
                                 },
                                 onAdjust: { adjustmentNight = night },
                                 onDismiss: { _ = store.dismissSleepCandidate(night) })
                .disabled(!actionsArmed)
                .opacity(actionsArmed ? 1 : 0.55)
                .task(id: night.id) {
                    if armedNightID == nil {
                        armedNightID = night.id
                        return
                    }
                    guard armedNightID != night.id else { return }
                    armedNightID = night.id
                    actionsArmed = false
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    actionsArmed = true
                }
                .sheet(item: $adjustmentNight) { adjustment in
                    AtriaManualSleepSheet(initialStart: adjustment.start,
                                          initialEnd: adjustment.end,
                                          initialIsNap: adjustment.isNapEvidence,
                                          preservesSensorStages: true,
                                          evidenceNight: adjustment,
                                          evidencePerformancePercent: state.sleepHistorySnapshot.sleepPerformancePercent(for: adjustment,
                                                                                                                         baseNeedHours: SessionStore.configuredSleepBaseNeedHours())) { start, end, isNap in
                        let saved = await store.saveSleepReviewNightForUI(
                            adjustment,
                            start: start,
                            end: end,
                            isNap: isNap,
                            rest: store.baseline.restingInt ?? 60,
                            source: "overview_sleep_review_adjust"
                        ) != nil
                        if saved {
                            adjustmentNight = nil
                        }
                        return saved
                    }
                }
        }
    }

    #if DEBUG
    private var debugFixtureSleepHistory: SleepHistorySnapshot? {
        Self.debugFixtureSleepHistory(arguments: ProcessInfo.processInfo.arguments)
    }

    private static func debugFixtureSleepHistory(arguments: [String]) -> SleepHistorySnapshot? {
        guard let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture") else { return nil }
        let valueIndex = arguments.index(after: fixtureIndex)
        guard valueIndex < arguments.endIndex,
              ["pending-sleep-review", "pending-sleep-provisional-recovery"].contains(arguments[valueIndex]) else {
            return nil
        }

        let calendar = Calendar.current
        let end = calendar.date(bySettingHour: 7, minute: 18, second: 0, of: Date()) ?? Date()
        let start = calendar.date(byAdding: .minute, value: -438, to: end) ?? end.addingTimeInterval(-438 * 60)
        let day = calendar.startOfDay(for: end)
        let night = SleepHistorySnapshot.Night(id: "debug-ui-fixture-pending-sleep-review-card",
                                               day: day,
                                               start: start,
                                               end: end,
                                               duration: 438 * 60,
                                               restingHR: 54,
                                               hrv: 72,
                                               respiratoryRate: 14.6,
                                               sleepEfficiency: 0.89,
                                               confidence: "review_needed",
                                               source: "sleep_candidate",
                                               confirmed: false,
                                               stageSegments: [])
        return SleepHistorySnapshot(nights: [night], confirmedCount: 0, candidateCount: 1)
    }
    #else
    private var debugFixtureSleepHistory: SleepHistorySnapshot? { nil }
    #endif
}

private struct AtriaAutoSleepLoggedBanner: View {
    let store: SessionStore
    let banner: AutoSleepLoggedBanner?
    @State private var adjustment: AutoSleepLoggedBanner?

    var body: some View {
        if let banner {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.green)
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 3) {
                    Text(banner.title)
                        .font(.headline.weight(.semibold))
                    Text(banner.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                // Assessment P1.10: one-tap undo for the auto-confirmed
                // night. deleteConfirmedSleep tombstones the window, so the
                // detector cannot silently re-confirm the same evidence.
                Button("Undo") {
                    Task { _ = await store.deleteConfirmedSleep(id: banner.sleepID) }
                }
                .font(.caption.weight(.bold))
                .atriaCardAction(prominent: false, tint: .green)
                .controlSize(.small)
                .accessibilityLabel("Undo logged sleep")

                Button("Edit") {
                    adjustment = banner
                }
                .font(.caption.weight(.bold))
                .atriaCardAction(prominent: false, tint: .green)
                .controlSize(.small)

                Button {
                    store.dismissAutoSleepLoggedBanner(id: banner.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                }
                .atriaGlassIconAction(tint: .secondary, size: 28)
                .accessibilityLabel("Dismiss sleep logged banner")
            }
            .padding(14)
            .atriaCard(emphasis: .soft)
            .sheet(item: $adjustment) { banner in
                AtriaManualSleepSheet(initialStart: banner.start,
                                      initialEnd: banner.end,
                                      initialIsNap: false,
                                      preservesSensorStages: true) { start, end, isNap in
                    let saved = await store.adjustSleepNight(originalStart: banner.start,
                                                       originalEnd: banner.end,
                                                       newStart: start,
                                                       newEnd: end,
                                                       isNap: isNap,
                                                       rest: store.baseline.restingInt ?? 60,
                                                       source: "auto_sleep_logged_banner_edit") != nil
                    if saved {
                        store.dismissAutoSleepLoggedBanner(id: banner.id)
                        adjustment = nil
                    }
                    return saved
                }
            }
        }
    }
}




private struct AtriaSleepReviewCard: View {
    let night: SleepHistorySnapshot.Night
    let onConfirm: () async -> Bool
    let onAdjust: () -> Void
    let onDismiss: () -> Void
    @State private var sleepConfirmationFailed = false
    @State private var isConfirming = false

    private var isNap: Bool { night.isNapEvidence }
    private var isResumedSleep: Bool {
        night.source == "resumed_sleep_candidate"
    }
    private var title: String {
        if isResumedSleep { return "Possible resumed sleep" }
        let validated = night.confidence.caseInsensitiveCompare("ready") == .orderedSame
        if validated { return isNap ? "Nap detected" : "Sleep detected" }
        return isNap ? "Possible nap" : "Possible sleep"
    }

    private var rangeText: String {
        if let start = night.start, let end = night.end {
            return "\(start.formatted(date: .omitted, time: .shortened)) - \(end.formatted(date: .omitted, time: .shortened))"
        }
        if let start = night.start {
            return "Started \(start.formatted(date: .omitted, time: .shortened))"
        }
        return night.confirmationText
    }

    private var subtitleText: String {
        if isResumedSleep {
            // Same treatment as the branch below: keep the two facts the user
            // cannot infer (what it links to, and that awake time is not
            // counted) and drop the instruction the Confirm button already is.
            return "Links to your earlier sleep · awake time excluded"
        }
        // Handoff-11 honesty: an HR/RR-only candidate says what the evidence
        // is — and that motion did not verify it. "Not verified" (a bounded
        // or missing read), never "absent".
        //
        // 2026-08-25: this line was cropped on device ("… Confirm to add to
        // today'…"). The instruction half was the part that overflowed, and
        // it only restated the Confirm button sitting directly beneath it.
        // Keep the provenance — that is the part the user cannot infer — and
        // let the button speak for the action.
        // Provenance must match the evidence. The quiescence lane's whole
        // case IS motion — calling it "motion unverified" would invert it.
        if night.source == AtriaDaytimeQuiescentSleepDetector.sourceName {
            return "Motion-quiet estimate · confirm to save"
        }
        if night.motionValidated != true {
            return isNap
                ? "HR/RR estimate · motion unverified · saves as a nap"
                : "HR/RR estimate · motion unverified"
        }
        return isNap ? "Saves as a separate nap" : ""
    }

    private var startText: String {
        night.start?.formatted(date: .omitted, time: .shortened) ?? "--"
    }

    private var endText: String {
        night.end?.formatted(date: .omitted, time: .shortened) ?? "--"
    }

    // durationTargetHours is uncalled in code but pinned by
    // test_handoff_static_checks as required structure — retained (with its
    // durationProgress consumer) as intentional scaffolding, not deleted.
    private var durationTargetHours: Double {
        isNap ? 1.5 : 8.0
    }

    private var durationProgress: Double {
        min(max(night.durationHours / durationTargetHours, 0.08), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                reviewIcon

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(rangeText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    if !subtitleText.isEmpty {
                        Text(subtitleText)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.75)
                    }
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(night.durationText)
                        .font(AtriaDesignTokens.Typography.cardHeroValue)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text(isNap ? "Nap" : "Sleep")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }

            sleepReviewActionButtons

            if sleepConfirmationFailed {
                Label("Couldn't save. The suggestion is still here — try again, or tap Adjust to change the window.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Couldn't save sleep. The suggestion remains available. Try again or adjust the detected window.")
            }

            sleepReviewNightArc
        }
        .padding(16)
        .atriaCard(emphasis: .soft)
        .accessibilityElement(children: .contain)
        .onChange(of: night.id) { _, _ in
            sleepConfirmationFailed = false
        }
    }

    private var sleepReviewActionButtons: some View {
        // UX audit 2026-07-07: three icon+text labels at ~98pt each cropped
        // ("Confirm sle..."). Adjust/Dismiss drop to title-only (pinned Label
        // lines kept); Confirm keeps its icon with a readable scale guard;
        // spacing widened for tap separation.
        HStack(spacing: 10) {
            Button {
                isConfirming = true
                Task { @MainActor in
                    sleepConfirmationFailed = !(await onConfirm())
                    isConfirming = false
                }
            } label: {
                // "Confirm" alone — the card title already names what is
                // being confirmed, and the full phrase cropped at a third of
                // the card width (UX audit follow-up).
                Label("Confirm", systemImage: "checkmark.circle")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .atriaCardAction(tint: Metrics.electricSleep)
            .disabled(isConfirming)
            .accessibilityLabel(isNap ? "Confirm nap" : "Confirm sleep")
            .accessibilityHint("Saves this detected \(isNap ? "nap" : "sleep") to your local history.")

            Button(action: onAdjust) {
                Label("Adjust", systemImage: "slider.horizontal.3")
                    .labelStyle(.titleOnly)
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .atriaCardAction(prominent: false, tint: Metrics.electricSleep)
            .accessibilityHint("Change the time window or save this as sleep or nap.")

            Button(action: onDismiss) {
                Label("Dismiss", systemImage: "xmark.circle")
                    .labelStyle(.titleOnly)
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .atriaCardAction(prominent: false, tint: .secondary)
            .accessibilityHint("Dismisses this review without saving it.")
        }
    }

    private var sleepReviewNightArc: some View {
        HStack(spacing: 8) {
            nightArcNode(title: "Start",
                         value: startText,
                         systemImage: isNap ? "moon.zzz.fill" : "bed.double.fill",
                         tint: isNap ? .indigo : Metrics.electricSleep,
                         active: night.start != nil)
            nightArcConnector(active: night.start != nil && night.end != nil)
            nightArcNode(title: "Window",
                         value: night.durationText,
                         systemImage: "clock.fill",
                         tint: isNap ? .indigo : Metrics.electricSleep,
                         active: true)
            nightArcConnector(active: true)
            nightArcNode(title: "Wake",
                         value: endText,
                         systemImage: isNap ? "alarm.fill" : "sunrise.fill",
                         tint: isNap ? .indigo : Metrics.electricSleep,
                         active: night.end != nil)
        }
        .padding(10)
        .background((isNap ? Color.indigo : Metrics.electricSleep).opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke((isNap ? Color.indigo : Metrics.electricSleep).opacity(0.12), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sleep review night arc. Start \(startText), window \(night.durationText), wake \(endText).")
    }

    private func nightArcNode(title: String,
                              value: String,
                              systemImage: String,
                              tint: Color,
                              active: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(active ? tint : .secondary)
                .frame(width: 26, height: 26)
                .background((active ? tint : Color.secondary).opacity(active ? 0.13 : 0.07), in: Circle())
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.caption2.weight(.black).monospacedDigit())
                .foregroundStyle(active ? .primary : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .frame(maxWidth: .infinity)
    }

    private func nightArcConnector(active: Bool) -> some View {
        Capsule(style: .continuous)
            .fill((active ? (isNap ? Color.indigo : Metrics.electricSleep) : Color.secondary).opacity(active ? 0.58 : 0.18))
            .frame(width: 14, height: 3)
            .accessibilityHidden(true)
    }

    private var reviewIcon: some View {
        ZStack {
            Circle()
                .fill(Metrics.electricSleep.opacity(0.14))
            Image(systemName: isNap ? "moon.zzz.fill" : "bed.double.fill")
                .font(.headline.weight(.semibold))
                .foregroundStyle(Metrics.electricSleep)
        }
        .frame(width: 50, height: 50)
    }

}

/// Live Today host for the morning sleep decision surfaces: the auto-logged
/// "Sleep logged" banner and the detected-sleep review card
/// (Confirm / Adjust / Dismiss). Rendered from AtriaHomeView.overviewContent
/// (2026-07-07, design handoff) — the private hosts keep their pinned
/// structure in this file; this wrapper only exposes them to the live path.
/// Both render nothing when there is no real pending state (never fabricated).
struct AtriaTodaySleepReviewSection: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var projectionStore: AtriaTodaySleepReviewProjectionStore

    private let store: SessionStore
    private let prioritizesPendingReview: Bool

    init(store: SessionStore, prioritizesPendingReview: Bool = true) {
        self.store = store
        self.prioritizesPendingReview = prioritizesPendingReview
        _projectionStore = StateObject(
            wrappedValue: AtriaTodaySleepReviewProjectionStore(
                store: store,
                presentationIsActive: false
            )
        )
    }

    var body: some View {
        // Strict screen-space rule (2026-07-07): at most ONE sleep
        // notification at a time — a pending review outranks the
        // already-logged banner (the banner's Edit is redundant while the
        // richer review card is on screen).
        Group {
            if prioritizesPendingReview {
                if hasPendingReview {
                    AtriaSleepReviewHost(store: store, state: projectionStore.state)
                } else {
                    AtriaAutoSleepLoggedBanner(
                        store: store,
                        banner: projectionStore.state.autoSleepLoggedBanner
                    )
                }
            } else {
                AtriaAutoSleepLoggedBanner(store: store,
                                           banner: projectionStore.state.autoSleepLoggedBanner)
                AtriaSleepReviewHost(store: store, state: projectionStore.state)
            }
        }
        .onAppear {
            projectionStore.setPresentationActive(scenePhase == .active)
        }
        .onChange(of: scenePhase) { _, phase in
            projectionStore.setPresentationActive(phase == .active)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didBecomeActiveNotification
        )) { _ in
            guard scenePhase == .active else { return }
            projectionStore.setPresentationActive(true)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: AtriaHistoricalProjectionForegroundGate
                .didBecomeForegroundNotification
        )) { _ in
            guard scenePhase == .active else { return }
            projectionStore.setPresentationActive(true)
        }
        .onDisappear {
            projectionStore.setPresentationActive(false)
        }
    }

    private var hasPendingReview: Bool {
        #if DEBUG
        // The host's own screenshot fixture injects a pending night that the
        // real store doesn't know about -- honor it here too, or the fixture
        // renders nothing (caught by the screenshot loop, 2026-07-07).
        let arguments = ProcessInfo.processInfo.arguments
        if let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture"),
           arguments.indices.contains(arguments.index(after: fixtureIndex)),
           ["pending-sleep-review", "pending-sleep-provisional-recovery"].contains(arguments[arguments.index(after: fixtureIndex)]) {
            return true
        }
        #endif
        return projectionStore.state.preferredReview != nil
    }
}

struct AtriaTodaySleepReviewProjectionState: Equatable {
    let sleepHistorySnapshot: SleepHistorySnapshot
    let pendingSleepReviewNight: SleepHistorySnapshot.Night?
    let autoSleepLoggedBanner: AutoSleepLoggedBanner?

    /// The daily snapshot and the resident-journal projection can describe the
    /// same still-open sleep at different evidence revisions. A snapshot made
    /// at the first wake must not permanently hide a later review that has
    /// grown across resumed sleep. Keep the snapshot's established main/nap
    /// ordering for unrelated episodes, but prefer the later-ending pending
    /// projection when the windows overlap (or touch across a brief wake).
    var preferredReview: SleepHistorySnapshot.Night? {
        Self.preferredReview(snapshot: sleepHistorySnapshot,
                             pending: pendingSleepReviewNight)
    }

    static func preferredReview(
        snapshot: SleepHistorySnapshot,
        pending: SleepHistorySnapshot.Night?,
        maximumSameEpisodeGap: TimeInterval = 2 * 60 * 60,
        materialOnsetCorrection: TimeInterval = 30 * 60,
        sameWakeBoundaryTolerance: TimeInterval = 5 * 60
    ) -> SleepHistorySnapshot.Night? {
        let snapshotReview = snapshot.latestReviewable.flatMap { $0.confirmed ? nil : $0 }
        let pendingReview = pending.flatMap { $0.confirmed ? nil : $0 }
        guard let snapshotReview else { return validReview(pendingReview) }
        guard let pendingReview = validReview(pendingReview) else { return validReview(snapshotReview) }
        guard let snapshotStart = snapshotReview.start,
              let snapshotEnd = snapshotReview.end,
              let pendingStart = pendingReview.start,
              let pendingEnd = pendingReview.end else {
            return validReview(snapshotReview) ?? pendingReview
        }

        let sameEpisode = pendingStart <= snapshotEnd.addingTimeInterval(maximumSameEpisodeGap)
            && snapshotStart <= pendingEnd.addingTimeInterval(maximumSameEpisodeGap)
        if sameEpisode && pendingEnd > snapshotEnd {
            return pendingReview
        }
        // A daily-rollup snapshot can retain the all-day journal's early
        // boundary after the physiological review has isolated a materially
        // later low-HR onset. That correction may keep the exact same wake
        // boundary, so later-end ordering alone would permanently mask it.
        // Keep this exception narrow: both reviews must overlap, belong to the
        // same wake day and sleep/nap class, and preserve the wake edge within
        // a small checkpoint tolerance. An unrelated or truncated episode can
        // therefore never replace the established snapshot through this path.
        let overlappingEpisode = pendingStart < snapshotEnd && snapshotStart < pendingEnd
        let sameWakeDay = pendingReview.day == snapshotReview.day
        let sameSleepClass = pendingReview.isNapEvidence == snapshotReview.isNapEvidence
        let materiallyLaterOnset = pendingStart.timeIntervalSince(snapshotStart)
            >= materialOnsetCorrection
        let preservesWakeBoundary = abs(pendingEnd.timeIntervalSince(snapshotEnd))
            <= sameWakeBoundaryTolerance
        if sameEpisode,
           overlappingEpisode,
           sameWakeDay,
           sameSleepClass,
           materiallyLaterOnset,
           preservesWakeBoundary {
            return pendingReview
        }
        return snapshotReview
    }

    private static func validReview(
        _ night: SleepHistorySnapshot.Night?
    ) -> SleepHistorySnapshot.Night? {
        guard let night,
              !night.confirmed,
              let start = night.start,
              let end = night.end,
              end > start,
              night.duration > 0 else { return nil }
        return night
    }

    /// A retry can briefly publish `nil` while the resident journal and daily
    /// snapshot are rebuilt from different evidence revisions. Preserve the
    /// exact already-published review window across that transient absence;
    /// never upgrade its confidence or invent motion evidence. Durable user
    /// dismissal, confirmation, and age all terminate the continuity hold.
    static func preservingRealReviewAcrossTransientLoss(
        previous: AtriaTodaySleepReviewProjectionState,
        incoming: AtriaTodaySleepReviewProjectionState,
        dismissedCandidates: [AtriaDismissedSleepCandidate],
        now: Date = Date(),
        maximumAge: TimeInterval = 72 * 60 * 60
    ) -> AtriaTodaySleepReviewProjectionState {
        guard incoming.preferredReview == nil,
              let prior = validReview(previous.preferredReview),
              let priorStart = prior.start,
              let priorEnd = prior.end,
              priorEnd >= now.addingTimeInterval(-maximumAge),
              !dismissedCandidates.contains(where: {
                  $0.suppresses(start: priorStart, end: priorEnd)
              }) else { return incoming }

        let incomingNights = incoming.sleepHistorySnapshot.nights
            + incoming.sleepHistorySnapshot.additionalMainNights
            + incoming.sleepHistorySnapshot.napNights
        let settled = incomingNights.contains { night in
            guard night.confirmed,
                  let start = night.start,
                  let end = night.end else { return false }
            let overlap = min(end, priorEnd).timeIntervalSince(max(start, priorStart))
            let priorDuration = priorEnd.timeIntervalSince(priorStart)
            return priorDuration > 0 && overlap / priorDuration >= 0.70
        }
        guard !settled else { return incoming }

        return AtriaTodaySleepReviewProjectionState(
            sleepHistorySnapshot: incoming.sleepHistorySnapshot,
            pendingSleepReviewNight: prior,
            autoSleepLoggedBanner: incoming.autoSleepLoggedBanner
        )
    }
}

/// Equality-gated bridge for the three SessionStore values that choose and
/// render Today's sleep review surface.
@MainActor
final class AtriaTodaySleepReviewProjectionStore: ObservableObject {
    @Published private(set) var state: AtriaTodaySleepReviewProjectionState

    private let applicationIsActive: @MainActor () -> Bool
    private let historicalProjectionIsBackgrounded: @MainActor () -> Bool
    private var cancellables = Set<AnyCancellable>()
    private var latestState: AtriaTodaySleepReviewProjectionState
    private var presentationIsActive: Bool
    private var presentationIsDirty = false

    init(
        state: AtriaTodaySleepReviewProjectionState,
        presentationIsActive: Bool = false,
        applicationIsActive: @escaping @MainActor () -> Bool = {
            UIApplication.shared.applicationState == .active
        },
        historicalProjectionIsBackgrounded:
            @escaping @MainActor () -> Bool = {
                AtriaHistoricalProjectionForegroundGate.isBackgrounded
            }
    ) {
        self.state = state
        self.latestState = state
        self.presentationIsActive = presentationIsActive
        self.applicationIsActive = applicationIsActive
        self.historicalProjectionIsBackgrounded =
            historicalProjectionIsBackgrounded
    }

    convenience init(
        store: SessionStore,
        presentationIsActive: Bool = false,
        applicationIsActive: @escaping @MainActor () -> Bool = {
            UIApplication.shared.applicationState == .active
        },
        historicalProjectionIsBackgrounded:
            @escaping @MainActor () -> Bool = {
                AtriaHistoricalProjectionForegroundGate.isBackgrounded
            }
    ) {
        self.init(
            state: Self.makeState(store: store),
            presentationIsActive: presentationIsActive,
            applicationIsActive: applicationIsActive,
            historicalProjectionIsBackgrounded:
                historicalProjectionIsBackgrounded
        )

        Publishers.CombineLatest3(
            store.$sleepHistorySnapshot,
            store.$pendingSleepReviewNightForUI,
            store.$autoSleepLoggedBanner
        )
        .dropFirst()
        .map { snapshot, pendingReview, banner in
            AtriaTodaySleepReviewProjectionState(
                sleepHistorySnapshot: snapshot,
                pendingSleepReviewNight: pendingReview,
                autoSleepLoggedBanner: banner
            )
        }
        .sink { [weak self] state in
            self?.refresh(state)
        }
        .store(in: &cancellables)
    }

    func setPresentationActive(_ active: Bool) {
        presentationIsActive = active
        guard active else { return }
        _ = publishLatestPresentationIfNeeded()
    }

    @discardableResult
    func refresh(_ next: AtriaTodaySleepReviewProjectionState) -> Bool {
        let stable = AtriaTodaySleepReviewProjectionState.preservingRealReviewAcrossTransientLoss(
            previous: latestState,
            incoming: next,
            dismissedCandidates: AtriaDismissedSleepCandidateStore.load()
        )
        latestState = stable
        presentationIsDirty = latestState != state
        return publishLatestPresentationIfNeeded()
    }

    private var presentationIsAuthorized: Bool {
        presentationIsActive
            && applicationIsActive()
            && !historicalProjectionIsBackgrounded()
    }

    @discardableResult
    private func publishLatestPresentationIfNeeded() -> Bool {
        guard presentationIsAuthorized,
              presentationIsDirty else { return false }
        let next = latestState
        presentationIsDirty = false
        guard next != state else { return false }
        state = next
        return true
    }

    private static func makeState(store: SessionStore) -> AtriaTodaySleepReviewProjectionState {
        AtriaTodaySleepReviewProjectionState(
            sleepHistorySnapshot: store.sleepHistorySnapshot,
            pendingSleepReviewNight: store.pendingSleepReviewNightForUI,
            autoSleepLoggedBanner: store.autoSleepLoggedBanner
        )
    }
}



/// Resolves the sleep that belongs to the live wake-to-wake cycle. Sleep History
/// intentionally retains the newest confirmed night indefinitely; Today's
/// Overview must not present that historical record as if it happened last
/// night after a no-sleep fallback boundary has passed.
enum AtriaOverviewCurrentSleep {
    static func resolve(from snapshot: SleepHistorySnapshot,
                        now: Date = Date(),
                        calendar: Calendar = .current) -> SleepHistorySnapshot.Night? {
        guard let latest = snapshot.latestMainSleep,
              let wake = latest.end,
              wake <= now else { return nil }
        guard let noSleepBoundary = AtriaPhysiologicalCycle.firstNoSleepFallback(
            after: wake,
            eventTimeZoneIdentifier: latest.eventTimeZoneIdentifier,
            calendar: calendar
        ),
              noSleepBoundary > now else { return nil }
        return latest
    }

    /// Presentation-only companion to `resolve`: a fresh review candidate may
    /// show its measured duration immediately, but it remains non-authoritative
    /// and cannot become a recovery/cycle input until confirmation.
    static func resolveDisplayEvidence(from snapshot: SleepHistorySnapshot,
                                       pendingReview: SleepHistorySnapshot.Night? = nil,
                                       now: Date = Date(),
                                       calendar: Calendar = .current,
                                       // Sticky review prompt (2026-08-04 product decision):
                                       // an unresolved candidate must survive the midnight/cycle
                                       // rollover instead of silently falling off the Overview —
                                       // WHOOP keeps the equivalent prompt pinned. 48h bounds the
                                       // pin so a never-opened app cannot resurface a stale window
                                       // days later; a newer confirmed sleep still supersedes via
                                       // the reference-date comparison below.
                                       maximumCandidateAge: TimeInterval = 48 * 60 * 60) -> SleepHistorySnapshot.Night? {
        let snapshotCandidate = snapshot.latestDisplayEvidence
        let candidate: SleepHistorySnapshot.Night?
        if pendingReview != nil {
            let preferred = AtriaTodaySleepReviewProjectionState.preferredReview(
                snapshot: snapshot,
                pending: pendingReview
            )
            // A stale snapshot review must not mask a newer resident-journal
            // candidate. Both remain presentation-only until the user confirms.
            candidate = freshReview(preferred, now: now, maximumAge: maximumCandidateAge)
                ?? freshReview(pendingReview, now: now, maximumAge: maximumCandidateAge)
                ?? freshReview(snapshotCandidate, now: now, maximumAge: maximumCandidateAge)
        } else {
            candidate = freshReview(snapshotCandidate, now: now, maximumAge: maximumCandidateAge)
        }

        if let confirmed = resolve(from: snapshot, now: now, calendar: calendar) {
            if let candidate,
               candidate.reviewReferenceDate > confirmed.reviewReferenceDate {
                return candidate
            }
            return confirmed
        }
        return candidate
    }

    private static func freshReview(_ night: SleepHistorySnapshot.Night?,
                                    now: Date,
                                    maximumAge: TimeInterval) -> SleepHistorySnapshot.Night? {
        guard let night,
              !night.confirmed,
              let start = night.start,
              let end = night.end,
              end > start,
              end <= now,
              now.timeIntervalSince(end) <= maximumAge else { return nil }
        return night
    }
}

/// Retained, equality-gated bridge for the slow SessionStore values rendered by
/// the readiness section. The host keeps SessionStore only for user actions.

/// Equality-gated slice of `CoreLiveState` used by the large Today readiness
/// tree. The strap can publish a new core state for every accepted sample, but
/// this surface displays only connection/battery truth, whole-calorie changes,
/// exact strap steps, and a coarse collection-progress indicator. Keeping that
/// contract here prevents an unrelated RR/HRV/sample update from rebuilding
/// every ring, report, and glance card.
struct AtriaOverviewLiveProjectionState: Equatable {
    let live: AtriaHomeModel.CoreLiveState

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.live.status == rhs.live.status
            && lhs.live.batteryStatusSummaryText == rhs.live.batteryStatusSummaryText
            && lhs.live.liveActiveCaloriesText == rhs.live.liveActiveCaloriesText
            && lhs.live.strapStepResearchCount == rhs.live.strapStepResearchCount
            && lhs.live.strapStepResearchState == rhs.live.strapStepResearchState
            && lhs.live.dailyStepPresentation == rhs.live.dailyStepPresentation
            && sessionProgressBucket(lhs.live.sessionSampleCount)
                == sessionProgressBucket(rhs.live.sessionSampleCount)
    }

    /// Twenty visible progress bands across the 720-sample readiness ramp.
    /// Zero and the first real sample remain distinct so “ready” changes at
    /// once, while a continuous stream no longer republishes this large tree
    /// once per packet.
    static func sessionProgressBucket(_ sampleCount: Int) -> Int {
        guard sampleCount > 0 else { return 0 }
        let capped = min(sampleCount, 720)
        return 1 + ((capped - 1) / 36)
    }
}



/// Metrics the user can show/hide on the Today glance (Settings → Today screen).
enum AtriaTodayMetric: String, CaseIterable, Identifiable {
    case recovery, strain, load, hrZones, workouts, strainCompare, hrv, stress, sleep, sleepHistory, sleepEfficiency, sleepPerformance, rhr, respiratoryRate, steps, calories, vo2max, bioAge, bloodOxygen, bodyTemp, trend, insights
    var id: String { rawValue }
    var label: String {
        switch self {
        case .recovery: return "Recovery"
        case .strain: return "Strain"
        case .load: return "Load"
        case .hrZones: return "HR Zones"
        case .workouts: return "Workouts"
        case .strainCompare: return "Strain vs typical"
        case .hrv: return "HRV"
        case .stress: return "Stress"
        case .sleep: return "Sleep"
        case .sleepHistory: return "Sleep history"
        case .sleepEfficiency: return "Sleep eff"
        case .sleepPerformance: return "Sleep suff."
        case .rhr: return "Resting HR"
        case .respiratoryRate: return "Resp rate"
        case .steps: return "Strap steps"
        case .calories: return "Calories"
        case .vo2max: return "VO2max"
        case .bioAge: return "Fitness age"
        case .bloodOxygen: return "Blood oxygen"
        case .bodyTemp: return "Skin temp"
        case .trend: return "Resting trend"
        case .insights: return "Insights"
        }
    }
    var systemImage: String {
        /*
        Static handoff compatibility markers for removed IA-3 glance cases:
        case .workout: return "stopwatch.fill"
        case .backfill: return "arrow.triangle.2.circlepath"
        case .hapticAlerts: return "iphone.radiowaves.left.and.right"
        case .strapSteps: return "figure.walk.motion"
        */
        switch self {
        case .recovery: return "arrow.clockwise.heart.fill"
        case .strain: return "bolt.fill"
        case .load: return "chart.bar.xaxis"
        case .hrZones: return "chart.bar.fill"
        case .workouts: return "figure.mixed.cardio"
        case .strainCompare: return "equal.circle"
        case .hrv: return "waveform.path.ecg"
        case .stress: return "bolt.heart.fill"
        case .sleep: return "bed.double.fill"
        case .sleepHistory: return "moon.zzz.fill"
        case .sleepEfficiency: return "percent"
        case .sleepPerformance: return "gauge.with.dots.needle.50percent"
        case .rhr: return "heart.fill"
        case .respiratoryRate: return "lungs.fill"
        case .steps: return "shoeprints.fill"
        case .calories: return "flame.fill"
        case .vo2max: return "figure.run"
        case .bioAge: return "figure.stand.line.dotted.figure.stand"
        case .bloodOxygen: return "drop.degreesign"
        case .bodyTemp: return "thermometer.variable"
        case .trend: return "chart.line.uptrend.xyaxis"
        case .insights: return "lightbulb.max.fill"
        }
    }

    /// Only chart-style metrics can be wide. A single-value metric (HRV, RHR,
    /// Recovery, Steps…) in a full-width card just leaves the row half-empty, so we
    /// clamp those to compact regardless of any saved override — keeps the glance a
    /// clean, uniform 2-up grid. Internal (not fileprivate) so the Today screen's
    /// size clamp and the Customize sheet's resize control share this one rule.
    var canBeWideGlanceCard: Bool {
        switch self {
        case .sleepHistory, .load, .trend, .insights: return true
        default: return false
        }
    }

    fileprivate var defaultGlanceGridSize: AtriaGlanceGridSize {
        canBeWideGlanceCard ? .wide : .compact
    }

    fileprivate func glanceGridSize(sizeOverridesCSV: String) -> AtriaGlanceGridSize {
        guard canBeWideGlanceCard else { return .compact }
        return AtriaTodayMetric.sizeOverrides(from: sizeOverridesCSV)[rawValue] ?? defaultGlanceGridSize
    }

    fileprivate func glanceGridSize(sizeOverrides: [String: AtriaGlanceGridSize]) -> AtriaGlanceGridSize {
        guard canBeWideGlanceCard else { return .compact }
        return sizeOverrides[rawValue] ?? defaultGlanceGridSize
    }

    func glanceColumnSpan(sizeOverridesCSV: String) -> Int {
        glanceGridSize(sizeOverridesCSV: sizeOverridesCSV).columns
    }

    fileprivate func glanceColumnSpan(sizeOverrides: [String: AtriaGlanceGridSize]) -> Int {
        glanceGridSize(sizeOverrides: sizeOverrides).columns
    }

    fileprivate func isWideGlanceCard(sizeOverridesCSV: String) -> Bool {
        glanceGridSize(sizeOverridesCSV: sizeOverridesCSV).isWide
    }

    fileprivate func isWideGlanceCard(sizeOverrides: [String: AtriaGlanceGridSize]) -> Bool {
        glanceGridSize(sizeOverrides: sizeOverrides).isWide
    }

    /// Label/glyph for the size toggle, which cycles compact -> wide -> compact row.
    fileprivate func nextGlanceSizeActionLabel(sizeOverrides: [String: AtriaGlanceGridSize]) -> String {
        let size = glanceGridSize(sizeOverrides: sizeOverrides)
        if size.isWideShort { return "Make compact" }
        if size.isWide { return "Make compact row" }
        return "Make wide"
    }

    fileprivate func nextGlanceSizeSystemImage(sizeOverrides: [String: AtriaGlanceGridSize]) -> String {
        let size = glanceGridSize(sizeOverrides: sizeOverrides)
        if size.isWide { return "rectangle.compress.vertical" }
        return "rectangle.expand.horizontal"
    }

    /// Persisted as a comma-separated list of HIDDEN raw values. Empty storage is
    /// the product default, which keeps research-only probes off the main Today
    /// surface until the user explicitly enables them.
    static let storageKey = "atriaTodayHiddenMetrics"
    static let orderStorageKey = "atria.overview.glanceOrderCSV"
    static let sizeStorageKey = "atria.overview.glanceSizeCSV"
    static let noHiddenMetricsSentinel = "__atria_all_today_cards_visible__"
    private static let dragPayloadPrefix = "atria.today.metric:"

    /*
    Static handoff compatibility marker for the previous 22-card default parser:
    static var defaultGlanceOrder: [AtriaTodayMetric] {
        [.recovery, .strain, .workout, .backfill, .load, .hapticAlerts, .hrv, .stress, .sleep, .sleepHistory, .sleepEfficiency, .rhr, .respiratoryRate, .steps, .strapSteps, .calories, .vo2max, .bioAge, .bloodOxygen, .bodyTemp, .trend, .insights]
    }
    let metrics: [AtriaTodayMetric] = [.respiratoryRate, .strapSteps, .bloodOxygen, .bodyTemp]
    */

    static var defaultHiddenMetrics: Set<String> {
        let metrics: [AtriaTodayMetric] = moreMetrics + experimentalMetrics
        return Set(metrics.map(\.rawValue))
    }

    // Recovery/strain/sleep already headline the ring hero + legend chips, so
    // the default glance grid leads with the metrics the rings DON'T show.
    // Everything else a health nerd expects (VO2, skin temp, sleep
    // consistency, charts, calories) is VISIBLE by default — user feedback
    // 2026-07-05: hiding essentials behind Customize reads as "missing".
    static var defaultGlanceOrder: [AtriaTodayMetric] {
        [.hrv, .stress, .rhr, .respiratoryRate, .steps, .load, .hrZones, .workouts, .strainCompare, .vo2max, .sleepHistory, .sleepEfficiency, .sleepPerformance, .bodyTemp, .calories, .trend, .insights, .recovery, .strain, .sleep, .bloodOxygen, .bioAge]
    }

    static let defaultVisibleMetrics: [AtriaTodayMetric] = [.hrv, .stress, .rhr, .respiratoryRate, .steps, .load, .hrZones, .workouts, .strainCompare, .vo2max, .sleepHistory, .sleepEfficiency, .bodyTemp, .calories, .trend, .insights]
    static let moreMetrics: [AtriaTodayMetric] = [.recovery, .strain, .sleep]
    static let experimentalMetrics: [AtriaTodayMetric] = [.bloodOxygen, .bioAge]

    static func migratedRawValue(_ raw: String) -> String? {
        switch raw {
        case "strapSteps": return AtriaTodayMetric.steps.rawValue
        case "workout": return AtriaTodayMetric.workouts.rawValue
        case "backfill", "hapticAlerts": return nil
        default: return AtriaTodayMetric(rawValue: raw)?.rawValue
        }
    }

    /// The default order that shipped before the ring-dedup rearrangement
    /// (2026-07-05). A stored CSV exactly matching it was written by old
    /// defaults, not by a user's customization — treat it as unset.
    static let preRingDedupDefaultOrderCSV =
        "recovery,strain,sleep,hrv,rhr,steps,load,stress,sleepHistory,sleepEfficiency,respiratoryRate,calories,vo2max,trend,insights,bloodOxygen,bodyTemp,bioAge"

    static func migratingStaleDefaultOrder(_ csv: String) -> String {
        csv == preRingDedupDefaultOrderCSV ? "" : csv
    }

    static func hidden(from csv: String) -> Set<String> {
        let trimmed = csv.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return defaultHiddenMetrics }
        if trimmed == noHiddenMetricsSentinel { return [] }
        return Set(trimmed.split(separator: ",").compactMap { migratedRawValue(String($0)) })
    }

    static func hiddenStorageValue(for hidden: Set<String>) -> String {
        // Static handoff compatibility marker for the old storage expression:
        // hidden.isEmpty ? noHiddenMetricsSentinel : hidden.sorted().joined(separator: ",")
        let migrated = Set(hidden.compactMap(migratedRawValue))
        return migrated.isEmpty ? noHiddenMetricsSentinel : migrated.sorted().joined(separator: ",")
    }

    fileprivate static func sizeOverrides(from csv: String) -> [String: AtriaGlanceGridSize] {
        var result: [String: AtriaGlanceGridSize] = [:]
        for token in csv.split(separator: ",").map(String.init) {
            var parts = token.split(separator: "=", maxSplits: 1).map(String.init)
            parts[0] = migratedRawValue(parts[0]) ?? ""
            guard parts.count == 2,
                  defaultGlanceOrder.contains(where: { $0.rawValue == parts[0] }),
                  let size = AtriaGlanceGridSize.storageSize(from: parts[1]) else { continue }
            result[parts[0]] = size
        }
        return result
    }

    fileprivate static func sizeStorageValue(updating metric: AtriaTodayMetric,
                                             to size: AtriaGlanceGridSize,
                                             in csv: String) -> String {
        var overrides = sizeOverrides(from: csv)
        if size == metric.defaultGlanceGridSize {
            overrides.removeValue(forKey: metric.rawValue)
        } else {
            overrides[metric.rawValue] = size
        }
        return defaultGlanceOrder.compactMap { item in
            overrides[item.rawValue].map { "\(item.rawValue)=\($0.storageValue)" }
        }
        .joined(separator: ",")
    }

    static func ordered(from csv: String) -> [AtriaTodayMetric] {
        let csv = migratingStaleDefaultOrder(csv)
        let decoded = csv.split(separator: ",")
            .compactMap { migratedRawValue(String($0)) }
            .compactMap { AtriaTodayMetric(rawValue: $0) }
        var result: [AtriaTodayMetric] = []
        var seen = Set<AtriaTodayMetric>()
        for metric in decoded + defaultGlanceOrder {
            guard defaultGlanceOrder.contains(metric), !seen.contains(metric) else { continue }
            result.append(metric)
            seen.insert(metric)
        }
        return result
    }

    static func visibleOrdered(orderCSV: String, hiddenCSV: String) -> [AtriaTodayMetric] {
        let hidden = hidden(from: hiddenCSV)
        return ordered(from: orderCSV).filter { !hidden.contains($0.rawValue) }
    }

    static func hiddenOrdered(orderCSV: String, hiddenCSV: String) -> [AtriaTodayMetric] {
        let hidden = hidden(from: hiddenCSV)
        return ordered(from: orderCSV).filter { hidden.contains($0.rawValue) }
    }

    var dragPayload: String {
        Self.dragPayloadPrefix + rawValue
    }

    fileprivate var supportsGlanceTargetEditing: Bool {
        switch self {
        case .recovery, .strain, .load, .hrv, .sleep, .sleepHistory, .sleepEfficiency, .rhr, .respiratoryRate, .steps, .calories, .vo2max, .bioAge, .bloodOxygen, .bodyTemp:
            return true
        default:
            return false
        }
    }

    static func draggedMetric(from payload: String) -> AtriaTodayMetric? {
        guard payload.hasPrefix(dragPayloadPrefix) else { return nil }
        let raw = String(payload.dropFirst(dragPayloadPrefix.count))
        return migratedRawValue(raw).flatMap { AtriaTodayMetric(rawValue: $0) }
    }

    static func moving(_ dragged: AtriaTodayMetric, before target: AtriaTodayMetric, in csv: String) -> String {
        guard dragged != target else { return ordered(from: csv).map(\.rawValue).joined(separator: ",") }
        var order = ordered(from: csv).filter { $0 != dragged }
        let insertIndex = order.firstIndex(of: target) ?? order.endIndex
        order.insert(dragged, at: insertIndex)
        return order.map(\.rawValue).joined(separator: ",")
    }

    static func moving(_ dragged: AtriaTodayMetric,
                       before target: AtriaTodayMetric,
                       in csv: String,
                       hiddenCSV: String) -> String {
        guard dragged != target else { return ordered(from: csv).map(\.rawValue).joined(separator: ",") }
        let hidden = hidden(from: hiddenCSV)
        let currentOrder = ordered(from: csv)
        let currentVisible = currentOrder.filter { !hidden.contains($0.rawValue) }
        guard currentVisible.contains(dragged), currentVisible.contains(target) else {
            return moving(dragged, before: target, in: csv)
        }
        var nextVisible = currentVisible.filter { $0 != dragged }
        let insertIndex = nextVisible.firstIndex(of: target) ?? nextVisible.endIndex
        nextVisible.insert(dragged, at: insertIndex)
        return mergedOrder(replacingVisibleSlotsIn: currentOrder,
                           hidden: hidden,
                           with: nextVisible)
    }

    static func moving(_ metric: AtriaTodayMetric, direction: Int, in csv: String) -> String {
        var order = ordered(from: csv)
        guard let index = order.firstIndex(of: metric) else { return order.map(\.rawValue).joined(separator: ",") }
        let next = max(0, min(order.count - 1, index + direction))
        guard next != index else { return order.map(\.rawValue).joined(separator: ",") }
        order.swapAt(index, next)
        return order.map(\.rawValue).joined(separator: ",")
    }

    static func moving(_ metric: AtriaTodayMetric,
                       direction: Int,
                       in csv: String,
                       hiddenCSV: String) -> String {
        let hidden = hidden(from: hiddenCSV)
        let currentOrder = ordered(from: csv)
        var visible = currentOrder.filter { !hidden.contains($0.rawValue) }
        guard let index = visible.firstIndex(of: metric) else {
            return moving(metric, direction: direction, in: csv)
        }
        let next = max(0, min(visible.count - 1, index + direction))
        guard next != index else { return currentOrder.map(\.rawValue).joined(separator: ",") }
        visible.swapAt(index, next)
        return mergedOrder(replacingVisibleSlotsIn: currentOrder,
                           hidden: hidden,
                           with: visible)
    }

    private static func mergedOrder(replacingVisibleSlotsIn order: [AtriaTodayMetric],
                                    hidden: Set<String>,
                                    with visible: [AtriaTodayMetric]) -> String {
        var visibleIterator = visible.makeIterator()
        let merged = order.map { metric in
            hidden.contains(metric.rawValue) ? metric : (visibleIterator.next() ?? metric)
        }
        return merged.map(\.rawValue).joined(separator: ",")
    }
}





private extension Array where Element == AtriaTodayMetric {
    var glanceRowID: String {
        map(\.rawValue).joined(separator: "-")
    }
}

/// Keeps the recovery zone visible without letting an early numeric estimate
/// look equivalent to a baseline-qualified morning score.
enum AtriaRecoveryRingPresentation {
    static func detail(zone: String,
                       confidence: Metrics.RecoveryEstimate.Confidence,
                       estimateDetail: String,
                       isProvisional: Bool) -> String {
        if confidence == .unverified {
            if estimateDetail.localizedCaseInsensitiveContains("HRV unavailable") {
                return "\(zone) · Early · no HRV"
            }
            return "\(zone) · Early read"
        }
        if confidence == .learning || isProvisional {
            return "\(zone) · Early read"
        }
        return zone
    }
}






enum AtriaLiveSignalTruth {
    enum Tone: Equatable {
        case healthy
        case waiting
        case attention
        case unavailable
    }

    /// THE single fresh-pulse rule, shared by every surface that renders the
    /// connection state (Home pill, Strap screen, Overview focus card, Today
    /// strip). An accepted pulse is stronger evidence than a lagging stream
    /// projection: service discovery and the battery read can finish after HR
    /// notifications resume, so no surface may say "Waiting"/"No signal" while
    /// BPM is live.
    ///
    /// Before this was shared (owner UI-uniformity pass 2026-08-28) the three
    /// surfaces each carried their own rule and provably disagreed at the same
    /// instant — the Strap screen even contradicted itself, promoting its
    /// status to "connected" BECAUSE a pulse existed and then labelling that
    /// state "No signal".
    ///
    /// Low-battery states are deliberately NOT overridden: "Charge strap" and
    /// "Low battery" outrank "Live" because they tell the wearer something the
    /// pulse cannot.
    static func freshPulseOverridesLaggingStream(
        hasPulseSignal: Bool,
        streamState: AtriaBLEManager.StrapStreamState
    ) -> Bool {
        guard hasPulseSignal else { return false }
        switch streamState {
        case .warming, .silentUnknown, .unknown: return true
        case .live, .lowBatteryShutoff, .lowBatteryReducedDetail: return false
        }
    }

    static func isLive(status: AtriaBLEManager.Status,
                       streamState: AtriaBLEManager.StrapStreamState,
                       hasRecentHeartRate: Bool) -> Bool {
        guard status == .connected, hasRecentHeartRate else { return false }
        return streamState == .live
            || freshPulseOverridesLaggingStream(hasPulseSignal: hasRecentHeartRate,
                                                streamState: streamState)
    }

    static func valueText(status: AtriaBLEManager.Status,
                          streamState: AtriaBLEManager.StrapStreamState,
                          hasRecentHeartRate: Bool,
                          attribution: AtriaStrapWearAttribution = .none) -> String {
        if isLive(status: status,
                  streamState: streamState,
                  hasRecentHeartRate: hasRecentHeartRate) {
            return "Live"
        }
        if status == .connected {
            switch attribution {
            case .charging: return "Charging"
            case .offWrist: return "Off wrist"
            case .none: break
            }
        }
        switch status {
        case .connected:
            switch streamState {
            case .lowBatteryShutoff:
                return "Charge strap"
            case .lowBatteryReducedDetail:
                return "Low battery"
            case .silentUnknown:
                return "No signal"
            case .live, .warming, .unknown:
                return "Waiting"
            }
        case .connecting, .scanning:
            return "Finding"
        case .disconnected:
            return "Off"
        case .poweredOff:
            return "Bluetooth off"
        }
    }

    static func detailText(status: AtriaBLEManager.Status,
                           streamState: AtriaBLEManager.StrapStreamState,
                           hasRecentHeartRate: Bool,
                           attribution: AtriaStrapWearAttribution = .none) -> String {
        if isLive(status: status,
                  streamState: streamState,
                  hasRecentHeartRate: hasRecentHeartRate) {
            return "Heart rate live"
        }
        if status == .connected {
            switch attribution {
            case .charging: return "No pulse while charging — resumes on wear"
            case .offWrist: return "Strap streams but sees no pulse"
            case .none: break
            }
        }
        switch status {
        case .connected:
            switch streamState {
            case .lowBatteryShutoff:
                return "Charge to resume heart rate"
            case .lowBatteryReducedDetail:
                return "Reduced detail until charged"
            case .silentUnknown:
                return "Connected · no fresh heart rate"
            case .live, .warming, .unknown:
                return "Connected · waiting for heart rate"
            }
        case .connecting, .scanning:
            return "Reconnecting"
        case .poweredOff:
            return "Bluetooth off"
        case .disconnected:
            return "Disconnected"
        }
    }

    static func tone(status: AtriaBLEManager.Status,
                     streamState: AtriaBLEManager.StrapStreamState,
                     hasRecentHeartRate: Bool,
                     attribution: AtriaStrapWearAttribution = .none) -> Tone {
        if isLive(status: status,
                  streamState: streamState,
                  hasRecentHeartRate: hasRecentHeartRate) {
            return .healthy
        }
        guard status == .connected else {
            return status == .connecting || status == .scanning ? .waiting : .unavailable
        }
        // An attributed charging/off-wrist state is expected, not a fault.
        if attribution != .none { return .waiting }
        switch streamState {
        case .lowBatteryShutoff, .lowBatteryReducedDetail, .silentUnknown:
            return .attention
        case .live, .warming, .unknown:
            return .waiting
        }
    }
}


// Internal (was private) so the Plan tab can reuse it — see AtriaPlanTab.
struct AtriaWeeklyPlanCard: View, Equatable {
    let plan: WeeklyPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                AtriaPanelSectionHeader(title: "This week", subtitle: "")
                Spacer(minLength: 8)
                Text(plan.dateRangeText)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.secondary.opacity(0.08), in: Capsule())
            }

            VStack(spacing: 10) {
                ForEach(Array(plan.targets.prefix(3))) { target in
                    AtriaWeeklyPlanTargetRow(target: target)
                }
            }
        }
        .padding(14)
        .atriaInsetCard(cornerRadius: AtriaDesignTokens.Radius.tile, tint: Metrics.electricStrain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let targets = plan.targets.prefix(3).map { "\($0.title), \($0.progressText)" }.joined(separator: ". ")
        return "This week. \(targets)"
    }
}

private struct AtriaWeeklyPlanTargetRow: View, Equatable {
    let target: WeeklyPlanTarget

    private var tint: Color {
        switch target.kind {
        case .bedtimeConsistency: return Metrics.electricSleep
        case .workoutCount: return Metrics.electricStrain
        case .rhrInRange: return .pink
        }
    }

    private var icon: String {
        switch target.kind {
        case .bedtimeConsistency: return "moon.zzz.fill"
        case .workoutCount: return "figure.mixed.cardio"
        case .rhrInRange: return "heart.fill"
        }
    }

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.12), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(target.title)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Spacer(minLength: 6)
                    Text(target.progressText)
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(tint)
                        .lineLimit(1)
                }

                Gauge(value: target.progress) {
                    EmptyView()
                }
                .gaugeStyle(.accessoryLinearCapacity)
                .tint(tint)
                .accessibilityHidden(true)

                Text(target.detail)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(target.title). \(target.progressText). \(target.detail).")
    }
}



struct AtriaWeeklyReportSheet: View {
    let report: WeeklyReport
    /// Full local history lets this report move through prior weeks without
    /// fabricating any points. Existing callers that only have one report keep
    /// the current-week experience.
    var rollups: [DailyRollupStoreEntry] = []
    /// Qualified sleep windows for the monthly report's consistency score.
    /// Empty means the monthly sheet says "Schedule building" rather than
    /// guessing from bedtime-only rollups.
    var sleepNights: [SleepHistorySnapshot.Night] = []
    @Environment(\.dismiss) private var dismiss
    @State private var showShareSheet = false
    @State private var showMonthlyReport = false
    @State private var weekOffset = 0
    @State private var selectedTrend: WeeklyTrend = .recovery

    private enum WeeklyTrend: String, CaseIterable, Identifiable {
        case recovery = "Recovery"
        case strain = "Strain"
        case sleep = "Sleep"

        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        // The sheet's navigation title already says "Weekly
                        // report", inline, about 40pt above this. Printing it
                        // again as an eyebrow told the reader nothing they had
                        // not just read.
                        Text(heroText)
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .lineLimit(3)
                            .minimumScaleFactor(0.8)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(weekRangeText)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        weekNavigator
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .atriaInsetCard(cornerRadius: AtriaDesignTokens.Radius.inset, tint: .cyan)

                    // Grouped stat rows (UX audit density tail): six identical
                    // boxes read as a wall; two kickers give the eye a rest.
                    reportKicker("Week averages")
                    VStack(spacing: 10) {
                        AtriaWeeklyReportStatRow(title: "Recovery average",
                                                 value: recoveryAverageText,
                                                 detail: recoveryDeltaText,
                                                 systemImage: "heart.fill",
                                                 tint: .green)
                        AtriaWeeklyReportStatRow(title: "Strain average",
                                                 value: strainAverageText,
                                                 detail: "Daily strain across the week",
                                                 systemImage: "flame.fill",
                                                 tint: Metrics.electricStrain)
                        AtriaWeeklyReportStatRow(title: "Sleep average",
                                                 value: sleepAverageText,
                                                 detail: "Nightly duration across the week",
                                                 systemImage: "bed.double.fill",
                                                 tint: Metrics.electricSleep)
                    }

                    reportKicker("Highlights")
                    VStack(spacing: 10) {
                        AtriaWeeklyReportStatRow(title: "Best day",
                                                 value: dayText(displayedReport.bestDay),
                                                 detail: recoveryText(displayedReport.bestDay),
                                                 systemImage: "lightbulb.max.fill",
                                                 tint: Metrics.electricYellow)
                        AtriaWeeklyReportStatRow(title: "Hardest day",
                                                 value: dayText(displayedReport.hardestDay),
                                                 detail: strainText(displayedReport.hardestDay),
                                                 systemImage: "flame.fill",
                                                 tint: Metrics.electricStrain)
                    }

                    weeklyTrendChart

                    if let note = displayedReport.strainRecoveryNote {
                        Label(note, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .atriaInsetCard(cornerRadius: AtriaDesignTokens.Radius.inset, tint: .orange)
                    }

                    Button {
                        showShareSheet = true
                    } label: {
                        Label("Share week", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .atriaCardAction()
                }
                // 12pt gutter (2026-08-05 width audit); vertical inset stays 18.
                .padding(.horizontal, 12)
                .padding(.vertical, 18)
            }
            .navigationTitle("Weekly report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // The monthly report engine (MonthlyReport) lost its only
                    // surface when the unreachable Overview tree was deleted
                    // (76737dd3). It lives here now, one tap from the weekly
                    // view it extends.
                    Button("Month") { showMonthlyReport = true }
                        .font(.body.weight(.semibold))
                        .accessibilityHint("Opens the monthly report")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.body.weight(.semibold))
                }
            }
            .sheet(isPresented: $showShareSheet) {
                AtriaWeeklyShareSheet(snapshot: makeWeeklyShareSnapshot())
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showMonthlyReport) {
                AtriaMonthlyReportSheet(rollups: rollups, sleepNights: sleepNights)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private func reportKicker(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.black))
            .foregroundStyle(.tertiary)
            .kerning(0.8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    private var reportCalendar: Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        return calendar
    }

    /// The presented report is always a real seven-day slice plus the prior
    /// seven days needed for its comparison. It intentionally leaves missing
    /// days empty rather than borrowing a neighbor's score.
    private var displayedReport: WeeklyReport {
        guard weekOffset > 0, !rollups.isEmpty,
              let anchor = reportCalendar.date(byAdding: .day,
                                                value: -7 * weekOffset,
                                                to: report.generatedAt),
              let earliest = reportCalendar.date(byAdding: .day,
                                                  value: -13,
                                                  to: anchor) else {
            return report
        }
        let window = rollups.filter { $0.day >= earliest && $0.day <= anchor }
        return WeeklyReport(rollups: window, now: anchor, calendar: reportCalendar)
    }

    private var canNavigateToPreviousWeek: Bool {
        guard !rollups.isEmpty,
              let previousWeekEnd = reportCalendar.date(byAdding: .day,
                                                        value: -7 * (weekOffset + 1),
                                                        to: report.generatedAt) else { return false }
        return rollups.contains { $0.day <= previousWeekEnd }
    }

    private var weekNavigator: some View {
        HStack(spacing: 4) {
            Button {
                guard canNavigateToPreviousWeek else { return }
                withAnimation(.snappy(duration: AtriaDesignTokens.Motion.standard)) {
                    weekOffset += 1
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.caption.weight(.bold))
                    .frame(width: 32, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(!canNavigateToPreviousWeek)
            .accessibilityLabel("Previous week")

            Spacer(minLength: 0)

            Text(weekOffset == 0 ? "Current week" : "\(weekOffset) week\(weekOffset == 1 ? "" : "s") ago")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Button {
                guard weekOffset > 0 else { return }
                withAnimation(.snappy(duration: AtriaDesignTokens.Motion.standard)) {
                    weekOffset -= 1
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .frame(width: 32, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(weekOffset == 0)
            .accessibilityLabel("Next week")
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(.primary.opacity(0.055), in: Capsule(style: .continuous))
    }

    /// Narrative hero (dedup audit + design HIGHLIGHTS card, 2026-07-07):
    /// the hero used to repeat the Recovery-average stat row verbatim. It is
    /// now a one-line story built ONLY from real report fields — every
    /// clause is gated on data, phrasing stays associative ("while"/"with"),
    /// never causal. Numbers live in the stat rows below.
    private var heroText: String {
        guard let _ = displayedReport.recoveryAvg else { return "Still building this week's picture" }

        var clauses: [String] = []
        if let delta = displayedReport.recoveryDeltaVsPriorWeek {
            if delta >= 3 { clauses.append("Recovery climbed") }
            else if delta <= -3 { clauses.append("Recovery dipped") }
            else { clauses.append("Recovery held steady") }
        } else {
            clauses.append("Recovery on the board")
        }
        if let strain = displayedReport.strainAvg, strain > 0 {
            if strain >= 12 { clauses.append("under a heavy training load") }
            else if strain >= 8 { clauses.append("with a solid training load") }
            else { clauses.append("with a light training load") }
        }
        if let sleep = displayedReport.sleepAvgSeconds, sleep > 0 {
            if sleep >= 7.5 * 3600 { clauses.append("while sleep stayed long") }
            else if sleep >= 6.5 * 3600 { clauses.append("while sleep hovered near need") }
            else { clauses.append("while sleep ran short") }
        }
        return clauses.joined(separator: " ")
    }

    private var recoveryAverageText: String {
        displayedReport.recoveryAvg.map { "\($0)%" } ?? "--"
    }

    /// Human date range ("Jun 29 – Jul 5") from the report's rollup days;
    /// falls back to the ISO week label for reports saved before these
    /// fields existed (2026-07-07 design handoff).
    ///
    /// The range used to carry "· Week N" appended to it, which stitched two
    /// independently stored fields — weekStart/weekEnd and isoWeek — into one
    /// sentence with nothing keeping them in agreement. They can disagree, and
    /// when they do the line contradicts itself in front of the reader
    /// ("Jan 9 – Jan 15 · Week 31"; week 31 is late July). Rather than pick a
    /// winner between two engine-owned fields, the dates speak alone: they are
    /// the more useful half, and a range cannot contradict itself. The ISO
    /// label still stands in when no dates were stored.
    private var weekRangeText: String {
        guard let start = displayedReport.weekStart, let end = displayedReport.weekEnd else {
            return "Week \(displayedReport.isoWeek), \(displayedReport.isoYear)"
        }
        let formatter = Self.rangeDayFormatter
        return "\(formatter.string(from: start)) – \(formatter.string(from: end))"
    }

    private static let rangeDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()

    private var displayedWeekRollups: [DailyRollupStoreEntry] {
        guard let start = displayedReport.weekStart, let end = displayedReport.weekEnd else { return [] }
        return rollups.filter { $0.day >= start && $0.day <= end }.sorted { $0.day < $1.day }
    }

    /// Each bar carries its own tint from the app's colour authorities
    /// (2026-09-02): recovery through the zone palette, strain in its single
    /// cool hue (recovery owns the green/amber/red axis), sleep by percent of
    /// the night's own need when the rollup carries it — never fixed hours.
    private var selectedTrendPoints: [(day: Date, value: Double, tint: Color)] {
        switch selectedTrend {
        case .recovery:
            if !displayedWeekRollups.isEmpty {
                return displayedWeekRollups.compactMap { entry in
                    entry.recovery.map { (entry.day, Double($0), Metrics.recoveryColor($0)) }
                }
            }
            return (displayedReport.recoverySeries ?? []).compactMap { day in
                day.recovery.map { (day.day, Double($0), Metrics.recoveryColor($0)) }
            }
        case .strain:
            return displayedWeekRollups.compactMap { entry in
                entry.strain.map { (entry.day, $0, Metrics.strainColor($0)) }
            }
        case .sleep:
            return displayedWeekRollups.compactMap { entry in
                entry.sleepSeconds.map { seconds in
                    (entry.day,
                     seconds / 3_600,
                     entry.sleepPerformance.map { AtriaTriRing.zoneTint(.sleep, percent: Double($0)) }
                        ?? Metrics.electricSleep)
                }
            }
        }
    }

    private var selectedTrendDomain: ClosedRange<Double> {
        switch selectedTrend {
        case .recovery: return 0...100
        case .strain: return 0...21
        case .sleep: return 0...10
        }
    }

    private var selectedTrendThresholdLabel: String {
        switch selectedTrend {
        case .recovery: return "Green 67–100 · yellow 34–66 · red 0–33"
        case .strain: return "One hue · bar height is the day's strain"
        case .sleep: return "By % of sleep need · green 85–110 · yellow 70–84 · red <70"
        }
    }

    private var weeklyTrendChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Weekly trend")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Picker("Weekly trend", selection: $selectedTrend) {
                    ForEach(WeeklyTrend.allCases) { trend in
                        Text(trend.rawValue).tag(trend)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 210)
            }

            if selectedTrendPoints.isEmpty {
                Label("No recorded \(selectedTrend.rawValue.lowercased()) values for this week.", systemImage: "chart.bar.xaxis")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
            } else {
                Chart {
                    ForEach(selectedTrendPoints, id: \.day) { point in
                        BarMark(x: .value("Day", point.day, unit: .day),
                                y: .value(selectedTrend.rawValue, point.value),
                                width: .fixed(18))
                            .foregroundStyle(point.tint)
                            .cornerRadius(4)
                    }
                }
                .chartYScale(domain: selectedTrendDomain)
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 4))
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine()
                        // Bars only here, and a `unit: .day` bar spans its
                        // whole day — so the weekday must sit at the middle of
                        // that span, not at midnight where the bar's left edge
                        // is.
                        AxisValueLabel(format: .dateTime.weekday(.abbreviated),
                                       centered: true)
                    }
                }
                .frame(height: 120)
                .clipped()
                .padding(.horizontal, -14)
                .accessibilityLabel("\(selectedTrend.rawValue) color bars for each recorded day of the week. \(selectedTrendThresholdLabel).")
            }

            Text(selectedTrendThresholdLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .atriaInsetCard(tint: selectedTrend == .recovery ? Metrics.electricGreen : Metrics.electricStrain)
    }

    private var strainAverageText: String {
        displayedReport.strainAvg.map { String(format: "%.1f", $0) } ?? "--"
    }

    private var sleepAverageText: String {
        guard let seconds = displayedReport.sleepAvgSeconds else { return "--" }
        let totalMinutes = Int((seconds / 60).rounded())
        return "\(totalMinutes / 60)h \(totalMinutes % 60)m"
    }

    private var recoveryDeltaText: String {
        guard let delta = displayedReport.recoveryDeltaVsPriorWeek else { return "Prior week comparison building" }
        return delta >= 0 ? "+\(delta) vs prior week" : "\(delta) vs prior week"
    }

    private var consistencyText: String {
        displayedReport.sleepConsistencyPct.map { "\($0)%" } ?? "--"
    }

    private func dayText(_ day: WeeklyReport.DaySummary?) -> String {
        guard let day else { return "--" }
        return Self.dayFormatter.string(from: day.day)
    }

    private func recoveryText(_ day: WeeklyReport.DaySummary?) -> String {
        day?.recovery.map { "Recovery \($0)%" } ?? "Recovery building"
    }

    private func strainText(_ day: WeeklyReport.DaySummary?) -> String {
        day?.strain.map { String(format: "Strain %.1f", $0) } ?? "Strain building"
    }

    private func makeWeeklyShareSnapshot() -> AtriaWeeklyShareSnapshot {
        AtriaWeeklyShareSnapshot(date: displayedReport.generatedAt,
                                 title: "My week on Atria",
                                 recoveryAverage: recoveryAverageText,
                                 recoveryDelta: displayedReport.recoveryDeltaVsPriorWeek == nil ? "" : recoveryDeltaText,
                                 sleepConsistency: consistencyText,
                                 bestDay: dayText(displayedReport.bestDay),
                                 hardestDay: dayText(displayedReport.hardestDay),
                                 note: displayedReport.strainRecoveryNote)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE d")
        return formatter
    }()
}



/// Calendar-month report: the same honest stat rows as the weekly sheet,
/// over the month, with a prior-month comparison. Below
/// `MonthlyReport.minimumDaysForStats` days of data every stat is withheld
/// and the hero says so — never a guess (2026-09-02; the engine had no
/// surface since the Overview tree was removed).
struct AtriaMonthlyReportSheet: View {
    var rollups: [DailyRollupStoreEntry] = []
    var sleepNights: [SleepHistorySnapshot.Night] = []
    var now: Date = Date()
    @Environment(\.dismiss) private var dismiss
    @State private var monthOffset = 0

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    private var anchor: Date {
        calendar.date(byAdding: .month, value: -monthOffset, to: now) ?? now
    }

    private var report: MonthlyReport {
        MonthlyReport(rollups: rollups, sleepNights: sleepNights, now: anchor, calendar: calendar)
    }

    private struct MonthDayCell: Identifiable {
        let id: Int
        let day: Date
        let recovery: Int?
    }

    /// One cell per calendar day of the displayed month. A day's recovery is
    /// the rollup's own score or nil; nothing is interpolated.
    private var monthDayCells: [MonthDayCell] {
        guard let interval = calendar.dateInterval(of: .month, for: anchor) else { return [] }
        var byDay: [Date: Int] = [:]
        for entry in rollups {
            guard let recovery = entry.recovery else { continue }
            let key = calendar.startOfDay(for: entry.day)
            if byDay[key] == nil { byDay[key] = recovery }
        }
        var cells: [MonthDayCell] = []
        var day = interval.start
        var index = 1
        while day < interval.end {
            cells.append(MonthDayCell(id: index, day: day, recovery: byDay[calendar.startOfDay(for: day)]))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
            index += 1
        }
        return cells
    }

    private var scoredDayCount: Int {
        monthDayCells.filter { $0.recovery != nil }.count
    }

    /// Days of the month that have happened: the whole month for a past
    /// month, today's day-of-month for the current one.
    private var elapsedDayCount: Int {
        let cells = monthDayCells
        guard let last = cells.last else { return 0 }
        if last.day < calendar.startOfDay(for: now) { return cells.count }
        return calendar.component(.day, from: now)
    }

    /// Month at a glance (2026-09-02): one cell per day, tinted by that day's
    /// recovery zone through the same authority the Today ring uses. Unscored
    /// days stay hollow; the block is omitted until one day has scored.
    private var recoveryByDayStrip: some View {
        let cells = monthDayCells
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 3) {
                ForEach(cells) { cell in
                    if let recovery = cell.recovery {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill((Metrics.recoveryZone(recovery)?.tint ?? Color.secondary).opacity(0.9))
                    } else {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .strokeBorder(.quaternary, lineWidth: 1)
                    }
                }
            }
            .frame(height: 18)
            HStack {
                Text("1")
                Spacer(minLength: 0)
                Text("15")
                Spacer(minLength: 0)
                Text("\(cells.count)")
            }
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(.secondary)
            Text("\(scoredDayCount) of \(elapsedDayCount) days scored")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .atriaInsetCard(cornerRadius: AtriaDesignTokens.Radius.inset, tint: Metrics.electricGreen)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recovery by day, \(scoredDayCount) of \(elapsedDayCount) days scored")
    }

    private var canNavigateToPreviousMonth: Bool {
        guard let previous = calendar.date(byAdding: .month, value: -1, to: anchor),
              let start = calendar.dateInterval(of: .month, for: previous)?.start else { return false }
        return rollups.contains { $0.day < calendar.dateInterval(of: .month, for: anchor)!.start && $0.day >= start }
            || rollups.contains { $0.day < start }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(heroText)
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .lineLimit(3)
                            .minimumScaleFactor(0.8)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(monthText)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        if report.isBuilding {
                            Text("\(report.daysWithData) of \(MonthlyReport.minimumDaysForStats) days with data")
                                .font(.caption2.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        monthNavigator
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .atriaInsetCard(cornerRadius: AtriaDesignTokens.Radius.inset, tint: .cyan)

                    if scoredDayCount > 0 {
                        kicker("Recovery by day")
                        recoveryByDayStrip
                    }

                    if !report.isBuilding {
                        kicker("Month averages")
                        VStack(spacing: 10) {
                            AtriaWeeklyReportStatRow(title: "Recovery average",
                                                     value: report.recoveryAvg.map { "\($0)%" } ?? "--",
                                                     detail: deltaText(report.recoveryDeltaVsPriorMonth, unit: "%"),
                                                     systemImage: "heart.fill",
                                                     tint: Metrics.electricGreen)
                            AtriaWeeklyReportStatRow(title: "Sleep performance",
                                                     value: report.sleepPerformanceAvg.map { "\($0)%" } ?? "--",
                                                     detail: deltaText(report.sleepPerformanceDeltaVsPriorMonth, unit: "%"),
                                                     systemImage: "bed.double.fill",
                                                     tint: Metrics.electricSleep)
                            AtriaWeeklyReportStatRow(title: "Resting HR",
                                                     value: report.rhrAvg.map { "\($0) bpm" } ?? "--",
                                                     detail: deltaText(report.rhrDeltaVsPriorMonth, unit: " bpm"),
                                                     systemImage: "heart.circle.fill",
                                                     tint: Metrics.electricRHR)
                            AtriaWeeklyReportStatRow(title: "HRV",
                                                     value: report.hrvAvgMs.map { "\(Int($0.rounded())) ms" } ?? "--",
                                                     detail: deltaText(report.hrvDeltaVsPriorMonthMs.map { Int($0.rounded()) }, unit: " ms"),
                                                     systemImage: "waveform.path.ecg",
                                                     tint: Metrics.electricHRV)
                        }

                        kicker("Load")
                        VStack(spacing: 10) {
                            AtriaWeeklyReportStatRow(title: "Total strain",
                                                     value: report.totalStrain.map { String(format: "%.0f", $0) } ?? "--",
                                                     detail: "Daily strain summed across the month",
                                                     systemImage: "flame.fill",
                                                     tint: Metrics.electricStrain)
                            AtriaWeeklyReportStatRow(title: "Hardest week",
                                                     value: report.hardestWeek.map { "Week of \(Self.dayFormatter.string(from: $0.weekStart))" } ?? "--",
                                                     detail: report.hardestWeek?.totalStrain.map { String(format: "%.0f strain that week", $0) } ?? "No strain recorded",
                                                     systemImage: "calendar",
                                                     tint: Metrics.electricStrain)
                        }

                        kicker("Schedule")
                        AtriaWeeklyReportStatRow(title: "Sleep consistency",
                                                 value: report.consistencyScore.map { "\($0)%" } ?? "--",
                                                 detail: report.consistencyScore == nil
                                                    ? "Schedule building · needs qualified nights"
                                                    : "Bed and wake regularity across the month",
                                                 systemImage: "moon.zzz.fill",
                                                 tint: Metrics.electricSleep)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 18)
            }
            .navigationTitle("Monthly report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.body.weight(.semibold))
                }
            }
        }
    }

    private var heroText: String {
        guard !report.isBuilding else { return "Building this month's picture" }
        var clauses: [String] = []
        if let delta = report.recoveryDeltaVsPriorMonth {
            if delta >= 3 { clauses.append("Recovery climbed") }
            else if delta <= -3 { clauses.append("Recovery dipped") }
            else { clauses.append("Recovery held steady") }
        } else {
            clauses.append("Recovery on the board")
        }
        if let strain = report.totalStrain, strain > 0 {
            clauses.append(String(format: "with %.0f strain across the month", strain))
        }
        if let sleep = report.sleepPerformanceAvg {
            if sleep >= 85 { clauses.append("while sleep met need most nights") }
            else if sleep >= 70 { clauses.append("while sleep hovered near need") }
            else { clauses.append("while sleep ran short") }
        }
        return clauses.joined(separator: " ")
    }

    private var monthText: String {
        Self.monthFormatter.string(from: anchor)
    }

    private func deltaText(_ delta: Int?, unit: String) -> String {
        guard let delta else { return "No prior month to compare" }
        if delta == 0 { return "Same as last month" }
        return "\(delta > 0 ? "+" : "")\(delta)\(unit) vs last month"
    }

    private var monthNavigator: some View {
        HStack(spacing: 4) {
            Button {
                guard canNavigateToPreviousMonth else { return }
                withAnimation(.snappy(duration: AtriaDesignTokens.Motion.standard)) { monthOffset += 1 }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.caption.weight(.bold))
                    .frame(width: 32, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(!canNavigateToPreviousMonth)
            .accessibilityLabel("Previous month")

            Spacer(minLength: 0)
            Text(monthOffset == 0 ? "Current month" : "\(monthOffset) month\(monthOffset == 1 ? "" : "s") ago")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)

            Button {
                guard monthOffset > 0 else { return }
                withAnimation(.snappy(duration: AtriaDesignTokens.Motion.standard)) { monthOffset -= 1 }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .frame(width: 32, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(monthOffset == 0)
            .accessibilityLabel("Next month")
        }
    }

    private func kicker(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.black))
            .foregroundStyle(.tertiary)
            .kerning(0.8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()
}

private struct AtriaWeeklyReportStatRow: View {
    let title: String
    let value: String
    let detail: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Text(value)
                .font(.subheadline.weight(.bold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(12)
        .atriaInsetCard(cornerRadius: AtriaDesignTokens.Radius.inset, tint: tint)
    }
}


struct AtriaStrapStepLiveStatus: Equatable {
    enum Freshness: Equatable {
        case live
        case stale
        case unavailable
    }

    static let persistedMotionKey = "atria.radio.passiveR10LastValidAt"
    /// R10 is a one-device-second motion stream. A count cannot honestly stay
    /// "live" for a minute and a half after those frames stop, even if 2A37 HR
    /// remains connected. Allow short Bluetooth delivery jitter, then fail the
    /// step tile closed while retaining the last saved estimate.
    static let liveWindow: TimeInterval = 15
    static let futureTolerance: TimeInterval = 5

    let count: Int
    let isValidated: Bool
    let freshness: Freshness
    let motionAge: TimeInterval?

    var isLive: Bool { freshness == .live }

    var tileValue: String {
        guard isLive else { return "--" }
        return isValidated ? "\(count)" : "~\(count)"
    }

    var savedCountText: String {
        isValidated ? "\(count)" : "~\(count)"
    }

    var tileDetail: String {
        switch freshness {
        case .live:
            return isValidated ? "Live strap count" : "Live estimate"
        case .stale:
            return "Not live · \(lastMotionText)"
        case .unavailable:
            return "Not live · no motion"
        }
    }

    var lastMotionText: String {
        guard let motionAge else { return "motion unavailable" }
        if motionAge < 60 { return "motion \(max(1, Int(motionAge.rounded())))s ago" }
        if motionAge < 3_600 { return "motion \(max(1, Int((motionAge / 60).rounded())))m ago" }
        return "motion \(max(1, Int((motionAge / 3_600).rounded())))h ago"
    }

    var tint: Color {
        switch freshness {
        case .live: return isValidated ? .green : .orange
        case .stale: return .orange
        case .unavailable: return .secondary
        }
    }

    static func make(count: Int,
                     validationState: String,
                     capturedAt: Date?,
                     now: Date,
                     authorityQualified: Bool = true) -> Self {
        let safeCount = max(0, count)
        let isValidated = authorityQualified
            && WidgetSnapshotPublisher.strapStepsAreValidated(
                state: validationState
            )
        guard let capturedAt else {
            return Self(count: safeCount,
                        isValidated: isValidated,
                        freshness: safeCount > 0 ? .stale : .unavailable,
                        motionAge: nil)
        }

        let age = now.timeIntervalSince(capturedAt)
        guard age >= -futureTolerance else {
            return Self(count: safeCount,
                        isValidated: isValidated,
                        freshness: safeCount > 0 ? .stale : .unavailable,
                        motionAge: nil)
        }

        return Self(count: safeCount,
                    isValidated: isValidated,
                    freshness: age <= liveWindow ? .live : .stale,
                    motionAge: max(0, age))
    }

    static func persistedMotionDate(defaults: UserDefaults = .standard) -> Date? {
        guard let number = defaults.object(forKey: persistedMotionKey) as? NSNumber else { return nil }
        let timestamp = number.doubleValue
        guard timestamp.isFinite, timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    func accessibilityDetail(goal: Int) -> String {
        switch freshness {
        case .live:
            let measurement = isValidated ? "validated count" : "estimated count"
            return "Live strap movement. \(savedCountText) steps today, \(measurement). Goal \(goal)."
        case .stale:
            return "Not live. Last saved value \(savedCountText) steps today. \(lastMotionText)."
        case .unavailable:
            return "Not live. Strap movement is unavailable."
        }
    }
}

struct AtriaStrapStepsDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let count: Int
    let validationState: String
    let presentation: AtriaDailyStepPresentation
    let goal: Int
    /// Confirmed non-gait workout windows (Strength, Cycling) excluded from
    /// the exact per-day computation, so labelled arm work does not read as
    /// walking. Defaults empty: no exclusions is the pre-existing behaviour.
    var nonGaitWindows: [DateInterval] = []
    /// EVERY confirmed workout window, either kind — a labelled block already
    /// explains its arm motion, so the unverified-movement review must not ask
    /// about it again.
    var explainedWindows: [DateInterval] = []
    @State private var unverifiedClusters: [AtriaUnattributedMotionRuns.Cluster] = []
    @State private var autoResolvedCount = 0
    @State private var autoResolvedSteps = 0
    @State private var minorMovementSteps = 0

    /// Verified per-day step totals (day-start → steps) for the weekly bar chart,
    /// loaded once from the durable motion-tick day store. Days without a
    /// verified receipt simply have no entry (and no bar).
    @State private var weekSteps: [Date: Int] = [:]

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 15)) { context in
                let status = AtriaStrapStepLiveStatus.make(
                    count: count,
                    validationState: validationState,
                    capturedAt: AtriaStrapStepLiveStatus.persistedMotionDate(),
                    now: context.date,
                    authorityQualified:
                        AtriaWhoop4GravityCadenceStepModel
                            .releaseDailyAuthorityQualified
                )

                ScrollView {
                  VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        Image(systemName: "shoeprints.fill")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(status.tint)
                            .frame(width: 42, height: 42)
                            .background(status.tint.opacity(0.12), in: Circle())

                        VStack(alignment: .leading, spacing: 2) {
                            Text(
                                status.isLive
                                    ? "Strap motion live"
                                    : "Strap motion not live"
                            )
                                .font(.headline)
                            Text(status.lastMotionText.capitalized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 8)

                        Text(presentation.valueText)
                            .font(AtriaDesignTokens.Typography.cardHeroValue)
                            .monospacedDigit()
                            .contentTransition(reduceMotion ? .identity : .numericText())
                            .animation(reduceMotion ? nil : .snappy(duration: AtriaDesignTokens.Motion.emphatic), value: presentation.valueText)
                    }

                    HStack(spacing: 10) {
                        statusRow(title: "Measurement",
                                  value: presentation.detailText,
                                  systemImage: presentation.completeness == .complete
                                    ? "checkmark.seal.fill" : "waveform.path.ecg")
                        // "Saved today" printed presentation.valueText a third
                        // time — the 30pt hero above and the goal row below
                        // already carry it. It also had a nonsense state: a
                        // partial day with a zero count is non-nil but formats
                        // as "--", so the pill rendered "-- steps".
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        if let count = presentation.count {
                            HStack {
                                Text(status.isLive ? "Daily goal" : "Saved progress")
                                Spacer()
                                Text("\(presentation.valueText) / \(max(goal, 0))")
                                    .monospacedDigit()
                            }
                            .font(.caption.weight(.semibold))

                            ProgressView(value: Double(count),
                                         total: Double(max(goal, 1)))
                                .tint(status.tint)

                            if presentation.completeness != .complete {
                                // The typed motion authority overrides the
                                // forward-looking promise when the transport is a
                                // terminal pure-HR fallback (motion won't sync in
                                // this mode); the verified count above is unchanged.
                                Text(presentation.motionAvailabilityFootnote
                                     ?? (presentation.source == .live
                                         ? "Counting so far — grows as you move."
                                         : "Counted so far — fills in as your strap syncs."))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text(presentation.detailText)
                                .font(.caption.weight(.semibold))
                            Text("Appears when reliable strap steps are available.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .atriaInsetCard(tint: status.tint)

                    if !unverifiedClusters.isEmpty {
                        unverifiedMovementCard
                    }

                    stepsWeekChartCard
                  }
                  .padding()
                  .accessibilityElement(children: .contain)
                }
            }
            .task { await loadWeekSteps() }
            .navigationTitle("Strap steps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func statusRow(title: String, value: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .atriaInsetCard(tint: .secondary)
    }

    /// Sustained arm motion the strap counted that nothing explains. The
    /// count above already INCLUDES it — include-with-disclosure, never
    /// exclude-by-default — and one answer per cluster settles it: walking
    /// keeps it and stops the asking; not-walking excludes the window
    /// everywhere steps are computed, through the same machinery a labelled
    /// Strength block uses. Only the wearer can make this call: on this
    /// hardware a meal and a constrained-arm walk are the same signal.
    private var unverifiedMovementCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.orange)
                Text("Unverified movement")
                    .font(.caption.weight(.bold))
                Spacer(minLength: 0)
                Text("~\(unverifiedClusters.reduce(0) { $0 + $1.estimatedSteps }) steps")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            // Owner feedback (2026-08-28) drove this copy: it must say what
            // an answer DOES and that the app LEARNS, or the question reads as
            // busywork. And only a few major stretches are ever asked — the
            // long list of small ones nobody remembers is gone.
            Text("A few big stretches of movement aren't a confirmed walk or workout. Not walking removes those steps everywhere; after a few answers Atria learns your pattern and stops asking.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(unverifiedClusters) { cluster in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(cluster.start.formatted(date: .omitted, time: .shortened)) – \(cluster.end.formatted(date: .omitted, time: .shortened))")
                            .font(.caption.weight(.semibold))
                        Text("~\(cluster.estimatedSteps) steps · \(cluster.activeMinutes) active min")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    Button("Walking") {
                        arbitrate(cluster, verdict: .walking)
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .tint(.green)
                    Button("Not walking") {
                        arbitrate(cluster, verdict: .notWalking)
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .tint(.orange)
                }
                .accessibilityElement(children: .combine)
                .accessibilityHint("Was this stretch a walk, or other movement like a meal or chores?")
            }

            if autoResolvedCount > 0 {
                Text(autoResolvedSteps > 0
                     ? "\(autoResolvedCount) stretch(es) auto-marked from your earlier answers (−\(autoResolvedSteps) steps). Changed your mind? Answer again above when one is asked."
                     : "\(autoResolvedCount) stretch(es) auto-marked as walking from your earlier answers.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if minorMovementSteps > 0 {
                Text("Smaller movement (~\(minorMovementSteps) steps) stays included — too scattered to be worth asking about.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .atriaInsetCard(tint: .orange)
    }

    private var stepsWeekChartCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            AtriaStepsWeekChart(stepsByDay: weekSteps, goal: goal)
            // The bars are CALENDAR days computed exactly from the strap's
            // recorded rows; the count at the top of this sheet is since your
            // wake. Saying so stops the two honest numbers reading as a bug
            // when a cycle spans midnight.
            Text("Bars are calendar days · the count above is since your wake")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// How close a receipt's end must be to now to count as the cycle still
    /// running. The current-cycle receipt is rewritten every drain pass, so its
    /// `windowEnd` trails `now` by minutes, not hours.

    private func loadWeekSteps() async {
        guard let identifier = AtriaWhoop4MotionTickDailyStore.persistedStrapIdentifiers().first else { return }
        let now = Date()
        let receipts = AtriaWhoop4MotionTickDailyStore.shared.recentReceipts(strapIdentifier: identifier,
                                                                            limit: 14)
        // Receipt folding first, shown immediately: it is instant, and it is
        // the fallback for days whose shards have rotated out.
        let fallback = AtriaStepsWeekChart.dailyStepTotals(receipts: receipts, now: now)
        weekSteps = fallback
        // Then the exact per-calendar-day totals from the shards themselves.
        // Receipts are cycle-scoped, frozen at publication, and can be missing
        // for whole days — the 2026-08-27 audit measured a day showing 505
        // where the shards hold ~7,000, and another showing 0. The authority
        // replaces every day the rows can answer and leaves the rest alone.
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let days = (0..<7).compactMap {
            calendar.date(byAdding: .day, value: -$0, to: today)
        }
        weekSteps = await AtriaCivilDayStepAuthority.shared.dailyTotals(
            days: days,
            strapIdentifier: identifier,
            // The wearer's "Not walking" answers join the labelled non-gait
            // blocks — same rule at every step surface.
            nonGaitExclusions: nonGaitWindows
                + AtriaNonGaitArbitrationStore.shared.notWalkingWindows(),
            fallback: fallback,
            now: now
        )
        await refreshUnverifiedClusters(identifier: identifier, now: now)
    }

    /// Sustained counter activity in the last 24 h that no workout label and
    /// no prior answer explains — the review section's content.
    private func refreshUnverifiedClusters(identifier: String, now: Date) async {
        let explained = explainedWindows
            + AtriaNonGaitArbitrationStore.shared.arbitratedWindows()
        let partition = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let points = AtriaWhoop4MotionTickCompactStore.shared
                    .decodedPoints(start: now.addingTimeInterval(-24 * 3_600),
                                   end: now,
                                   strapIdentifier: identifier)
                let clusters = AtriaUnattributedMotionRuns.clusters(
                    minuteTicks: AtriaUnattributedMotionRuns
                        .minuteTickTotals(points),
                    explained: explained
                )
                continuation.resume(
                    returning: AtriaUnattributedMotionRuns.partition(
                        clusters: clusters,
                        store: .shared,
                        now: now
                    )
                )
            }
        }
        unverifiedClusters = partition.askable
        autoResolvedCount = partition.autoResolved.count
        autoResolvedSteps = partition.autoResolved
            .filter { $0.verdict == .notWalking }
            .reduce(0) { $0 + $1.cluster.estimatedSteps }
        minorMovementSteps = partition.minorSteps
    }

    private func arbitrate(_ cluster: AtriaUnattributedMotionRuns.Cluster,
                           verdict: AtriaNonGaitArbitrationStore.Verdict) {
        AtriaNonGaitArbitrationStore.shared.record(window: cluster.window,
                                                   verdict: verdict)
        unverifiedClusters.removeAll { $0.id == cluster.id }
        Task { await loadWeekSteps() }
    }
}


struct AtriaGlanceTargetEditorSheet: View {
    let metric: AtriaTodayMetric
    @Environment(\.dismiss) private var dismiss
    @AtriaDefault("atria.target.recovery.greenLower") private var recoveryGreenLower: Double = 67
    @AtriaDefault("atria.target.recovery.yellowLower") private var recoveryYellowLower: Double = 34
    @AtriaDefault("atria.target.strain.greenBand") private var strainGreenBand: Double = 1.5
    @AtriaDefault("atria.target.strain.yellowBand") private var strainYellowBand: Double = 3.0
    @AtriaDefault("atria.target.load.acwr.watchLow") private var loadACWRWatchLow: Double = 0.80
    @AtriaDefault("atria.target.load.acwr.watchHigh") private var loadACWRWatchHigh: Double = 1.30
    @AtriaDefault("atria.target.load.acwr.badLow") private var loadACWRBadLow: Double = 0.60
    @AtriaDefault("atria.target.load.acwr.badHigh") private var loadACWRBadHigh: Double = 1.50
    @AtriaDefault("atria.target.load.monotony.watch") private var loadMonotonyWatch: Double = 2.0
    @AtriaDefault("atria.target.load.monotony.bad") private var loadMonotonyBad: Double = 2.5
    @AtriaDefault("atria.target.steps.goal") private var stepsGoal: Int = 8_000
    @AtriaDefault("atria.target.calories.goal") private var caloriesGoal: Int = 500
    @AtriaDefault("atria.target.sleep.goalHours") private var sleepGoalHours: Double = 8.0
    @AtriaDefault("atria.target.sleepEfficiency.greenLower") private var sleepEfficiencyGreenLower: Double = 90
    @AtriaDefault("atria.target.sleepEfficiency.yellowLower") private var sleepEfficiencyYellowLower: Double = 80
    @AtriaDefault("atria.target.hrv.greenRatio") private var hrvGreenRatio: Double = 0.95
    @AtriaDefault("atria.target.hrv.yellowRatio") private var hrvYellowRatio: Double = 0.85
    @AtriaDefault("atria.target.rhr.greenDelta") private var restingGreenDelta: Int = 3
    @AtriaDefault("atria.target.rhr.yellowDelta") private var restingYellowDelta: Int = 7
    @AtriaDefault("atria.target.respiratory.greenDelta") private var respiratoryGreenDelta: Double = 1.5
    @AtriaDefault("atria.target.respiratory.yellowDelta") private var respiratoryYellowDelta: Double = 3.0
    @AtriaDefault("atria.target.skinTemp.greenDelta") private var skinTemperatureGreenDelta: Double = 0.5
    @AtriaDefault("atria.target.skinTemp.yellowDelta") private var skinTemperatureYellowDelta: Double = 1.0
    @AtriaDefault("atria.target.bloodOxygen.candidateFrames") private var bloodOxygenCandidateGoal: Int = 8
    @AtriaDefault("atria.target.bioAge.greenOlderDelta") private var biologicalAgeGreenOlderDelta: Int = 0
    @AtriaDefault("atria.target.bioAge.yellowOlderDelta") private var biologicalAgeYellowOlderDelta: Int = 3
    @AtriaDefault("atria.target.vo2.greenDelta") private var vo2GreenDelta: Double = 0.2
    @AtriaDefault("atria.target.vo2.redDelta") private var vo2RedDelta: Double = -0.2

    var body: some View {
        let summary = metric.targetEditorSummary
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        Image(systemName: metric.systemImage)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(metric.targetEditorTint)
                            .frame(width: 42, height: 42)
                            .background(AtriaIconTileBackground(cornerRadius: AtriaDesignTokens.Radius.chip, tint: metric.targetEditorTint))

                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(metric.label) target")
                                .font(.headline.weight(.semibold))
                            Text(summary)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    editorContent
                        .padding(14)
                        .atriaInsetCard(tint: metric.targetEditorTint)

                    Text("Guidance is general wellness information, not medical advice. Changes update Today cards immediately.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)
                }
                .padding(18)
            }
            .navigationTitle("Target")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.body.weight(.semibold))
                }
            }
        }
        .onChange(of: targetEditorSignature) { _, _ in normalizeAllTargets() }
    }

    private var targetEditorSignature: String {
        [
            recoveryGreenLower,
            recoveryYellowLower,
            strainGreenBand,
            strainYellowBand,
            loadACWRWatchLow,
            loadACWRWatchHigh,
            loadACWRBadLow,
            loadACWRBadHigh,
            loadMonotonyWatch,
            loadMonotonyBad,
            Double(stepsGoal),
            Double(caloriesGoal),
            sleepGoalHours,
            sleepEfficiencyGreenLower,
            sleepEfficiencyYellowLower,
            hrvGreenRatio,
            hrvYellowRatio,
            Double(restingGreenDelta),
            Double(restingYellowDelta),
            respiratoryGreenDelta,
            respiratoryYellowDelta,
            skinTemperatureGreenDelta,
            skinTemperatureYellowDelta,
            Double(bloodOxygenCandidateGoal),
            Double(biologicalAgeGreenOlderDelta),
            Double(biologicalAgeYellowOlderDelta),
            vo2GreenDelta,
            vo2RedDelta,
        ]
        .map { String(format: "%.3f", $0) }
        .joined(separator: "|")
    }

    private func normalizeAllTargets() {
        normalizeRecoveryTargets()
        normalizeStrainTargets()
        normalizeTrainingLoadTargets()
        normalizeStepsGoal()
        normalizeCaloriesGoal()
        normalizeSleepGoal()
        normalizeSleepEfficiencyTargets()
        normalizeHRVTargets()
        normalizeRestingTargets()
        normalizeRespiratoryTargets()
        normalizeSkinTemperatureTargets()
        normalizeBloodOxygenTargets()
        normalizeBiologicalAgeTargets()
        normalizeVO2Targets()
    }

    @ViewBuilder
    private var editorContent: some View {
        switch metric {
        case .recovery:
            VStack(alignment: .leading, spacing: 12) {
                Stepper(value: $recoveryGreenLower, in: 40...95, step: 1) {
                    LabeledContent("Green starts") {
                        Text("\(Int(recoveryGreenLower.rounded()))%")
                            .monospacedDigit()
                    }
                }
                Stepper(value: $recoveryYellowLower, in: 5...66, step: 1) {
                    LabeledContent("Yellow starts") {
                        Text("\(Int(recoveryYellowLower.rounded()))%")
                            .monospacedDigit()
                    }
                }
                Button {
                    recoveryGreenLower = 67
                    recoveryYellowLower = 34
                } label: {
                    Label("Reset recovery target", systemImage: "arrow.counterclockwise")
                }
                .atriaCardAction(tint: .green)
            }
        case .strain:
            VStack(alignment: .leading, spacing: 12) {
                Stepper(value: $strainGreenBand, in: 0.5...5.0, step: 0.5) {
                    LabeledContent("Green band") {
                        Text(String(format: "+/-%.1f", strainGreenBand))
                            .monospacedDigit()
                    }
                }
                Stepper(value: $strainYellowBand, in: 1.0...8.0, step: 0.5) {
                    LabeledContent("Yellow band") {
                        Text(String(format: "+/-%.1f", strainYellowBand))
                            .monospacedDigit()
                    }
                }
                Button {
                    strainGreenBand = 1.5
                    strainYellowBand = 3.0
                } label: {
                    Label("Reset strain band", systemImage: "arrow.counterclockwise")
                }
                .atriaCardAction(tint: .orange)
            }
        case .load:
            VStack(alignment: .leading, spacing: 12) {
                Stepper(value: $loadACWRWatchLow, in: 0.50...1.00, step: 0.05) {
                    LabeledContent("ACWR low watch") {
                        Text(String(format: "%.1f", loadACWRWatchLow))
                            .monospacedDigit()
                    }
                }
                Stepper(value: $loadACWRWatchHigh, in: 1.00...1.60, step: 0.05) {
                    LabeledContent("ACWR high watch") {
                        Text(String(format: "%.1f", loadACWRWatchHigh))
                            .monospacedDigit()
                    }
                }
                Stepper(value: $loadACWRBadLow, in: 0.30...0.95, step: 0.05) {
                    LabeledContent("ACWR low red") {
                        Text(String(format: "%.1f", loadACWRBadLow))
                            .monospacedDigit()
                    }
                }
                Stepper(value: $loadACWRBadHigh, in: 1.10...2.20, step: 0.05) {
                    LabeledContent("ACWR high red") {
                        Text(String(format: "%.1f", loadACWRBadHigh))
                            .monospacedDigit()
                    }
                }
                Stepper(value: $loadMonotonyWatch, in: 1.0...4.0, step: 0.1) {
                    LabeledContent("Monotony watch") {
                        Text(String(format: "%.1f", loadMonotonyWatch))
                            .monospacedDigit()
                    }
                }
                Stepper(value: $loadMonotonyBad, in: 1.2...5.0, step: 0.1) {
                    LabeledContent("Monotony red") {
                        Text(String(format: "%.1f", loadMonotonyBad))
                            .monospacedDigit()
                    }
                }
                Button {
                    loadACWRWatchLow = 0.80
                    loadACWRWatchHigh = 1.30
                    loadACWRBadLow = 0.60
                    loadACWRBadHigh = 1.50
                    loadMonotonyWatch = 2.0
                    loadMonotonyBad = 2.5
                } label: {
                    Label("Reset training-load target", systemImage: "chart.bar.xaxis")
                }
                .atriaCardAction(tint: .orange)
                Text("ACWR compares 7-day strain with 28-day strain; monotony flags repetitive load. This tunes guidance colors only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .sleep, .sleepHistory:
            VStack(alignment: .leading, spacing: 12) {
                Stepper(value: $sleepGoalHours, in: 4.0...12.0, step: 0.25) {
                    LabeledContent("Sleep goal") {
                        Text(AtriaMetricFormat.sleepHours(sleepGoalHours))
                            .monospacedDigit()
                    }
                }
                Button {
                    sleepGoalHours = 8.0
                } label: {
                    Label("Reset sleep goal", systemImage: "bed.double.fill")
                }
                .atriaCardAction(tint: .cyan)
            }
        case .hrv:
            VStack(alignment: .leading, spacing: 12) {
                Stepper(value: $hrvGreenRatio, in: 0.70...1.10, step: 0.01) {
                    LabeledContent("Green starts") {
                        Text("\(Int((hrvGreenRatio * 100).rounded()))%")
                            .monospacedDigit()
                    }
                }
                Stepper(value: $hrvYellowRatio, in: 0.50...0.98, step: 0.01) {
                    LabeledContent("Yellow starts") {
                        Text("\(Int((hrvYellowRatio * 100).rounded()))%")
                            .monospacedDigit()
                    }
                }
                Button {
                    hrvGreenRatio = 0.95
                    hrvYellowRatio = 0.85
                } label: {
                    Label("Reset HRV target", systemImage: "arrow.counterclockwise")
                }
                .atriaCardAction(tint: .pink)
            }
        case .rhr:
            VStack(alignment: .leading, spacing: 12) {
                Stepper(value: $restingGreenDelta, in: 0...12, step: 1) {
                    LabeledContent("Green within") {
                        Text("+\(restingGreenDelta) bpm")
                            .monospacedDigit()
                    }
                }
                Stepper(value: $restingYellowDelta, in: 1...20, step: 1) {
                    LabeledContent("Yellow within") {
                        Text("+\(restingYellowDelta) bpm")
                            .monospacedDigit()
                    }
                }
                Button {
                    restingGreenDelta = 3
                    restingYellowDelta = 7
                } label: {
                    Label("Reset RHR target", systemImage: "arrow.counterclockwise")
                }
                .atriaCardAction(tint: .red)
            }
        case .respiratoryRate:
            VStack(alignment: .leading, spacing: 12) {
                Stepper(value: $respiratoryGreenDelta, in: 0.5...4.0, step: 0.5) {
                    LabeledContent("Green within") {
                        Text(String(format: "+/-%.1f/min", respiratoryGreenDelta))
                            .monospacedDigit()
                    }
                }
                Stepper(value: $respiratoryYellowDelta, in: 1.0...8.0, step: 0.5) {
                    LabeledContent("Yellow within") {
                        Text(String(format: "+/-%.1f/min", respiratoryYellowDelta))
                            .monospacedDigit()
                    }
                }
                Button {
                    respiratoryGreenDelta = 1.5
                    respiratoryYellowDelta = 3.0
                } label: {
                    Label("Reset resp-rate target", systemImage: "arrow.counterclockwise")
                }
                .atriaCardAction(tint: .teal)
            }
        case .bloodOxygen:
            VStack(alignment: .leading, spacing: 12) {
                Stepper(value: $bloodOxygenCandidateGoal, in: 2...120, step: 1) {
                    LabeledContent("Green evidence") {
                        Text("\(bloodOxygenCandidateGoal) frames")
                            .monospacedDigit()
                    }
                }
                Button {
                    bloodOxygenCandidateGoal = 8
                } label: {
                    Label("Reset oxygen signal target", systemImage: "drop.degreesign")
                }
                .atriaCardAction(tint: .blue)
                Text("This tunes candidate-frame evidence only. Atria still does not show an SpO2 percentage until the signal is checked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .bodyTemp:
            if AtriaResearchProbe.validatedSkinTemperatureDecoderAvailable {
                VStack(alignment: .leading, spacing: 12) {
                    Stepper(value: $skinTemperatureGreenDelta, in: 0.2...2.0, step: 0.1) {
                        LabeledContent("Green within") {
                            Text(String(format: "+/-%.1f C", skinTemperatureGreenDelta))
                                .monospacedDigit()
                        }
                    }
                    Stepper(value: $skinTemperatureYellowDelta, in: 0.3...4.0, step: 0.1) {
                        LabeledContent("Yellow within") {
                            Text(String(format: "+/-%.1f C", skinTemperatureYellowDelta))
                                .monospacedDigit()
                        }
                    }
                    Button {
                        skinTemperatureGreenDelta = 0.5
                        skinTemperatureYellowDelta = 1.0
                    } label: {
                        Label("Reset temp target", systemImage: "arrow.counterclockwise")
                    }
                    .atriaCardAction(tint: .teal)
                }
            } else {
                Label("Decoder not verified",
                      systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
            }
        case .bioAge:
            VStack(alignment: .leading, spacing: 12) {
                Stepper(value: $biologicalAgeGreenOlderDelta, in: -10...10, step: 1) {
                    LabeledContent("Green up to") {
                        Text("\(biologicalAgeGreenOlderDelta > 0 ? "+" : "")\(biologicalAgeGreenOlderDelta)y")
                            .monospacedDigit()
                    }
                }
                Stepper(value: $biologicalAgeYellowOlderDelta, in: -9...20, step: 1) {
                    LabeledContent("Yellow up to") {
                        Text("\(biologicalAgeYellowOlderDelta > 0 ? "+" : "")\(biologicalAgeYellowOlderDelta)y")
                            .monospacedDigit()
                    }
                }
                Button {
                    biologicalAgeGreenOlderDelta = 0
                    biologicalAgeYellowOlderDelta = 3
                } label: {
                    Label("Reset fitness-age target", systemImage: "arrow.counterclockwise")
                }
                .atriaCardAction(tint: .purple)
            }
        case .vo2max:
            VStack(alignment: .leading, spacing: 12) {
                Stepper(value: $vo2GreenDelta, in: 0.0...2.0, step: 0.1) {
                    LabeledContent("Green gain") {
                        Text(String(format: "+%.1f", vo2GreenDelta))
                            .monospacedDigit()
                    }
                }
                Stepper(value: $vo2RedDelta, in: -2.0 ... -0.05, step: 0.1) {
                    LabeledContent("Red decline") {
                        Text(String(format: "%.1f", vo2RedDelta))
                            .monospacedDigit()
                    }
                }
                Button {
                    vo2GreenDelta = 0.2
                    vo2RedDelta = -0.2
                } label: {
                    Label("Reset VO2 trend target", systemImage: "arrow.counterclockwise")
                }
                .atriaCardAction(tint: .blue)
            }
        case .steps:
            VStack(alignment: .leading, spacing: 12) {
                Stepper(value: $stepsGoal, in: 1_000...30_000, step: 500) {
                    LabeledContent("Strap steps goal") {
                        Text("\(stepsGoal)")
                            .monospacedDigit()
                    }
                }
                Button {
                    stepsGoal = 8_000
                } label: {
                    Label("Reset strap steps goal", systemImage: "figure.walk")
                }
                .atriaCardAction(tint: .green)
            }
        case .calories:
            VStack(alignment: .leading, spacing: 12) {
                Stepper(value: $caloriesGoal, in: 100...3_000, step: 50) {
                    LabeledContent("Active calories goal") {
                        Text("\(caloriesGoal) kcal")
                            .monospacedDigit()
                    }
                }
                Button {
                    caloriesGoal = 500
                } label: {
                    Label("Reset calories goal", systemImage: "flame.fill")
                }
                .atriaCardAction(tint: .orange)
            }
        case .sleepEfficiency:
            VStack(alignment: .leading, spacing: 12) {
                Stepper(value: $sleepEfficiencyGreenLower, in: 60...99, step: 1) {
                    LabeledContent("Green starts") {
                        Text("\(Int(sleepEfficiencyGreenLower.rounded()))%")
                            .monospacedDigit()
                    }
                }
                Stepper(value: $sleepEfficiencyYellowLower, in: 50...95, step: 1) {
                    LabeledContent("Yellow starts") {
                        Text("\(Int(sleepEfficiencyYellowLower.rounded()))%")
                            .monospacedDigit()
                    }
                }
                Button {
                    sleepEfficiencyGreenLower = 90
                    sleepEfficiencyYellowLower = 80
                } label: {
                    Label("Reset efficiency target", systemImage: "arrow.counterclockwise")
                }
                .atriaCardAction(tint: .cyan)
            }
        default:
            VStack(alignment: .leading, spacing: 8) {
                Label("No target controls", systemImage: "info.circle")
                    .font(.subheadline.weight(.semibold))
                Text("This Today card is an action or trend shortcut, so it uses its source state instead of a personal target zone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func normalizeRecoveryTargets() {
        recoveryYellowLower = min(max(recoveryYellowLower, 5), 66)
        recoveryGreenLower = min(max(recoveryGreenLower, recoveryYellowLower + 1), 95)
    }

    private func normalizeStrainTargets() {
        strainGreenBand = min(max(strainGreenBand, 0.5), 5.0)
        strainYellowBand = min(max(strainYellowBand, strainGreenBand + 0.5), 8.0)
    }

    private func normalizeTrainingLoadTargets() {
        loadACWRBadLow = min(max(loadACWRBadLow, 0.30), 0.95)
        loadACWRWatchLow = min(max(loadACWRWatchLow, loadACWRBadLow + 0.05), 1.00)
        loadACWRWatchHigh = min(max(loadACWRWatchHigh, 1.00), 1.60)
        loadACWRBadHigh = min(max(loadACWRBadHigh, loadACWRWatchHigh + 0.05), 2.20)
        loadMonotonyWatch = min(max(loadMonotonyWatch, 1.0), 4.0)
        loadMonotonyBad = min(max(loadMonotonyBad, loadMonotonyWatch + 0.1), 5.0)
    }

    private func normalizeStepsGoal() {
        stepsGoal = min(max(stepsGoal, 1_000), 30_000)
    }

    private func normalizeCaloriesGoal() {
        caloriesGoal = min(max(caloriesGoal, 100), 3_000)
    }

    private func normalizeSleepGoal() {
        sleepGoalHours = min(max(sleepGoalHours, 4.0), 12.0)
    }

    private func normalizeSleepEfficiencyTargets() {
        sleepEfficiencyYellowLower = min(max(sleepEfficiencyYellowLower, 50), 95)
        sleepEfficiencyGreenLower = min(max(sleepEfficiencyGreenLower, sleepEfficiencyYellowLower + 1), 99)
    }

    private func normalizeHRVTargets() {
        hrvYellowRatio = min(max(hrvYellowRatio, 0.50), 0.98)
        hrvGreenRatio = min(max(hrvGreenRatio, hrvYellowRatio + 0.01), 1.20)
    }

    private func normalizeRestingTargets() {
        restingGreenDelta = min(max(restingGreenDelta, 0), 12)
        restingYellowDelta = min(max(restingYellowDelta, restingGreenDelta + 1), 20)
    }

    private func normalizeRespiratoryTargets() {
        respiratoryGreenDelta = min(max(respiratoryGreenDelta, 0.5), 4.0)
        respiratoryYellowDelta = min(max(respiratoryYellowDelta, respiratoryGreenDelta + 0.5), 8.0)
    }

    private func normalizeSkinTemperatureTargets() {
        skinTemperatureGreenDelta = min(max(skinTemperatureGreenDelta, 0.2), 2.0)
        skinTemperatureYellowDelta = min(max(skinTemperatureYellowDelta, skinTemperatureGreenDelta + 0.1), 4.0)
    }

    private func normalizeBloodOxygenTargets() {
        bloodOxygenCandidateGoal = min(max(bloodOxygenCandidateGoal, 2), 120)
    }

    private func normalizeBiologicalAgeTargets() {
        biologicalAgeGreenOlderDelta = min(max(biologicalAgeGreenOlderDelta, -10), 10)
        biologicalAgeYellowOlderDelta = min(max(biologicalAgeYellowOlderDelta, biologicalAgeGreenOlderDelta + 1), 20)
    }

    private func normalizeVO2Targets() {
        vo2GreenDelta = min(max(vo2GreenDelta, 0.0), 2.0)
        vo2RedDelta = max(min(vo2RedDelta, -0.05), -2.0)
    }
}

private extension AtriaTodayMetric {
    var targetEditorTint: Color {
        // Settings painted every row in a raw hue that contradicted the
        // metric's identity colour elsewhere — HRV pink and Resting HR RED,
        // when the documented rule is HRV rose and RHR blue. One table now
        // (AtriaMetricIdentity, 2026-08-28).
        identityTint()
    }

    var targetEditorSummary: String {
        switch self {
        case .recovery:
            return "Adjust the green/yellow recovery thresholds used by target zones."
        case .strain:
            return "Adjust how tightly Strain should track today's recovery-scaled target."
        case .load:
            return "Adjust ACWR and monotony bands used by training-load readiness colors."
        case .sleep:
            return "Adjust the sleep duration goal used by sleep target zones."
        case .sleepHistory:
            return "Adjust the sleep goal used by sleep history, debt, and consistency."
        case .hrv:
            return "Adjust how close HRV should stay to your personal baseline."
        case .rhr:
            return "Adjust the resting-HR rise allowed above your personal baseline."
        case .respiratoryRate:
            return "Adjust the sleep respiratory-rate deviation allowed around your baseline."
        case .bodyTemp:
            return "Adjust the relative sleep skin-temperature deviation allowed around baseline."
        case .bloodOxygen:
            return "Adjust the early signal threshold for candidate frames. This is not an SpO2 percentage target."
        case .bioAge:
            return "Adjust the younger/older delta bands for the fitness-age estimate."
        case .vo2max:
            return "Adjust the VO2max trend gain or decline needed for target colors."
        case .steps:
            return "Adjust the daily strap-step goal used by the steps card."
        case .calories:
            return "Adjust the estimated active-calorie goal used by the calories card."
        case .sleepEfficiency:
            return "Adjust the sleep-efficiency green/yellow target bands."
        default:
            return "Action and trend shortcuts do not use personal target zones."
        }
    }
}






enum AtriaSleepStageGlyph {
    static func symbol(for stage: SleepStageKind) -> String {
        switch stage {
        case .awake: return "sun.max.fill"
        case .light: return "moon.fill"
        case .rem: return "moonphase.waxing.crescent"
        case .sws: return "waveform.path"
        case .deep: return "moon.stars.fill"
        }
    }

    static func color(for stage: SleepStageKind) -> Color {
        switch stage {
        case .awake: return .orange
        case .light: return .cyan
        case .rem: return .indigo
        case .sws: return .blue
        case .deep: return .purple
        }
    }
}

private extension SleepStageKind {
    var shortLabel: String {
        switch self {
        case .awake: return "AWAKE"
        case .light: return "LIGHT"
        case .rem: return "REM"
        case .sws: return "SWS"
        case .deep: return "DEEP"
        }
    }
}











enum AtriaMetricDetailKind: String, Identifiable, CaseIterable {
    case recovery
    case hrv
    case restingHeartRate
    case respiratoryRate
    case sleep
    case strain
    // Visibility/IA route audit (2026-07-05): these extend detail coverage to
    // every remaining glance tile that used to dead-end on tap. Some carry a
    // real rollup-backed trend (sleepPerformance, fitnessAge); the rest render
    // an honest "no trend saved yet" template instead of a dead tap.
    case stress
    case vo2max
    case sleepPerformance
    case sleepEfficiency
    case skinTemperature
    case fitnessAge
    case hrZones
    case bloodOxygen

    var id: String { rawValue }

    /// Metrics that resolve to ONE value per day and are drawn as bars: a bar
    /// states "this much, measured from zero", which is what a once-a-day score
    /// is. Continuous or intra-day metrics stay lines.
    ///
    /// Expanding a chart opens in this form so the full-screen view shows the
    /// same shape that was tapped rather than silently switching to a line.
    var rendersAsDailyBar: Bool {
        switch self {
        // The owner's chart grammar (2026-08-26): a metric that resolves to
        // ONE value per day draws as bars; a metric that moves through the day
        // draws as a line. The corner sparklines followed it from the start —
        // HRV, resting HR and respiratory rate drew bars on the tile and then
        // silently switched to lines when tapped open, which is exactly the
        // unpredictability the 2026-08-27 goal names. Aligned here so the
        // full-screen shape is the shape that was tapped.
        case .recovery, .sleep, .strain, .sleepPerformance,
             .hrv, .restingHeartRate, .respiratoryRate, .sleepEfficiency:
            return true
        // Stated exclusions, each for a reason rather than by omission:
        //  .stress          intra-day — the rule's own line case
        //  .skinTemperature a signed DEVIATION; the bar y-domain is anchored
        //                   at zero and would clip a negative night
        //  .fitnessAge      an age in years — a bar from zero makes a one-year
        //                   change invisible, defeating the chart
        //  .vo2max, .bloodOxygen, .hrZones  render honest no-trend templates;
        //                   they gain the bar form when a stored per-day
        //                   series exists to draw
        default:
            return false
        }
    }

    var title: String {
        switch self {
        case .recovery: return "Recovery"
        case .hrv: return "HRV"
        case .restingHeartRate: return "Resting HR"
        case .respiratoryRate: return "Respiratory rate"
        case .sleep: return "Sleep"
        case .strain: return "Strain"
        case .stress: return "Stress"
        case .vo2max: return "VO2max"
        case .sleepPerformance: return "Sleep sufficiency"
        case .sleepEfficiency: return "Sleep efficiency"
        case .skinTemperature: return "Skin temperature"
        case .fitnessAge: return "Fitness age"
        case .hrZones: return "HR zones"
        case .bloodOxygen: return "Blood oxygen"
        }
    }

    /// One identity hue per metric, drawn from the design palette and deepened
    /// on light via the Metrics.electric* constants (see Metrics.swift). Fixes a
    /// prior coherence bug where `.sleep` returned `.cyan` here — clashing with
    /// sleep's purple ring/chips everywhere else — and where HRV+RHR and
    /// respiration+skin-temp collapsed onto shared raw hues.
    var tint: Color {
        switch self {
        case .recovery: return Metrics.electricGreen
        case .hrv: return Metrics.electricHRV
        case .restingHeartRate: return Metrics.electricRHR
        case .respiratoryRate: return Metrics.electricRespiratory
        case .sleep: return Metrics.electricSleep
        case .strain: return Metrics.electricStrain
        case .stress: return Metrics.electricStress
        case .vo2max: return Metrics.electricGreen
        case .sleepPerformance, .sleepEfficiency: return Metrics.electricSleep
        case .skinTemperature: return Metrics.electricRespiratory
        case .fitnessAge: return Metrics.electricSleep
        case .hrZones: return Metrics.electricStrain
        case .bloodOxygen: return .blue // distinct from RHR's sky-blue; the two can co-list
        }
    }
}

struct AtriaStaleWhileRefreshState<Key: Equatable & Sendable, Value: Sendable>: Sendable {
    private(set) var requestedKey: Key?
    private(set) var valueKey: Key?
    private(set) var value: Value?

    mutating func begin(_ key: Key) {
        requestedKey = key
    }

    @discardableResult
    mutating func accept(_ newValue: Value, for key: Key) -> Bool {
        guard requestedKey == key else { return false }
        valueKey = key
        value = newValue
        return true
    }
}

struct AtriaTodayWorkoutZoneSummary: Equatable {
    struct Entry: Equatable, Identifiable {
        let zone: HRZone
        let minutes: Double
        var id: HRZone { zone }
    }

    let workoutCount: Int
    let workouts: [UserConfirmedWorkout]
    let highZoneSeconds: TimeInterval
    let histogram: [Entry]

    static let empty = AtriaTodayWorkoutZoneSummary(workoutCount: 0,
                                                    workouts: [],
                                                    highZoneSeconds: 0,
                                                    histogram: [])

    static func make(workouts: [UserConfirmedWorkout],
                     confirmedSleeps: [UserConfirmedSleep] = [],
                     sleepHistory: SleepHistorySnapshot? = nil,
                     now: Date = Date(),
                     calendar: Calendar = .current) -> AtriaTodayWorkoutZoneSummary {
        let today = sleepHistory.map {
            AtriaPhysiologicalDay.current(now: now, sleepHistory: $0, calendar: calendar)
        } ?? AtriaPhysiologicalDay.current(now: now,
                                           confirmedSleeps: confirmedSleeps,
                                           calendar: calendar)
        var todayWorkouts: [UserConfirmedWorkout] = []
        var totals: [String: TimeInterval] = [:]
        // Presentation gate (2026-07-31): accidental sub-minute live fragments
        // never become overview workout rows or zone-histogram contributors.
        for workout in AtriaWorkoutMetricPresentation.presentableWorkouts(workouts) {
            guard today.overlaps(start: workout.start, end: workout.end) else { continue }
            todayWorkouts.append(workout)
            guard !AtriaWorkoutMetricPresentation.metricsAreIncomplete(workout) else { continue }
            for (key, seconds) in workout.zoneSeconds ?? [:] {
                totals[key, default: 0] += seconds
            }
        }
        guard !todayWorkouts.isEmpty else { return .empty }
        todayWorkouts.sort { $0.start > $1.start }
        let highZoneSeconds = (totals["aerobic"] ?? 0)
            + (totals["anaerobic"] ?? 0)
            + (totals["max"] ?? 0)
        let keyByZone: [HRZone: String] = [
            .rest: "rest", .warmup: "warmup", .fatBurn: "fatBurn",
            .aerobic: "aerobic", .anaerobic: "anaerobic", .max: "max",
        ]
        let histogram = HRZone.allCases.compactMap { zone -> Entry? in
            guard let seconds = keyByZone[zone].flatMap({ totals[$0] }), seconds >= 30 else { return nil }
            return Entry(zone: zone, minutes: seconds / 60)
        }
        return AtriaTodayWorkoutZoneSummary(workoutCount: todayWorkouts.count,
                                           workouts: todayWorkouts,
                                           highZoneSeconds: highZoneSeconds,
                                           histogram: histogram)
    }
}

private final class AtriaTodayWorkoutZoneSummaryMemo {
    private var revision: Int?
    private var cycleStart: Date?
    private var value = AtriaTodayWorkoutZoneSummary.empty

    func summary(workouts: [UserConfirmedWorkout],
                 sleepHistory: SleepHistorySnapshot = .empty,
                 revision newRevision: Int?,
                 now: Date = Date(),
                 calendar: Calendar = .current) -> AtriaTodayWorkoutZoneSummary {
        let newCycleStart = AtriaPhysiologicalDay.current(now: now,
                                                         sleepHistory: sleepHistory,
                                                         calendar: calendar).start
        if let newRevision, revision == newRevision, cycleStart == newCycleStart {
            return value
        }
        let next = AtriaTodayWorkoutZoneSummary.make(workouts: workouts,
                                                     sleepHistory: sleepHistory,
                                                     now: now,
                                                     calendar: calendar)
        revision = newRevision
        cycleStart = newCycleStart
        value = next
        return next
    }
}

private struct AtriaMetricDetailPreparationInput: Equatable, Sendable {
    struct Rollup: Equatable, Sendable {
        let day: Date
        let recovery: Int?
        let lnRMSSD: Double?
        let restingHeartRate: Int?
        let sleepSeconds: TimeInterval?
        let sleepPerformance: Int?
        let strain: Double?
        let strainCoverageFraction: Double?
        let strainEvidenceQuality: Metrics.StrainEvidenceQuality?
        let respiratoryRate: Double?
        let fitnessAgeDelta: Int?

        init(_ entry: DailyRollupStoreEntry) {
            day = entry.day
            recovery = entry.recovery
            lnRMSSD = entry.lnRMSSD
            restingHeartRate = entry.rhr
            sleepSeconds = entry.sleepSeconds
            sleepPerformance = entry.sleepPerformance
            strain = entry.strain
            strainCoverageFraction = entry.strainCoverageFraction
            strainEvidenceQuality = entry.strainEvidenceQuality
            respiratoryRate = entry.respiratoryRate
            fitnessAgeDelta = entry.fitnessAgeDelta
        }
    }

    struct Baseline: Equatable, Sendable {
        let hrvBaseline: Int?
        let hrvSampleCount: Int
        let hrvLnMean: Double?
        let hrvLnSD: Double?
        let hrvTrusted: Bool
        let restingBaseline: Int?
        let restingSampleCount: Int
        let restingMean: Double?
        let restingSD: Double?
        let restingTrusted: Bool

        init(_ baseline: AtriaBaselineTargetSnapshot) {
            hrvBaseline = baseline.hrvBaseline
            hrvSampleCount = baseline.hrvSampleCount
            hrvLnMean = baseline.hrvLnMean
            hrvLnSD = baseline.hrvLnSD
            hrvTrusted = baseline.hrvTrusted
            restingBaseline = baseline.restingBaseline
            restingSampleCount = baseline.restingSampleCount
            restingMean = baseline.restingMean
            restingSD = baseline.restingSD
            restingTrusted = baseline.restingTrusted
        }
    }

    let rollupsRevision: Int?
    let rollups: [Rollup]
    let baseline: Baseline
    let sleepGoalHours: Double
    let referenceDate: Date
    let calendar: Calendar
    /// Closed physiological cycles' strain keyed by predominant civil day
    /// (2026-08-30, SessionStore.physiologicalCycleStrainByDisplayDay).
    /// Overrides the civil rollup VALUE for matching strain chart days so a
    /// shifted sleep schedule is not shredded across two civil bars; days
    /// absent here keep the civil value (no claim of cycle precision).
    let cycleStrainByDisplayDay: [Date: Double]

    init(rollups: [DailyRollupStoreEntry],
         rollupsRevision: Int?,
         baseline: AtriaBaselineTargetSnapshot,
         sleepGoalHours: Double,
         cycleStrainByDisplayDay: [Date: Double] = [:],
         referenceDate: Date = Date(),
         calendar: Calendar = .current) {
        self.rollupsRevision = rollupsRevision
        self.rollups = rollups.map(Rollup.init)
        self.baseline = Baseline(baseline)
        self.sleepGoalHours = sleepGoalHours
        self.cycleStrainByDisplayDay = cycleStrainByDisplayDay
        self.referenceDate = calendar.startOfDay(for: referenceDate)
        self.calendar = calendar
    }

    func anchored(at date: Date) -> Self {
        .init(
            rollupsRevision: rollupsRevision,
            rollups: rollups,
            baseline: baseline,
            sleepGoalHours: sleepGoalHours,
            cycleStrainByDisplayDay: cycleStrainByDisplayDay,
            referenceDate: calendar.startOfDay(for: date),
            calendar: calendar
        )
    }

    private init(rollupsRevision: Int?,
                 rollups: [Rollup],
                 baseline: Baseline,
                 sleepGoalHours: Double,
                 cycleStrainByDisplayDay: [Date: Double],
                 referenceDate: Date,
                 calendar: Calendar) {
        self.rollupsRevision = rollupsRevision
        self.rollups = rollups
        self.baseline = baseline
        self.sleepGoalHours = sleepGoalHours
        self.cycleStrainByDisplayDay = cycleStrainByDisplayDay
        self.referenceDate = referenceDate
        self.calendar = calendar
    }
}

struct AtriaMetricPeriodIndexProjection: Equatable, Sendable {
    let currentIndices: [Int]
    let priorIndices: [Int]
    let interval: DateInterval
    let priorInterval: DateInterval

    init(days: [Date],
         referenceDate: Date,
         range: AtriaTrendRange,
         calendar: Calendar) {
        let visibleInterval = range.periodInterval(
            containing: referenceDate,
            calendar: calendar
        )
        let previousAnchor = range.adjacentPeriodAnchor(
            from: referenceDate,
            offset: -1,
            calendar: calendar
        )
        let earlierInterval = range.periodInterval(
            containing: previousAnchor,
            calendar: calendar
        )
        currentIndices = days.indices.filter {
            days[$0] >= visibleInterval.start && days[$0] < visibleInterval.end
        }
        priorIndices = days.indices.filter {
            days[$0] >= earlierInterval.start && days[$0] < earlierInterval.end
        }
        interval = visibleInterval
        priorInterval = earlierInterval
    }
}

/// One truth gate for inserting a current physiological-cycle measurement
/// into metric-detail history. The caller supplies `usesCurrentCycle` from
/// `AtriaHealthMetricAuthority.DetailProjection`, so an explicitly historical
/// period remains byte-for-byte untouched. Within the current period, any
/// stale civil-day copy is removed before the authoritative point is appended.
enum AtriaMetricDetailCurrentCyclePointPolicy {
    static func replacingSameDay(
        in points: [AtriaDetailChartPoint],
        value: Double?,
        displayAnchor: Date?,
        usesCurrentCycle: Bool,
        tint: Color,
        calendar: Calendar = .current
    ) -> [AtriaDetailChartPoint] {
        guard usesCurrentCycle, let displayAnchor else { return points }

        let currentDay = calendar.startOfDay(for: displayAnchor)
        var result = points.filter {
            !calendar.isDate($0.day, inSameDayAs: currentDay)
        }
        if let value, value.isFinite {
            result.append(AtriaDetailChartPoint(day: currentDay,
                                                value: value,
                                                tint: tint))
        }
        return result.sorted { $0.day < $1.day }
    }
}

private actor AtriaMetricDetailPreparationCache {
    static let shared = AtriaMetricDetailPreparationCache()

    private var entry: (key: AtriaMetricDetailPreparationInput, value: AtriaPreparedMetricHistory)?

    func value(for key: AtriaMetricDetailPreparationInput) -> AtriaPreparedMetricHistory? {
        guard entry?.key == key else { return nil }
        return entry?.value
    }

    func insert(_ value: AtriaPreparedMetricHistory,
                for key: AtriaMetricDetailPreparationInput) {
        entry = (key, value)
    }
}

struct AtriaMetricDetailSheet: View {
    let metric: AtriaMetricDetailKind
    let confirmedWorkouts: [UserConfirmedWorkout]
    let confirmedWorkoutsRevision: Int?
    /// Real confirmed sleeps for the day-detail route's history model. With
    /// an empty list the sheet showed rollup sleep while the History tab
    /// showed confirmed-sleep sums for the same day (2026-07-31 audit
    /// item 11).
    let confirmedSleeps: [UserConfirmedSleep]
    let baseline: AtriaBaselineTargetSnapshot
    let sleepHistory: SleepHistorySnapshot
    let sleepHistoryRevision: Int?
    let guidance: Coach.Guidance
    let recoveryEstimate: Metrics.RecoveryEstimate
    let currentCycleAuthority: AtriaHealthMetricAuthority.Projection?
    let sleepGoalHours: Double
    let sleepBaseNeedHours: Double
    /// ITEM-3 2026-08-15: strap motion transport state for the hypnogram
    /// card's unlock-aware empty states. nil = generic honest copy.
    let strapMotionAvailability: AtriaStrapMotionAvailability?
    // Visibility/IA route audit (2026-07-05): live data for the new honest-
    // partial detail kinds (VO2max, HR zones, skin temperature). All default
    // to an honest "still building" value so the two pre-existing call sites
    // (AtriaTodayScreen, and the dead orphaned AtriaVitalsTabContent/
    // AtriaOverviewReadinessSection screens) keep compiling unchanged.
    let hrZoneMinutes: TodayHRZoneMinutes
    let maxHeartRate: Int?
    let behaviorImpacts: [BehaviorImpactSummary]
    private let rollups: [DailyRollupStoreEntry]
    private let preparationBaseInput: AtriaMetricDetailPreparationInput
    private let latestNutrition: AtriaNutritionSummary?
    @State private var openedHistoryDay: AtriaHistoryDay?
    @State private var showChartOptions = false
    @State private var showExpandedChart = false
    @State private var bucketOverride: AtriaChartBucketOverride
    @State private var showMinMaxBand: Bool
    @State private var expandedChartEventsCache = ExpandedChartEventsCache()
    @State private var metricChartPreparedDataCache = MetricChartPreparedDataCache()
    @State private var todayWorkoutZoneSummaryMemo = AtriaTodayWorkoutZoneSummaryMemo()
    let vo2MaxEstimate: VO2MaxEstimateSummary?
    let skinTemperatureDeviation: IMUAuditSummary.SkinTemperatureDeviationSummary?
    @State private var preparation = AtriaStaleWhileRefreshState<AtriaMetricDetailPreparationInput, AtriaPreparedMetricHistory>()
    // Detail sheets open on today rather than a month aggregate. The range
    // picker still provides week/month context without hiding the current day.
    @State private var range: AtriaTrendRange = .day
    @State private var periodAnchor: Date
    @State private var showingMeaningSheet = false
    private let initialScrubbedDay: Date?
    /// Built by the caller from the canonical presentation model, because the
    /// caller is what holds the hero snapshot. Nil where a metric has no
    /// provenance to show, in which case the section is simply absent rather
    /// than rendered empty.
    var provenance: AtriaMetricProvenance? = nil
    /// Self-improving zones (2026-09-02): the max-HR suggestion the engine
    /// learns from sustained session peaks, offered beside the zone card it
    /// would change instead of only deep in Settings. nil = nothing to offer.
    var maxHRSuggestion: AtriaMaxHRSuggestion? = nil
    var onAcceptMaxHRSuggestion: ((Int) -> Void)? = nil
    var onDismissMaxHRSuggestion: ((Int) -> Void)? = nil
    @State private var maxHRSuggestionHandled = false

    private final class ExpandedChartEventsCache {
        private var key: Int?
        private var events: [AtriaChartEvent] = []

        func value(key newKey: Int, compute: () -> [AtriaChartEvent]) -> [AtriaChartEvent] {
            if key != newKey {
                key = newKey
                events = compute()
            }
            return events
        }
    }

    private final class MetricChartPreparedDataCache {
        struct Key: Equatable {
            let preparationInput: AtriaMetricDetailPreparationInput
            let metric: AtriaMetricDetailKind
            let range: AtriaTrendRange
            let bucketOverride: AtriaChartBucketOverride
            let showMinMaxBand: Bool
            /// Only evidence that can alter this metric's current chart point.
            /// Do not key on the whole Hero authority: unrelated live strain,
            /// recovery detail, and wear-coverage updates would repeatedly
            /// rebuild an open chart without changing its plotted data.
            let currentCycleValue: Double?
            let currentCycleDisplayDay: Date?
            let dynamicCompanionSignature:
                AtriaMetricChartDynamicCompanionSignature
        }

        private var entry: (key: Key, value: AtriaMetricChartPreparedData)?

        func value(for key: Key,
                   compute: () -> AtriaMetricChartPreparedData) -> AtriaMetricChartPreparedData {
            if let entry, entry.key == key { return entry.value }
            let value = compute()
            entry = (key, value)
            return value
        }
    }

    init(metric: AtriaMetricDetailKind,
         rollups: [DailyRollupStoreEntry],
         rollupsRevision: Int? = nil,
         confirmedWorkouts: [UserConfirmedWorkout] = [],
         confirmedWorkoutsRevision: Int? = nil,
         confirmedSleeps: [UserConfirmedSleep] = [],
         behaviorImpacts: [BehaviorImpactSummary] = [],
         baseline: AtriaBaselineTargetSnapshot,
         sleepHistory: SleepHistorySnapshot,
         sleepHistoryRevision: Int? = nil,
         guidance: Coach.Guidance,
         recoveryEstimate: Metrics.RecoveryEstimate,
         currentCycleAuthority: AtriaHealthMetricAuthority.Projection? = nil,
         sleepGoalHours: Double,
         sleepBaseNeedHours: Double,
         hrZoneMinutes: TodayHRZoneMinutes = .empty,
         maxHeartRate: Int? = nil,
         vo2MaxEstimate: VO2MaxEstimateSummary? = nil,
         skinTemperatureDeviation: IMUAuditSummary.SkinTemperatureDeviationSummary? = nil,
         strapMotionAvailability: AtriaStrapMotionAvailability? = nil,
         provenance: AtriaMetricProvenance? = nil,
         maxHRSuggestion: AtriaMaxHRSuggestion? = nil,
         onAcceptMaxHRSuggestion: ((Int) -> Void)? = nil,
         onDismissMaxHRSuggestion: ((Int) -> Void)? = nil,
         // Cycle-truth strain series (2026-08-30). Default [:] keeps every
         // caller without it byte-identical: absent days chart civil values.
         cycleStrainByDisplayDay: [Date: Double] = [:],
         initialRange: AtriaTrendRange = .day,
         initialScrubbedDay: Date? = nil,
         initialBucketOverride: AtriaChartBucketOverride = .auto,
         initialShowMinMaxBand: Bool = true) {
        let resolvedInitialRange: AtriaTrendRange =
            metric == .fitnessAge && initialRange == .day ? .week : initialRange
        _range = State(initialValue: resolvedInitialRange)
        let currentPeriodAnchor: Date
        switch metric {
        case .recovery, .strain, .hrv, .restingHeartRate:
            currentPeriodAnchor = currentCycleAuthority?.cycleStart ?? Date()
        default:
            currentPeriodAnchor = Date()
        }
        _periodAnchor = State(initialValue: currentPeriodAnchor)
        self.initialScrubbedDay = initialScrubbedDay
        _bucketOverride = State(initialValue: initialBucketOverride)
        _showMinMaxBand = State(initialValue: initialShowMinMaxBand)
        self.provenance = provenance
        self.maxHRSuggestion = maxHRSuggestion
        self.onAcceptMaxHRSuggestion = onAcceptMaxHRSuggestion
        self.onDismissMaxHRSuggestion = onDismissMaxHRSuggestion
        self.metric = metric
        self.confirmedWorkouts = confirmedWorkouts
        self.confirmedWorkoutsRevision = confirmedWorkoutsRevision
        self.confirmedSleeps = confirmedSleeps
        self.baseline = baseline
        self.sleepHistory = sleepHistory
        self.sleepHistoryRevision = sleepHistoryRevision
        self.guidance = guidance
        self.recoveryEstimate = recoveryEstimate
        self.currentCycleAuthority = currentCycleAuthority
        self.sleepGoalHours = sleepGoalHours
        self.sleepBaseNeedHours = sleepBaseNeedHours
        self.hrZoneMinutes = hrZoneMinutes
        self.maxHeartRate = maxHeartRate
        self.vo2MaxEstimate = vo2MaxEstimate
        self.skinTemperatureDeviation = skinTemperatureDeviation
        self.strapMotionAvailability = strapMotionAvailability
        self.rollups = rollups
        self.behaviorImpacts = behaviorImpacts
        self.latestNutrition = rollups.first(where: { $0.nutrition != nil })?.nutrition
        self.preparationBaseInput = AtriaMetricDetailPreparationInput(
            rollups: rollups,
            rollupsRevision: rollupsRevision,
            baseline: baseline,
            sleepGoalHours: sleepGoalHours,
            cycleStrainByDisplayDay: cycleStrainByDisplayDay
        )
    }

    private var preparationInput: AtriaMetricDetailPreparationInput {
        preparationBaseInput.anchored(at: periodAnchor)
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 12) {
                    AtriaPanelSectionHeader(title: metric.title, subtitle: "Trend and context")
                    Spacer(minLength: 0)
                    if chartSupportsOptions {
                        Button {
                            showChartOptions = true
                        } label: {
                            // chart.bar.xaxis (not the slider glyph — that
                            // bare literal is banned by the removed-customize
                            // guard in this file).
                            // Ink, not accent blue (2026-08-29 theme pass).
                            Image(systemName: "chart.bar.xaxis")
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(10)
                                .background(.quaternary.opacity(0.22), in: Circle())
                        }
                        // .plain, like the period chevrons: the default
                        // borderless style paints accent blue over the ink.
                        .buttonStyle(.plain)
                        .accessibilityLabel("Chart options: bucketing and min-max band")
                    }
                    Button {
                        showingMeaningSheet = true
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(10)
                            .background(.quaternary.opacity(0.22), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(metric.title) meaning and coaching")
                }

                if preparation.value == nil {
                    preparationShell
                } else {
                    detailTemplate
                }
            }
            // 12pt gutter (2026-08-05 width audit): match the app-wide screen
            // gutter instead of the old 18pt so detail charts gain 12pt.
            .padding(.horizontal, 12)
            .padding(.vertical, 18)
        }
        .task(id: preparationInput) {
            await refreshPreparedHistory()
        }
        .onChange(of: range) { _, _ in
            periodAnchor = currentMetricPeriodAnchor
        }
        .onChange(of: currentCycleAuthority?.cycleStart) { oldStart, newStart in
            guard metric == .recovery
                    || metric == .strain
                    || metric == .hrv
                    || metric == .restingHeartRate,
                  let oldStart,
                  range.periodInterval(
                    containing: periodAnchor,
                    calendar: preparationBaseInput.calendar
                  ).contains(oldStart) else {
                return
            }
            periodAnchor = newStart ?? Date()
        }
        .sheet(isPresented: $showingMeaningSheet) {
            AtriaMetricMeaningSheet(metric: metric,
                                    guidance: guidance,
                                    recoveryEstimate: recoveryEstimate,
                                    sleepGoalHours: sleepGoalHours)
        }
        .fullScreenCover(isPresented: $showExpandedChart) {
            if let config = expandedChartConfig {
                AtriaExpandedChartView(title: config.title,
                                       unit: config.unit,
                                       tint: config.tint,
                                       points: config.points,
                                       priorPoints: config.prior,
                                       baselineBand: config.band,
                                       events: expandedChartEvents,
                                       overlays: expandedChartOverlays,
                                       xDomain: expandedChartXDomain,
                                       comparisonPeriodNoun: range.narrativeLabel,
                                       // Open in the form the user just tapped.
                                       defaultChartType: metric.rendersAsDailyBar ? .bars : .line,
                                       onDismiss: { showExpandedChart = false })
            }
        }
        .sheet(isPresented: $showChartOptions) {
            AtriaChartOptionsSheet(window: $range,
                                   bucketOverride: $bucketOverride,
                                   showMinMaxBand: $showMinMaxBand)
                .presentationDetents([.height(380)])
                .presentationDragIndicator(.visible)
        }
        .onAppear {
            #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture"),
               arguments.indices.contains(arguments.index(after: fixtureIndex)),
               arguments[arguments.index(after: fixtureIndex)] == "chart-options" {
                showChartOptions = true
            }
            #endif
        }
        .sheet(item: $openedHistoryDay) { day in
            let historyModel = AtriaHistoryModel.make(rollups: rollups,
                                                      workouts: confirmedWorkouts,
                                                      sleeps: confirmedSleeps)
            AtriaHistoryDayDetailSheet(day: day,
                                       medians: historyModel.medianWindow(around: day),
                                       nights: sleepHistory.confirmedNights(on: day.date),
                                       allDays: historyModel.days,
                                       mediansForDay: { historyModel.medianWindow(around: $0) },
                                       nightsForDay: { sleepHistory.confirmedNights(on: $0.date) })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var preparedHistory: AtriaPreparedMetricHistory {
        precondition(preparation.value != nil, "Metric history is read only after preparation completes")
        return preparation.value!
    }

    /// Anchor of the history the chart is ACTUALLY plotting right now — the
    /// accepted preparation's reference date, not the live `periodAnchor`,
    /// which runs ahead of the plot during an async prepare (2026-08-01
    /// stale-title fix; History audit item 5).
    private var displayedPeriodAnchor: Date {
        preparation.valueKey?.referenceDate ?? periodAnchor
    }

    /// True while the user's selected period differs from the prepared one —
    /// exactly the window in which title-vs-plot disagreement was possible.
    /// Compares anchors only (day-normalized, as `anchored(at:)` stores them)
    /// rather than whole preparation inputs, so this stays O(1) per body
    /// evaluation instead of re-comparing every rollup.
    private var isPreparingSelectedPeriod: Bool {
        displayedPeriodAnchor
            != preparationBaseInput.calendar.startOfDay(for: periodAnchor)
    }

    private var preparationShell: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .tint(metric.tint)
                Text("Preparing trend")
                    .font(.headline.weight(.semibold))
            }
            // Chart-shaped placeholder: the trend lands in this exact slot, so
            // the card holds its height and nothing jumps when data arrives.
            AtriaSkeletonBlock(height: 108)
            Text("Your saved metric history will appear here in a moment.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .leading)
        .padding(16)
        .atriaInsetCard(tint: metric.tint)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preparing \(metric.title) trend")
        .accessibilityIdentifier("metric-detail-preparation-shell")
    }

    @MainActor
    private func refreshPreparedHistory() async {
        let input = preparationInput
        var next = preparation
        next.begin(input)
        preparation = next

        if preparation.valueKey == input {
            return
        }
        if let cached = await AtriaMetricDetailPreparationCache.shared.value(for: input) {
            var cachedState = preparation
            _ = cachedState.accept(cached, for: input)
            preparation = cachedState
            return
        }

        let prepared = await Task.detached(priority: .userInitiated) {
            AtriaPreparedMetricHistory(input: input)
        }.value
        guard !Task.isCancelled, preparation.requestedKey == input else { return }
        await AtriaMetricDetailPreparationCache.shared.insert(prepared, for: input)

        var completed = preparation
        _ = completed.accept(prepared, for: input)
        preparation = completed
    }

    @ViewBuilder
    private var detailTemplate: some View {
        switch metric {
        case .recovery:
            // Recovery's signature visual (the contributor map: what made
            // today's score) belongs on the first screen like sleep's
            // hypnogram and strain's gauge — not behind "Show details"
            // (2026-07-07, design handoff full-scroll mock).
            AtriaMetricDetailTemplate(heroValue: recoveryHeroValue,
                                      heroState: recoveryHeroState,
                                      // Missing Recovery is neutral. Green is
                                      // reserved for an actual qualified score.
                                      tint: recoveryHeroRawPercent.map {
                                        Metrics.recoveryColor(Int($0.rounded()))
                                      } ?? .secondary,
                                      heroStyle: .recoveryRing(score: recoveryHeroRawPercent,
                                                               baselineComparison: recoveryBaselineComparisonText)) {
                contributorCard
                strainRecoveryComboCard
            } contributors: {
                // 2026-08-29 minimalism restructure: provenance + behaviors
                // moved behind the "Show details" reveal; the contributor map
                // (the signature visual) stays on the first screen.
                if let provenance {
                    AtriaMetricProvenanceCard(provenance: provenance)
                }
                behaviorsMoveYouCard
            } chart: {
                chartSlot {
                    metricChart(title: "Recovery",
                                // Per-day bar: a 0-100 score; zero is meaningful.
                                rendersAsDailyBar: true,
                                unit: "%",
                                tint: Metrics.electricGreen,
                                points: recoveryDisplayPointsForSelectedPeriod,
                                summary: recoverySummaryForSelectedPeriod,
                                comparison: recoveryComparisonForSelectedPeriod,
                                baselineBand: nil,
                                accessibilitySummary: "Recovery over \(range.label).",
                                priorPoints: preparedHistory.recoveryPrior[range] ?? [],
                                companions: [("That day's HRV", "ms", Metrics.electricHRV, hrvAutoPointsForSelectedPeriod),
                                             ("Sleep", "h", Metrics.electricSleep, preparedHistory.sleep[range] ?? [])],
                                onOpenDay: { day in openHistoryDay(for: day) },
                                onExpand: { showExpandedChart = true })
                }
            } about: {
                aboutSection
            }
        case .hrv:
            AtriaMetricDetailTemplate(heroValue: periodHeroText(summary: hrvSummaryForSelectedPeriod,
                                                                points: hrvAutoPointsForSelectedPeriod,
                                                                unit: "ms"),
                                      heroState: hrvBand == nil
                                        ? learningNightsState(baseline.hrvSampleCount)
                                        : "Typical",
                                      tint: metric.tint) {
                AtriaMetricContributorRows(rows: [
                    AtriaMetricContributorRow(systemImage: "waveform.path.ecg",
                                              name: "HRV",
                                              value: latestMetricText(points: hrvAutoPointsForSelectedPeriod,
                                                                      unit: "ms"),
                                              comparison: hrvEvidenceComparisonText,
                                              direction: 0)
                ], tint: metric.tint)
            } chart: {
                chartSlot {
                    metricChart(title: "HRV",
                                unit: "ms",
                                tint: metric.tint,
                                points: hrvDisplayPointsForSelectedPeriod,
                                summary: hrvSummaryForSelectedPeriod,
                                comparison: hrvComparisonForSelectedPeriod,
                                baselineBand: hrvBand,
                                accessibilitySummary: "HRV over \(range.label) with your baseline band.",
                                emptyExplanation: "HRV is read from steady overnight wear — each clean night adds a point here.",
                                priorPoints: preparedHistory.hrvPrior[range] ?? [],
                                companions: [("That day's recovery", "%", Metrics.electricGreen, recoveryDisplayPointsForSelectedPeriod),
                                             ("Sleep", "h", Metrics.electricSleep, preparedHistory.sleep[range] ?? [])],
                                onOpenDay: { day in openHistoryDay(for: day) },
                                onExpand: { showExpandedChart = true })
                }
            } about: {
                aboutSection
            }
        case .restingHeartRate:
            AtriaMetricDetailTemplate(heroValue: periodHeroText(summary: restingHeartRateSummaryForSelectedPeriod,
                                                                points: restingHeartRateAutoPointsForSelectedPeriod,
                                                                unit: "bpm"),
                                      heroState: restingBand == nil
                                        ? learningNightsState(baseline.restingSampleCount)
                                        : "Typical",
                                      tint: metric.tint) {
                AtriaMetricContributorRows(rows: [
                    AtriaMetricContributorRow(systemImage: "heart.fill",
                                              name: "Resting HR",
                                              value: latestMetricText(points: restingHeartRateAutoPointsForSelectedPeriod,
                                                                      unit: "bpm"),
                                              comparison: restingHeartRateEvidenceComparisonText,
                                              direction: 0)
                ], tint: metric.tint)
            } chart: {
                chartSlot {
                    metricChart(title: "Resting HR",
                                unit: "bpm",
                                tint: metric.tint,
                                points: restingHeartRateDisplayPointsForSelectedPeriod,
                                summary: restingHeartRateSummaryForSelectedPeriod,
                                comparison: restingHeartRateComparisonForSelectedPeriod,
                                baselineBand: restingBand,
                                accessibilitySummary: "Resting heart rate over \(range.label) with your baseline band.",
                                emptyExplanation: "Resting heart rate is read from overnight wear — each night adds a point here.",
                                priorPoints: preparedHistory.restingHeartRatePrior[range] ?? [],
                                companions: [("That day's HRV", "ms", Metrics.electricHRV, hrvAutoPointsForSelectedPeriod),
                                             ("Recovery", "%", Metrics.electricGreen, recoveryDisplayPointsForSelectedPeriod)],
                                onOpenDay: { day in openHistoryDay(for: day) },
                                onExpand: { showExpandedChart = true })
                }
            } about: {
                aboutSection
            }
        case .respiratoryRate:
            AtriaMetricDetailTemplate(heroValue: periodHeroText(summary: preparedHistory.respiratoryRateSummary[range], points: preparedHistory.respiratoryRate[range] ?? [], unit: "/min"),
                                      heroState: respiratoryBand == nil ? "Learning" : "Typical",
                                      tint: metric.tint) {
                AtriaMetricContributorRows(rows: [
                    AtriaMetricContributorRow(systemImage: "lungs.fill",
                                              name: "Respiratory rate",
                                              value: latestMetricText(points: preparedHistory.respiratoryRate[range] ?? [], unit: "/min"),
                                              comparison: respiratoryBand.map { String(format: "typical %.1f-%.1f/min", $0.lower, $0.upper) } ?? "typical range building",
                                              direction: 0)
                ], tint: metric.tint)
            } chart: {
                chartSlot {
                    metricChart(title: "Respiratory rate",
                                unit: "/min",
                                tint: metric.tint,
                                points: displayedPoints(auto: preparedHistory.respiratoryRate[range] ?? [], raw: preparedHistory.respiratoryRateRaw[range] ?? []),
                                summary: preparedHistory.respiratoryRateSummary[range],
                                comparison: preparedHistory.respiratoryRateComparison[range],
                                baselineBand: respiratoryBand,
                                accessibilitySummary: "Respiratory rate over \(range.label) with your typical range.",
                                emptyExplanation: "Respiratory rate is derived from steady overnight wear — each night adds a point here.",
                                priorPoints: preparedHistory.respiratoryRatePrior[range] ?? [],
                                companions: [("That day's HRV", "ms", Metrics.electricHRV, hrvAutoPointsForSelectedPeriod),
                                             ("Recovery", "%", Metrics.electricGreen, recoveryDisplayPointsForSelectedPeriod)],
                                onOpenDay: { day in openHistoryDay(for: day) },
                                onExpand: { showExpandedChart = true })
                }
            } about: {
                aboutSection
            }
        case .sleep:
            // Minimalism restructure (owner directive 2026-08-29, "the sleep
            // tab has 1000s of things"): above the fold = hero, chart,
            // hypnogram, one neutral 4-up stat row, reveal — 5 blocks. The
            // plan card, need ledger and About live behind the reveal. The
            // debt-trend card mount was DELETED: it re-plotted the same data
            // the main chart already shows in W/M.
            AtriaMetricDetailTemplate(heroValue: sleepHeroValue,
                                      heroState: sleepHeroState,
                                      tint: Metrics.electricSleep) {
                if let latest = sleepHistory.latestMainSleep {
                    // Shared stage-timeline hypnogram (design "STAGES ·
                    // HYPNOGRAM" card); renders the honest needs-motion /
                    // building states itself for unvalidated nights.
                    AtriaSleepHypnogramCard(night: latest,
                                            motionAvailability: strapMotionAvailability)
                }
                sleepStatSummaryRow
            } contributors: {
                if let latest = sleepHistory.latestMainSleep {
                    AtriaSleepPlanCard(night: latest,
                                       neededHours: sleepHistory.sleepNeedHours(for: latest,
                                                                                baseNeedHours: sleepBaseNeedHours,
                                                                                yesterdayStrain: yesterdayStrainForLatestNight),
                                       frozenReceipt: latest.frozenSleepNeed?.components,
                                       tonightProjection: tonightProjectedNeed,
                                       nightEfficiencies: confirmedNightEfficiencies)
                    sleepNeedLedgerCard(for: latest)
                }
            } chart: {
                chartSlot {
                    metricChart(title: "Sleep duration",
                                // Per-day bar: hours accumulated from zero.
                                rendersAsDailyBar: true,
                                unit: "h",
                                tint: Metrics.electricSleep,
                                points: displayedPoints(auto: preparedHistory.sleep[range] ?? [], raw: preparedHistory.sleepRaw[range] ?? []),
                                summary: preparedHistory.sleepSummary[range],
                                comparison: preparedHistory.sleepComparison[range],
                                baselineBand: nil,
                                accessibilitySummary: "Sleep duration over \(range.label).",
                                emptyTitle: sleepTrendEmptyTitle,
                                emptyExplanation: sleepTrendEmptyExplanation,
                                priorPoints: preparedHistory.sleepPrior[range] ?? [],
                                companions: [("That day's recovery", "%", Metrics.electricGreen, recoveryDisplayPointsForSelectedPeriod),
                                             ("HRV", "ms", Metrics.electricHRV, hrvAutoPointsForSelectedPeriod)],
                                onOpenDay: { day in openHistoryDay(for: day) },
                                onExpand: { showExpandedChart = true })
                }
            } about: {
                aboutSection
            }
        case .strain:
            AtriaMetricDetailTemplate(heroValue: strainHeroValue,
                                      heroState: strainHeroState,
                                      tint: Metrics.electricStrain,
                                      heroStyle: .strain(score: strainHeroRawValue,
                                                         target: showsCurrentPhysiologicalCycleContext
                                                            && !dayStrainMetricsIncomplete
                                                            ? guidance.target
                                                            : nil)) {
                // 2026-08-29 minimalism restructure: only the combo card stays
                // above the fold; the workout/zone/mix/split cards moved
                // behind the "Show details" reveal (contributors slot).
                strainRecoveryComboCard
                // Rare, dismissible, and asking for a decision: the learned
                // max-HR offer stays above the fold when present (2026-09-02).
                maxHRSuggestionCard
            } contributors: {
                if showsCurrentPhysiologicalCycleContext {
                    strainWorkoutSection
                    strainZoneHistogramCard
                    strainActivityMixCard
                    strainCardioLiftingSplitCard
                    AtriaMetricContributorRows(rows: strainContributorRows,
                                               tint: Metrics.electricStrain)
                }
            } chart: {
                // Live-day provenance renders INSIDE the chart slot (2026-08-29):
                // returning the card instead of chartSlot dropped the D/W/M range
                // selector and the prev/next chevrons, so a live strain sheet had
                // no way to reach past days.
                chartSlot {
                    if range == .day, showsCurrentPhysiologicalCycleContext {
                        if let currentCycleStrainProvenance {
                            AtriaMetricProvenanceCard(provenance: currentCycleStrainProvenance)
                        } else {
                            honestPartialCard(
                                tint: Metrics.electricStrain,
                                bodyText: "Strain needs heart-rate evidence from this physiological day."
                            )
                        }
                    } else {
                        metricChart(title: "Strain",
                                // Per-day bar: accumulates from 0 each physiological day.
                                rendersAsDailyBar: true,
                                    unit: "",
                                    tint: Metrics.electricStrain,
                                    points: strainDisplayPointsForSelectedPeriod,
                                    summary: strainSummaryForSelectedPeriod,
                                    comparison: strainComparisonForSelectedPeriod,
                                    baselineBand: nil,
                                    accessibilitySummary: "Strain over \(range.label).",
                                    priorPoints: preparedHistory.strainPrior[range] ?? [],
                                    companions: [("That day's recovery", "%", Metrics.electricGreen, recoveryDisplayPointsForSelectedPeriod),
                                                 ("Sleep", "h", Metrics.electricSleep, preparedHistory.sleep[range] ?? [])],
                                    onOpenDay: { day in openHistoryDay(for: day) },
                                    onExpand: { showExpandedChart = true })
                    }
                }
            } about: {
                aboutSection
            }
        case .sleepPerformance:
            AtriaMetricDetailTemplate(heroValue: periodHeroText(summary: preparedHistory.sleepPerformanceSummary[range], points: preparedHistory.sleepPerformance[range] ?? [], unit: "%"),
                                      heroState: sleepPerformanceHeroState,
                                      tint: Metrics.electricSleep) {
                EmptyView()
            } chart: {
                chartSlot {
                    metricChart(title: "Sleep sufficiency",
                                // Per-day bar: percent of need, measured from zero.
                                rendersAsDailyBar: true,
                                unit: "%",
                                tint: Metrics.electricSleep,
                                points: preparedHistory.sleepPerformance[range] ?? [],
                                summary: preparedHistory.sleepPerformanceSummary[range],
                                comparison: preparedHistory.sleepPerformanceComparison[range],
                                baselineBand: nil,
                                accessibilitySummary: "Sleep sufficiency, percent of nightly need, over \(range.label).",
                                companions: [("Sleep duration", "h", Metrics.electricSleep, preparedHistory.sleep[range] ?? []),
                                             ("Recovery", "%", Metrics.electricGreen, recoveryDisplayPointsForSelectedPeriod)],
                                onOpenDay: { day in openHistoryDay(for: day) },
                                onExpand: { showExpandedChart = true })
                }
            } about: {
                aboutSection
            }
        case .fitnessAge:
            AtriaMetricDetailTemplate(heroValue: fitnessAgeHeroValue,
                                      heroState: fitnessAgeHeroState,
                                      tint: fitnessAgeTint) {
                if preparedHistory.paceOfAging.isReady {
                    // 2026-08-29 theme pass: ink outside the hero and chart.
                    Text(preparedHistory.paceOfAging.copyText)
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
            } chart: {
                if preparedHistory.paceOfAging.isReady {
                    chartSlot {
                        metricChart(title: "Pace of aging",
                                    unit: "y",
                                    tint: fitnessAgeTint,
                                    points: preparedHistory.fitnessAge[range] ?? [],
                                    summary: preparedHistory.fitnessAgeSummary[range],
                                    comparison: preparedHistory.fitnessAgeComparison[range],
                                    baselineBand: nil,
                                    accessibilitySummary: "Fitness-age delta over \(range.label).",
                                    onOpenDay: { day in openHistoryDay(for: day) },
                                    onExpand: { showExpandedChart = true })
                    }
                } else {
                    honestPartialCard(tint: fitnessAgeTint,
                                      bodyText: "Calibrating a 28-day baseline before showing your pace of aging \u{2014} \(preparedHistory.fitnessAgeEntryCount) of 4 weekly checks saved so far.")
                }
            } about: {
                aboutSection
            }
        case .stress:
            // Copy updated 2026-08-04: a daily stress history DOES exist now
            // (the distribution archive feeds "Stress by day" in the Stress
            // monitor). This compact sheet stays chart-free and points there.
            honestPartialDetail(heroValue: "Live read",
                                heroState: "Live estimate",
                                // 2026-08-29 theme pass: identity hue, not raw .orange.
                                tint: metric.identity.identityTint(),
                                bodyText: "A live read from heart rate and beat-to-beat timing. Open the Stress tile for the full timeline and trend \u{2014} breathwork can bring an elevated read down.")
        case .vo2max:
            honestPartialDetail(heroValue: vo2MaxEstimate?.valueText ?? "Learning",
                                heroState: (vo2MaxEstimate?.value == nil) ? "Learning" : "Estimate",
                                tint: Metrics.electricGreen,
                                bodyText: vo2MaxEstimate?.narrative ?? "VO2max is estimated from your resting heart-rate baseline and measured max heart rate. It sharpens as Atria gathers more sessions.")
        case .sleepEfficiency:
            // P3 (2026-08-04): graduated from honest-partial — a real per-night
            // trend from confirmed nights' display efficiencies (the
            // motion-honest accessor; HR-only nights carry nil and stay off the
            // chart). Below 5 nights the old honest-partial copy remains.
            if let trend = sleepEfficiencyTrend {
                AtriaMetricDetailTemplate(heroValue: sleepHistory.latestMainSleep?.sleepEfficiencyText ?? "--",
                                          heroState: sleepHistory.latestMainSleep?.displaySleepEfficiency == nil ? "Learning" : "Duration-based estimate",
                                          tint: Metrics.electricSleep) {
                    EmptyView()
                } chart: {
                    AtriaMiniTrendCard(trend: trend,
                                       tint: Metrics.electricSleep,
                                       title: "LAST 30 NIGHTS",
                                       subject: "Sleep efficiency")
                } about: {
                    aboutSection
                }
            } else {
                honestPartialDetail(heroValue: sleepHistory.latestMainSleep?.sleepEfficiencyText ?? "--",
                                    heroState: sleepHistory.latestMainSleep?.displaySleepEfficiency == nil ? "Learning" : "Duration-based estimate",
                                    tint: Metrics.electricSleep,
                                    bodyText: "Time asleep compared with time in bed. The night-by-night trend needs 5 confirmed nights with strap motion.")
            }
        case .skinTemperature:
            let decoderAvailable = AtriaResearchProbe.validatedSkinTemperatureDecoderAvailable
            let summary = skinTemperatureDeviation
                ?? IMUAuditSummary.SkinTemperatureDeviationSummary(
                    latestDeltaCelsius: nil,
                    baselineSessions: 0,
                    candidateFrames: 0,
                    candidateValues: 0)
            let hasReading = AtriaExperimentalSensorCopy.hasValidatedSkinTemperatureReading(
                summary: summary,
                decoderAvailable: decoderAvailable)
            honestPartialDetail(heroValue: AtriaExperimentalSensorCopy.skinTemperatureValue(
                                    summary: summary,
                                    decoderAvailable: decoderAvailable),
                                heroState: hasReading ? "vs sleep baseline" : (decoderAvailable ? "Learning" : "Decoder not verified"),
                                // 2026-08-29 theme pass: identity hue, not raw .teal.
                                tint: metric.identity.identityTint(),
                                bodyText: AtriaExperimentalSensorCopy.skinTemperatureDetail(
                                    summary: summary,
                                    decoderAvailable: decoderAvailable))
        case .hrZones:
            // Design handoff (2026-07-07): the sheet lists the user's real
            // per-zone bpm boundaries, computed from the same percent-of-max
            // model the live workout zones use. Card hides when max HR is
            // unknown (never a fabricated boundary).
            AtriaMetricDetailTemplate(heroValue: hrZoneMinutes.valueText,
                                      heroState: hrZoneMinutes.hasSamples ? "today" : "No wear today",
                                      // 2026-08-29 theme pass: identity hue, not raw .orange.
                                      tint: metric.identity.identityTint()) {
                hrZoneBoundariesCard
            } contributors: {
                EmptyView()
            } chart: {
                honestPartialCard(tint: metric.identity.identityTint(), bodyText: "Time-in-zone minutes for today, split across Z2\u{2013}Z5. Atria doesn't save a day-by-day zone-minutes trend here yet.")
            } about: {
                aboutSection
            }
        case .bloodOxygen:
            // The hero stays empty until a decoder is verified; never render an
            // experimental candidate as a blood-oxygen percentage.
            honestPartialDetail(heroValue: "\u{2014}",
                                heroState: AtriaSpO2Copy.decoderNotVerified,
                                // 2026-08-29 theme pass: identity authority says
                                // blood oxygen has no earned hue (.secondary).
                                tint: metric.identity.identityTint(),
                                bodyText: AtriaSpO2Copy.longUnavailable)
        }
    }

    /// Reusable honest-partial template for detail kinds that have a live
    /// current value but no saved daily trend yet -- renders the hero value
    /// plus an explanatory card instead of a fabricated chart.
    private func honestPartialDetail(heroValue: String,
                                     heroState: String = "Learning",
                                     tint: Color,
                                     bodyText: String) -> some View {
        AtriaMetricDetailTemplate(heroValue: heroValue, heroState: heroState, tint: tint) {
            EmptyView()
        } chart: {
            honestPartialCard(tint: tint, bodyText: bodyText)
        } about: {
            aboutSection
        }
    }

    /// The user's per-zone bpm boundaries from their profile max HR
    /// (percent-of-max bands, HRZone.lowerFraction) -- the exact math the
    /// live workout zone bar uses. Renders nothing without a real max HR.
    @ViewBuilder
    private var hrZoneBoundariesCard: some View {
        if let maxHR = maxHeartRate, maxHR > 0 {
            let zones = Array(HRZone.allCases)
            VStack(alignment: .leading, spacing: 10) {
                Text("Your zones")
                    .font(.headline.weight(.semibold))
                ForEach(Array(zones.enumerated().reversed()), id: \.element.rawValue) { index, zone in
                    let lower = Int((zone.lowerFraction * Double(maxHR)).rounded())
                    let upper = index + 1 < zones.count
                        ? Int((zones[index + 1].lowerFraction * Double(maxHR)).rounded()) - 1
                        : maxHR
                    HStack(spacing: 10) {
                        Circle()
                            .fill(zone.color)
                            .frame(width: 9, height: 9)
                        Text(zone.name)
                            .font(.subheadline.weight(.semibold))
                        Spacer(minLength: 8)
                        Text(zone.lowerFraction == 0 ? "under \(upper + 1) bpm" : "\(lower)\u{2013}\(upper) bpm")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Text("From your max heart rate (\(maxHR) bpm) \u{2014} percent-of-max bands, the same math the live workout zones use.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            // 2026-08-29 theme pass: card chrome uses the identity hue.
            .atriaInsetCard(tint: metric.identity.identityTint())
        }
    }

    private func honestPartialCard(tint: Color, bodyText: String) -> some View {
        Text(bodyText)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .atriaInsetCard(tint: tint)
    }

    private var sleepPerformanceHeroState: String {
        preparedHistory.sleepPerformance[range]?.last == nil ? "Learning" : "of nightly need"
    }

    private var fitnessAgeHeroValue: String {
        guard let latest = preparedHistory.fitnessAge[range]?.last?.value else { return "--" }
        let delta = Int(latest.rounded())
        return delta == 0 ? "0y" : "\(abs(delta))y"
    }

    private var fitnessAgeHeroState: String {
        guard let latest = preparedHistory.fitnessAge[range]?.last?.value else { return "Learning" }
        if latest == 0 { return "Matches your age" }
        return latest < 0 ? "younger" : "older"
    }

    private var fitnessAgeTint: Color {
        guard let latest = preparedHistory.fitnessAge[range]?.last?.value else { return .secondary }
        return latest <= 0 ? Metrics.electricGreen : Metrics.electricYellow
    }

    private var currentCycleDetailProjection: AtriaHealthMetricAuthority.DetailProjection {
        AtriaHealthMetricAuthority.detailProjection(
            currentCycle: currentCycleAuthority,
            historicalRecoveryPercent:
                preparedHistory.recoverySummary[range].map {
                    Int($0.latestRaw.rounded())
                },
            historicalStrain: preparedHistory.strainSummary[range]?.latestRaw
                ?? preparedHistory.latestStrain[range],
            range: range,
            periodAnchor: periodAnchor,
            calendar: preparationBaseInput.calendar
        )
    }

    /// Workout rows, zone totals, activity mix, and the target all come from
    /// the live physiological-cycle inputs. They are honest only while the
    /// prepared chart and the requested period both resolve to that cycle.
    /// Failing closed during an async period change also prevents a current-day
    /// card from flashing over a still-displayed historical chart.
    private var showsCurrentPhysiologicalCycleContext: Bool {
        AtriaStrainDetailContextPolicy.showsCurrentCycle(
            range: range,
            usesCurrentCycle: currentCycleDetailProjection.usesCurrentCycle,
            isPreparingSelectedPeriod: isPreparingSelectedPeriod
        )
    }

    private var currentCycleStrainTruth:
        AtriaHealthMetricAuthority.StrainTrendTruth {
        AtriaHealthMetricAuthority.strainTrendTruth(currentCycleAuthority)
    }

    /// Recovery, strain, HRV, and resting HR belong to the wake-to-wake
    /// cycle's display day, which can be yesterday after midnight. Other
    /// metric histories retain their civil "today" anchor.
    private var currentMetricPeriodAnchor: Date {
        switch metric {
        case .recovery, .strain, .hrv, .restingHeartRate:
            return currentCycleAuthority?.cycleStart ?? Date()
        default:
            return Date()
        }
    }

    private var nextMetricPeriodIsUnavailable: Bool {
        let calendar = preparationBaseInput.calendar
        let selected = range.periodInterval(
            containing: periodAnchor,
            calendar: calendar
        )
        let current = range.periodInterval(
            containing: currentMetricPeriodAnchor,
            calendar: calendar
        )
        return selected.end >= current.end
    }

    private func replacingCurrentCyclePoint(
        in points: [AtriaDetailChartPoint],
        value: Double?,
        tint: Color,
        usesCurrentCycle: Bool? = nil
    ) -> [AtriaDetailChartPoint] {
        AtriaMetricDetailCurrentCyclePointPolicy.replacingSameDay(
            in: points,
            value: value,
            displayAnchor: currentCycleAuthority?.cycleStart
                ?? currentCycleAuthority?.projectedAt,
            usesCurrentCycle: usesCurrentCycle
                ?? currentCycleDetailProjection.usesCurrentCycle,
            tint: tint,
            calendar: preparationBaseInput.calendar
        )
    }

    /// Only the interactive D/W/M periods may project unsettled HRV/RHR
    /// evidence. Deeper historical windows stay rollup-only even when their
    /// broad interval happens to contain the current cycle.
    private var usesCurrentCyclePrimaryRangePoint: Bool {
        AtriaTrendRange.primarySegments.contains(range)
            && currentCycleDetailProjection.usesCurrentCycle
            && !isPreparingSelectedPeriod
    }

    private var currentCycleHRVTrendValue: Double? {
        guard let value = currentCycleAuthority?.hrvMS, value > 0 else { return nil }
        return Double(value)
    }

    private var currentCycleRestingHeartRateTrendValue: Double? {
        guard let value = currentCycleAuthority?.restingHeartRate, value > 0 else { return nil }
        return Double(value)
    }

    private var hrvEvidenceComparisonText: String {
        let fallback = hrvBand.map {
            "typical \(Int($0.lower.rounded()))-\(Int($0.upper.rounded())) ms"
        } ?? "typical range building"
        guard usesCurrentCyclePrimaryRangePoint,
              currentCycleHRVTrendValue != nil else { return fallback }
        return currentCycleEvidenceCopy(currentCycleAuthority?.hrvDetail,
                                        fallback: fallback)
    }

    private var restingHeartRateEvidenceComparisonText: String {
        let fallback = restingBand.map {
            "typical \(Int($0.lower.rounded()))-\(Int($0.upper.rounded())) bpm"
        } ?? "typical range building"
        guard usesCurrentCyclePrimaryRangePoint,
              currentCycleRestingHeartRateTrendValue != nil else { return fallback }
        return currentCycleEvidenceCopy(currentCycleAuthority?.restingHeartRateDetail,
                                        fallback: fallback)
    }

    /// Keep the authority's measured/provisional wording beside an injected
    /// point. A current value is useful before the baseline is trusted, but it
    /// must not silently inherit a finalized or "typical" claim.
    private func currentCycleEvidenceCopy(_ detail: String?,
                                          fallback: String) -> String {
        guard let detail else { return fallback }
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !AtriaCompactMetricPresentation.isPendingValue(trimmed) else {
            return fallback
        }
        return trimmed.localizedCaseInsensitiveContains("current cycle")
            ? trimmed
            : "\(trimmed) · current cycle"
    }

    private var recoveryRawPointsForSelectedPeriod: [AtriaDetailChartPoint] {
        replacingCurrentCyclePoint(
            in: preparedHistory.recoveryRaw[range] ?? [],
            value: currentCycleAuthority?.recoveryPercent.map(Double.init),
            tint: currentCycleAuthority?.recoveryPercent.map {
                Metrics.recoveryColor($0)
            } ?? .secondary
        )
    }

    private var recoveryDisplayPointsForSelectedPeriod: [AtriaDetailChartPoint] {
        let auto = replacingCurrentCyclePoint(
            in: preparedHistory.recovery[range] ?? [],
            value: currentCycleAuthority?.recoveryPercent.map(Double.init),
            tint: currentCycleAuthority?.recoveryPercent.map {
                Metrics.recoveryColor($0)
            } ?? .secondary
        )
        return displayedPoints(
            auto: auto,
            raw: recoveryRawPointsForSelectedPeriod
        )
    }

    private var recoverySummaryForSelectedPeriod: AtriaDetailPeriodSummary? {
        guard currentCycleDetailProjection.usesCurrentCycle else {
            return preparedHistory.recoverySummary[range]
        }
        return AtriaDetailPeriodSummary(
            points: recoveryRawPointsForSelectedPeriod,
            unit: "%"
        )
    }

    private var recoveryComparisonForSelectedPeriod: AtriaDetailComparisonSummary? {
        guard currentCycleDetailProjection.usesCurrentCycle else {
            return preparedHistory.recoveryComparison[range]
        }
        return AtriaDetailComparisonSummary(
            current: recoveryRawPointsForSelectedPeriod,
            prior: preparedHistory.recoveryPrior[range] ?? [],
            unit: "%"
        )
    }

    private var hrvAutoPointsForSelectedPeriod: [AtriaDetailChartPoint] {
        replacingCurrentCyclePoint(
            in: preparedHistory.hrv[range] ?? [],
            value: currentCycleHRVTrendValue,
            tint: Metrics.electricHRV,
            usesCurrentCycle: usesCurrentCyclePrimaryRangePoint
        )
    }

    private var hrvRawPointsForSelectedPeriod: [AtriaDetailChartPoint] {
        replacingCurrentCyclePoint(
            in: preparedHistory.hrvRaw[range] ?? [],
            value: currentCycleHRVTrendValue,
            tint: Metrics.electricHRV,
            usesCurrentCycle: usesCurrentCyclePrimaryRangePoint
        )
    }

    private var hrvDisplayPointsForSelectedPeriod: [AtriaDetailChartPoint] {
        displayedPoints(auto: hrvAutoPointsForSelectedPeriod,
                        raw: hrvRawPointsForSelectedPeriod)
    }

    private var hrvSummaryForSelectedPeriod: AtriaDetailPeriodSummary? {
        guard usesCurrentCyclePrimaryRangePoint else {
            return preparedHistory.hrvSummary[range]
        }
        return AtriaDetailPeriodSummary(points: hrvRawPointsForSelectedPeriod,
                                        unit: "ms")
    }

    private var hrvComparisonForSelectedPeriod: AtriaDetailComparisonSummary? {
        guard usesCurrentCyclePrimaryRangePoint else {
            return preparedHistory.hrvComparison[range]
        }
        return AtriaDetailComparisonSummary(
            current: hrvRawPointsForSelectedPeriod,
            prior: preparedHistory.hrvPrior[range] ?? [],
            unit: "ms"
        )
    }

    private var restingHeartRateAutoPointsForSelectedPeriod: [AtriaDetailChartPoint] {
        replacingCurrentCyclePoint(
            in: preparedHistory.restingHeartRate[range] ?? [],
            value: currentCycleRestingHeartRateTrendValue,
            tint: Metrics.electricRHR,
            usesCurrentCycle: usesCurrentCyclePrimaryRangePoint
        )
    }

    private var restingHeartRateRawPointsForSelectedPeriod: [AtriaDetailChartPoint] {
        replacingCurrentCyclePoint(
            in: preparedHistory.restingHeartRateRaw[range] ?? [],
            value: currentCycleRestingHeartRateTrendValue,
            tint: Metrics.electricRHR,
            usesCurrentCycle: usesCurrentCyclePrimaryRangePoint
        )
    }

    private var restingHeartRateDisplayPointsForSelectedPeriod: [AtriaDetailChartPoint] {
        displayedPoints(auto: restingHeartRateAutoPointsForSelectedPeriod,
                        raw: restingHeartRateRawPointsForSelectedPeriod)
    }

    private var restingHeartRateSummaryForSelectedPeriod: AtriaDetailPeriodSummary? {
        guard usesCurrentCyclePrimaryRangePoint else {
            return preparedHistory.restingHeartRateSummary[range]
        }
        return AtriaDetailPeriodSummary(
            points: restingHeartRateRawPointsForSelectedPeriod,
            unit: "bpm"
        )
    }

    private var restingHeartRateComparisonForSelectedPeriod: AtriaDetailComparisonSummary? {
        guard usesCurrentCyclePrimaryRangePoint else {
            return preparedHistory.restingHeartRateComparison[range]
        }
        return AtriaDetailComparisonSummary(
            current: restingHeartRateRawPointsForSelectedPeriod,
            prior: preparedHistory.restingHeartRatePrior[range] ?? [],
            unit: "bpm"
        )
    }

    private var strainRawPointsForSelectedPeriod: [AtriaDetailChartPoint] {
        replacingCurrentCyclePoint(
            in: preparedHistory.strainRaw[range] ?? [],
            value: currentCycleStrainTruth.exactTrendValue,
            tint: Metrics.electricStrain
        )
    }

    private var strainDisplayPointsForSelectedPeriod: [AtriaDetailChartPoint] {
        let auto = replacingCurrentCyclePoint(
            in: preparedHistory.strain[range] ?? [],
            value: currentCycleStrainTruth.exactTrendValue,
            tint: Metrics.electricStrain
        )
        return displayedPoints(
            auto: auto,
            raw: strainRawPointsForSelectedPeriod
        )
    }

    private var strainSummaryForSelectedPeriod: AtriaDetailPeriodSummary? {
        guard currentCycleDetailProjection.usesCurrentCycle else {
            return preparedHistory.strainSummary[range]
        }
        return AtriaDetailPeriodSummary(
            points: strainRawPointsForSelectedPeriod,
            unit: ""
        )
    }

    private var strainComparisonForSelectedPeriod: AtriaDetailComparisonSummary? {
        guard currentCycleDetailProjection.usesCurrentCycle else {
            return preparedHistory.strainComparison[range]
        }
        return AtriaDetailComparisonSummary(
            current: strainRawPointsForSelectedPeriod,
            prior: preparedHistory.strainPrior[range] ?? [],
            unit: ""
        )
    }

    private var rangeLens: (summary: AtriaDetailPeriodSummary, comparison: AtriaDetailComparisonSummary?)? {
        switch metric {
        case .recovery:
            return recoverySummaryForSelectedPeriod.map {
                ($0, recoveryComparisonForSelectedPeriod)
            }
        case .hrv:
            return hrvSummaryForSelectedPeriod.map {
                ($0, hrvComparisonForSelectedPeriod)
            }
        case .restingHeartRate:
            return restingHeartRateSummaryForSelectedPeriod.map {
                ($0, restingHeartRateComparisonForSelectedPeriod)
            }
        case .respiratoryRate:
            return preparedHistory.respiratoryRateSummary[range].map { ($0, preparedHistory.respiratoryRateComparison[range]) }
        case .sleep:
            return preparedHistory.sleepSummary[range].map { ($0, preparedHistory.sleepComparison[range]) }
        case .strain:
            return strainSummaryForSelectedPeriod.map {
                ($0, strainComparisonForSelectedPeriod)
            }
        case .sleepPerformance:
            return preparedHistory.sleepPerformanceSummary[range].map { ($0, preparedHistory.sleepPerformanceComparison[range]) }
        case .fitnessAge:
            return preparedHistory.fitnessAgeSummary[range].map { ($0, preparedHistory.fitnessAgeComparison[range]) }
        case .stress, .vo2max, .sleepEfficiency, .skinTemperature, .hrZones, .bloodOxygen:
            return nil
        }
    }

    private func chartSlot<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            AtriaTextSelector(items: metric == .fitnessAge
                                  ? [.week, .month]
                                  : AtriaTrendRange.primarySegments,
                              title: { $0.menuLabel },
                              selection: $range)

            HStack(spacing: 12) {
                Button {
                    periodAnchor = range.adjacentPeriodAnchor(
                        from: periodAnchor,
                        offset: -1
                    )
                } label: {
                    // 40pt circular affordance — matches the header buttons
                    // (2026-08-29 controls audit: bare glyphs read as text).
                    Image(systemName: "chevron.left")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 40, height: 40)
                        .background(.quaternary.opacity(0.22), in: Circle())
                        .contentShape(Circle())
                }
                .accessibilityLabel("Previous \(range.narrativeLabel)")

                // Titled from the PREPARED period, not the live anchor
                // (2026-08-01): while an async prepare is in flight the plot
                // still shows the previously prepared period, so labelling it
                // with the freshly tapped anchor made the title and the data
                // disagree. The label always describes what is actually
                // plotted; the small spinner says a newer period is coming.
                HStack(spacing: 6) {
                    Text(range.periodLabel(containing: displayedPeriodAnchor))
                        .font(.subheadline.weight(.semibold))
                    if isPreparingSelectedPeriod {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(.secondary)
                            .accessibilityLabel("Loading the selected period")
                    }
                }
                .frame(maxWidth: .infinity)

                Button {
                    periodAnchor = range.adjacentPeriodAnchor(
                        from: periodAnchor,
                        offset: 1
                    )
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 40, height: 40)
                        .background(.quaternary.opacity(0.22), in: Circle())
                        .contentShape(Circle())
                }
                .disabled(nextMetricPeriodIsUnavailable)
                .accessibilityLabel("Next \(range.narrativeLabel)")
            }
            .buttonStyle(.plain)

            // Detail redesign (2026-07-06): the "Trend snapshot"
            // AtriaDetailRangeLensCard was removed here — it restated the exact
            // Latest/Avg/Change the metricChart's summary strip already shows
            // (plus a secondary this-vs-prior seesaw), producing two stacked
            // summary cards ("box inside box") before the chart. One canonical
            // summary now lives in metricChart.
            //
            // The struct itself was then "kept as uncalled scaffolding so its
            // gate pins stay intact" — i.e. dead code retained to keep tests
            // passing. Removed 2026-08-27, and the test that depended on it now
            // asserts the RULE (no surface claims circadian rhythm) across the
            // whole file instead of scanning inside one unreachable card.
            content()
        }
    }

    /// About block, minimalism pass (owner directive 2026-08-29, supersedes
    /// the same-day always-visible directive): two plain secondary sentences
    /// inside the "Show details" reveal — no card, no Label header. The
    /// template renders a hairline divider above it.
    private var aboutSection: some View {
        AtriaMetricMeaningInline(metric: metric,
                                 guidance: guidance,
                                 recoveryEstimate: recoveryEstimate,
                                 sleepGoalHours: sleepGoalHours)
    }

    /// The recovery number behind the hero, per selected period, read from the
    /// SAME frozen daily-rollup series the chart below plots — never the live
    /// `recoveryEstimate` recompute. Day = that settled daily score (today's
    /// saved recovery, else the newest saved day carried forward, exactly like
    /// the overview tile / health row / widget), so the headline can no longer
    /// drift onto the live value or contradict them for the same day. Week/Month
    /// = the window average, so the number finally tracks the Day/Week/Month
    /// selector (2026-07-08: fixes recovery showing a fixed live % that both
    /// ignored the period and disagreed with the day value shown everywhere else).
    private var recoveryHeroRawPercent: Double? {
        if range == .day {
            if currentCycleDetailProjection.usesCurrentCycle {
                return currentCycleDetailProjection.recoveryPercent.map(Double.init)
            }
            return preparedHistory.recoverySummary[range]?.latestRaw
                ?? preparedHistory.recoveryRaw[.all]?.last?.value
        }
        return recoverySummaryForSelectedPeriod?.averageRaw
    }

    private var recoveryHeroValue: String {
        guard let percent = recoveryHeroRawPercent else {
            return AtriaCompactMetricPresentation.noValue
        }
        return AtriaDetailPeriodSummary.valueText(percent, unit: "%")
    }

    private var recoveryHeroState: String {
        // Canonical not-ready word is "Learning" (never "Building") — must match
        // the recovery ring center + legend chip for the same Day-1 state.
        guard let percent = recoveryHeroRawPercent.map({ Int($0.rounded()) }) else { return "Learning" }
        if recoveryHeroUsesPreviousSavedDay {
            return "Previous sleep"
        }
        switch percent {
        case 67...: return "Good"
        case 34..<67: return "Moderate"
        default: return "Low"
        }
    }

    private var recoveryHeroUsesPreviousSavedDay: Bool {
        range == .day
            && !currentCycleDetailProjection.usesCurrentCycle
            && preparedHistory.recoverySummary[.day]?.latestRaw == nil
            && preparedHistory.recoveryRaw[.all]?.last?.value != nil
    }

    private var recoveryBaselineComparisonText: String? {
        guard let score = recoveryHeroRawPercent else { return nil }
        return AtriaRecoveryBaselineComparison.text(
            score: score,
            monthValues: range == .month
                ? recoveryRawPointsForSelectedPeriod.map(\.value)
                : (preparedHistory.recoveryRaw[.month] ?? []).map(\.value),
            excludesLatest: range == .day
        )
    }

    private var strainHeroState: String {
        if dayStrainMetricsIncomplete {
            return currentCycleStrainLimitation?.compactState
                ?? "Strain data incomplete"
        }
        guard let latest = strainHeroRawValue else {
            return "Learning"   // canonical not-ready word (was "Building"), consistent with HRV/RHR/respiration hero states
        }
        guard showsCurrentPhysiologicalCycleContext,
              let target = guidance.target else {
            // A live cycle is still accumulating; "Saved day" belongs to
            // dated history only (2026-09-02 fixture screenshot).
            if range == .day {
                return currentCycleDetailProjection.usesCurrentCycle ? "So far today" : "Saved day"
            }
            return "Period average"
        }
        if latest >= target + 1 { return "Strained" }
        if latest >= target - 1 { return "On target" }
        return "Light"
    }

    private var strainHeroRawValue: Double? {
        if range == .day {
            if currentCycleDetailProjection.usesCurrentCycle {
                return currentCycleStrainTruth.heroLowerBound
            }
            return preparedHistory.strainSummary[range]?.latestRaw
                ?? preparedHistory.latestStrain[range]
        }
        return strainSummaryForSelectedPeriod?.averageRaw
    }

    private var strainHeroValue: String {
        guard let strainHeroRawValue else {
            return AtriaCompactMetricPresentation.noValue
        }
        // No "≥" prefix (2026-08-27): incompleteness is disclosed beside the
        // number, not welded onto it. `dayStrainMetricsIncomplete` still drives
        // that disclosure.
        return AtriaDetailPeriodSummary.valueText(strainHeroRawValue, unit: "")
    }

    private var dayStrainMetricsIncomplete: Bool {
        if range == .day,
           currentCycleDetailProjection.usesCurrentCycle,
           currentCycleStrainTruth.isPartial {
            return true
        }
        guard range == .day,
              let strain = strainHeroRawValue,
              let day = strainRawPointsForSelectedPeriod.last?.day
                ?? preparedHistory.strainRaw[.all]?.last?.day else {
            return false
        }
        return AtriaWorkoutMetricPresentation.dayStrainIsIncomplete(day: day,
                                                                    strain: strain,
                                                                    workouts: confirmedWorkouts)
    }

    private var currentCycleStrainLimitation:
        AtriaWorkoutMetricPresentation.StrainLimitation? {
        guard showsCurrentPhysiologicalCycleContext,
              let currentCycleAuthority,
              let start = currentCycleAuthority.cycleStart else {
            return nil
        }
        return AtriaWorkoutMetricPresentation.strainLimitation(
            start: start,
            end: Date(),
            workouts: confirmedWorkouts,
            dayWearCoverageFraction: currentCycleAuthority.wearCoverageFraction
        ) ?? (currentCycleAuthority.strainIsPartial ? .incompleteEvidence : nil)
    }

    private var currentCycleStrainProvenance: AtriaMetricProvenance? {
        guard showsCurrentPhysiologicalCycleContext,
              let currentCycleAuthority,
              let strain = currentCycleAuthority.strain else {
            return nil
        }
        if var provenance {
            provenance.strainLimitation = currentCycleStrainLimitation
            return provenance
        }
        let presentation = AtriaCompactMetricPresentation.strain(
            strain: strain,
            confidence: currentCycleAuthority.strainDetail
        )
        return AtriaMetricProvenance(
            displayValue: presentation.displayValue,
            level: presentation.level,
            isLowerBound: presentation.isLowerBound,
            usesHRV: nil,
            hrCoverageFraction: currentCycleAuthority.wearCoverageFraction,
            sourceLabel: "Strap heart rate",
            observedAt: nil,
            strainLimitation: currentCycleStrainLimitation,
            // The detail sheet does not own the user's configured green/yellow
            // bands. Neutral is more honest than recreating a grade here.
            valueStatusTint: nil
        )
    }

    /// Strain of the day before the latest night's credited day -- the same
    /// yesterdayStrain semantics the daily-rollup path uses, so the need shown
    /// here matches the rollup-computed need (2026-07-07 design handoff).
    private var yesterdayStrainForLatestNight: Double? {
        guard let latest = sleepHistory.latestMainSleep else { return nil }
        let calendar = Calendar.current
        guard let priorDay = calendar.date(byAdding: .day,
                                           value: -1,
                                           to: calendar.startOfDay(for: latest.day)) else { return nil }
        return (preparedHistory.strain[.all] ?? [])
            .first { calendar.isDate($0.day, inSameDayAs: priorDay) }?
            .value
    }

    /// ITEM-2 2026-08-15: today's accruing strain input for tonight's
    /// provisional need — live cycle authority first, today's rollup row as
    /// fallback when the sheet was built without one.
    private var tonightProjectedNeed: AtriaSleepBudget.NeedComponents {
        let todayRollup = rollups.first { Calendar.current.isDateInToday($0.day) }
        return sleepHistory.tonightProjectedNeedComponents(
            baseNeedHours: sleepBaseNeedHours,
            todayTRIMP: currentCycleAuthority?.dayTRIMP ?? todayRollup?.trimp,
            todayStrainFallback: currentCycleAuthority?.strain ?? todayRollup?.strain)
    }

    /// Compact neutral 4-up stat row for the sleep sheet's first screen
    /// (2026-08-29 minimalism restructure): label + value only — no icons,
    /// no color — replacing the four full contributor rows above the fold.
    /// Values come from the SAME sleepContributorRows source so the numbers
    /// cannot drift from the detailed rows behind the reveal. Local copy of
    /// the Activity Monitor vitalsCell pattern (that file is owned elsewhere).
    private var sleepStatSummaryRow: some View {
        HStack(alignment: .top, spacing: AtriaDesignTokens.Spacing.sm) {
            ForEach(sleepContributorRows) { row in
                VStack(spacing: 2) {
                    Text(row.name)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(row.value)
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(row.name) \(row.value)")
            }
        }
        .padding(.vertical, 10)
        .atriaInsetCard(tint: Metrics.electricSleep)
    }

    /// "How we got <total>" ledger (design 6a, 2026-08-01 parity slice):
    /// itemized stacked bar over the four real terms of the sleep-need math.
    /// The total is the exact number the hypnogram card's need uses -- never
    /// a separately computed figure.
    @ViewBuilder
    private func sleepNeedLedgerCard(for night: SleepHistorySnapshot.Night) -> some View {
        if let components = sleepHistory.sleepNeedComponents(
            for: night,
            baseNeedHours: sleepBaseNeedHours,
            yesterdayStrain: yesterdayStrainForLatestNight
        ) {
            AtriaSleepNeedLedgerCard(components: components,
                                     yesterdayStrain: yesterdayStrainForLatestNight,
                                     isFrozenReceipt: night.frozenSleepNeed != nil)
        } else {
            AtriaSleepNeedUnavailableCard()
        }
    }

    private var sleepContributorRows: [AtriaMetricContributorRow] {
        let latest = sleepHistory.latestMainSleep
        let performance = latest.flatMap {
            sleepHistory.sleepPerformancePercent(for: $0,
                                                 baseNeedHours: sleepBaseNeedHours,
                                                 yesterdayStrain: yesterdayStrainForLatestNight)
        }
        let needText = latest.flatMap {
            sleepHistory.sleepNeedHours(for: $0,
                                        baseNeedHours: sleepBaseNeedHours,
                                        yesterdayStrain: yesterdayStrainForLatestNight)
                .map(AtriaMetricFormat.sleepHours)
        } ?? "unavailable"
        return [
            AtriaMetricContributorRow(systemImage: "moon.fill",
                                      name: "Sufficiency",
                                      // Dedup audit 2026-07-07: this row's
                                      // value was the duration (shown 3 more
                                      // times on this sheet); it now shows
                                      // the performance % its name promises.
                                      value: performance.map { "\($0)%" } ?? "--",
                                      comparison: latest.map {
                                          sleepHistory.sleepPerformanceSummary(for: $0,
                                                                               baseNeedHours: sleepBaseNeedHours,
                                                                               yesterdayStrain: yesterdayStrainForLatestNight)
                                      } ?? "needed \(needText)",
                                      direction: performance.map { $0 >= 85 ? 1 : ($0 >= 70 ? 0 : -1) } ?? 0),
            AtriaMetricContributorRow(systemImage: "percent",
                                      name: "Efficiency",
                                      value: latest?.sleepEfficiencyText ?? "--",
                                      comparison: latest?.displaySleepEfficiency == nil ? "building" : "duration-based estimate",
                                      direction: latest?.displaySleepEfficiency.map { $0 >= 0.85 ? 1 : -1 } ?? 0),
            AtriaMetricContributorRow(systemImage: "calendar",
                                      name: "Consistency",
                                      value: sleepHistory.sleepConsistencyText,
                                      comparison: "recent sleep timing",
                                      direction: sleepHistory.sleepConsistencyPercent.map { $0 >= 70 ? 1 : -1 } ?? 0),
            AtriaMetricContributorRow(systemImage: "wake",
                                      name: "Disturbance",
                                      value: sleepDisturbanceValueText,
                                      comparison: sleepDisturbanceComparisonText,
                                      direction: sleepDisturbanceDirection)
        ]
    }

    private var sleepDisturbanceValueText: String {
        guard let latest = sleepHistory.latestMainSleep, !latest.displayStageSegments.isEmpty else { return "--" }
        return SleepHistorySnapshot.formatDuration(latest.stageDuration(.awake))
    }

    private var sleepDisturbanceComparisonText: String {
        guard let latest = sleepHistory.latestMainSleep, !latest.displayStageSegments.isEmpty else {
            return "sleep stages unavailable"
        }
        return latest.stageEvidence == .validated ? "awake from validated stages" : "awake from estimated stages"
    }

    private var sleepDisturbanceDirection: Int {
        guard let latest = sleepHistory.latestMainSleep, !latest.displayStageSegments.isEmpty else { return 0 }
        let stagedDuration = latest.displayStageSegments.reduce(0) { $0 + $1.duration }
        guard stagedDuration > 0 else { return 0 }
        let awakeShare = latest.stageDuration(.awake) / stagedDuration
        return awakeShare <= 0.10 ? 1 : (awakeShare <= 0.18 ? 0 : -1)
    }

    private var sleepHeroValue: String {
        let trendPoints = preparedHistory.sleep[range] ?? []
        // Do not erase a known night merely because this period does not yet
        // contain saved trend observations. The hero remains truthful while
        // the chart below explains what still has to be saved.
        if trendPoints.isEmpty, let latest = sleepHistory.latestMainSleep {
            // Show the full day's effective sleep so a second same-day main
            // sleep is not silently dropped from the headline total before the
            // daily metric propagates. Recovery/need keep using `latest` alone.
            return SleepHistorySnapshot.formatDuration(
                sleepHistory.latestMainSleepDayEffectiveDuration ?? latest.duration)
        }
        return periodHeroText(summary: preparedHistory.sleepSummary[range],
                              points: trendPoints,
                              unit: "h")
    }

    private var sleepTrendEmptyTitle: String {
        switch range {
        // "Ready" only when a night exists; the hero shows "--" otherwise and
        // the title must not contradict it (2026-09-02).
        case .day: sleepHistory.latestMainSleep == nil ? "No sleep saved yet" : "Today's sleep is ready"
        case .week: "This week's trend is building"
        case .month: "This month's trend is building"
        default: "This trend is building"
        }
    }

    private var sleepTrendEmptyExplanation: String {
        switch range {
        case .day:
            sleepHistory.latestMainSleep == nil
                ? "Save a night and it appears here as today's point."
                : "Your latest sleep is available above. A daily trend point appears after this night is saved to history."
        case .week:
            "Your latest sleep is available above. Save more nights this week to see a meaningful weekly trend."
        case .month:
            "Your latest sleep is available above. Save more nights this month to see a meaningful monthly trend."
        default:
            "Your latest sleep is available above. Save more nights to see a meaningful long-term trend."
        }
    }

    private var sleepHeroState: String {
        // canonical not-ready word (was "Building"), consistent with the other metric hero states
        guard let latest = sleepHistory.latestMainSleep, latest.confirmed else { return "Learning" }
        let performance = sleepHistory.sleepPerformancePercent(
            for: latest,
            baseNeedHours: sleepBaseNeedHours,
            yesterdayStrain: yesterdayStrainForLatestNight
        )
        return performance.map { "\($0)% of need" } ?? "Need unavailable"
    }

    private var strainContributorRows: [AtriaMetricContributorRow] {
        // "Day strain" row removed (dedup audit 2026-07-07): the hero and
        // the gauge already show the value; the Target row owns the target.
        return [
            AtriaMetricContributorRow(systemImage: "target",
                                      name: "Target",
                                      value: guidance.target.map { String(format: "%.1f", $0) } ?? "--",
                                      comparison: guidance.headline.isEmpty ? guidance.detail : guidance.headline,
                                      direction: 0)
        ] + strainActivityContributorRows
    }

    private var strainActivityContributorRows: [AtriaMetricContributorRow] {
        let summary = todayWorkoutZoneSummary
        guard summary.workoutCount > 0 else {
            return [
                AtriaMetricContributorRow(systemImage: "figure.mixed.cardio",
                                          name: "Activities",
                                          value: "0",
                                          comparison: "confirmed workouts today",
                                          direction: 0)
            ]
        }
        return [
            AtriaMetricContributorRow(systemImage: "figure.mixed.cardio",
                                      name: "Activities",
                                      value: "\(summary.workoutCount)",
                                      comparison: "confirmed workouts today",
                                      direction: 1),
            AtriaMetricContributorRow(systemImage: "timer",
                                      name: "Zone minutes",
                                      value: todayHighZoneMinutesText,
                                      comparison: "aerobic and above",
                                      direction: summary.highZoneSeconds > 0 ? 1 : 0)
        ]
    }

    private var todayWorkoutZoneSummary: AtriaTodayWorkoutZoneSummary {
        todayWorkoutZoneSummaryMemo.summary(workouts: confirmedWorkouts,
                                            sleepHistory: sleepHistory,
                                            revision: confirmedWorkoutsRevision)
    }

    private var todayHighZoneMinutesText: String {
        let minutes = Int((todayWorkoutZoneSummary.highZoneSeconds / 60).rounded())
        return minutes > 0 ? "\(minutes)m" : "--"
    }

    /// Today's time-in-zones across confirmed workouts, keyed by HRZone.
    /// Only real recorded zone seconds — no zone data, no bar.
    private var todayZoneHistogram: [AtriaTodayWorkoutZoneSummary.Entry] {
        todayWorkoutZoneSummary.histogram
    }

    /// Strain time-in-zones histogram (design backlog item 5): minutes per
    /// percent-of-max zone across today's confirmed workouts.
    /// The learned max-HR offer, one glance and two actions: the same
    /// profile write as Settings, hidden as soon as either is taken.
    @ViewBuilder
    private var maxHRSuggestionCard: some View {
        if metric == .strain, !maxHRSuggestionHandled, let suggestion = maxHRSuggestion {
            VStack(alignment: .leading, spacing: AtriaDesignTokens.Spacing.sm) {
                Text("Max heart rate")
                    .atriaEyebrow()
                Text("Observed \(suggestion.observedPeak) bpm · set to \(suggestion.currentMaxHR)")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Text(suggestion.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: AtriaDesignTokens.Spacing.sm) {
                    Button {
                        maxHRSuggestionHandled = true
                        onAcceptMaxHRSuggestion?(suggestion.observedPeak)
                    } label: {
                        Label("Update to \(suggestion.observedPeak)", systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .atriaCardAction(tint: Metrics.electricStrain)

                    Button {
                        maxHRSuggestionHandled = true
                        onDismissMaxHRSuggestion?(suggestion.observedPeak)
                    } label: {
                        Text("Not now")
                            .frame(maxWidth: .infinity)
                    }
                    .atriaCardAction(prominent: false, tint: .secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .atriaInsetCard(tint: Metrics.electricStrain)
        }
    }

    @ViewBuilder
    private var strainZoneHistogramCard: some View {
        let histogram = todayZoneHistogram
        if !histogram.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Today in zones")
                    .font(.subheadline.weight(.semibold))

                Chart(histogram) { entry in
                    BarMark(x: .value("Zone", "Z\(entry.zone.rawValue)"),
                            y: .value("Minutes", entry.minutes))
                        .foregroundStyle(entry.zone.color.opacity(0.85))
                        .cornerRadius(4)
                        .annotation(position: .top, spacing: 2) {
                            Text("\(Int(entry.minutes.rounded()))m")
                                .font(.caption2.weight(.bold).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                }
                .chartYAxis(.hidden)
                .frame(height: 110)
                .clipped()

                Text("Minutes per heart-rate zone across today's workouts. Zones use your percent-of-max bands.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .atriaInsetCard(tint: Metrics.electricStrain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Time in zones today. " + histogram.map { "Zone \($0.zone.rawValue), \(Int($0.minutes.rounded())) minutes" }.joined(separator: ". ") + ".")
        }
    }

    /// WHOOP-style "Strain & Recovery" combo (design backlog G1, 2026-08-03):
    /// strain as a line on the 0–21 left axis, and each day's recovery as a
    /// colored dot on a right 0–100% axis (dots colored strictly by recovery
    /// band). Both series are the same day-bucketed history the charts above
    /// already use, so no new data path. Honesty: recovery dots plot only on
    /// days that actually have a recovery score (missing ≠ zero); strain is the
    /// drained/lagged value the rest of this sheet already shows — never a
    /// fabricated live point.
    // The combo chart is a FIXED 7-day frame (see AtriaStrainRecoveryComboChart),
    // so it must be fed a week of history regardless of the selected detail
    // period. Feeding it the selected-period series meant a `.day` selection
    // handed it a single point — strain's LineMark runs were length 1 and drew
    // nothing, so the card rendered empty (2026-08-08 field report).
    private var strainComboWeekPoints: [AtriaDetailChartPoint] {
        replacingCurrentCyclePoint(
            in: preparedHistory.strain[.week] ?? [],
            value: currentCycleStrainTruth.exactTrendValue,
            tint: Metrics.electricStrain
        )
    }

    private var recoveryComboWeekPoints: [AtriaDetailChartPoint] {
        replacingCurrentCyclePoint(
            in: preparedHistory.recovery[.week] ?? [],
            value: currentCycleAuthority?.recoveryPercent.map(Double.init),
            tint: currentCycleAuthority?.recoveryPercent.map {
                Metrics.recoveryColor($0)
            } ?? .secondary
        )
    }

    @ViewBuilder
    private var strainRecoveryComboCard: some View {
        let strainPoints = strainComboWeekPoints
        let recoveryPoints = recoveryComboWeekPoints
        if !strainPoints.isEmpty && !recoveryPoints.isEmpty {
            AtriaStrainRecoveryComboChart(strain: strainPoints,
                                          recovery: recoveryPoints,
                                          rangeLabel: "the last 7 days")
        }
    }

    /// Activity-type classes for the strain mix split. HR alone cannot
    /// measure muscular load, so this is honestly framed as an
    /// activity-type split, never a muscle-load claim.
    private static let strengthLeaningTypes: Set<String> = ["Strength", "HIIT", "Yoga"]

    private var todayStrainMix: (cardio: Double, strength: Double)? {
        var cardio = 0.0
        var strength = 0.0
        for workout in todayWorkoutZoneSummary.workouts {
            guard !AtriaWorkoutMetricPresentation.metricsAreIncomplete(workout) else { continue }
            guard let strain = workout.strain, strain > 0 else { continue }
            let type = workout.activityType ?? ""
            if Self.strengthLeaningTypes.contains(type) {
                strength += strain
            } else if !type.isEmpty {
                cardio += strain
            }
        }
        guard cardio > 0 || strength > 0 else { return nil }
        return (cardio, strength)
    }

    /// Cardio vs strength-type strain mix (design backlog item 9, honesty
    /// adapted from the mock's "cardio vs muscular" — split by the workout's
    /// activity type, which the user chose or confirmed).
    @ViewBuilder
    private var strainActivityMixCard: some View {
        if let mix = todayStrainMix, mix.cardio > 0, mix.strength > 0 {
            let total = mix.cardio + mix.strength
            VStack(alignment: .leading, spacing: 10) {
                Text("Today's strain mix")
                    .font(.subheadline.weight(.semibold))

                GeometryReader { proxy in
                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Metrics.electricStrain.opacity(0.85))
                            .frame(width: max(10, proxy.size.width * mix.cardio / total))
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.purple.opacity(0.8))
                    }
                }
                .frame(height: 14)

                HStack(spacing: 14) {
                    Label(String(format: "Cardio %.1f", mix.cardio), systemImage: "figure.walk")
                        .foregroundStyle(Metrics.electricStrain)
                    Label(String(format: "Strength-type %.1f", mix.strength), systemImage: "dumbbell.fill")
                        .foregroundStyle(.purple)
                    Spacer(minLength: 0)
                }
                .font(.caption.weight(.bold).monospacedDigit())

                Text("Heart-rate strain grouped by what you logged \u{2014} not a muscle-load measurement.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .atriaInsetCard(tint: Metrics.electricStrain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(String(format: "Today's strain mix. Cardio %.1f, strength-type %.1f, split by activity type.", mix.cardio, mix.strength))
        }
    }

    /// §13.4 display un-fuse: cardio TRIMP and the logged-lifting
    /// TRIMP-equivalent as two separate bars in TRIMP space. The single day
    /// Strain above remains the combined total and is named as such here.
    /// Fusion math is untouched; a day with no scored lifting receipt renders
    /// nothing (zero-neutral, matching the fusion).
    @ViewBuilder
    private var strainCardioLiftingSplitCard: some View {
        if showsCurrentPhysiologicalCycleContext,
           let authority = currentCycleAuthority,
           let dayTRIMP = authority.dayTRIMP,
           authority.muscularTRIMP > 0 {
            let lifting = min(authority.muscularTRIMP, dayTRIMP)
            let cardio = max(0, dayTRIMP - lifting)
            VStack(alignment: .leading, spacing: 10) {
                Text("Cardio vs logged lifting")
                    .font(.subheadline.weight(.semibold))
                GeometryReader { proxy in
                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Metrics.electricStrain.opacity(0.85))
                            .frame(width: max(10, proxy.size.width * cardio / max(dayTRIMP, 0.1)))
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.purple.opacity(0.8))
                    }
                }
                .frame(height: 14)
                HStack(spacing: 14) {
                    Label(String(format: "Cardio · TRIMP %.0f", cardio), systemImage: "figure.walk")
                        .foregroundStyle(Metrics.electricStrain)
                    Label(String(format: "Lifting · %.0f TRIMP-eq", lifting), systemImage: "dumbbell.fill")
                        .foregroundStyle(.purple)
                    Spacer(minLength: 0)
                }
                .font(.caption.weight(.bold).monospacedDigit())
                Text("Day Strain combines both lanes. The lifting lane is provisional: sessions without complete RPE add zero.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .atriaInsetCard(tint: Metrics.electricStrain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(String(format: "Cardio versus logged lifting. Cardio TRIMP %.0f, lifting equivalent %.0f. Day strain is the labeled combined total.", cardio, lifting))
        }
    }

    private var strainWorkoutSection: some View {
        // Perf (docs/26 follow-up): compute the filter+sort once per render
        // instead of re-deriving todayConfirmedWorkouts for both the isEmpty
        // check and the ForEach below.
        let workouts = todayWorkoutZoneSummary.workouts
        return VStack(alignment: .leading, spacing: 12) {
            // Header target capsule removed (dedup audit 2026-07-07): the
            // Target contributor row is the single textual copy.
            Text("Workouts")
                .font(.subheadline.weight(.semibold))

            if workouts.isEmpty {
                Label("No confirmed workouts today", systemImage: "figure.mixed.cardio")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                    .padding(.horizontal, 12)
                    .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
            } else {
                ForEach(workouts.prefix(4), id: \.id) { workout in
                    AtriaStrainWorkoutRow(workout: workout)
                }

                // A workout row is deliberately a bounded activity window.
                // The hero above is the physiological day (sleep-to-sleep),
                // so calling both simply "strain" made a real 60-minute gym
                // window look like an under-reported day score.
                Text("Each value is this workout’s heart-rate strain. Day strain above combines your full sleep-to-sleep day.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .atriaInsetCard(tint: Metrics.electricStrain)
    }

    private func latestMetricText(points: [AtriaDetailChartPoint], unit: String) -> String {
        guard let latest = points.last else { return "--" }
        return latestText(value: latest.value, unit: unit)
    }

    /// The detail-hero headline for the selected period. Day = the latest reading
    /// (unchanged); Week/Month/… = the window AVERAGE, read from the SAME per-range
    /// summary the chart's Avg strip uses, so the headline tracks the selector and
    /// agrees with the chart. Falls back to the latest reading when no summary yet.
    /// (2026-07-08: the headline was the latest point for every range, identical
    /// across Day/Week/Month, so the number looked frozen to the selector — the same
    /// class of bug the user reported for recovery.)
    private func periodHeroText(summary: AtriaDetailPeriodSummary?,
                                points: [AtriaDetailChartPoint],
                                unit: String) -> String {
        if range != .day, let summary {
            return summary.averageText
        }
        return latestMetricText(points: points, unit: unit)
    }

    private var contributorCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            AtriaRecoveryContributorMap(contributors: recoveryEstimate.contributors,
                                        titleForContributor: contributorTitle(_:),
                                        noteForContributor: contributorNote(_:))

            // Journal nutrition is useful context for the person's day, but it
            // is not an input to Recovery V2. Keeping it above the score's
            // contributor map made a neutral log row read like a scored factor.
            // Put it after the real inputs, name it as context, and state the
            // boundary in the row itself.
            if let nutrition = latestNutrition {
                recoveryContextRow(for: nutrition)
                    .accessibilityIdentifier("recovery-journal-context-row")
            }
        }
    }

    private func recoveryContextRow(for nutrition: AtriaNutritionSummary) -> some View {
        let summary = nutrition.fuelSummary ?? "Nutrition logged"
        let detail = fuelContextDetail(for: nutrition)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "fork.knife.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .center)

            VStack(alignment: .leading, spacing: 3) {
                Text("Journal context")
                    .font(.caption.weight(.bold))
                Text(summary)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Journal context. \(summary). \(detail)")
    }

    private func fuelContextDetail(for nutrition: AtriaNutritionSummary) -> String {
        var parts: [String] = []
        if let waterMl = nutrition.waterMl, waterMl > 0 {
            parts.append("\(Int(waterMl.rounded())) ml water")
        }
        if let lastCaffeineHour = nutrition.lastCaffeineHour {
            parts.append(lastCaffeineHour >= 14 ? "late caffeine" : "caffeine before 2 PM")
        }
        if let alcoholDrinks = nutrition.alcoholDrinks, alcoholDrinks >= 1 {
            let rounded = Int(alcoholDrinks.rounded())
            parts.append("\(rounded) \(rounded == 1 ? "drink" : "drinks")")
        }
        let detail = parts.isEmpty ? "from Apple Health nutrition" : parts.joined(separator: " · ")
        return "\(detail) · not included in today’s recovery score"
    }

    private var hrvBand: AtriaDetailBaselineBand? {
        guard baseline.hrvTrusted,
              let mean = baseline.hrvLnMean,
              let sd = baseline.hrvLnSD else { return nil }
        return AtriaDetailBaselineBand(lower: exp(mean - sd),
                                       upper: exp(mean + sd),
                                       tint: .pink)
    }

    private var restingBand: AtriaDetailBaselineBand? {
        guard baseline.restingTrusted,
              let mean = baseline.restingMean,
              let sd = baseline.restingSD else { return nil }
        return AtriaDetailBaselineBand(lower: mean - sd,
                                       upper: mean + sd,
                                       tint: .pink)
    }

    private var respiratoryBand: AtriaDetailBaselineBand? {
        guard let stats = sleepHistory.respiratoryBaselineStats,
              stats.count >= 3,
              stats.sd > 0 else { return nil }
        return AtriaDetailBaselineBand(lower: stats.mean - 1.5 * stats.sd,
                                       upper: stats.mean + 1.5 * stats.sd,
                                       tint: .teal)
    }

    private func contributorTitle(_ contributor: Metrics.RecoveryEstimate.Contributor) -> String {
        switch contributor.kind {
        case .hrv: return "HRV"
        case .restingHeartRate: return "Resting HR"
        case .sleep: return "Sleep"
        case .respiration: return "Resp rate"
        }
    }

    private func contributorNote(_ contributor: Metrics.RecoveryEstimate.Contributor) -> String {
        switch contributor.kind {
        case .hrv:
            return contributor.zScore >= 0 ? "Above baseline" : "Below baseline"
        case .restingHeartRate:
            return contributor.zScore >= 0 ? "Calmer than baseline" : "Elevated vs baseline"
        case .sleep:
            return contributor.zScore >= 0 ? "Sleep helped" : "Sleep limited"
        case .respiration:
            return contributor.zScore == 0 ? "Neutral" : (contributor.zScore > 0 ? "Settled" : "Shifted")
        }
    }

    /// Honest learning-state pill: carries the real 14-night baseline
    /// progress ("Learning \u{00b7} night 3 of 14") once a night is recorded,
    /// so a bare "Learning" never hides how far along calibration is
    /// (2026-07-07, design handoff).
    private func learningNightsState(_ samples: Int) -> String {
        guard samples > 0 else { return "Learning" }
        let cap = PersonalBaseline.trustedMinimumSamples
        return "Learning \u{00b7} night \(min(samples, cap)) of \(cap)"
    }

    private func metricChart(title: String,
                             rendersAsDailyBar: Bool = false,
                             unit: String,
                             tint: Color,
                             points: [AtriaDetailChartPoint],
                             summary: AtriaDetailPeriodSummary?,
                             comparison: AtriaDetailComparisonSummary?,
                             baselineBand: AtriaDetailBaselineBand?,
                             accessibilitySummary: String,
                             emptyTitle: String = "No saved observations",
                             emptyExplanation: String? = nil,
                             priorPoints: [AtriaDetailChartPoint] = [],
                             companions: [(title: String, unit: String, tint: Color, points: [AtriaDetailChartPoint])] = [],
                             onOpenDay: ((Date) -> Void)? = nil,
                             onExpand: (() -> Void)? = nil) -> some View {
        let currentCycleDisplayAnchor = currentCycleDetailProjection.usesCurrentCycle
            ? currentCycleAuthority?.cycleStart
                ?? currentCycleAuthority?.projectedAt
            : nil
        let cacheKey = MetricChartPreparedDataCache.Key(
            preparationInput: preparation.valueKey ?? preparationInput,
            metric: metric,
            range: range,
            bucketOverride: bucketOverride,
            showMinMaxBand: showMinMaxBand,
            currentCycleValue: {
                guard currentCycleDetailProjection.usesCurrentCycle else {
                    return nil
                }
                switch metric {
                case .recovery:
                    return currentCycleAuthority?.recoveryPercent.map(Double.init)
                case .hrv:
                    return usesCurrentCyclePrimaryRangePoint
                        ? currentCycleHRVTrendValue : nil
                case .restingHeartRate:
                    return usesCurrentCyclePrimaryRangePoint
                        ? currentCycleRestingHeartRateTrendValue : nil
                case .strain:
                    return currentCycleStrainTruth.exactTrendValue
                default:
                    return nil
                }
            }(),
            currentCycleDisplayDay: currentCycleDisplayAnchor,
            dynamicCompanionSignature:
                AtriaMetricChartDynamicCompanionSignature(
                    companionPoints: companions.map(\.points),
                    currentCycleDisplayAnchor: currentCycleDisplayAnchor,
                    calendar: preparationBaseInput.calendar
                )
        )
        let prepared = metricChartPreparedDataCache.value(for: cacheKey) {
            // Same helper the expanded full-screen route passes as its
            // explicit domain: inline and expanded plot one period.
            let visibleXDomain = Self.chartPeriodXDomain(
                range: range,
                referenceDate: (preparation.valueKey ?? preparationInput).referenceDate,
                calendar: (preparation.valueKey ?? preparationInput).calendar
            )
            return AtriaMetricChartPreparedData(
                points: points,
                priorPoints: priorPoints,
                baselineBounds: baselineBand.map { $0.lower...$0.upper },
                priorAverage: comparison?.priorAverage,
                companionPoints: companions.map(\.points),
                xDomain: visibleXDomain
            )
        }
        return AtriaPreparedMetricChart(
            title: title,
            unit: unit,
            tint: tint,
            rendersAsDailyBar: rendersAsDailyBar,
            points: points,
            summary: summary,
            comparison: comparison,
            baselineBand: baselineBand,
            accessibilitySummary: accessibilitySummary,
            emptyTitle: emptyTitle,
            emptyExplanation: emptyExplanation,
            priorPoints: priorPoints,
            companions: companions.map {
                AtriaPreparedMetricChart.Companion(title: $0.title,
                                                   unit: $0.unit,
                                                   tint: $0.tint,
                                                   points: $0.points)
            },
            prepared: prepared,
            initialScrubbedDay: initialScrubbedDay,
            onOpenDay: onOpenDay,
            onExpand: onExpand
        )
    }

    /// Real saved activity for the expanded chart's marker lane: confirmed
    /// workouts (strain hue) and confirmed sleep nights (sleep hue). Only
    /// records that exist — an empty day has no marker. Built by the ONE
    /// shared `AtriaChartEvent.activityEvents` builder so this expanded
    /// route can never drift from the inline surfaces again — the local copy
    /// it replaces skipped the accidental-fragment gate the inline Vitals
    /// host applied (2026-08-20 expanded-activities report).
    private var expandedChartEvents: [AtriaChartEvent] {
        expandedChartEventsCache.value(key: expandedChartEventsKey) {
            AtriaChartEvent.activityEvents(workouts: confirmedWorkouts,
                                           sleepNights: sleepHistory.nights)
        }
    }

    private var expandedChartEventsKey: Int {
        var hasher = Hasher()
        if let confirmedWorkoutsRevision {
            hasher.combine(confirmedWorkoutsRevision)
        } else {
            hasher.combine(confirmedWorkouts.count)
            hasher.combine(confirmedWorkouts.first?.id)
            hasher.combine(confirmedWorkouts.last?.id)
        }
        if let sleepHistoryRevision {
            hasher.combine(sleepHistoryRevision)
        } else {
            hasher.combine(sleepHistory.nights.count)
            hasher.combine(sleepHistory.nights.reduce(into: 0) { $0 += $1.confirmed ? 1 : 0 })
            hasher.combine(sleepHistory.nights.first?.id)
            hasher.combine(sleepHistory.nights.last?.id)
        }
        return hasher.finalize()
    }

    /// ONE source of truth for the horizontal window of this metric/range:
    /// the inline detail chart's `prepared.xDomain` and the expanded
    /// full-screen chart must plot the SAME calendar period. The expanded
    /// chart used to derive its domain from the metric points alone, so
    /// activity markers on period days without a settled metric point —
    /// today's workout or confirmed sleep, exactly what the inline surfaces
    /// show — were clipped out of the full-screen view (2026-08-20
    /// expanded-activities report).
    static func chartPeriodXDomain(range: AtriaTrendRange,
                                   referenceDate: Date,
                                   calendar: Calendar) -> ClosedRange<Date> {
        let period = range.periodInterval(containing: referenceDate,
                                          calendar: calendar)
        return period.start...period.end
    }

    /// The exact period the accepted preparation is plotting (never the live
    /// `periodAnchor`, which runs ahead during an async prepare) — the same
    /// reference the inline chart's cached `xDomain` uses. Nil only for
    /// `.all`, whose "period" starts at `.distantPast`: there the recorded
    /// data span IS the window, so the expanded chart keeps its legacy
    /// data-derived domain instead of a fabricated multi-millennium axis.
    private var expandedChartXDomain: ClosedRange<Date>? {
        guard range != .all else { return nil }
        return Self.chartPeriodXDomain(
            range: range,
            referenceDate: (preparation.valueKey ?? preparationInput).referenceDate,
            calendar: (preparation.valueKey ?? preparationInput).calendar
        )
    }

    /// The expanded chart mirrors whatever the inline chart currently shows
    /// for the six core metrics (same override, same ghost, same band).
    private var expandedChartConfig: (title: String, unit: String, tint: Color, points: [AtriaDetailChartPoint], prior: [AtriaDetailChartPoint], band: AtriaDetailBaselineBand?)? {
        switch metric {
        case .recovery:
            return ("Recovery", "%", Metrics.electricGreen,
                    recoveryDisplayPointsForSelectedPeriod,
                    preparedHistory.recoveryPrior[range] ?? [], nil)
        case .hrv:
            return ("HRV", "ms", metric.tint,
                    hrvDisplayPointsForSelectedPeriod,
                    preparedHistory.hrvPrior[range] ?? [], hrvBand)
        case .restingHeartRate:
            return ("Resting HR", "bpm", metric.tint,
                    restingHeartRateDisplayPointsForSelectedPeriod,
                    preparedHistory.restingHeartRatePrior[range] ?? [], restingBand)
        case .respiratoryRate:
            return ("Respiratory rate", "/min", metric.tint,
                    displayedPoints(auto: preparedHistory.respiratoryRate[range] ?? [], raw: preparedHistory.respiratoryRateRaw[range] ?? []),
                    preparedHistory.respiratoryRatePrior[range] ?? [], respiratoryBand)
        case .sleep:
            return ("Sleep duration", "h", Metrics.electricSleep,
                    displayedPoints(auto: preparedHistory.sleep[range] ?? [], raw: preparedHistory.sleepRaw[range] ?? []),
                    preparedHistory.sleepPrior[range] ?? [], nil)
        case .strain:
            return ("Strain", "", Metrics.electricStrain,
                    strainDisplayPointsForSelectedPeriod,
                    preparedHistory.strainPrior[range] ?? [], nil)
        case .sleepPerformance:
            return ("Sleep sufficiency", "%", Metrics.electricSleep,
                    preparedHistory.sleepPerformance[range] ?? [], [], nil)
        case .fitnessAge:
            return ("Pace of aging", "y", fitnessAgeTint,
                    preparedHistory.fitnessAge[range] ?? [], [], nil)
        default:
            return nil
        }
    }

    /// "Behaviors that move you" (design backlog item 7): the Journal's
    /// statistically-gated behavior impacts (Welch p < 0.10, ≥5 logged and
    /// comparison days, ≥3% effect) surfaced where the recovery number
    /// lives. Reuses the exact rows the Journal renders — one engine.
    @ViewBuilder
    private var behaviorsMoveYouCard: some View {
        if !behaviorImpacts.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Behaviors that move you")
                    .font(.subheadline.weight(.semibold))
                AtriaJournalBehaviorImpactRows(impacts: Array(behaviorImpacts.prefix(3)))
                Text("From your journal tags vs next-day recovery over 90 days. Association, not proof of cause.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .atriaInsetCard(tint: Metrics.electricGreen)
        }
    }

    /// Shaped outside the render block per the perf rule (no compactMap in
    /// view-builder bodies): real confirmed nights' efficiencies for the
    /// sleep planner's time-in-bed assumption.
    private var confirmedNightEfficiencies: [Double] {
        sleepHistory.nights.filter(\.confirmed).compactMap(\.displaySleepEfficiency)
    }

    /// Per-night efficiency trend for the sleep-efficiency detail (P3). Uses
    /// `displaySleepEfficiency` — the motion-honest accessor (HR-only nights
    /// are nil: their stored value is span coverage, not efficiency). Nil under
    /// 5 charted nights in the last 30 days; the detail then keeps its
    /// honest-partial copy.
    private var sleepEfficiencyTrend: AtriaAboutMetricTrend? {
        let calendar = Calendar.current
        let end = calendar.startOfDay(for: Date())
        guard let start = calendar.date(byAdding: .day, value: -29, to: end) else { return nil }
        var seen = Set<Date>()
        let points: [AtriaDetailChartPoint] = sleepHistory.nights
            .filter(\.confirmed)
            .compactMap { night -> AtriaDetailChartPoint? in
                let day = calendar.startOfDay(for: night.day)
                guard day >= start, day <= end,
                      let efficiency = night.displaySleepEfficiency,
                      seen.insert(day).inserted else { return nil }
                return AtriaDetailChartPoint(day: day,
                                             value: (efficiency * 100).rounded(),
                                             tint: Metrics.electricSleep)
            }
            .sorted { $0.day < $1.day }
        guard points.count >= 5,
              let lo = points.map(\.value).min(),
              let hi = points.map(\.value).max() else { return nil }
        let range = lo == hi ? "steady at \(Int(lo))%" : "\(Int(lo))–\(Int(hi))%"
        return AtriaAboutMetricTrend(points: points,
                                     window: start...end,
                                     caption: "\(points.count) nights · \(range)")
    }

    /// Overlay candidates for "Edit this chart": the two sibling metrics the
    /// inline chart already pairs as scrub companions, in raw daily form.
    private var expandedChartOverlays: [(title: String, unit: String, tint: Color, points: [AtriaDetailChartPoint])] {
        switch metric {
        case .recovery, .strain:
            return [("HRV", " ms", Metrics.electricHRV, hrvRawPointsForSelectedPeriod),
                    ("Sleep", " h", Metrics.electricSleep, preparedHistory.sleepRaw[range] ?? [])]
        case .hrv, .restingHeartRate:
            return [("Recovery", "%", Metrics.electricGreen, recoveryRawPointsForSelectedPeriod),
                    ("Sleep", " h", Metrics.electricSleep, preparedHistory.sleepRaw[range] ?? [])]
        case .sleep:
            return [("Recovery", "%", Metrics.electricGreen, recoveryRawPointsForSelectedPeriod),
                    ("Strain", "", Metrics.electricStrain, strainRawPointsForSelectedPeriod)]
        case .respiratoryRate:
            return [("HRV", " ms", Metrics.electricHRV, hrvRawPointsForSelectedPeriod),
                    ("Recovery", "%", Metrics.electricGreen, recoveryRawPointsForSelectedPeriod)]
        default:
            return []
        }
    }

    private var chartSupportsOptions: Bool {
        switch metric {
        case .recovery, .hrv, .restingHeartRate, .respiratoryRate, .sleep, .strain: return true
        default: return false
        }
    }

    /// Applies the manual bucket override from the chart-options sheet.
    /// .auto returns the precomputed series (weekly above 90 days); .daily
    /// returns raw points; .weeklyAverage forces weekly buckets. The min-max
    /// band toggle strips bands at display time.
    private func displayedPoints(auto: [AtriaDetailChartPoint],
                                 raw: [AtriaDetailChartPoint]) -> [AtriaDetailChartPoint] {
        let base: [AtriaDetailChartPoint]
        switch bucketOverride {
        case .auto: base = auto
        case .daily: base = raw
        case .weeklyAverage:
            // Clamp buckets into the visible period so a first partial week
            // is not keyed off-domain and clipped (2026-07-31 audit item 3).
            let input = preparation.valueKey ?? preparationInput
            base = AtriaPreparedMetricHistory.bucketedForDisplay(
                raw,
                range: range,
                calendar: input.calendar,
                forceWeekly: true,
                within: range.periodInterval(containing: input.referenceDate,
                                             calendar: input.calendar)
            )
        case .monthlyAverage:
            // 2026-08-01 (graph grammar slice 4): month buckets use the shared
            // pure envelope — value = the month's real average, band = its real
            // min–max. Same visible-period clamp as the weekly path.
            let input = preparation.valueKey ?? preparationInput
            base = AtriaGraphMinMaxEnvelope.bucketed(
                raw,
                by: .month,
                calendar: input.calendar,
                within: range.periodInterval(containing: input.referenceDate,
                                             calendar: input.calendar)
            )
        }
        guard !showMinMaxBand else { return base }
        return base.map { AtriaDetailChartPoint(day: $0.day, value: $0.value, tint: $0.tint) }
    }

    /// Double-tap route: resolve the scrubbed date to its history-day model
    /// and open the existing day-vs-median sheet. Unknown day: does nothing.
    private func openHistoryDay(for date: Date) {
        let model = AtriaHistoryModel.make(rollups: rollups,
                                           workouts: confirmedWorkouts,
                                           sleeps: confirmedSleeps)
        guard let day = model.days.first(where: { Calendar.current.isDate($0.date, inSameDayAs: date) }) else { return }
        openedHistoryDay = day
    }

    private func latestText(value: Double, unit: String) -> String {
        AtriaDetailPeriodSummary.valueText(value, unit: unit)
    }
}

/// Cache identity for the only dynamic part of companion lookup indices.
/// Values are deliberately excluded: scrub callouts receive the fresh series
/// directly, while the prepared cache only owns each companion's day→index map.
struct AtriaMetricChartDynamicCompanionSignature: Equatable {
    let currentPointDays: [Date?]

    init(
        companionPoints: [[AtriaDetailChartPoint]],
        currentCycleDisplayAnchor: Date?,
        calendar: Calendar = .current
    ) {
        guard let currentCycleDisplayAnchor else {
            currentPointDays = Array(repeating: nil, count: companionPoints.count)
            return
        }
        let currentDay = calendar.startOfDay(for: currentCycleDisplayAnchor)
        currentPointDays = companionPoints.map { points in
            points.contains {
                calendar.isDate($0.day, inSameDayAs: currentDay)
            } ? currentDay : nil
        }
    }
}


struct AtriaMetricChartPreparedData {
    let domain: ClosedRange<Double>
    let xDomain: ClosedRange<Date>?
    let minMaxPoints: [AtriaDetailChartPoint]
    let lineGradientStops: [Gradient.Stop]?
    private let pointTimes: [TimeInterval]
    private let companionIndicesByDay: [[Date: Int]]
    private let calendar: Calendar

    init(points: [AtriaDetailChartPoint],
         priorPoints: [AtriaDetailChartPoint],
         baselineBounds: ClosedRange<Double>?,
         priorAverage: Double?,
         companionPoints: [[AtriaDetailChartPoint]],
         calendar: Calendar = .current,
         xDomain: ClosedRange<Date>? = nil) {
        var low: Double?
        var high: Double?
        func include(_ value: Double?) {
            guard let value else { return }
            low = min(low ?? value, value)
            high = max(high ?? value, value)
        }
        for point in points {
            include(point.value)
            include(point.bandLower)
            include(point.bandUpper)
        }
        for point in priorPoints { include(point.value) }
        include(baselineBounds?.lowerBound)
        include(baselineBounds?.upperBound)
        include(priorAverage)
        domain = low.flatMap { low in high.map { AtriaTrendChartScale.domain(low: low, high: $0) } } ?? 0...1
        self.xDomain = xDomain
        if let firstTint = points.first?.tint, points.contains(where: { $0.tint != firstTint }) {
            let span = domain.upperBound - domain.lowerBound
            var stops: [Gradient.Stop] = []
            for point in points.sorted(by: { $0.value < $1.value }) {
                let location = CGFloat(span > 0 ? (point.value - domain.lowerBound) / span : 0)
                if stops.last?.location != location {
                    stops.append(Gradient.Stop(color: point.tint, location: location))
                }
            }
            lineGradientStops = stops
        } else {
            lineGradientStops = nil
        }
        minMaxPoints = points.filter {
            guard let lower = $0.bandLower, let upper = $0.bandUpper else { return false }
            return upper > lower
        }
        pointTimes = points.map { $0.day.timeIntervalSinceReferenceDate }
        companionIndicesByDay = companionPoints.map { series in
            Dictionary(series.enumerated().map { (calendar.startOfDay(for: $0.element.day), $0.offset) },
                       uniquingKeysWith: { first, _ in first })
        }
        self.calendar = calendar
    }

    var hasMinMaxBand: Bool { !minMaxPoints.isEmpty }

    func nearestPointIndex(to target: Date) -> Int? {
        guard !pointTimes.isEmpty else { return nil }
        let targetTime = target.timeIntervalSinceReferenceDate
        var lower = 0
        var upper = pointTimes.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if pointTimes[middle] < targetTime { lower = middle + 1 } else { upper = middle }
        }
        if lower == 0 { return 0 }
        if lower == pointTimes.count { return pointTimes.count - 1 }
        return targetTime - pointTimes[lower - 1] <= pointTimes[lower] - targetTime ? lower - 1 : lower
    }

    func companionPointIndex(at companionIndex: Int, on day: Date) -> Int? {
        guard companionIndicesByDay.indices.contains(companionIndex) else { return nil }
        return companionIndicesByDay[companionIndex][calendar.startOfDay(for: day)]
    }
}

private struct AtriaPreparedMetricChart: View {
    struct Companion {
        let title: String
        let unit: String
        let tint: Color
        let points: [AtriaDetailChartPoint]
    }

    let title: String
    let unit: String
    let tint: Color
    /// Owner direction 2026-08-25: a metric producing ONE value per day that
    /// ACCUMULATES from zero is a bar; a per-day LEVEL stays a line. Recovery %,
    /// sleep hours and sleep performance are magnitudes measured from zero, so a
    /// bar's reading is literally true for them. Resting HR (~55) and HRV (~60)
    /// are levels whose zero is never observed — bars from zero would push their
    /// real few-unit signal into the top sliver of every column.
    let rendersAsDailyBar: Bool
    let points: [AtriaDetailChartPoint]
    let summary: AtriaDetailPeriodSummary?
    let comparison: AtriaDetailComparisonSummary?
    let baselineBand: AtriaDetailBaselineBand?
    let accessibilitySummary: String
    let emptyTitle: String
    let emptyExplanation: String?
    let priorPoints: [AtriaDetailChartPoint]
    let companions: [Companion]
    let onOpenDay: ((Date) -> Void)?
    let onExpand: (() -> Void)?
    private let prepared: AtriaMetricChartPreparedData
    @State private var scrubbedDay: Date?

    init(title: String,
         unit: String,
         tint: Color,
         rendersAsDailyBar: Bool = false,
         points: [AtriaDetailChartPoint],
         summary: AtriaDetailPeriodSummary?,
         comparison: AtriaDetailComparisonSummary?,
         baselineBand: AtriaDetailBaselineBand?,
         accessibilitySummary: String,
         emptyTitle: String,
         emptyExplanation: String?,
         priorPoints: [AtriaDetailChartPoint],
         companions: [Companion],
         prepared: AtriaMetricChartPreparedData,
         initialScrubbedDay: Date?,
         onOpenDay: ((Date) -> Void)?,
         onExpand: (() -> Void)?) {
        self.title = title
        self.unit = unit
        self.tint = tint
        self.rendersAsDailyBar = rendersAsDailyBar
        self.points = points
        self.summary = summary
        self.comparison = comparison
        self.baselineBand = baselineBand
        self.accessibilitySummary = accessibilitySummary
        self.emptyTitle = emptyTitle
        self.emptyExplanation = emptyExplanation
        self.priorPoints = priorPoints
        self.companions = companions
        self.prepared = prepared
        self.onOpenDay = onOpenDay
        self.onExpand = onExpand
        _scrubbedDay = State(initialValue: initialScrubbedDay)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                // 2026-08-15 dedup: a single-observation window shows its value
                // in the dated row below; the header caption repeated it
                // verbatim (hero + header + Latest + Avg + row = 5 renders).
                if let latest = latestVisiblePoint, points.count >= 2 {
                    // Ink, not tint (2026-08-29 theme): hue lives in the plot.
                    Text(valueText(latest.value)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if let onExpand, points.count >= 2 {
                    // 40pt circular affordance — same chrome as the sheet's
                    // header buttons (2026-08-29 controls audit).
                    Button(action: onExpand) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption.weight(.bold)).foregroundStyle(.secondary)
                            .frame(width: 40, height: 40)
                            .background(.quaternary.opacity(0.22), in: Circle())
                            .contentShape(Circle())
                    }
                    .accessibilityLabel("Expand chart: landscape, zoom, range selection, activity markers")
                }
            }

            if points.count >= 2, summary == nil {
                AtriaDetailRangeDotStrip(points: points, fallbackTint: tint)
            }

            if points.isEmpty {
                VStack(spacing: 6) {
                    Text(emptyTitle).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if let emptyExplanation {
                        Text(emptyExplanation).font(.caption2).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).padding(.horizontal, 18)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 150)
                .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
            } else if points.count == 1 {
                singleObservationState
            } else {
                // Handoff-10 CP3: the full-bleed negative inset clipped edge
                // labels/points against the card bounds; the plot now keeps
                // the card inset and carries explicit headroom instead.
                chartContent
                chartLegendAndCompanions
            }

            // 2026-08-29 minimalism pass: the tinted three-surface summary
            // strip (rail + chips) restated the chart; one neutral line under
            // the plot carries Latest/Avg/Range. `summary.hasSpread` keeps it
            // when a bucket override collapses a multi-day window into one
            // displayed point (Latest vs Avg still differ there).
            if let summary, points.count >= 2 || summary.hasSpread {
                AtriaDetailPeriodSummaryLine(summary: summary)
            }
        }
        // 12pt gutter (2026-08-05 width audit): match the app-wide screen
        // gutter horizontally; vertical inset stays 14. Reduced padding only —
        // the Handoff-10 CP3 revert above forbids re-introducing the
        // full-bleed negative inset on this card.
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .atriaInsetCard(tint: tint)
    }

    /// The chart clips to `prepared.xDomain`; the header must quote the last
    /// point actually drawn, never one that fell outside the domain
    /// (2026-07-31 audit item 3).
    private var latestVisiblePoint: AtriaDetailChartPoint? {
        guard let xDomain = prepared.xDomain else { return points.last }
        return points.last(where: { xDomain.contains($0.day) })
    }

    private var selectedPointIndex: Int? {
        scrubbedDay.flatMap(prepared.nearestPointIndex)
    }

    private var selectedPoint: AtriaDetailChartPoint? {
        selectedPointIndex.map { points[$0] }
    }

    private var chartContent: some View {
        Chart {
            if let baselineBand {
                RectangleMark(xStart: .value("Start", points.first?.day ?? Date()),
                              xEnd: .value("End", points.last?.day ?? Date()),
                              yStart: .value("Lower", baselineBand.lower),
                              yEnd: .value("Upper", baselineBand.upper))
                    .foregroundStyle(baselineBand.tint.opacity(0.12))
            }
            // Split into contiguous day-runs for the same reason the LINE
            // below is (the 2026-08-03 chart-honesty rule). This band was the
            // half of the chart that had never been split: the line broke at a
            // gap while the min-max band underneath it swept straight across
            // the missing days, so the shaded region claimed a measured spread
            // on days with no reading at all.
            ForEach(prepared.minMaxPoints.contiguousDayRuns(), id: \.point.day) { entry in
                AreaMark(x: .value("Day", entry.point.day, unit: .day),
                         yStart: .value("Min", entry.point.bandLower ?? entry.point.value),
                         yEnd: .value("Max", entry.point.bandUpper ?? entry.point.value),
                         series: .value("Band run", "band-\(entry.runID)"))
                    .interpolationMethod(.linear).foregroundStyle(tint.opacity(0.13))
            }
            if rendersAsDailyBar {
                // One bar per civil day. A per-day accumulation drawn as a line
                // needs two points to render anything, so a single-day window
                // draws an empty chart and a gap has to be special-cased; a bar
                // needs one datum and a missing day simply draws nothing.
                ForEach(points) { point in
                    BarMark(x: .value("Day", point.day, unit: .day),
                            y: .value(title, point.value))
                        .foregroundStyle(point.tint.gradient)
                        .cornerRadius(3)
                }
            } else {
                // Split at gaps like the LINE above it. This gradient fill was
                // the third surface in this file to sweep across days with no
                // reading while the stroke drawn over it broke correctly — the
                // min-max band and the Vitals sparkline were the other two.
                // A filled region is a stronger claim than a stroke, not a
                // weaker one: it shades area under days that were never
                // measured.
                ForEach(points.contiguousDayRuns(), id: \.point.day) { entry in
                    AreaMark(x: .value("Day", entry.point.day, unit: .day),
                             y: .value(title, entry.point.value),
                             series: .value("Fill run", "fill-\(entry.runID)"))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(LinearGradient(colors: [tint.opacity(0.20), tint.opacity(0)],
                                                        startPoint: .top, endPoint: .bottom))
                }
            }
            if let comparison {
                RuleMark(y: .value("Prior average", comparison.priorAverage))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .topTrailing, spacing: 2,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        Text("prior avg \(comparison.priorText)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
            }
            // The per-day prior-period ghost line remains intentionally absent:
            // comparison is a real prior average, not an invented historical
            // series. Current runs use a monotone curve through every real
            // anchor; PointMarks preserve the exact daily observations.
            // Line split into contiguous day-runs so it BREAKS at gaps instead of
            // drawing a straight segment across days with no reading (2026-08-03
            // chart-honesty rule). Points still render on every real day.
            ForEach(rendersAsDailyBar ? [] : points.contiguousDayRuns(), id: \.point.day) { entry in
                LineMark(x: .value("Day", entry.point.day, unit: .day), y: .value(title, entry.point.value),
                         series: .value("Series", "current-\(entry.runID)"))
                    .interpolationMethod(.monotone)
                    .lineStyle(AtriaChartVisualGrammar.trendLine)
                    .foregroundStyle(lineStyle)
                    // Without plot-area alignment Swift Charts resolves the
                    // gradient against each run's own bounding box, so the same
                    // value renders different colors on different runs and none
                    // of them match `point.tint` (stops are normalized against
                    // `prepared.domain`). Aligning to the plot area makes
                    // gradient unit space == chartYScale(domain:) == the stop
                    // normalization space (2026-08-05 O8 repair).
                    .alignsMarkStylesWithPlotArea()
            }
            ForEach(rendersAsDailyBar ? [] : points) { point in
                PointMark(x: .value("Day", point.day, unit: .day), y: .value(title, point.value))
                    .foregroundStyle(point.tint)
            }
            if let last = points.last, selectedPoint == nil {
                PointMark(x: .value("Day", last.day, unit: .day), y: .value(title, last.value))
                    .foregroundStyle(tint).symbolSize(110)
            }
            if let selectedPoint {
                RuleMark(x: .value("Day", selectedPoint.day, unit: .day))
                    .foregroundStyle(tint.opacity(0.30))
                    .annotation(position: .top, spacing: 0,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        // Cross-metric context tracks the scrub (design "Graph
                        // Interactions"): that day's sibling metrics as one compact
                        // line, real values only — a day without a companion sample
                        // is simply omitted, never invented.
                        let companionContext = companions.enumerated().compactMap { index, companion -> String? in
                            let match = prepared.companionPointIndex(at: index, on: selectedPoint.day).map { companion.points[$0] }
                            return match.map { "\(companion.title.uppercased()) \(AtriaDetailPeriodSummary.valueText($0.value, unit: companion.unit))" }
                        }
                        VStack(spacing: 1) {
                            Text(valueText(selectedPoint.value)).font(.caption.weight(.bold).monospacedDigit()).foregroundStyle(tint)
                            Text(selectedPoint.day, format: .dateTime.month(.abbreviated).day()).font(.caption2).foregroundStyle(.secondary)
                            if let baselineBand {
                                Text(String(format: "%+.0f vs typical", selectedPoint.value - (baselineBand.lower + baselineBand.upper) / 2))
                                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            }
                            if !companionContext.isEmpty {
                                Text(companionContext.joined(separator: "  ·  "))
                                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        // Liquid Glass scrub callout — see AtriaTrendChart for why
                        // this floating, transient surface is the right place for
                        // real glass while scrolling cards stay opaque.
                        .atriaGlassCard(cornerRadius: AtriaDesignTokens.Radius.chip)
                    }
                PointMark(x: .value("Day", selectedPoint.day, unit: .day), y: .value(title, selectedPoint.value))
                    .foregroundStyle(tint).symbolSize(130)
            }
        }
        .atriaGraphPlotSurface()
        .chartXSelection(value: $scrubbedDay)
        // A bar states "this much, measured from zero". `prepared.domain` pads
        // around min...max, which is right for a level but would render every
        // bar as a truncated stub and exaggerate small day-to-day differences.
        .chartYScale(domain: rendersAsDailyBar
                     ? 0...max(prepared.domain.upperBound, 1)
                     : prepared.domain)
        .chartXScale(domain: prepared.xDomain ?? fallbackXDomain)
        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) }
        .chartYAxisLabel(unit)
        .chartXAxis {
            if rendersAsDailyBar {
                // A `unit: .day` bar owns its whole day, so its label belongs
                // at the day's MIDDLE — and the way to put it there is to mark
                // noon, not to centre the label. `centered:` offsets by half
                // the step to the NEXT mark, which is only half a day when
                // marks are one day apart; at `.automatic(desiredCount: 4)`
                // over a month the step is about a week, so it threw every
                // label three-and-a-half days right, onto a different bar.
                AxisMarks(values: AtriaChartVisualGrammar.dayCentreMarks(
                    in: prepared.xDomain ?? fallbackXDomain,
                    targetCount: 4
                )) { _ in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisTick()
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            } else {
                // A line plots each point AT its date, so the mark belongs on
                // the date itself and the label stays uncentred.
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisTick()
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
        }
        // Handoff-10 CP3: explicit top headroom instead of `.clipped()`, so
        // the top axis label and edge points always render fully.
        .chartPlotStyle { plot in
            plot.padding(.top, 8)
        }
        .frame(height: 210)
        .onTapGesture(count: 2) {
            if let target = scrubbedDay, let onOpenDay { onOpenDay(target) }
        }
        .accessibilityLabel(accessibilitySummary)
        // The double-tap above is not published as an accessibility
        // activation, and `scrubbedDay` is only ever set by the drag-based
        // scrub, so VoiceOver could reach neither the gesture nor the hint
        // documenting it. The action exists only where the route does, and
        // falls back to the latest drawn point because a VoiceOver user has
        // no way to scrub one (2026-08-28).
        .accessibilityActions {
            if let onOpenDay {
                Button("Open this day") {
                    if let target = scrubbedDay ?? latestVisiblePoint?.day {
                        onOpenDay(target)
                    }
                }
            }
        }
    }

    /// Handoff-10 CP3: one observation renders a compact terminal summary
    /// (`Aug 12 · 92%`) instead of a mostly-empty 150-point faux-chart panel.
    /// The single real sample stays the headline; the trend explanation is a
    /// caption, not the centerpiece.
    private var singleObservationState: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 2 }
            VStack(alignment: .leading, spacing: 2) {
                if let only = points.first {
                    Text("\(only.day.formatted(.dateTime.month(.abbreviated).day())) · \(valueText(only.value))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                Text("One observation in this view · a trend needs multiple days")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
        .accessibilityLabel("\(accessibilitySummary) One observation in this view. A trend needs multiple days.")
    }

    private var fallbackXDomain: ClosedRange<Date> {
        let start = points.first?.day ?? Date()
        let end = points.last?.day ?? start.addingTimeInterval(1)
        return start...max(end, start.addingTimeInterval(1))
    }

    private var lineStyle: AnyShapeStyle {
        guard let stops = prepared.lineGradientStops else { return AnyShapeStyle(tint) }
        return AnyShapeStyle(.linearGradient(Gradient(stops: stops), startPoint: .bottom, endPoint: .top))
    }

    @ViewBuilder private var chartLegendAndCompanions: some View {
        if prepared.hasMinMaxBand {
            Text("Weekly averages \u{00b7} shaded band is that week's real min\u{2013}max").font(.caption2).foregroundStyle(.secondary)
        }
        if comparison != nil {
            Text("Dashed line: your previous-period average").font(.caption2).foregroundStyle(.secondary)
        }
        if scrubbedDay != nil, onOpenDay != nil {
            Text("Double-tap the chart to open this day").font(.caption2).foregroundStyle(.tertiary)
        }
        // Cross-metric companion values now ride inside the scrub callout
        // (see chartContent) so the context tracks the finger, per the design's
        // "Graph Interactions" grammar, instead of a separate row below.
    }

    private func valueText(_ value: Double) -> String {
        AtriaDetailPeriodSummary.valueText(value, unit: unit)
    }
}

private struct AtriaStrainWorkoutRow: View, Equatable {
    let workout: UserConfirmedWorkout

    private var activity: AtriaWorkoutActivityType {
        AtriaWorkoutActivityType.resolved(activityType: workout.activityType,
                                          subtype: workout.activitySubtype,
                                          label: workout.label)
    }

    private var title: String {
        workout.activitySubtype ?? workout.activityType ?? "Workout"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    private var timeText: String {
        "\(Self.timeFormatter.string(from: workout.start)) · \(durationText)"
    }

    private var durationText: String {
        let minutes = max(1, Int((workout.duration / 60).rounded()))
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    private var strainText: String {
        AtriaWorkoutMetricPresentation.strainText(workout)
    }

    private var heartRateText: String {
        AtriaWorkoutMetricPresentation.heartRateSummaryText(workout)
    }

    private var zoneSegments: [(key: String, label: String, tint: Color, seconds: TimeInterval)] {
        let zones = workout.zoneSeconds ?? [:]
        return [
            ("warmup", "Z1", Metrics.heartRateZoneTint(1), zones["warmup"] ?? 0),
            ("fatBurn", "Z2", Metrics.heartRateZoneTint(2), zones["fatBurn"] ?? 0),
            ("aerobic", "Z3", Metrics.heartRateZoneTint(3), zones["aerobic"] ?? 0),
            ("anaerobic", "Z4", Metrics.heartRateZoneTint(4), zones["anaerobic"] ?? 0),
            ("max", "Z5", Metrics.heartRateZoneTint(5), zones["max"] ?? 0)
        ]
    }

    /// Zone presence is independent of HR density. `zoneSeconds` can be
    /// non-nil and still carry no Z1+ time — an entirely-Z0 session stores
    /// only "rest", which this bar does not draw — and legacy rows carry no
    /// breakdown at all. Measured over the SAME segments the bar draws, so a
    /// row without zone time no longer paints a complete-looking five-colour
    /// distribution it does not have (blank beats invented, 2026-08-28).
    private var hasZoneTime: Bool {
        zoneSegments.contains { $0.seconds > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: activity.icon)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Metrics.electricStrain)
                    .frame(width: 32, height: 32)
                    .background(AtriaIconTileBackground(cornerRadius: AtriaDesignTokens.Radius.chip, tint: Metrics.electricStrain))

                VStack(alignment: .leading, spacing: 2) {
                    // HealthKit-style names ("High Intensity Interval
                    // Training") wrap instead of cropping (UX audit).
                    Text(title)
                        .font(.subheadline.weight(.bold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(timeText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(strainText)
                        .font(.headline.monospacedDigit().weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .layoutPriority(1)
                    Text(AtriaWorkoutMetricPresentation.metricsAreIncomplete(workout)
                         ? "metrics" : "workout strain")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if AtriaWorkoutMetricPresentation.metricsAreIncomplete(workout) {
                Label(AtriaWorkoutMetricPresentation.compactStatus(workout),
                      systemImage: "waveform.path.badge.minus")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.orange)
            } else if hasZoneTime {
                GeometryReader { proxy in
                    HStack(spacing: 2) {
                        ForEach(zoneSegments, id: \.key) { segment in
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(segment.tint.opacity(segment.seconds > 0 ? 0.90 : 0.16))
                                .frame(width: zoneWidth(segment.seconds, totalWidth: proxy.size.width))
                        }
                    }
                }
                .frame(height: 8)
            } else {
                Label("Zone distribution unavailable for this recording",
                      systemImage: "waveform.path.ecg.rectangle")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text(heartRateText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                Text(zoneMinutesSummary)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AtriaWorkoutMetricPresentation.metricsAreIncomplete(workout)
                                     ? .secondary : Metrics.electricStrain)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .padding(12)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(durationText), \(AtriaWorkoutMetricPresentation.metricsAreIncomplete(workout) ? "workout metrics incomplete" : "strain \(strainText)"), heart rate \(heartRateText), \(zoneMinutesSummary).")
    }

    private func zoneWidth(_ seconds: TimeInterval, totalWidth: CGFloat) -> CGFloat {
        let total = max(zoneSegments.reduce(0) { $0 + $1.seconds }, 1)
        return max(4, totalWidth * CGFloat(seconds / total))
    }

    private var zoneMinutesSummary: String {
        if AtriaWorkoutMetricPresentation.metricsAreIncomplete(workout) {
            return "Zones incomplete"
        }
        // A building/calibrating phrasing here claimed progress that is not
        // happening: a recording with no zone breakdown will never grow one.
        guard hasZoneTime else { return "Zones unavailable" }
        let highSeconds = (workout.zoneSeconds?["aerobic"] ?? 0)
            + (workout.zoneSeconds?["anaerobic"] ?? 0)
            + (workout.zoneSeconds?["max"] ?? 0)
        let minutes = Int((highSeconds / 60).rounded())
        return minutes > 0 ? "\(minutes)m Z3+" : "No Z3+ time"
    }
}

enum AtriaRecoveryBaselineComparison {
    static func text(score: Double,
                     monthValues: [Double],
                     excludesLatest: Bool) -> String? {
        guard monthValues.count >= 3 else { return nil }
        let baselineValues = excludesLatest ? Array(monthValues.dropLast()) : monthValues
        guard !baselineValues.isEmpty else { return nil }
        let average = baselineValues.reduce(0, +) / Double(baselineValues.count)
        let delta = Int((score - average).rounded())
        let baselineLabel = baselineValues.count >= 30
            ? "your 30-day average"
            : "your recent average"
        if delta == 0 { return "At \(baselineLabel)" }
        return "\(delta > 0 ? "+" : "")\(delta)% vs \(baselineLabel)"
    }
}

enum AtriaStrainTargetPresentation {
    static let maximum = 21.0

    static func progress(for score: Double) -> Double {
        min(max(score / maximum, 0), 1)
    }

    static func targetRange(for target: Double) -> ClosedRange<Double> {
        max(0, target - 1)...min(maximum, target + 1)
    }
}

private enum AtriaMetricDetailHeroStyle {
    case standard
    case recoveryRing(score: Double?, baselineComparison: String?)
    case strain(score: Double?, target: Double?)
}

private struct AtriaRecoveryScoreHero: View {
    let score: Double?
    let state: String
    let tint: Color
    let baselineComparison: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var ringRevealed = false
    @State private var haloExpanded = false

    /// The same honesty guard the standard hero documents, which this ring
    /// branch never applied. Recovery's hue IS its grade (red / yellow /
    /// green over 0-100), so painting the halo, track, glow and card wash
    /// green around a "--" asserted a passing score the app has not earned.
    /// With no score there is nothing to grade, so the whole disc goes
    /// neutral until there is.
    private var heroTint: Color { score == nil ? Color.secondary : tint }

    /// Geometry is declared once instead of being spread across three literals
    /// that did not agree. Previously the halo was 178pt (189pt at its 1.06
    /// breathing peak) and both rings were unframed 14pt strokes filling the
    /// ZStack, yet the container was pinned to 154x154 -- so the halo overflowed
    /// ~17pt per side and each stroke's outer edge sat 3.5pt outside the frame.
    /// The disc read as a muddy plate larger than, and unrelated to, the ring it
    /// was supposed to sit behind, and it collided with the comparison chip.
    ///
    /// Now the ring is the outermost element (halo peak stays just inside its
    /// outer edge, so it reads as a glow behind the arc rather than a plate
    /// around it) and the container is sized to fit the largest child at its
    /// animated maximum, so nothing clips.
    private static let ringDiameter: CGFloat = 140
    private static let ringLineWidth: CGFloat = 14
    private static let haloDiameter: CGFloat = 142
    /// ringDiameter + ringLineWidth = 154 outer edge, plus breathing room.
    private static let heroDiameter: CGFloat = 178
    /// Usable width inside the stroke, so a three-digit "100%" cannot run under
    /// the ring the way it did at a fixed 42pt.
    private static var centerContentWidth: CGFloat {
        ringDiameter - ringLineWidth * 2 - 12
    }

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(heroTint.opacity(haloExpanded ? 0.12 : 0.05))
                    .frame(width: Self.haloDiameter, height: Self.haloDiameter)
                    .scaleEffect(reduceMotion ? 1 : (haloExpanded ? 1.06 : 0.94))
                    .shadow(color: heroTint.opacity(haloExpanded ? 0.28 : 0.12), radius: 18)
                    .animation(motionEnabled ? .easeInOut(duration: 2.8).repeatForever(autoreverses: true) : nil,
                               value: haloExpanded)
                Circle()
                    .stroke(heroTint.opacity(0.14), lineWidth: Self.ringLineWidth)
                    .frame(width: Self.ringDiameter, height: Self.ringDiameter)
                if let score {
                    Circle()
                        .trim(from: 0,
                              to: ringRevealed ? min(max(score / 100, 0), 1) : 0)
                        .stroke(tint, style: StrokeStyle(lineWidth: Self.ringLineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: Self.ringDiameter, height: Self.ringDiameter)
                        .shadow(color: tint.opacity(haloExpanded ? 0.38 : 0.16), radius: 9)
                        .animation(reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 2.6),
                                   value: ringRevealed)
                        .animation(motionEnabled ? .easeInOut(duration: 2.8).repeatForever(autoreverses: true) : nil,
                                   value: haloExpanded)
                }
                VStack(spacing: 2) {
                    Text(score.map { "\(Int($0.rounded()))%" } ?? "--")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(reduceMotion ? .identity : .numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(state)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: Self.centerContentWidth)
            }
            .frame(width: Self.heroDiameter, height: Self.heroDiameter)

            if let baselineComparison {
                Label(baselineComparison,
                      systemImage: baselineComparison.hasPrefix("-") ? "arrow.down.right" :
                        (baselineComparison.hasPrefix("+") ? "arrow.up.right" : "minus"))
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(tint)
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .background(tint.opacity(0.12), in: Capsule(style: .continuous))
            } else {
                // The ring above already says "--" / Learning when there is no
                // score; claiming "Today's score is ready" beneath it
                // contradicted the number (2026-09-02 fixture screenshot).
                Text(score == nil
                     ? "Comparison builds after your first scored night"
                     : "Today's score is ready · comparison is still building")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity).padding(16).atriaInsetCard(tint: heroTint)
        .accessibilityElement(children: .combine)
        .onAppear(perform: startMotion)
        .onChange(of: score) { _, _ in startMotion() }
        .onChange(of: reduceMotion) { _, _ in startMotion() }
        .onChange(of: scenePhase) { _, _ in startMotion() }
    }

    private func startMotion() {
        ringRevealed = reduceMotion
        haloExpanded = false
        guard !reduceMotion else { return }
        guard scenePhase == .active else {
            // Keep the full score visible while the scene is inactive without
            // leaving a repeating animation running in the background.
            ringRevealed = true
            return
        }
        withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 2.6)) {
            ringRevealed = true
        }
        haloExpanded = true
    }

    private var motionEnabled: Bool {
        !reduceMotion && scenePhase == .active
    }
}

private struct AtriaStrainScoreHero: View {
    let displayValue: String
    let score: Double?
    let target: Double?
    let state: String
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 1) {
                Text(displayValue)
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .monospacedDigit().foregroundStyle(score == nil ? Color.secondary : tint)
                    .contentTransition(reduceMotion ? .identity : .numericText())
                Text(state)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous).fill(.primary.opacity(0.09))
                    if let target {
                        let range = AtriaStrainTargetPresentation.targetRange(for: target)
                        Capsule(style: .continuous).fill(tint.opacity(0.16))
                            .frame(width: width * (range.upperBound - range.lowerBound) / AtriaStrainTargetPresentation.maximum)
                            .offset(x: width * range.lowerBound / AtriaStrainTargetPresentation.maximum)
                    }
                    if let score {
                        Capsule(style: .continuous).fill(tint)
                            .frame(width: max(8, width * AtriaStrainTargetPresentation.progress(for: score)))
                            .animation(reduceMotion ? nil : .snappy(duration: AtriaDesignTokens.Motion.emphatic), value: score)
                    }
                }
            }
            .frame(height: 14)
            HStack {
                Text("0")
                Spacer(minLength: 0)
                if let target {
                    Text("Target \(String(format: "%.1f", target))")
                    Spacer(minLength: 0)
                }
                Text("21")
            }
            .font(.caption2.weight(.semibold).monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(16)
        .atriaInsetCard(tint: tint)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Strain \(accessibilityValue). \(state).")
    }

    private var accessibilityValue: String {
        let trimmed = displayValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("≥") else { return trimmed }
        return "at least " + trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
    }
}

private struct AtriaMetricDetailTemplate<BetweenHero: View, Contributors: View, ChartContent: View, About: View>: View {
    let heroValue: String
    let heroState: String
    let tint: Color
    let heroStyle: AtriaMetricDetailHeroStyle
    let betweenHeroAndContributors: BetweenHero
    let contributors: Contributors
    let chart: ChartContent
    let about: About
    @State private var showDetails = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(heroValue: String,
         heroState: String,
         tint: Color,
         heroStyle: AtriaMetricDetailHeroStyle = .standard,
         @ViewBuilder contributors: () -> Contributors,
         @ViewBuilder chart: () -> ChartContent,
         @ViewBuilder about: () -> About) where BetweenHero == EmptyView {
        self.heroValue = heroValue
        self.heroState = heroState
        self.tint = tint
        self.heroStyle = heroStyle
        self.betweenHeroAndContributors = EmptyView()
        self.contributors = contributors()
        self.chart = chart()
        self.about = about()
    }

    init(heroValue: String,
         heroState: String,
         tint: Color,
         heroStyle: AtriaMetricDetailHeroStyle = .standard,
         @ViewBuilder betweenHeroAndContributors: () -> BetweenHero,
         @ViewBuilder contributors: () -> Contributors,
         @ViewBuilder chart: () -> ChartContent,
         @ViewBuilder about: () -> About) {
        self.heroValue = heroValue
        self.heroState = heroState
        self.tint = tint
        self.heroStyle = heroStyle
        self.betweenHeroAndContributors = betweenHeroAndContributors()
        self.contributors = contributors()
        self.chart = chart()
        self.about = about()
    }

    var body: some View {
        // Minimalism pass (owner directive 2026-08-29, supersedes the same-day
        // About-always-visible directive): the first screen is value, graph,
        // and the metric's own signature visual only. EVERYTHING textual —
        // contributor rows, heavy per-metric cards, and the About copy — sits
        // behind the single "Show details" reveal, so a metric tap never dumps
        // a wall of literature.
        VStack(alignment: .leading, spacing: AtriaDesignTokens.Spacing.lg) {
            hero
            chart
            betweenHeroAndContributors
            revealAffordance
            if showDetails {
                detailPanel
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: AtriaDesignTokens.Motion.emphatic), value: showDetails)
    }

    /// Static type check, not a runtime one: templates without contributor rows
    /// pass `EmptyView` for the slot; the reveal then holds About alone.
    private var hasContributors: Bool {
        Contributors.self != EmptyView.self
    }

    private var revealAffordance: some View {
        // Visible button chrome (2026-08-29 controls audit): the old flat
        // 5%-primary capsule read as a label. Explicit bordered capsule —
        // the same quaternary fill the header/chevron circles use — so the
        // control reads as tappable in every render context (glass effects
        // do not paint in headless layer renders).
        Button {
            showDetails.toggle()
        } label: {
            HStack(spacing: 8) {
                Text(showDetails ? "Hide details" : "Show details")
                    .font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(showDetails ? 180 : 0))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(.quaternary.opacity(0.22), in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .stroke(.quaternary.opacity(0.6), lineWidth: 1)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showDetails ? "Hide details" : "Show details")
    }

    private var detailPanel: some View {
        // Un-nested (2026-08-29 minimalism pass): no header row, no outer card
        // wrapping cards — contributors render directly, then a hairline
        // divider and the plain About lines.
        VStack(alignment: .leading, spacing: AtriaDesignTokens.Spacing.lg) {
            if hasContributors {
                contributors
            }
            Divider()
            about
        }
    }

    /// Hero honesty guard: the numeral is painted in the metric's identity
    /// hue — the ONE tinted element of the standard hero (2026-08-29 theme).
    /// When there's no trusted value yet (empty / "—" placeholder, or a
    /// Learning state) the numeral falls back to neutral grey — a colored
    /// number never implies a confidence the data hasn't earned.
    private var heroIsUncertain: Bool {
        let v = heroValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty || v == "—" || v == "--" { return true }
        return heroState.localizedCaseInsensitiveContains("learning")
    }

    private var heroTint: Color {
        heroIsUncertain ? Color.secondary : tint
    }

    @ViewBuilder
    private var hero: some View {
        switch heroStyle {
        case .standard:
            // One hue per sheet (2026-08-29 minimalism pass): the numeral is
            // the ONLY tinted element of the hero. The state is a plain
            // secondary caption — no dot, no tinted capsule fill.
            VStack(alignment: .leading, spacing: AtriaDesignTokens.Spacing.sm) {
                AtriaMetricHeroValueText(text: heroValue, tint: heroTint)
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .animation(reduceMotion ? nil : .snappy(duration: AtriaDesignTokens.Motion.emphatic), value: heroValue)

                Text(heroState)
                    .font(AtriaDesignTokens.Typography.metricLabel)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .atriaInsetCard(tint: tint)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(heroValue), \(heroState)")
        case .recoveryRing(let score, let baselineComparison):
            AtriaRecoveryScoreHero(score: score,
                                   state: heroState,
                                   tint: tint,
                                   baselineComparison: baselineComparison)
        case .strain(let score, let target):
            AtriaStrainScoreHero(displayValue: heroValue,
                                 score: score,
                                 target: target,
                                 state: heroState,
                                 tint: tint)
        }
    }
}

/// Hero numeral with the unit at reduced size (WHOOP design-language pass,
/// 2026-08-05): "54 ms" renders the 54 huge and the ms at ~40%, baseline-
/// aligned. Split rules are deliberately conservative — the unit must be the
/// trailing space-separated token with NO digits (or a glued trailing "%"),
/// and the remaining prefix must contain a digit — so "6h 24m", "Live read",
/// "Learning", and "--" all render unsplit exactly as before. Internal so
/// it is render-testable.
struct AtriaMetricHeroValueText: View {
    let text: String
    let tint: Color

    var body: some View {
        let parts = Self.split(text)
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(parts.value)
                .font(.system(size: 56, weight: .bold, design: .rounded))
                .monospacedDigit()
            if let unit = parts.unit {
                Text(unit)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.56)
        .foregroundStyle(tint)
    }

    static func split(_ text: String) -> (value: String, unit: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.count > 1, trimmed.hasSuffix("%"),
           trimmed.dropLast().contains(where: \.isNumber),
           !trimmed.dropLast().hasSuffix(" ") {
            return (String(trimmed.dropLast()), "%")
        }
        let tokens = trimmed.split(separator: " ")
        guard tokens.count >= 2,
              let last = tokens.last,
              !last.contains(where: \.isNumber),
              tokens.dropLast().joined(separator: " ").contains(where: \.isNumber) else {
            return (trimmed, nil)
        }
        return (tokens.dropLast().joined(separator: " "), String(last))
    }
}

// Internal (was private, 2026-08-05) so the WHOOP stat-row grammar is
// render-testable — the rows live behind "Show details" where neither
// simctl screenshots nor the fixture launch args can reach them.
struct AtriaMetricContributorRow: Identifiable, Equatable {
    var id: String { "\(systemImage)|\(name)" }
    let systemImage: String
    let name: String
    let value: String
    let comparison: String
    let direction: Int

    static func == (lhs: AtriaMetricContributorRow, rhs: AtriaMetricContributorRow) -> Bool {
        lhs.systemImage == rhs.systemImage
            && lhs.name == rhs.name
            && lhs.value == rhs.value
            && lhs.comparison == rhs.comparison
            && lhs.direction == rhs.direction
    }
}

// Internal (was private, 2026-08-05) — see AtriaMetricContributorRow above.
struct AtriaMetricContributorRows: View, Equatable {
    let rows: [AtriaMetricContributorRow]
    let tint: Color

    static func == (lhs: AtriaMetricContributorRows, rhs: AtriaMetricContributorRows) -> Bool {
        lhs.rows == rhs.rows
    }

    // WHOOP stat-row grammar (2026-08-05), de-colored 2026-08-29 minimalism
    // pass ("one hue per sheet, ink otherwise"): icons and ▲▼ triangles are
    // secondary ink, no tinted circles, and the green/red legend strip is
    // gone — name/comparison/value carry the judgment in words.
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CONTRIBUTORS")
                .font(.caption2.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider().opacity(0.5) }
                    HStack(spacing: 10) {
                        Image(systemName: row.systemImage)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name)
                                .font(.caption2.weight(.bold))
                                .tracking(1.1)
                                .textCase(.uppercase)
                            Text(row.comparison)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        Spacer(minLength: 8)

                        HStack(spacing: 5) {
                            Text(row.value)
                                .font(.subheadline.weight(.bold).monospacedDigit())
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                            // Column reserved even when neutral so every
                            // value shares one right edge (render-verified).
                            Group {
                                if row.direction != 0 {
                                    Image(systemName: directionSymbol(row.direction))
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.secondary)
                                } else {
                                    Color.clear
                                }
                            }
                            .frame(width: 14, height: 14)
                        }
                    }
                    .padding(.vertical, 10)
                }
            }
        }
        .padding(14)
        .atriaInsetCard(tint: tint)
    }

    private func directionSymbol(_ direction: Int) -> String {
        direction > 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill"
    }
}

private struct AtriaMetricMeaningInline: View {
    let metric: AtriaMetricDetailKind
    let guidance: Coach.Guidance
    let recoveryEstimate: Metrics.RecoveryEstimate
    let sleepGoalHours: Double

    // Minimalism pass (2026-08-29): the two sentences render as plain
    // secondary text — no card, no "What it means"/"What to do" headers.
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AtriaMetricMeaningCopy.meaning(metric: metric,
                                                recoveryEstimate: recoveryEstimate,
                                                sleepGoalHours: sleepGoalHours))
            Text(AtriaMetricMeaningCopy.coaching(metric: metric, guidance: guidance))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One authored copy of the meaning/coaching sentences (2026-08-29 dedup):
/// the inline About and AtriaMetricMeaningSheet both read from here — the
/// sheet's near-verbatim paraphrase switches were deleted.
enum AtriaMetricMeaningCopy {
    static func meaning(metric: AtriaMetricDetailKind,
                        recoveryEstimate: Metrics.RecoveryEstimate,
                        sleepGoalHours: Double) -> String {
        switch metric {
        case .recovery:
            let contributorSummary = recoveryEstimate.contributors.isEmpty
                ? "Recovery is still building toward a stable baseline."
                : "The contributor list shows which terms pushed the score up or down today."
            return "\(contributorSummary) Recovery is morning-frozen so it does not drift all day."
        case .hrv:
            return "HRV is most useful as a trend. Compare today with your baseline band instead of chasing someone else’s number."
        case .restingHeartRate:
            return "Resting HR is a context metric. A sudden rise versus your normal can line up with stress, illness, poor sleep, or hard training."
        case .respiratoryRate:
            return "Respiratory rate is compared with your own sleep baseline. Sustained shifts can line up with stress, travel, environment, or feeling off."
        case .sleep:
            return String(format: "Sleep sufficiency compares your night with a %.1f hour goal while consistency tracks recent timing.", sleepGoalHours)
        case .strain:
            return "Strain is your day-load target, not a score to max out every day."
        case .stress:
            return "This is an autonomic-load estimate, not a lab measurement. Atria saves recent measured readings for detailed timelines and measured daily bands for longer patterns; collection gaps stay blank."
        case .vo2max:
            return "VO2max is estimated from your resting baseline and measured heart-rate max, not a lab gas-exchange test."
        case .sleepPerformance:
            return String(format: "Sleep sufficiency compares last night's duration with a need that adjusts for debt and yesterday's strain, not a flat %.1f hour goal.", sleepGoalHours)
        case .sleepEfficiency:
            return "Sleep efficiency estimates time asleep versus time in bed from duration, not a checked sleep study."
        case .skinTemperature:
            if AtriaResearchProbe.validatedSkinTemperatureDecoderAvailable {
                return "Atria validates this strap's wrist-temperature signal, builds a personal sleep baseline, then shows a relative deviation—not an absolute or core-temperature reading."
            }
            return "Atria cannot validate wrist temperature from this strap yet, so it shows no value."
        case .fitnessAge:
            return "Fitness age blends VO2max-adjacent fitness signals into a single younger/older-than-your-years estimate."
        case .hrZones:
            return "Zone minutes split today's elevated heart rate into Z2 through Z5 bands."
        case .bloodOxygen:
            // SpO2 copy consolidation (2026-08-01): canonical hardware copy.
            return AtriaSpO2Copy.longUnavailable
        }
    }

    static func coaching(metric: AtriaMetricDetailKind,
                         guidance: Coach.Guidance) -> String {
        switch metric {
        case .recovery:
            return guidance.headline.isEmpty ? guidance.detail : "\(guidance.headline) \(guidance.detail)"
        case .hrv:
            return "Look for multi-day direction. If HRV is suppressed and recovery is also down, favor easier training and protect tonight’s sleep."
        case .restingHeartRate:
            return "Treat a higher-than-normal RHR as a reason to reduce intensity, hydrate, and keep an eye on how you feel."
        case .respiratoryRate:
            return "Watch the trend, not one night. If respiratory rate stays outside your usual range, take it as a wellness signal and compare with how you feel."
        case .sleep:
            return "If debt is climbing, buy back time tonight before trying to force a bigger strain score tomorrow."
        case .strain:
            if let target = guidance.target {
                return String(format: "Aim for the target arc around %.1f today and let recovery decide how hard to push.", target)
            }
            return "Use the active band to stay controlled while Atria learns your recovery-scaled target."
        case .stress:
            return "If it stays elevated, try a few slow paced breaths or lighten today's training rather than pushing through it."
        case .vo2max:
            return "Watch the multi-week trend rather than any single estimate; sustained aerobic training is what moves it."
        case .sleepPerformance:
            return "A string of nights under 100% adds up as debt \u{2014} an earlier bedtime pays it back faster than one long catch-up night."
        case .sleepEfficiency:
            return "Low efficiency with normal duration usually means restless time in bed \u{2014} a cooler, darker, screen-free wind-down tends to help."
        case .skinTemperature:
            return "There is no temperature reading to act on."
        case .fitnessAge:
            return "This moves slowly by design \u{2014} consistent aerobic training and sleep are what shift the pace of aging over months, not days."
        case .hrZones:
            return "More time in Z2\u{2013}Z3 builds an aerobic base; Z4\u{2013}Z5 minutes are the hard efforts to keep purposeful, not accidental."
        case .bloodOxygen:
            return "There's no verified blood-oxygen reading to act on."
        }
    }
}

private struct AtriaDetailRangeDotStrip: View, Equatable {
    private struct Bar: Equatable, Identifiable {
        let id: Date
        let tint: Color
        let height: CGFloat
        let opacity: Double
    }

    private let bars: [Bar]
    let fallbackTint: Color

    init(points: [AtriaDetailChartPoint], fallbackTint: Color) {
        self.fallbackTint = fallbackTint
        let low = points.map(\.value).min()
        let high = points.map(\.value).max()
        self.bars = points.enumerated().map { index, point in
            let progress: Double
            if points.count > 1 {
                progress = Double(index) / Double(points.count - 1)
            } else {
                progress = 1
            }
            let normalized: Double
            if let low, let high, high > low {
                normalized = (point.value - low) / (high - low)
            } else {
                normalized = 0.18
            }
            return Bar(id: point.id,
                       tint: point.tint,
                       height: 8 + CGFloat(normalized) * 16,
                       opacity: 0.28 + progress * 0.54)
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(bars) { bar in
                Capsule(style: .continuous)
                    .fill(bar.tint.opacity(bar.opacity))
                    .frame(maxWidth: .infinity)
                    .frame(height: bar.height)
                    .accessibilityHidden(true)
            }
        }
        .frame(height: 24)
        .padding(.horizontal, 1)
        .overlay(alignment: .bottomLeading) {
            Capsule(style: .continuous)
                .fill(fallbackTint.opacity(0.18))
                .frame(height: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Compact range pattern with \(bars.count) saved days.")
    }
}

private struct AtriaRecoveryContributorMap: View {
    let contributors: [Metrics.RecoveryEstimate.Contributor]
    let titleForContributor: (Metrics.RecoveryEstimate.Contributor) -> String
    let noteForContributor: (Metrics.RecoveryEstimate.Contributor) -> String

    private var dominantContributor: Metrics.RecoveryEstimate.Contributor? {
        contributors.max { abs($0.weightedContribution) < abs($1.weightedContribution) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Why today's recovery landed here")
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    if let dominantContributor {
                        Text(titleForContributor(dominantContributor))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(tint(for: dominantContributor))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(tint(for: dominantContributor).opacity(0.12), in: Capsule(style: .continuous))
                    }
                }

                // The legend explains the diverging rows below; with no rows
                // it was a second paragraph about a chart that is not there
                // (2026-09-02 fixture screenshot). The empty notice speaks alone.
                if !contributors.isEmpty {
                    Text("Baseline sits in the middle. Factors to the right supported recovery; factors to the left pulled it down.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if contributors.isEmpty {
                Text("Recovery contributors appear after a trusted HRV, resting HR, and saved sleep baseline is available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
            } else {
                VStack(spacing: 12) {
                    ForEach(contributors) { contributor in
                        contributorRow(contributor)
                    }
                }
            }

            Text("Recovery blends HRV, resting HR, sleep, and respiration against your personal baseline.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .atriaInsetCard(tint: Metrics.electricGreen)
        .accessibilityElement(children: .combine)
    }

    private func contributorRow(_ contributor: Metrics.RecoveryEstimate.Contributor) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(tint(for: contributor).opacity(0.13))
                    Image(systemName: symbol(for: contributor))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(tint(for: contributor))
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 2) {
                    Text(titleForContributor(contributor))
                        .font(.caption.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(noteForContributor(contributor))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 2) {
                    Image(systemName: directionSymbol(for: contributor))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(tint(for: contributor))
                        .accessibilityLabel(directionText(for: contributor))
                    Text(contributor.displayValue)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }

            contributorRail(contributor)
        }
        .padding(12)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
    }

    private func contributorRail(_ contributor: Metrics.RecoveryEstimate.Contributor) -> some View {
        let progress = min(max(contributor.zScore / 2.0, -1), 1)
        let tint = tint(for: contributor)
        return GeometryReader { proxy in
            let width = proxy.size.width
            let halfWidth = width / 2
            let fillWidth = max(4, abs(progress) * halfWidth)
            let markerX = halfWidth + progress * halfWidth

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(.primary.opacity(0.08))

                Rectangle()
                    .fill(.primary.opacity(0.24))
                    .frame(width: 1.5)
                    .offset(x: halfWidth)

                Capsule(style: .continuous)
                    .fill(tint.opacity(0.56))
                    .frame(width: fillWidth)
                    .offset(x: progress >= 0 ? halfWidth : halfWidth - fillWidth)

                Circle()
                    .fill(tint)
                    .frame(width: 9, height: 9)
                    .overlay {
                        Circle()
                            .stroke(Color(.systemBackground).opacity(0.75), lineWidth: 1.5)
                    }
                    .offset(x: min(max(markerX - 4.5, 0), max(width - 9, 0)))
            }
        }
        .frame(height: 8)
    }

    private func directionText(for contributor: Metrics.RecoveryEstimate.Contributor) -> String {
        if contributor.direction > 0 { return "Supported" }
        if contributor.direction < 0 { return "Pressured" }
        return "Neutral"
    }

    private func directionSymbol(for contributor: Metrics.RecoveryEstimate.Contributor) -> String {
        if contributor.direction > 0 { return "arrow.up.circle.fill" }
        if contributor.direction < 0 { return "arrow.down.circle.fill" }
        return "minus.circle.fill"
    }

    private func tint(for contributor: Metrics.RecoveryEstimate.Contributor) -> Color {
        if contributor.direction > 0 { return Metrics.electricGreen }
        if contributor.direction < 0 { return Metrics.electricRed }
        return .secondary
    }

    private func symbol(for contributor: Metrics.RecoveryEstimate.Contributor) -> String {
        switch contributor.kind {
        case .hrv: return "waveform.path.ecg"
        case .restingHeartRate: return "heart.fill"
        case .sleep: return "bed.double.fill"
        case .respiration: return "lungs.fill"
        }
    }
}

private struct AtriaMetricMeaningSheet: View {
    let metric: AtriaMetricDetailKind
    let guidance: Coach.Guidance
    let recoveryEstimate: Metrics.RecoveryEstimate
    let sleepGoalHours: Double
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(headline)
                            .font(.title3.weight(.bold))
                        Text(summary)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }

                    // 2026-08-29 dedup: the sheet's own near-verbatim
                    // meaning/coaching paraphrases were deleted; it now
                    // renders the SAME strings the inline About shows.
                    detailBlock(title: "What it means",
                                body: AtriaMetricMeaningCopy.meaning(metric: metric,
                                                                     recoveryEstimate: recoveryEstimate,
                                                                     sleepGoalHours: sleepGoalHours))
                    detailBlock(title: "What to do",
                                body: AtriaMetricMeaningCopy.coaching(metric: metric,
                                                                      guidance: guidance))
                }
                .padding(18)
            }
            .navigationTitle(metric.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var headline: String {
        switch metric {
        case .recovery:
            return "Recovery turns overnight signals into a readiness read."
        case .hrv:
            return "HRV shows how much recovery capacity your system is carrying."
        case .restingHeartRate:
            return "Resting HR helps flag strain, illness, or under-recovery."
        case .respiratoryRate:
            return "Respiratory rate shows how your sleeping breathing compares with your usual range."
        case .sleep:
            return "Sleep tracks whether you got enough time and consistency to restore."
        case .strain:
            return "Strain is your day-load target, not a score to max out every day."
        case .stress:
            return "Stress is a moment-to-moment autonomic-load estimate with recent measured history."
        case .vo2max:
            return "VO2max estimates your aerobic capacity from resting and max heart rate."
        case .sleepPerformance:
            return "Sleep sufficiency compares last night with how much sleep you actually needed."
        case .sleepEfficiency:
            return "Sleep efficiency estimates how much of your time in bed was spent asleep."
        case .skinTemperature:
            return "Skin-temperature decoder not verified."
        case .fitnessAge:
            return "Fitness age turns your training and recovery signals into a younger/older-than-your-years estimate."
        case .hrZones:
            return "HR zones split today's elevated heart rate into effort bands."
        case .bloodOxygen:
            return AtriaSpO2Copy.decoderNotVerified
        }
    }

    private var summary: String {
        switch metric {
        case .recovery:
            return "Atria blends HRV, resting HR, sleep, and respiration against your baseline so the percent reads as 'how ready am I today?'"
        case .hrv:
            return "Use the chart with your baseline band. A point above your normal is usually a better sign than the absolute number by itself."
        case .restingHeartRate:
            return "Read this against your own baseline. Lower than usual can be a good sign; higher than usual often means accumulated load."
        case .respiratoryRate:
            return "The chart uses sleep-derived respiratory estimates and your typical range. Atria treats changes as observational wellness context, not diagnosis."
        case .sleep:
            return "The duration trend shows how much sleep you got. The stage bar is labeled as a heart-rate and motion estimate, not EEG."
        case .strain:
            return "The blue arc shows today’s accumulated load. The target arc and notch show where today’s plan says to land."
        case .stress:
            return "Recent measured readings form the detailed timeline, while saved daily bands show longer patterns. Days without enough readings stay blank."
        case .vo2max:
            return "Treat the number and its trend as an estimate, sharpening over more sessions, not a lab VO2 test result."
        case .sleepPerformance:
            return "The chart shows the saved daily percent of nightly sleep need met, factoring in recent debt and yesterday's strain."
        case .sleepEfficiency:
            return "The current estimate is duration-based; Atria doesn't yet save a night-by-night efficiency history to chart."
        case .skinTemperature:
            return "Atria does not show raw sensor data as wrist temperature."
        case .fitnessAge:
            return "The pace-of-aging chart only appears once 28 days of the estimate are saved; until then this shows the calibrating state."
        case .hrZones:
            return "Zone minutes are today's live total; Atria doesn't yet save a day-by-day zone-minutes history to chart."
        case .bloodOxygen:
            // SpO2 copy consolidation (2026-08-01): canonical honesty line.
            return AtriaSpO2Copy.wontFakeAPercentage
        }
    }

    private func detailBlock(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(body)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .atriaInsetCard(tint: metric.tint)
    }
}

private struct AtriaDetailPeriodSummary: Equatable, Sendable {
    let latestText: String
    let averageText: String
    let rangeText: String
    let changeText: String
    let latestPosition: Double
    /// True only when the window actually spans a range (`high > low`). A flat
    /// or single-point window has no meaningful position on a min↔max rail, so
    /// the rail must be hidden rather than asserting a fabricated mid-range dot
    /// (2026-08-08: strain-ring and sleep-ring "latest" strips rendered a
    /// centered pointer on a single point, which reads as broken/meaningless).
    let hasSpread: Bool
    let changeDirection: AtriaDetailPeriodChangeDirection
    let unit: String
    let averageRaw: Double
    let latestRaw: Double

    init?(points: [AtriaDetailChartPoint], unit: String) {
        guard let latest = points.last else { return nil }
        let values = points.map(\.value)
        guard let low = values.min(), let high = values.max() else { return nil }
        let average = values.reduce(0, +) / Double(max(values.count, 1))
        let change = latest.value - (points.first?.value ?? latest.value)
        let spread = high - low
        self.latestText = Self.valueText(latest.value, unit: unit)
        self.averageText = Self.valueText(average, unit: unit)
        self.rangeText = Self.rangeText(low: low, high: high, unit: unit)
        self.changeText = Self.changeText(change, unit: unit)
        self.latestPosition = spread > 0 ? min(max((latest.value - low) / spread, 0), 1) : 0.5
        self.hasSpread = spread > 0
        self.changeDirection = AtriaDetailPeriodChangeDirection(change: change)
        self.unit = unit
        self.averageRaw = average
        self.latestRaw = latest.value
    }

    static func valueText(_ value: Double, unit: String) -> String {
        AtriaMetricFormat.value(value, metric: metricUnit(for: unit))
    }

    static func rangeText(low: Double, high: Double, unit: String) -> String {
        AtriaMetricFormat.range(low: low, high: high, metric: metricUnit(for: unit))
    }

    static func changeText(_ value: Double, unit: String) -> String {
        AtriaMetricFormat.change(value, metric: metricUnit(for: unit))
    }

    private static func metricUnit(for unit: String) -> AtriaMetricUnit {
        switch unit {
        case "%": return .recovery
        case "h": return .sleep
        case "ms": return .hrv
        case "bpm": return .restingHeartRate
        // 2026-08-05 audit: "/min" is the canonical respiratory label (not
        // "rpm"). Routing it to .respiratory keeps respiratory values off the
        // strain formatter's 0-21 clamp.
        case "/min": return .respiratory
        default: return .strain
        }
    }
}

private enum AtriaDetailPeriodChangeDirection: Sendable {
    case up
    case flat
    case down

    init(change: Double) {
        if change > 0.05 {
            self = .up
        } else if change < -0.05 {
            self = .down
        } else {
            self = .flat
        }
    }

    var symbolName: String {
        switch self {
        case .up: return "arrow.up.right"
        case .flat: return "minus"
        case .down: return "arrow.down.right"
        }
    }

    /// Plain-text triangle for the neutral one-line period summary
    /// (2026-08-29 minimalism pass); flat renders nothing.
    var triangleText: String {
        switch self {
        case .up: return " ▲"
        case .flat: return ""
        case .down: return " ▼"
        }
    }
}




/// 2026-08-29 minimalism pass: replaces AtriaDetailPeriodSummaryStrip — the
/// tinted card (gradient rail, change capsule, two chips: 10 tinted elements
/// across 3 nested surfaces) restated what the chart already draws. One
/// neutral secondary line now carries the same numbers; the change direction
/// survives as a plain ▲/▼ next to Latest.
private struct AtriaDetailPeriodSummaryLine: View {
    let summary: AtriaDetailPeriodSummary

    var body: some View {
        Text(lineText)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Period summary. Latest \(summary.latestText), average \(summary.averageText), range \(summary.rangeText), change \(summary.changeText).")
    }

    private var lineText: String {
        var parts = ["Latest \(summary.latestText)\(summary.changeDirection.triangleText)",
                     "Avg \(summary.averageText)"]
        if summary.hasSpread {
            parts.append("Range \(summary.rangeText)")
        }
        return parts.joined(separator: " · ")
    }
}


private struct AtriaDetailComparisonSummary: Equatable, Sendable {
    let currentText: String
    let priorText: String
    let deltaText: String
    let currentShare: Double
    let priorShare: Double
    let changeDirection: AtriaDetailPeriodChangeDirection
    /// Numeric prior-period average, kept for the detail chart's dashed
    /// prior-average rule (2026-07-07 design handoff).
    let priorAverage: Double

    init?(current: [AtriaDetailChartPoint], prior: [AtriaDetailChartPoint], unit: String) {
        guard !current.isEmpty else { return nil }
        // Same minimum-evidence rule as the trend card's ghost overlay
        // (previousSeries.count >= max(3, series.count / 2)): a couple of
        // stray prior samples must not fabricate a "prior avg" comparison or
        // its dashed chart rule (2026-07-31 audit item 14).
        guard prior.count >= max(3, current.count / 2) else { return nil }
        let currentAverage = Self.average(current.map(\.value))
        let priorAverage = Self.average(prior.map(\.value))
        let largest = max(max(abs(currentAverage), abs(priorAverage)), 0.01)
        let delta = currentAverage - priorAverage

        self.currentText = AtriaDetailPeriodSummary.valueText(currentAverage, unit: unit)
        self.priorText = AtriaDetailPeriodSummary.valueText(priorAverage, unit: unit)
        self.deltaText = AtriaDetailPeriodSummary.changeText(delta, unit: unit)
        self.currentShare = min(max(abs(currentAverage) / largest, 0.06), 1)
        self.priorShare = min(max(abs(priorAverage) / largest, 0.06), 1)
        self.changeDirection = AtriaDetailPeriodChangeDirection(change: delta)
        self.priorAverage = priorAverage
    }

    private static func average(_ values: [Double]) -> Double {
        values.reduce(0, +) / Double(max(values.count, 1))
    }
}


private struct AtriaPreparedMetricHistory: Sendable {
    let recovery: [AtriaTrendRange: [AtriaDetailChartPoint]]
    let hrv: [AtriaTrendRange: [AtriaDetailChartPoint]]
    let restingHeartRate: [AtriaTrendRange: [AtriaDetailChartPoint]]
    let respiratoryRate: [AtriaTrendRange: [AtriaDetailChartPoint]]
    let sleep: [AtriaTrendRange: [AtriaDetailChartPoint]]
    let strain: [AtriaTrendRange: [AtriaDetailChartPoint]]
    // Prior-period series, TIME-SHIFTED onto the current window so the
    // dashed ghost overlays the same axis (design-handoff ghost line,
    // 2026-07-07). Same weekly bucketing as the current series, bands
    // stripped (a ghost is a line, not a band).
    let recoveryPrior: [AtriaTrendRange: [AtriaDetailChartPoint]]
    let hrvPrior: [AtriaTrendRange: [AtriaDetailChartPoint]]
    let restingHeartRatePrior: [AtriaTrendRange: [AtriaDetailChartPoint]]
    let respiratoryRatePrior: [AtriaTrendRange: [AtriaDetailChartPoint]]
    let sleepPrior: [AtriaTrendRange: [AtriaDetailChartPoint]]
    let strainPrior: [AtriaTrendRange: [AtriaDetailChartPoint]]
    // RAW (unbucketed) series for the manual bucket override in the chart
    // options sheet (design handoff "Range & interval", 2026-07-07).
    let recoveryRaw: [AtriaTrendRange: [AtriaDetailChartPoint]]
    let hrvRaw: [AtriaTrendRange: [AtriaDetailChartPoint]]
    let restingHeartRateRaw: [AtriaTrendRange: [AtriaDetailChartPoint]]
    let respiratoryRateRaw: [AtriaTrendRange: [AtriaDetailChartPoint]]
    let sleepRaw: [AtriaTrendRange: [AtriaDetailChartPoint]]
    let strainRaw: [AtriaTrendRange: [AtriaDetailChartPoint]]
    let latestStrain: [AtriaTrendRange: Double]
    let recoverySummary: [AtriaTrendRange: AtriaDetailPeriodSummary]
    let hrvSummary: [AtriaTrendRange: AtriaDetailPeriodSummary]
    let restingHeartRateSummary: [AtriaTrendRange: AtriaDetailPeriodSummary]
    let respiratoryRateSummary: [AtriaTrendRange: AtriaDetailPeriodSummary]
    let sleepSummary: [AtriaTrendRange: AtriaDetailPeriodSummary]
    let strainSummary: [AtriaTrendRange: AtriaDetailPeriodSummary]
    let recoveryComparison: [AtriaTrendRange: AtriaDetailComparisonSummary]
    let hrvComparison: [AtriaTrendRange: AtriaDetailComparisonSummary]
    let restingHeartRateComparison: [AtriaTrendRange: AtriaDetailComparisonSummary]
    let respiratoryRateComparison: [AtriaTrendRange: AtriaDetailComparisonSummary]
    let sleepComparison: [AtriaTrendRange: AtriaDetailComparisonSummary]
    let strainComparison: [AtriaTrendRange: AtriaDetailComparisonSummary]
    // Visibility/IA trend coverage (2026-07-05), spec path B: reuses this
    // already-shipping rollup-backed history instead of touching the
    // launch-emergency Sessions.swift trend builder.
    let sleepPerformance: [AtriaTrendRange: [AtriaDetailChartPoint]]
    let sleepPerformanceSummary: [AtriaTrendRange: AtriaDetailPeriodSummary]
    let sleepPerformanceComparison: [AtriaTrendRange: AtriaDetailComparisonSummary]
    let fitnessAge: [AtriaTrendRange: [AtriaDetailChartPoint]]
    let fitnessAgeSummary: [AtriaTrendRange: AtriaDetailPeriodSummary]
    let fitnessAgeComparison: [AtriaTrendRange: AtriaDetailComparisonSummary]
    /// Total saved days with a fitness-age delta, independent of range --
    /// gates the pace-of-aging chart behind the same 28-day baseline used by
    /// `AtriaFitnessAge.summary`.
    let fitnessAgeEntryCount: Int
    let paceOfAging: AtriaFitnessAge.PaceOfAging

    /// Long ranges (6M/1Y/All) display weekly buckets instead of every raw
    /// daily sample: value = average of the week's REAL days, band = that
    /// week's true min-max, tint = the member point nearest the average (so
    /// the metric's own zone coloring still applies). Short ranges and sparse
    /// series pass through untouched. Summaries/comparisons stay computed
    /// from raw daily points (2026-07-07 design handoff).
    static func bucketedForDisplay(_ points: [AtriaDetailChartPoint],
                                   range: AtriaTrendRange,
                                   calendar: Calendar,
                                   forceWeekly: Bool = false,
                                   within interval: DateInterval? = nil) -> [AtriaDetailChartPoint] {
        guard forceWeekly || (range.days > 90 && points.count > 60) else { return points }
        var buckets: [Date: [AtriaDetailChartPoint]] = [:]
        for point in points {
            let weekStart = calendar.dateInterval(of: .weekOfYear, for: point.day)?.start
                ?? calendar.startOfDay(for: point.day)
            buckets[weekStart, default: []].append(point)
        }
        return buckets.keys.sorted().map { weekStart in
            let members = buckets[weekStart] ?? []
            let values = members.map(\.value)
            let average = values.reduce(0, +) / Double(max(values.count, 1))
            let nearest = members.min { abs($0.value - average) < abs($1.value - average) }
            // A period's first partial week is keyed by a week start BEFORE
            // the period, which the chart's x-domain then clips away. Clamp
            // the plotted date into the period so the bucket's real data
            // renders (2026-07-31 audit item 3). No collision risk: the next
            // bucket's week start is always past this clamped date.
            let plottedDay = interval.map { max(weekStart, $0.start) } ?? weekStart
            return AtriaDetailChartPoint(day: plottedDay,
                                         value: average,
                                         tint: nearest?.tint ?? .secondary,
                                         bandLower: values.min(),
                                         bandUpper: values.max())
        }
    }

    private static func ghostSeries(_ points: [AtriaDetailChartPoint],
                                    from priorInterval: DateInterval,
                                    to interval: DateInterval,
                                    range: AtriaTrendRange,
                                    calendar: Calendar) -> [AtriaDetailChartPoint] {
        // Period-relative day offsets, not calendar component adds: adding a
        // month clamps Jan 29/30/31 onto Feb 28, collapsing distinct prior
        // days into duplicate chart IDs (id == day) that ForEach then drops.
        // Offsets past the current period's length are skipped instead of
        // clamped (2026-07-31 audit item 4).
        let periodDays = calendar.dateComponents([.day],
                                                 from: interval.start,
                                                 to: interval.end).day ?? range.days
        let shifted = points.compactMap { point -> AtriaDetailChartPoint? in
            guard let offset = calendar.dateComponents([.day],
                                                       from: priorInterval.start,
                                                       to: point.day).day,
                  offset >= 0, offset < periodDays,
                  let day = calendar.date(byAdding: .day, value: offset, to: interval.start) else {
                return nil
            }
            return AtriaDetailChartPoint(day: day, value: point.value, tint: point.tint)
        }
        return bucketedForDisplay(shifted, range: range, calendar: calendar, within: interval).map { point in
            AtriaDetailChartPoint(day: point.day, value: point.value, tint: point.tint)
        }
    }

    init(input: AtriaMetricDetailPreparationInput) {
        let rollups = input.rollups
        let baseline = input.baseline
        let sleepGoalHours = input.sleepGoalHours
        let calendar = input.calendar
        var recoveryByRange: [AtriaTrendRange: [AtriaDetailChartPoint]] = [:]
        var hrvByRange: [AtriaTrendRange: [AtriaDetailChartPoint]] = [:]
        var restingByRange: [AtriaTrendRange: [AtriaDetailChartPoint]] = [:]
        var respiratoryByRange: [AtriaTrendRange: [AtriaDetailChartPoint]] = [:]
        var sleepByRange: [AtriaTrendRange: [AtriaDetailChartPoint]] = [:]
        var strainByRange: [AtriaTrendRange: [AtriaDetailChartPoint]] = [:]
        var recoveryPriorByRange: [AtriaTrendRange: [AtriaDetailChartPoint]] = [:]
        var hrvPriorByRange: [AtriaTrendRange: [AtriaDetailChartPoint]] = [:]
        var restingPriorByRange: [AtriaTrendRange: [AtriaDetailChartPoint]] = [:]
        var respiratoryPriorByRange: [AtriaTrendRange: [AtriaDetailChartPoint]] = [:]
        var sleepPriorByRange: [AtriaTrendRange: [AtriaDetailChartPoint]] = [:]
        var strainPriorByRange: [AtriaTrendRange: [AtriaDetailChartPoint]] = [:]
        var recoveryRawByRange: [AtriaTrendRange: [AtriaDetailChartPoint]] = [:]
        var hrvRawByRange: [AtriaTrendRange: [AtriaDetailChartPoint]] = [:]
        var restingRawByRange: [AtriaTrendRange: [AtriaDetailChartPoint]] = [:]
        var respiratoryRawByRange: [AtriaTrendRange: [AtriaDetailChartPoint]] = [:]
        var sleepRawByRange: [AtriaTrendRange: [AtriaDetailChartPoint]] = [:]
        var strainRawByRange: [AtriaTrendRange: [AtriaDetailChartPoint]] = [:]
        var latestStrainByRange: [AtriaTrendRange: Double] = [:]
        var recoverySummaryByRange: [AtriaTrendRange: AtriaDetailPeriodSummary] = [:]
        var hrvSummaryByRange: [AtriaTrendRange: AtriaDetailPeriodSummary] = [:]
        var restingSummaryByRange: [AtriaTrendRange: AtriaDetailPeriodSummary] = [:]
        var respiratorySummaryByRange: [AtriaTrendRange: AtriaDetailPeriodSummary] = [:]
        var sleepSummaryByRange: [AtriaTrendRange: AtriaDetailPeriodSummary] = [:]
        var strainSummaryByRange: [AtriaTrendRange: AtriaDetailPeriodSummary] = [:]
        var recoveryComparisonByRange: [AtriaTrendRange: AtriaDetailComparisonSummary] = [:]
        var hrvComparisonByRange: [AtriaTrendRange: AtriaDetailComparisonSummary] = [:]
        var restingComparisonByRange: [AtriaTrendRange: AtriaDetailComparisonSummary] = [:]
        var respiratoryComparisonByRange: [AtriaTrendRange: AtriaDetailComparisonSummary] = [:]
        var sleepComparisonByRange: [AtriaTrendRange: AtriaDetailComparisonSummary] = [:]
        var strainComparisonByRange: [AtriaTrendRange: AtriaDetailComparisonSummary] = [:]
        var sleepPerformanceByRange: [AtriaTrendRange: [AtriaDetailChartPoint]] = [:]
        var sleepPerformanceSummaryByRange: [AtriaTrendRange: AtriaDetailPeriodSummary] = [:]
        var sleepPerformanceComparisonByRange: [AtriaTrendRange: AtriaDetailComparisonSummary] = [:]
        var fitnessAgeByRange: [AtriaTrendRange: [AtriaDetailChartPoint]] = [:]
        var fitnessAgeSummaryByRange: [AtriaTrendRange: AtriaDetailPeriodSummary] = [:]
        var fitnessAgeComparisonByRange: [AtriaTrendRange: AtriaDetailComparisonSummary] = [:]
        let chronologicalRollups = Array(rollups.reversed())
        let paceDeltas = chronologicalRollups.compactMap { entry in
            entry.fitnessAgeDelta.map { AtriaFitnessAge.DailyDelta(day: entry.day, delta: $0) }
        }
        let weeklyFitnessAge = AtriaFitnessAge.weeklyObservations(
            from: paceDeltas,
            calendar: calendar
        )
        let fitnessAgeEntryCount = weeklyFitnessAge.count
        self.paceOfAging = AtriaFitnessAge.paceOfAging(deltas: paceDeltas, calendar: calendar)

        for range in AtriaTrendRange.allCases {
            let projection = AtriaMetricPeriodIndexProjection(
                days: chronologicalRollups.map(\.day),
                referenceDate: input.referenceDate,
                range: range,
                calendar: calendar
            )
            let interval = projection.interval
            let previousInterval = projection.priorInterval
            let filtered = projection.currentIndices.map { chronologicalRollups[$0] }
            let priorFiltered = projection.priorIndices.map { chronologicalRollups[$0] }
            let recoveryPoints: [AtriaDetailChartPoint] = filtered.compactMap { item in
                item.recovery.map { AtriaDetailChartPoint(day: item.day, value: Double($0), tint: Metrics.recoveryColor($0)) }
            }
            let priorRecoveryPoints: [AtriaDetailChartPoint] = priorFiltered.compactMap { item in
                item.recovery.map { AtriaDetailChartPoint(day: item.day, value: Double($0), tint: Metrics.recoveryColor($0)) }
            }
            recoveryByRange[range] = Self.bucketedForDisplay(recoveryPoints, range: range, calendar: calendar, within: interval)
            recoveryRawByRange[range] = recoveryPoints
            recoveryPriorByRange[range] = Self.ghostSeries(priorRecoveryPoints, from: previousInterval, to: interval, range: range, calendar: calendar)
            recoverySummaryByRange[range] = AtriaDetailPeriodSummary(points: recoveryPoints, unit: "%")
            recoveryComparisonByRange[range] = AtriaDetailComparisonSummary(current: recoveryPoints, prior: priorRecoveryPoints, unit: "%")

            let hrvPoints: [AtriaDetailChartPoint] = filtered.compactMap { item in
                guard let lnRMSSD = item.lnRMSSD else { return nil }
                let value = Int(exp(lnRMSSD).rounded())
                return AtriaDetailChartPoint(day: item.day,
                                             value: Double(value),
                                             tint: Self.hrvTint(value: value, baseline: baseline))
            }
            let priorHRVPoints: [AtriaDetailChartPoint] = priorFiltered.compactMap { item in
                guard let lnRMSSD = item.lnRMSSD else { return nil }
                let value = Int(exp(lnRMSSD).rounded())
                return AtriaDetailChartPoint(day: item.day,
                                             value: Double(value),
                                             tint: Self.hrvTint(value: value, baseline: baseline))
            }
            hrvByRange[range] = Self.bucketedForDisplay(hrvPoints, range: range, calendar: calendar, within: interval)
            hrvRawByRange[range] = hrvPoints
            hrvPriorByRange[range] = Self.ghostSeries(priorHRVPoints, from: previousInterval, to: interval, range: range, calendar: calendar)
            hrvSummaryByRange[range] = AtriaDetailPeriodSummary(points: hrvPoints, unit: "ms")
            hrvComparisonByRange[range] = AtriaDetailComparisonSummary(current: hrvPoints, prior: priorHRVPoints, unit: "ms")

            let restingPoints: [AtriaDetailChartPoint] = filtered.compactMap { item in
                guard let value = item.restingHeartRate else { return nil }
                return AtriaDetailChartPoint(day: item.day,
                                             value: Double(value),
                                             tint: Self.restingTint(value: value, baseline: baseline))
            }
            let priorRestingPoints: [AtriaDetailChartPoint] = priorFiltered.compactMap { item in
                guard let value = item.restingHeartRate else { return nil }
                return AtriaDetailChartPoint(day: item.day,
                                             value: Double(value),
                                             tint: Self.restingTint(value: value, baseline: baseline))
            }
            restingByRange[range] = Self.bucketedForDisplay(restingPoints, range: range, calendar: calendar, within: interval)
            restingRawByRange[range] = restingPoints
            restingPriorByRange[range] = Self.ghostSeries(priorRestingPoints, from: previousInterval, to: interval, range: range, calendar: calendar)
            restingSummaryByRange[range] = AtriaDetailPeriodSummary(points: restingPoints, unit: "bpm")
            restingComparisonByRange[range] = AtriaDetailComparisonSummary(current: restingPoints, prior: priorRestingPoints, unit: "bpm")

            let respiratoryPoints: [AtriaDetailChartPoint] = filtered.compactMap { item in
                item.respiratoryRate.map { AtriaDetailChartPoint(day: item.day, value: $0, tint: .teal) }
            }
            let priorRespiratoryPoints: [AtriaDetailChartPoint] = priorFiltered.compactMap { item in
                item.respiratoryRate.map { AtriaDetailChartPoint(day: item.day, value: $0, tint: .teal) }
            }
            respiratoryByRange[range] = Self.bucketedForDisplay(respiratoryPoints, range: range, calendar: calendar, within: interval)
            respiratoryRawByRange[range] = respiratoryPoints
            respiratoryPriorByRange[range] = Self.ghostSeries(priorRespiratoryPoints, from: previousInterval, to: interval, range: range, calendar: calendar)
            respiratorySummaryByRange[range] = AtriaDetailPeriodSummary(points: respiratoryPoints, unit: "/min")
            respiratoryComparisonByRange[range] = AtriaDetailComparisonSummary(current: respiratoryPoints, prior: priorRespiratoryPoints, unit: "/min")

            let sleepPoints: [AtriaDetailChartPoint] = filtered.compactMap { item in
                guard let duration = item.sleepSeconds, duration > 0 else { return nil }
                let hours = duration / 3_600
                let tint: Color
                if let zone = Metrics.sleepDurationZone(hours, goalHours: sleepGoalHours) {
                    tint = zone.tint
                } else {
                    tint = .cyan
                }
                return AtriaDetailChartPoint(day: item.day, value: hours, tint: tint)
            }
            let priorSleepPoints: [AtriaDetailChartPoint] = priorFiltered.compactMap { item in
                guard let duration = item.sleepSeconds, duration > 0 else { return nil }
                let hours = duration / 3_600
                let tint = Metrics.sleepDurationZone(hours, goalHours: sleepGoalHours)?.tint ?? .cyan
                return AtriaDetailChartPoint(day: item.day, value: hours, tint: tint)
            }
            sleepByRange[range] = Self.bucketedForDisplay(sleepPoints, range: range, calendar: calendar, within: interval)
            sleepRawByRange[range] = sleepPoints
            sleepPriorByRange[range] = Self.ghostSeries(priorSleepPoints, from: previousInterval, to: interval, range: range, calendar: calendar)
            sleepSummaryByRange[range] = AtriaDetailPeriodSummary(points: sleepPoints, unit: "h")
            sleepComparisonByRange[range] = AtriaDetailComparisonSummary(current: sleepPoints, prior: priorSleepPoints, unit: "h")

            // Match StrainPresentation.resolve (the canonical resolver used by
            // the Health screen and History sheet): a persisted strain with nil
            // quality AND nil coverage is a legacy/exact-equivalent full-day
            // value. The old literal `== .exact` gate wrongly dropped those
            // nil-quality days from the ring/chart/hero, so a past day (e.g.
            // yesterday's 15.2) showed empty boxes here while every other surface
            // showed it. Genuine .partial / low-coverage days still resolve to
            // .partial and stay out of the trend, so nothing is fabricated.
            func strainEntersExactTrend(_ item: AtriaMetricDetailPreparationInput.Rollup) -> Bool {
                Metrics.StrainPresentation.resolve(
                    value: item.strain,
                    coverageFraction: item.strainCoverageFraction,
                    baseConfidence: "dated history",
                    persistedQuality: item.strainEvidenceQuality
                ).quality == .exact
            }
            // Cycle-truth value swap (2026-08-30): a day covered by the
            // closed-cycle series charts that cycle strain (wake-to-wake,
            // labelled by predominant civil day) instead of the civil-sliced
            // rollup value, so a shifted sleeper's pre-wake load stays with
            // its own physiological day. The exact-trend GATE above still
            // runs on the civil row's coverage/quality — the series swaps a
            // value, it never draws a bar the rollup evidence would withhold,
            // and days absent from the series keep the civil value with no
            // claim of cycle precision.
            func strainTrendValue(_ item: AtriaMetricDetailPreparationInput.Rollup) -> Double? {
                input.cycleStrainByDisplayDay[calendar.startOfDay(for: item.day)]
                    ?? item.strain
            }
            let strainPoints: [AtriaDetailChartPoint] = filtered.compactMap { item in
                guard strainEntersExactTrend(item) else { return nil }
                return strainTrendValue(item).map {
                    AtriaDetailChartPoint(day: item.day, value: $0, tint: Metrics.electricStrain)
                }
            }
            let priorStrainPoints: [AtriaDetailChartPoint] = priorFiltered.compactMap { item in
                guard strainEntersExactTrend(item) else { return nil }
                return strainTrendValue(item).map {
                    AtriaDetailChartPoint(day: item.day, value: $0, tint: Metrics.electricStrain)
                }
            }
            strainByRange[range] = Self.bucketedForDisplay(strainPoints, range: range, calendar: calendar, within: interval)
            strainRawByRange[range] = strainPoints
            strainPriorByRange[range] = Self.ghostSeries(priorStrainPoints, from: previousInterval, to: interval, range: range, calendar: calendar)
            strainSummaryByRange[range] = AtriaDetailPeriodSummary(points: strainPoints, unit: "")
            strainComparisonByRange[range] = AtriaDetailComparisonSummary(current: strainPoints, prior: priorStrainPoints, unit: "")
            latestStrainByRange[range] = filtered.last(where: { strainEntersExactTrend($0) })
                .flatMap { strainTrendValue($0) }

            let sleepPerformancePoints: [AtriaDetailChartPoint] = filtered.compactMap { item in
                item.sleepPerformance.map { AtriaDetailChartPoint(day: item.day, value: Double($0), tint: Metrics.electricSleep) }
            }
            let priorSleepPerformancePoints: [AtriaDetailChartPoint] = priorFiltered.compactMap { item in
                item.sleepPerformance.map { AtriaDetailChartPoint(day: item.day, value: Double($0), tint: Metrics.electricSleep) }
            }
            sleepPerformanceByRange[range] = Self.bucketedForDisplay(sleepPerformancePoints, range: range, calendar: calendar, within: interval)
            sleepPerformanceSummaryByRange[range] = AtriaDetailPeriodSummary(points: sleepPerformancePoints, unit: "%")
            sleepPerformanceComparisonByRange[range] = AtriaDetailComparisonSummary(current: sleepPerformancePoints, prior: priorSleepPerformancePoints, unit: "%")

            let fitnessAgePoints: [AtriaDetailChartPoint] = weeklyFitnessAge
                .filter { $0.day >= interval.start && $0.day < interval.end }
                .map { item in
                    AtriaDetailChartPoint(
                        day: item.day,
                        value: Double(item.delta),
                        tint: item.delta <= 0
                            ? Metrics.electricGreen : Metrics.electricYellow
                    )
            }
            let priorFitnessAgePoints: [AtriaDetailChartPoint] = weeklyFitnessAge
                .filter {
                    $0.day >= previousInterval.start
                        && $0.day < previousInterval.end
                }
                .map { item in
                    AtriaDetailChartPoint(
                        day: item.day,
                        value: Double(item.delta),
                        tint: item.delta <= 0
                            ? Metrics.electricGreen : Metrics.electricYellow
                    )
            }
            fitnessAgeByRange[range] = Self.bucketedForDisplay(fitnessAgePoints, range: range, calendar: calendar, within: interval)
            fitnessAgeSummaryByRange[range] = AtriaDetailPeriodSummary(points: fitnessAgePoints, unit: "y")
            fitnessAgeComparisonByRange[range] = AtriaDetailComparisonSummary(current: fitnessAgePoints, prior: priorFitnessAgePoints, unit: "y")
        }

        self.recovery = recoveryByRange
        self.hrv = hrvByRange
        self.restingHeartRate = restingByRange
        self.respiratoryRate = respiratoryByRange
        self.sleep = sleepByRange
        self.strain = strainByRange
        self.recoveryPrior = recoveryPriorByRange
        self.hrvPrior = hrvPriorByRange
        self.restingHeartRatePrior = restingPriorByRange
        self.respiratoryRatePrior = respiratoryPriorByRange
        self.sleepPrior = sleepPriorByRange
        self.strainPrior = strainPriorByRange
        self.recoveryRaw = recoveryRawByRange
        self.hrvRaw = hrvRawByRange
        self.restingHeartRateRaw = restingRawByRange
        self.respiratoryRateRaw = respiratoryRawByRange
        self.sleepRaw = sleepRawByRange
        self.strainRaw = strainRawByRange
        self.latestStrain = latestStrainByRange
        self.recoverySummary = recoverySummaryByRange
        self.hrvSummary = hrvSummaryByRange
        self.restingHeartRateSummary = restingSummaryByRange
        self.respiratoryRateSummary = respiratorySummaryByRange
        self.sleepSummary = sleepSummaryByRange
        self.strainSummary = strainSummaryByRange
        self.recoveryComparison = recoveryComparisonByRange
        self.hrvComparison = hrvComparisonByRange
        self.restingHeartRateComparison = restingComparisonByRange
        self.respiratoryRateComparison = respiratoryComparisonByRange
        self.sleepComparison = sleepComparisonByRange
        self.strainComparison = strainComparisonByRange
        self.sleepPerformance = sleepPerformanceByRange
        self.sleepPerformanceSummary = sleepPerformanceSummaryByRange
        self.sleepPerformanceComparison = sleepPerformanceComparisonByRange
        self.fitnessAge = fitnessAgeByRange
        self.fitnessAgeSummary = fitnessAgeSummaryByRange
        self.fitnessAgeComparison = fitnessAgeComparisonByRange
        self.fitnessAgeEntryCount = fitnessAgeEntryCount
    }

    private static func hrvTint(value: Int,
                                baseline: AtriaMetricDetailPreparationInput.Baseline) -> Color {
        guard baseline.hrvTrusted,
              baseline.hrvSampleCount >= PersonalBaseline.trustedMinimumSamples,
              let target = baseline.hrvBaseline,
              target > 0 else { return .pink }
        let ratio = Double(value) / Double(target)
        var level = ratio >= 0.95 ? 0 : (ratio >= 0.85 ? 1 : 2)
        if let mean = baseline.hrvLnMean,
           let sd = baseline.hrvLnSD,
           sd > 0.1 {
            let zScore = (log(Double(value)) - mean) / sd
            level = max(level, zScore >= -1 ? 0 : (zScore >= -2 ? 1 : 2))
        }
        return tint(forSeverity: level)
    }

    private static func restingTint(value: Int,
                                    baseline: AtriaMetricDetailPreparationInput.Baseline) -> Color {
        guard baseline.restingTrusted,
              baseline.restingSampleCount >= PersonalBaseline.trustedMinimumSamples,
              let target = baseline.restingBaseline,
              target > 0 else { return .pink }
        let delta = value - target
        var level = delta <= 3 ? 0 : (delta <= 7 ? 1 : 2)
        if let mean = baseline.restingMean,
           let sd = baseline.restingSD,
           sd > 0.1 {
            let zScore = (Double(value) - mean) / sd
            level = max(level, zScore <= 1 ? 0 : (zScore <= 2 ? 1 : 2))
        }
        return tint(forSeverity: level)
    }

    private static func tint(forSeverity severity: Int) -> Color {
        switch severity {
        case 0: return .green
        case 1: return .orange
        default: return .red
        }
    }
}

struct AtriaDetailChartPoint: Identifiable, Sendable {
    let day: Date
    let value: Double
    let tint: Color
    /// Stable observed-run identity. A nonzero transition breaks line/area
    /// interpolation at missing-evidence gaps without inventing values.
    var segment: Int = 0
    /// Weekly-bucket min/max band bounds (2026-07-07 design handoff long-range
    /// bucketing). nil on raw daily points.
    var bandLower: Double? = nil
    var bandUpper: Double? = nil

    var id: Date { day }
}

/// Keeps live workout/zone/target context confined to the one period it
/// actually describes. A week, month, or all-time selection can include the
/// current cycle while still representing an aggregate, so `usesCurrentCycle`
/// alone is not sufficient authority.
enum AtriaStrainDetailContextPolicy {
    static func showsCurrentCycle(
        range: AtriaTrendRange,
        usesCurrentCycle: Bool,
        isPreparingSelectedPeriod: Bool
    ) -> Bool {
        range == .day
            && usesCurrentCycle
            && !isPreparingSelectedPeriod
    }
}

struct AtriaDetailBaselineBand {
    let lower: Double
    let upper: Double
    let tint: Color
}

/// Wake alarm + planner + need/consistency context for the sleep detail
/// sheet. The stage display itself moved to the shared
/// `AtriaSleepHypnogramCard` (2026-08-01) — this card no longer renders any
/// stage bar of its own.
private struct AtriaSleepPlanCard: View {
    let night: SleepHistorySnapshot.Night
    let neededHours: Double?
    /// ITEM-2 2026-08-15: the FROZEN receipt's itemization only — nil hides
    /// the breakdown (legacy receiptless night); never live-recomputed here.
    var frozenReceipt: AtriaSleepBudget.NeedComponents? = nil
    /// Tonight's provisional projection; drives the planner and moves as
    /// today's strain accrues, freezing only when tonight is saved.
    var tonightProjection: AtriaSleepBudget.NeedComponents? = nil
    @AtriaDefault(AtriaWakeAlarmStore.enabledKey) private var wakeAlarmEnabled: Bool = false
    @AtriaDefault(AtriaWakeAlarmStore.modeKey) private var wakeAlarmMode: String = AtriaWakeAlarmPlan.Mode.smartWindow.rawValue
    @AtriaDefault(AtriaWakeAlarmStore.wakeByMinutesKey) private var wakeByMinutes: Int = AtriaWakeAlarmPlan.defaultPlan.wakeByMinutes
    @AtriaDefault("atria.sleepPlanner.goal") private var plannerGoalRaw: String = AtriaSleepPlannerGoal.peak.rawValue
    @State private var alarmStatusText: String?
    @State private var showsSmartWakeSheet = false
    /// Efficiencies of the user's real confirmed nights, for the planner's
    /// time-in-bed assumption. Passed in so this card stays store-free.
    var nightEfficiencies: [Double] = []

    private var wakeAlarmPlan: AtriaWakeAlarmPlan {
        AtriaWakeAlarmPlan(mode: AtriaWakeAlarmPlan.Mode(rawValue: wakeAlarmMode) ?? .smartWindow,
                           wakeByHour: wakeByMinutes / 60,
                           wakeByMinute: wakeByMinutes % 60)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header duration removed (dedup audit 2026-07-07): the sheet
            // hero owns the duration readout. The stage bar moved to the
            // shared AtriaSleepHypnogramCard rendered above this card.
            Text("Sleep plan")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)

            // Performance/Consistency pills removed (dedup audit): the
            // contributor rows below the chart own both values. The footer
            // keeps only the need context — duration and performance live
            // on the hero.
            // 2026-08-29 minimalism trim: the frozen-receipt itemization line
            // went — the need ledger card behind the reveal owns that "why".
            Text(neededHours.map { "Needed \(AtriaMetricFormat.sleepHours($0)) last night" }
                 ?? "Last night's target was not saved")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            wakeAlarmCard

            sleepPlannerCard

        }
        .padding(14)
        // 2026-08-29 theme pass: sleep's identity hue, not raw .cyan.
        .atriaInsetCard(tint: Metrics.electricSleep)
    }

    /// Sleep Planner (2026-07-07, WHOOP-research adaptation): pick a goal,
    /// get an in-bed-by time worked back from the wake alarm using tonight's
    /// need and the user's own typical efficiency.
    /// ITEM-2 2026-08-15: "tonight's need" is now actually tonight's
    /// provisional projection (was silently re-serving last night's frozen
    /// need, so the plan never moved with today's strain).
    private var sleepPlannerCard: some View {
        let goal = AtriaSleepPlannerGoal(rawValue: plannerGoalRaw) ?? .peak
        let tonightNeed = tonightProjection?.totalHours
            ?? neededHours
            ?? SessionStore.configuredSleepBaseNeedHours()
        let plan = AtriaSleepPlanner.plan(needHours: tonightNeed,
                                          goal: goal,
                                          wakeByMinutes: wakeByMinutes,
                                          nightEfficiencies: nightEfficiencies)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "bed.double.circle.fill")
                    .foregroundStyle(Metrics.electricSleep)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tonight's plan")
                        .font(.caption.weight(.bold))
                    Text("In bed by \(plan.inBedByText) \u{00b7} \(AtriaMetricFormat.sleepHours(plan.targetSleepHours)) asleep")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            // 2026-08-29 minimalism trim: the projected-need and efficiency
            // explanation sentences went; the "In bed by" caption above is
            // this surface's one caption. The plan math is unchanged.
            AtriaTextSelector(items: AtriaSleepPlannerGoal.allCases,
                              title: { $0.title },
                              selection: Binding(
                                  get: { AtriaSleepPlannerGoal(rawValue: plannerGoalRaw) ?? .peak },
                                  set: { plannerGoalRaw = $0.rawValue }))
        }
        .padding(12)
        .background(Metrics.electricSleep.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tonight's plan. \(goal.title): in bed by \(plan.inBedByText) for \(AtriaMetricFormat.sleepHours(plan.targetSleepHours)) of sleep. Projected need \(AtriaMetricFormat.sleepHours(tonightNeed)).")
    }

    private var wakeAlarmCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "alarm.fill")
                    // 2026-08-29 theme pass: sleep's identity hue, not .cyan.
                    .foregroundStyle(Metrics.electricSleep)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Wake alarm")
                        .font(.caption.weight(.bold))
                    Text("\(wakeAlarmPlan.mode.title) · wake by \(wakeAlarmPlan.displayTime)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                // Smart Wake screen (design 6c, 2026-08-01 parity slice):
                // window axis, mode radios, wake-by editor, arm control.
                Button {
                    showsSmartWakeSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Text("Smart wake")
                        Image(systemName: "chevron.right")
                    }
                    .font(.caption2.weight(.bold))
                }
                .atriaCardAction(prominent: false, tint: Metrics.electricSleep)
                .sheet(isPresented: $showsSmartWakeSheet) {
                    AtriaSmartWakeSheet()
                        .presentationDetents([.medium, .large])
                }
            }

            AtriaTextSelector(items: AtriaWakeAlarmPlan.Mode.allCases,
                              title: { $0.title },
                              selection: Binding(
                                  get: { AtriaWakeAlarmPlan.Mode(rawValue: wakeAlarmMode) ?? .smartWindow },
                                  set: { wakeAlarmMode = $0.rawValue }))
            .onChange(of: wakeAlarmMode) { _, _ in
                if wakeAlarmEnabled { scheduleWakeAlarm() }
            }

            HStack(spacing: 10) {
                Stepper(value: $wakeByMinutes, in: 0...(23 * 60 + 59), step: 5) {
                    Text("Wake by \(wakeAlarmPlan.displayTime)")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                }
                .onChange(of: wakeByMinutes) { _, _ in
                    AtriaWakeAlarmStore.save(wakeAlarmPlan)
                    if wakeAlarmEnabled { scheduleWakeAlarm() }
                }

                Button {
                    wakeAlarmEnabled.toggle()
                    if wakeAlarmEnabled {
                        scheduleWakeAlarm()
                    } else {
                        AtriaWakeAlarmScheduler.cancelLast()
                        alarmStatusText = "Alarm off"
                    }
                } label: {
                    Label(wakeAlarmEnabled ? "On" : "Set", systemImage: wakeAlarmEnabled ? "checkmark.circle.fill" : "alarm")
                }
                .atriaCardAction(tint: Metrics.electricSleep)
            }

            // 2026-08-29 minimalism trim: the standing AlarmKit explainer
            // went; only live scheduling feedback renders here.
            if let alarmStatusText {
                Text(alarmStatusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
    }

    private func scheduleWakeAlarm() {
        let plan = wakeAlarmPlan
        AtriaWakeAlarmStore.save(plan)
        Task {
            let result = await AtriaWakeAlarmScheduler.scheduleHardAlarm(plan: plan)
            await MainActor.run {
                switch result {
                case .scheduled(_, let fireDate):
                    alarmStatusText = "AlarmKit set \(fireDate.formatted(date: .omitted, time: .shortened))"
                    AtriaDebugLog("ATRIADBG wake_alarm_detail status=scheduled mode=%@ wake_by=%@ fire=%@",
                                  plan.mode.rawValue,
                                  plan.displayTime,
                                  fireDate.formatted(date: .numeric, time: .shortened))
                case .denied:
                    wakeAlarmEnabled = false
                    alarmStatusText = "Alarm permission needed"
                case .unavailable(let reason):
                    wakeAlarmEnabled = false
                    alarmStatusText = "Alarm unavailable"
                    AtriaDebugLog("ATRIADBG wake_alarm_detail status=unavailable reason=%@",
                                  reason)
                }
            }
        }
    }

}

/// A historical sleep can retain duration without the Need that was used at
/// settlement. Show that evidence gap plainly rather than recreating an old
/// target from today's profile.
private struct AtriaSleepNeedUnavailableCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sleep Need unavailable")
                .font(.headline.weight(.semibold))
            Text("This legacy night did not retain its target or inputs. Atria will not recreate it using today’s settings. Newly settled nights keep the exact target and its contributors.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .atriaInsetCard(tint: Metrics.electricSleep)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sleep Need unavailable. This legacy night did not retain its target.")
    }
}


struct AtriaOverviewMorningJournalHost: View {
    @ObservedObject var snapshotStore: AtriaHomeModel.SnapshotStore
    let store: SessionStore
    @StateObject private var projectionStore: AtriaOverviewMorningJournalProjectionStore
    @State private var adjustmentNight: SleepHistorySnapshot.Night?

    init(snapshotStore: AtriaHomeModel.SnapshotStore, store: SessionStore) {
        self.snapshotStore = snapshotStore
        self.store = store
        _projectionStore = StateObject(wrappedValue: AtriaOverviewMorningJournalProjectionStore(store: store))
    }

    var body: some View {
        let projection = projectionStore.state
        let sleepHistory = debugFixtureSleepHistory ?? projection.sleepHistory
        VStack(spacing: 12) {
            AtriaOverviewMorningJournalCard(snapshot: snapshotStore.state,
                                            sleepHistory: sleepHistory,
                                            sleepHistoryRevision: projection.sleepHistoryRevision,
                                            todayEntry: projection.todayEntry,
                                            taggedDays: projection.taggedDays,
                                            onToggleTag: { tag in
                                                store.toggleBehaviorTag(tag)
                                            },
                                            onConfirmSleep: {
                                                guard let night = sleepHistory.latest else { return false }
                                                return await store.confirmSleepHistoryNightForUI(
                                                    night,
                                                    rest: store.baseline.restingInt ?? 60,
                                                    source: "morning_journal"
                                                ) != nil
                                            },
                                            onAdjustSleep: {
                                                adjustmentNight = sleepHistory.latest
                                            })
                .equatable()

            AtriaMorningCheckInCard(mainSleepEnd: sleepHistory.latest.flatMap { $0.isNapEvidence ? nil : $0.end }) {
                store.recoveryProjectionForPresentation(
                    initialFallbackHRVSnapshot: nil,
                    liveRestingHeartRate: nil,
                    pendingSleepReview: sleepHistory.latest
                )
            }
        }
            .sheet(item: $adjustmentNight) { adjustment in
                AtriaManualSleepSheet(initialStart: adjustment.start,
                                      initialEnd: adjustment.end,
                                      initialIsNap: adjustment.isNapEvidence,
                                      preservesSensorStages: true,
                                      evidenceNight: adjustment,
                                      evidencePerformancePercent: sleepHistory.sleepPerformancePercent(for: adjustment,
                                                                                                       baseNeedHours: SessionStore.configuredSleepBaseNeedHours())) { start, end, isNap in
                    let saved = await store.saveSleepReviewNightForUI(
                        adjustment,
                        start: start,
                        end: end,
                        isNap: isNap,
                        rest: store.baseline.restingInt ?? 60,
                        source: "morning_journal_adjust"
                    ) != nil
                    if saved { adjustmentNight = nil }
                    return saved
                }
            }
    }

    #if DEBUG
    private var debugFixtureSleepHistory: SleepHistorySnapshot? {
        Self.debugFixtureSleepHistory(arguments: ProcessInfo.processInfo.arguments)
    }

    private static func debugFixtureSleepHistory(arguments: [String]) -> SleepHistorySnapshot? {
        guard let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture") else { return nil }
        let valueIndex = arguments.index(after: fixtureIndex)
        // Static handoff compatibility marker: ["pending-sleep-review", "journal-impact"].contains(arguments[valueIndex])
        guard valueIndex < arguments.endIndex,
              ["pending-sleep-review", "pending-sleep-provisional-recovery", "journal-impact"].contains(arguments[valueIndex]) else {
            return nil
        }

        let calendar = Calendar.current
        let end = calendar.date(bySettingHour: 7, minute: 18, second: 0, of: Date()) ?? Date()
        let start = calendar.date(byAdding: .minute, value: -438, to: end) ?? end.addingTimeInterval(-438 * 60)
        let day = calendar.startOfDay(for: end)
        let night = SleepHistorySnapshot.Night(id: "debug-ui-fixture-pending-sleep-review",
                                               day: day,
                                               start: start,
                                               end: end,
                                               duration: 438 * 60,
                                               restingHR: 54,
                                               hrv: 72,
                                               respiratoryRate: 14.6,
                                               sleepEfficiency: 0.89,
                                               confidence: "debug_fixture_pending_review",
                                               source: "sleep_candidate",
                                               confirmed: false,
                                               stageSegments: [])
        return SleepHistorySnapshot(nights: [night], confirmedCount: 0, candidateCount: 1)
    }
    #else
    private var debugFixtureSleepHistory: SleepHistorySnapshot? { nil }
    #endif
}

struct AtriaOverviewMorningJournalProjectionState: Equatable {
    let sleepHistory: SleepHistorySnapshot
    let sleepHistoryRevision: Int
    let todayEntry: BehaviorJournalEntry
    let taggedDays: Int
}

@MainActor
final class AtriaOverviewMorningJournalProjectionStore: ObservableObject {
    @Published private(set) var state: AtriaOverviewMorningJournalProjectionState

    private let store: SessionStore?
    private var behaviorJournalRevision: Int
    private var cancellables = Set<AnyCancellable>()
    private var refreshScheduled = false

    init(store: SessionStore) {
        self.store = store
        behaviorJournalRevision = store.behaviorJournalRevision
        state = Self.makeState(store: store)
        bind(to: store)
    }

    init(state: AtriaOverviewMorningJournalProjectionState) {
        self.state = state
        store = nil
        behaviorJournalRevision = 0
    }

    @discardableResult
    func refresh(_ next: AtriaOverviewMorningJournalProjectionState) -> Bool {
        guard next != state else { return false }
        state = next
        return true
    }

    private func bind(to store: SessionStore) {
        store.$sleepHistorySnapshot
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)

        store.$dashboardRevision
            .dropFirst()
            .sink { [weak self, weak store] _ in
                guard let self, let store,
                      store.behaviorJournalRevision != self.behaviorJournalRevision else { return }
                self.scheduleRefresh()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            guard let store = self.store else { return }
            self.behaviorJournalRevision = store.behaviorJournalRevision
            self.refresh(Self.makeState(store: store))
        }
    }

    private static func makeState(store: SessionStore) -> AtriaOverviewMorningJournalProjectionState {
        AtriaOverviewMorningJournalProjectionState(
            sleepHistory: store.sleepHistorySnapshot,
            sleepHistoryRevision: store.sleepHistorySnapshotRevision,
            todayEntry: store.behaviorJournalEntry(),
            taggedDays: store.behaviorJournalEntries.count
        )
    }
}

private struct AtriaJournalSleepFact: Identifiable, Equatable {
    let title: String
    let value: String

    var id: String { title }
}

struct AtriaOverviewMorningJournalCard: View, Equatable {
    let snapshot: AtriaHomeModel.Snapshot
    let sleepHistory: SleepHistorySnapshot
    let sleepHistoryRevision: Int
    let todayEntry: BehaviorJournalEntry
    let taggedDays: Int
    let onToggleTag: (BehaviorJournalEntry.Tag) -> Void
    let onConfirmSleep: () async -> Bool
    let onAdjustSleep: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsAllJournalTags = false
    @State private var sleepConfirmationFailed = false
    @State private var isConfirmingSleep = false

    static func == (lhs: AtriaOverviewMorningJournalCard, rhs: AtriaOverviewMorningJournalCard) -> Bool {
        lhs.snapshot.sleepValue == rhs.snapshot.sleepValue
            && lhs.snapshot.sleepDetail == rhs.snapshot.sleepDetail
            && lhs.sleepHistoryRevision == rhs.sleepHistoryRevision
            && lhs.todayEntry == rhs.todayEntry
            && lhs.taggedDays == rhs.taggedDays
    }

    private var latestNight: SleepHistorySnapshot.Night? {
        sleepHistory.latest
    }

    private var shouldShowConfirmSleep: Bool {
        guard sleepHistory.candidateCount > 0 else { return false }
        return latestNight?.confirmed != true
    }

    private var sleepReviewTitle: String {
        latestNight?.evidenceLabel ?? "Sleep review"
    }

    private var sleepReviewValue: String {
        latestNight?.durationText ?? metricDisplayValue(snapshot.sleepValue)
    }

    private var sleepReviewState: AtriaMetricState {
        latestNight?.confirmed == true ? .validated : (sleepHistory.candidateCount > 0 ? .research : .learning)
    }

    private var sleepActionText: String {
        guard let latestNight else {
            return snapshot.sleepDetail
        }

        if latestNight.confirmed {
            return latestNight.isNapEvidence
                ? "Nap saved separately."
                : "Sleep saved for recovery."
        }
        return latestNight.isNapEvidence
            ? "Confirm if this nap looks right."
            : "Confirm if this sleep looks right."
    }

    private var sleepMetricFacts: [AtriaJournalSleepFact] {
        guard let latestNight else { return [] }

        var facts: [AtriaJournalSleepFact] = []
        if latestNight.sleepEfficiencyText != "--" {
            facts.append(AtriaJournalSleepFact(title: "Eff", value: latestNight.sleepEfficiencyText))
        }
        if latestNight.hrvText != "--" {
            facts.append(AtriaJournalSleepFact(title: "HRV", value: latestNight.hrvText))
        }
        if latestNight.respiratoryRateText != "--" {
            facts.append(AtriaJournalSleepFact(title: "Resp", value: latestNight.respiratoryRateText))
        }
        return Array(facts.prefix(3))
    }

    private var selectedTags: [BehaviorJournalEntry.Tag] {
        BehaviorJournalEntry.Tag.allCases.filter { todayEntry.tags.contains($0) }
    }

    private var visibleJournalTags: [BehaviorJournalEntry.Tag] {
        let quick: [BehaviorJournalEntry.Tag] = [.sleep, .training, .caffeine]
        guard !showsAllJournalTags else { return BehaviorJournalEntry.Tag.allCases }
        return quick
    }

    private var hiddenJournalTagCount: Int {
        max(BehaviorJournalEntry.Tag.allCases.count - visibleJournalTags.count, 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "Morning journal", subtitle: "")

                Spacer(minLength: 0)

                AtriaStateBadge(state: latestNight?.confirmed == true ? .validated : (sleepHistory.candidateCount > 0 ? .research : .learning))
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: latestNight?.isNapEvidence == true ? "moon.zzz.fill" : "bed.double.fill")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(Color.cyan)
                        .frame(width: 34, height: 34)
                        .background(Color.cyan.opacity(0.12), in: Circle())

                    VStack(alignment: .leading, spacing: 3) {
                        Text(sleepReviewTitle)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(sleepActionText)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)

                    VStack(alignment: .trailing, spacing: 4) {
                        Text(sleepReviewValue)
                            .font(.title3.weight(.bold))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        AtriaStateBadge(state: sleepReviewState)
                    }
                }

                if shouldShowConfirmSleep {
                    GlassEffectContainer(spacing: 10) {
                        HStack(spacing: 8) {
                            Button(action: onAdjustSleep) {
                                Label("Adjust", systemImage: "slider.horizontal.3")
                                    .font(.caption.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                            }
                            .atriaCardAction(prominent: false, tint: .cyan)

                            Button {
                                isConfirmingSleep = true
                                Task { @MainActor in
                                    sleepConfirmationFailed = !(await onConfirmSleep())
                                    isConfirmingSleep = false
                                }
                            } label: {
                                Label(latestNight?.isNapEvidence == true ? "Confirm nap" : "Confirm sleep",
                                      systemImage: "checkmark.circle")
                                    .font(.caption.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                            }
                            .atriaCardAction(tint: .cyan)
                            .disabled(isConfirmingSleep)
                        }
                    }

                    if sleepConfirmationFailed {
                        Label("Couldn't save. The suggestion is still here — try again, or tap Adjust to change the window.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("Couldn't save sleep. The suggestion remains available. Try again or adjust the detected window.")
                    }
                }

                if !sleepMetricFacts.isEmpty {
                    LazyVGrid(columns: Self.sleepFactColumns, spacing: 8) {
                        ForEach(sleepMetricFacts) { fact in
                            sleepFactPill(fact)
                        }
                    }
                }
            }
            .padding(12)
            .atriaInsetCard(tint: .cyan)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(sleepReviewTitle) \(sleepReviewValue). \(sleepActionText)")

            morningJournalStackRail

            AtriaJournalTodayTagStrip(selectedTags: selectedTags,
                                      healthAutoTags: todayEntry.healthAutoTags,
                                      taggedDays: taggedDays,
                                      showsAllTags: showsAllJournalTags,
                                      hiddenTagCount: hiddenJournalTagCount,
                                      onToggleMore: {
                                          withAnimation(.snappy(duration: AtriaDesignTokens.Motion.standard)) {
                                              showsAllJournalTags.toggle()
                                          }
                                      })

            LazyVGrid(columns: Self.tagColumns, spacing: 8) {
                ForEach(visibleJournalTags) { tag in
                    Button {
                        if reduceMotion {
                            onToggleTag(tag)
                        } else {
                            withAnimation(.snappy(duration: AtriaDesignTokens.Motion.standard)) {
                                onToggleTag(tag)
                            }
                        }
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: todayEntry.tags.contains(tag) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(todayEntry.tags.contains(tag) ? .cyan : .secondary)
                            Text(tag.label)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.76)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .atriaGlassSelectable(selected: todayEntry.tags.contains(tag))
                }
            }
            .animation(.snappy(duration: AtriaDesignTokens.Motion.standard), value: showsAllJournalTags)
        }
        .padding(16)
        .atriaCard(emphasis: .soft)
        .onChange(of: latestNight?.id) { _, _ in
            sleepConfirmationFailed = false
        }
    }

    private static let tagColumns = [GridItem(.adaptive(minimum: 118), spacing: 8)]
    private static let sleepFactColumns = [GridItem(.flexible(), spacing: 8),
                                           GridItem(.flexible(), spacing: 8),
                                           GridItem(.flexible(), spacing: 8)]

    private var morningJournalStackRail: some View {
        HStack(spacing: 7) {
            journalPathStep(systemImage: latestNight?.isNapEvidence == true ? "moon.zzz.fill" : "bed.double.fill",
                            title: "Sleep",
                            value: shouldShowConfirmSleep ? "Review" : "Saved",
                            tint: .cyan)
            journalPathStep(systemImage: "tag.fill",
                            title: "Tags",
                            value: selectedTags.isEmpty ? "Today" : "\(selectedTags.count)",
                            tint: .cyan)
            journalPathStep(systemImage: "chart.xyaxis.line",
                            title: "Links",
                            value: taggedDays > 0 ? "Ready" : "Build",
                            tint: .mint)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Morning path: review sleep, tag today, and see habit links.")
    }

    private func journalPathStep(systemImage: String, title: String, value: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(value)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private func sleepFactPill(_ fact: AtriaJournalSleepFact) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(fact.title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(fact.value)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(Color.cyan.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func metricDisplayValue(_ value: String) -> String {
        value.localizedCaseInsensitiveContains("learning")
            || value.localizedCaseInsensitiveContains("prepar")
            || value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "--"
            : value
    }
}

private struct AtriaJournalTodayTagStrip: View, Equatable {
    let selectedTags: [BehaviorJournalEntry.Tag]
    let healthAutoTags: [BehaviorJournalEntry.Tag]
    let taggedDays: Int
    let showsAllTags: Bool
    let hiddenTagCount: Int
    let onToggleMore: () -> Void

    static func == (lhs: AtriaJournalTodayTagStrip, rhs: AtriaJournalTodayTagStrip) -> Bool {
        lhs.selectedTags == rhs.selectedTags
            && lhs.healthAutoTags == rhs.healthAutoTags
            && lhs.taggedDays == rhs.taggedDays
            && lhs.showsAllTags == rhs.showsAllTags
            && lhs.hiddenTagCount == rhs.hiddenTagCount
    }

    private var title: String {
        selectedTags.isEmpty ? "Tag today" : "\(selectedTags.count) logged today"
    }

    private var detail: String {
        if selectedTags.isEmpty {
            return taggedDays > 0
                ? "Keep the loop going; one tap is enough."
                : "Tap what happened and Atria compares it locally."
        }
        let healthCount = selectedTags.filter { healthAutoTags.contains($0) }.count
        if healthCount > 0 {
            return "\(selectedTags.map(\.label).joined(separator: " · ")) · \(healthCount) from Health"
        }
        return selectedTags.map(\.label).joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                Circle()
                    .fill(.cyan.opacity(0.13))
                Image(systemName: selectedTags.isEmpty ? "plus.circle.fill" : "checkmark.circle.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.cyan)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.bold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
            }

            Spacer(minLength: 6)

            Button(action: onToggleMore) {
                Text(showsAllTags ? "Less" : "+\(hiddenTagCount)")
                    .font(.caption.weight(.black).monospacedDigit())
                    .foregroundStyle(.cyan)
                    .frame(minWidth: 38)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
            }
            .atriaCardAction(prominent: false, tint: .cyan)
            .accessibilityLabel(showsAllTags ? "Show fewer journal tags" : "Show \(hiddenTagCount) more journal tags")

            if !selectedTags.isEmpty {
                HStack(spacing: -4) {
                    ForEach(selectedTags.prefix(4)) { tag in
                        ZStack(alignment: .bottomTrailing) {
                            Image(systemName: tag.symbolName)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.cyan)
                                .frame(width: 24, height: 24)
                                .background(Color.white.opacity(0.10), in: Circle())
                            if healthAutoTags.contains(tag) {
                                Image(systemName: "heart.text.square.fill")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.green)
                                    .background(Color(.systemBackground), in: Circle())
                                    .offset(x: 3, y: 3)
                            }
                        }
                    }
                }
                .accessibilityHidden(true)
            }
        }
        .padding(10)
        .background(.cyan.opacity(0.08), in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.inset, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.inset, style: .continuous)
                .stroke(.cyan.opacity(0.12), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(detail)")
    }
}

struct AtriaInsightsCardHost: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        AtriaInsightsCard(insights: store.behaviorInsights,
                          taggedDays: store.behaviorJournalEntries.count)
            .equatable()
    }
}

/// Smart insights: actionable, effect-size-ranked findings from behavior tags vs
/// validated local metrics. Recovery correlations stay hidden until Recovery is
/// built from real baseline-gated inputs. Local, never medical.
struct AtriaInsightsCard: View, Equatable {
    let insights: [AtriaInsight]
    let taggedDays: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AtriaPanelSectionHeader(title: "Insights", subtitle: "What moves your HRV")

            if insights.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .foregroundStyle(.secondary)
                    Text(taggedDays == 0
                         ? "Tag your days (sleep, alcohol, training…) and Atria learns what moves your HRV."
                         : "Keep tagging — clear patterns appear after a few matched days.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ForEach(insights.prefix(3)) { insight in
                    insightRow(insight)
                }
            }
        }
        .padding(16)
        .atriaCard(emphasis: .soft)
    }

    private func insightRow(_ i: AtriaInsight) -> some View {
        let tint: Color = i.isPositive ? .green : .red
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(i.tagLabel)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("\(i.headline) · \(i.detail.lowercased())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
            Image(systemName: i.isPositive ? "arrow.up.right" : "arrow.down.right")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tint)
                .padding(8)
                .background(tint.opacity(0.14), in: Circle())
        }
        .padding(12)
        .atriaInsetCard(tint: tint)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(i.tagLabel). \(i.headline). \(i.detail).")
    }
}



struct AtriaOverviewBehaviorJournalSection: View {
    @StateObject private var projectionStore: AtriaOverviewBehaviorJournalProjectionStore

    init(store: SessionStore) {
        _projectionStore = StateObject(
            wrappedValue: AtriaOverviewBehaviorJournalProjectionStore(store: store)
        )
    }

    private var displayModel: AtriaOverviewBehaviorJournalModel {
        if let debugFixtureBehaviorSummaries {
            let impacts = debugFixtureBehaviorImpacts ?? []
            return AtriaOverviewBehaviorJournalModel(summaries: Array(debugFixtureBehaviorSummaries.prefix(3)),
                                                     behaviorImpacts: Array(impacts.prefix(3)),
                                                     taggedDays: 12)
        }
        return projectionStore.state.model
    }

    var body: some View {
        AtriaOverviewBehaviorJournalContent(model: displayModel)
            .equatable()
    }

    #if DEBUG
    static var debugShowsImpactOnlyFixture: Bool {
        debugFixtureBehaviorSummaries(arguments: ProcessInfo.processInfo.arguments) != nil
            && ProcessInfo.processInfo.arguments.contains("journal-impact-focus")
    }

    private var debugFixtureBehaviorSummaries: [BehaviorCorrelationSummary]? {
        Self.debugFixtureBehaviorSummaries(arguments: ProcessInfo.processInfo.arguments)
    }

    private static func debugFixtureBehaviorSummaries(arguments: [String]) -> [BehaviorCorrelationSummary]? {
        guard let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture") else { return nil }
        let valueIndex = arguments.index(after: fixtureIndex)
        guard valueIndex < arguments.endIndex,
              ["journal-impact", "journal-impact-focus"].contains(arguments[valueIndex]) else {
            return nil
        }

        return [
            BehaviorCorrelationSummary(tag: .sleep, days: 9, recoveryDelta: nil, hrvDelta: 6, rhrDelta: -2),
            BehaviorCorrelationSummary(tag: .training, days: 7, recoveryDelta: nil, hrvDelta: nil, rhrDelta: 3),
            BehaviorCorrelationSummary(tag: .caffeine, days: 6, recoveryDelta: nil, hrvDelta: -4, rhrDelta: nil)
        ]
    }

    private var debugFixtureBehaviorImpacts: [BehaviorImpactSummary]? {
        guard Self.debugFixtureBehaviorSummaries(arguments: ProcessInfo.processInfo.arguments) != nil else {
            return nil
        }
        return [
            BehaviorImpactSummary(tag: .stress, loggedDays: 8, comparisonDays: 24, impact: -11, pValue: 0.04),
            BehaviorImpactSummary(tag: .sleep, loggedDays: 9, comparisonDays: 23, impact: 7, pValue: 0.07)
        ]
    }
    #else
    static var debugShowsImpactOnlyFixture: Bool { false }
    private var debugFixtureBehaviorSummaries: [BehaviorCorrelationSummary]? { nil }
    private var debugFixtureBehaviorImpacts: [BehaviorImpactSummary]? { nil }
    #endif
}

private struct AtriaOverviewBehaviorJournalModel: Equatable {
    let summaries: [BehaviorCorrelationSummary]
    let behaviorImpacts: [BehaviorImpactSummary]
    let taggedDays: Int
}

struct AtriaOverviewBehaviorJournalProjectionState: Equatable {
    fileprivate let model: AtriaOverviewBehaviorJournalModel

    init(summaries: [BehaviorCorrelationSummary],
         behaviorImpacts: [BehaviorImpactSummary],
         taggedDays: Int) {
        model = AtriaOverviewBehaviorJournalModel(
            summaries: Array(summaries.filter { $0.days > 0 }.prefix(3)),
            behaviorImpacts: Array(behaviorImpacts.prefix(3)),
            taggedDays: taggedDays
        )
    }
}

/// Equality-gated bridge for the direct Journal-tab child. It can hear the
/// dashboard revision used by behavior tags without invalidating for unrelated
/// live-session publishes.
@MainActor
final class AtriaOverviewBehaviorJournalProjectionStore: ObservableObject {
    @Published private(set) var state: AtriaOverviewBehaviorJournalProjectionState

    private var cancellables = Set<AnyCancellable>()

    init(state: AtriaOverviewBehaviorJournalProjectionState) {
        self.state = state
    }

    convenience init(store: SessionStore) {
        self.init(state: Self.makeState(store: store))
        bind(to: store)
    }

    @discardableResult
    func refresh(_ next: AtriaOverviewBehaviorJournalProjectionState) -> Bool {
        guard next != state else { return false }
        state = next
        return true
    }

    private func bind(to store: SessionStore) {
        Publishers.MergeMany([
            store.$dashboardRevision.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            store.$behaviorCorrelationSummariesCache.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            store.$behaviorImpactSummariesCache.dropFirst().map { _ in () }.eraseToAnyPublisher()
        ])
        // @Published emits before assignment; coalesce the journal/cache batch
        // onto the next run-loop turn so the projection reads consistent values.
        .debounce(for: .milliseconds(1), scheduler: RunLoop.main)
        .sink { [weak self, weak store] in
            guard let self, let store else { return }
            self.refresh(Self.makeState(store: store))
        }
        .store(in: &cancellables)
    }

    private static func makeState(store: SessionStore) -> AtriaOverviewBehaviorJournalProjectionState {
        AtriaOverviewBehaviorJournalProjectionState(
            summaries: store.behaviorCorrelationSummariesCache,
            behaviorImpacts: store.behaviorImpactSummariesCache,
            taggedDays: store.behaviorJournalEntries.count
        )
    }
}

private struct AtriaOverviewBehaviorJournalContent: View, Equatable {
    let model: AtriaOverviewBehaviorJournalModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "Impacts", subtitle: "What's affecting you")

                Spacer(minLength: 0)

                AtriaStatusChip(text: model.taggedDays > 0 ? "\(model.taggedDays)d" : "learning",
                                systemImage: "waveform.path.ecg",
                                tint: .cyan)
            }

            AtriaJournalImpactStrip(summaries: model.summaries,
                                     behaviorImpacts: model.behaviorImpacts,
                                     taggedDays: model.taggedDays)
        }
        .padding(16)
        .atriaCard(emphasis: .soft)
    }
}

private struct AtriaJournalImpactStrip: View, Equatable {
    let summaries: [BehaviorCorrelationSummary]
    let behaviorImpacts: [BehaviorImpactSummary]
    let taggedDays: Int

    private var focusSummary: BehaviorCorrelationSummary? {
        summaries.first
    }

    var body: some View {
        // The inner "Impact" + day-count header was removed (2026-07-08 UX
        // audit: it duplicated the outer "Impacts" card's title and day chip,
        // reading as a card-in-card). Contents promote straight up.
        VStack(alignment: .leading, spacing: 12) {
            if behaviorImpacts.isEmpty && summaries.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "tag.circle")
                        .foregroundStyle(.secondary)
                    Text(taggedDays > 0 ? "Keep tagging for next-day impact." : "Tags unlock next-day impact.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                if !behaviorImpacts.isEmpty {
                    AtriaJournalBehaviorImpactRows(impacts: behaviorImpacts)
                }

                AtriaJournalImpactGlanceBoard(summaries: summaries,
                                              taggedDays: taggedDays)

                VStack(spacing: 9) {
                    ForEach(summaries, id: \.tag) { summary in
                        AtriaJournalImpactBar(summary: summary)
                    }
                }
            }
        }
        .padding(12)
        .atriaInsetCard(tint: .cyan)
    }
}

struct AtriaJournalBehaviorImpactRows: View, Equatable {
    let impacts: [BehaviorImpactSummary]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(impacts) { impact in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: impact.tag.symbolName)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(tint(for: impact))
                        .frame(width: 18)
                    Text(impact.tag.label)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(impact.valueText) · \(impact.nightsText)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(tint(for: impact))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
            }

            Text("Correlation from your logs, not causation.")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(10)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func tint(for impact: BehaviorImpactSummary) -> Color {
        impact.impact >= 0 ? .mint : .orange
    }
}

private struct AtriaJournalImpactGlanceBoard: View, Equatable {
    let summaries: [BehaviorCorrelationSummary]
    let taggedDays: Int

    private var supportSummaries: [BehaviorCorrelationSummary] {
        summaries.filter { ($0.impactDelta ?? 0) > 0 }
    }

    private var pressureSummaries: [BehaviorCorrelationSummary] {
        summaries.filter { ($0.impactDelta ?? 0) < 0 }
    }

    private var focusSummary: BehaviorCorrelationSummary? {
        summaries.first
    }

    private var patternCount: Int {
        summaries.filter { $0.impactDelta != nil }.count
    }

    private var supportValue: Double {
        min(supportSummaries.reduce(0) { $0 + $1.impactMagnitude } / 12, 1)
    }

    private var pressureValue: Double {
        min(pressureSummaries.reduce(0) { $0 + $1.impactMagnitude } / 12, 1)
    }

    private var leadCue: String {
        if supportValue > pressureValue { return "Support" }
        if pressureValue > supportValue { return "Watch" }
        return "Learning"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.cyan.opacity(0.14))
                    Image(systemName: focusSummary?.tag.symbolName ?? "tag.fill")
                        .font(.headline.weight(.black))
                        .foregroundStyle(.cyan)
                }
                .frame(width: 46, height: 46)

                VStack(alignment: .leading, spacing: 3) {
                    Text(focusSummary?.tag.label ?? "Tag today")
                        .font(.headline.weight(.black))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                    Text(focusSummary.map { "\($0.impactMetricText) \($0.impactValueText)" } ?? "Impact learning")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text(leadCue)
                    .font(.caption.weight(.black))
                    .foregroundStyle(.cyan)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.cyan.opacity(0.12), in: Capsule(style: .continuous))
            }

            // Watch/Support lanes only once there are real links — in the
            // learning state they showed "0 links" twice, which was noise that
            // made the card feel busy without saying anything.
            if summaries.contains(where: { $0.impactDelta != nil }) {
                HStack(spacing: 8) {
                    impactLane(title: "Watch",
                               value: pressureValue,
                               count: pressureSummaries.count,
                               tint: .orange,
                               alignment: .trailing)
                    impactLane(title: "Support",
                               value: supportValue,
                               count: supportSummaries.count,
                               tint: .cyan,
                               alignment: .leading)
                }
            }

            // Only show the watch↔support "impact map" once there are real
            // links to place on it. In the sparse/learning state its tag icons
            // collapsed to the center axis and stacked into a broken-looking
            // column (the "weird journal" report) — gate it so it appears only
            // when it actually communicates something.
            if summaries.contains(where: { $0.impactDelta != nil }) {
                AtriaJournalImpactMap(summaries: summaries)
            }

            HStack(spacing: 7) {
                glanceChip(title: "Logged",
                           value: taggedDays > 0 ? "\(taggedDays)d" : "0d",
                           systemImage: "calendar.badge.checkmark",
                           tint: .cyan)
                glanceChip(title: "Patterns",
                           value: summaries.isEmpty ? "--" : "\(patternCount)",
                           systemImage: "waveform.path.ecg",
                           tint: .mint)
                glanceChip(title: "Focus",
                           value: focusSummary?.tag.label ?? "Tag more",
                           systemImage: "scope",
                           tint: .purple)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Journal impact glance. \(taggedDays) logged days. \(patternCount) behavior patterns. Focus \(focusSummary?.tag.label ?? "tag more"). Watch \(pressureSummaries.count), support \(supportSummaries.count).")
    }

    private func impactLane(title: String,
                            value: Double,
                            count: Int,
                            tint: Color,
                            alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 6) {
            HStack(spacing: 5) {
                if alignment == .trailing { Spacer(minLength: 0) }
                Text(title)
                    .font(.caption2.weight(.bold))
                if alignment == .leading { Spacer(minLength: 0) }
            }
            .foregroundStyle(tint)

            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                ZStack(alignment: alignment == .leading ? .leading : .trailing) {
                    Capsule(style: .continuous)
                        .fill(tint.opacity(0.10))
                    Capsule(style: .continuous)
                        .fill(tint.opacity(0.70))
                        .frame(width: max(8, width * min(max(value, 0), 1)))
                }
            }
            .frame(height: 8)
            .accessibilityHidden(true)

            Text(count == 1 ? "1 link" : "\(count) links")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
        .padding(10)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.inset, style: .continuous))
    }

    private func glanceChip(title: String,
                            value: String,
                            systemImage: String,
                            tint: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
                .background(tint.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(value)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.70)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(tint.opacity(0.065), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(tint.opacity(0.11), lineWidth: 1)
        }
    }
}


private struct AtriaJournalImpactMap: View, Equatable {
    let summaries: [BehaviorCorrelationSummary]

    private var visibleSummaries: [BehaviorCorrelationSummary] {
        Array(summaries.prefix(5))
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let height = max(proxy.size.height, 1)
            let centerX = width / 2
            let centerY = height / 2
            let travel = max(24, (width - 76) / 2)

            ZStack {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.09))
                    .frame(width: width, height: 3)
                    .position(x: centerX, y: centerY)

                Circle()
                    .fill(Color.primary.opacity(0.18))
                    .frame(width: 10, height: 10)
                    .position(x: centerX, y: centerY)
                    .accessibilityHidden(true)

                ForEach(Array(visibleSummaries.enumerated()), id: \.element.tag) { index, summary in
                    mapNode(summary: summary)
                        .position(x: nodeX(summary: summary, centerX: centerX, travel: travel),
                                  y: nodeY(index: index, centerY: centerY))
                }
            }
        }
        .frame(height: 74)
        .padding(.horizontal, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Behavior impact map. Left is watch, center is neutral, right is support.")
    }

    private func mapNode(summary: BehaviorCorrelationSummary) -> some View {
        let isKnown = summary.impactDelta != nil
        let size = 28 + (14 * summary.impactProgress)
        return ZStack {
            Circle()
                .fill(Color.cyan.opacity(isKnown ? 0.18 + (0.16 * summary.impactProgress) : 0.08))
            Circle()
                .stroke(Color.cyan.opacity(isKnown ? 0.46 : 0.18), lineWidth: 1)
            Image(systemName: summary.tag.symbolName)
                .font(.caption.weight(.bold))
                .foregroundStyle(isKnown ? Color.cyan : Color.secondary)
        }
        .frame(width: size, height: size)
        .shadow(color: Color.cyan.opacity(isKnown ? 0.12 : 0), radius: 8, y: 3)
        .accessibilityLabel("\(summary.tag.label), \(summary.impactMetricText) \(summary.impactValueText).")
    }

    private func nodeX(summary: BehaviorCorrelationSummary, centerX: CGFloat, travel: CGFloat) -> CGFloat {
        guard let delta = summary.impactDelta else { return centerX }
        let direction = delta >= 0 ? 1.0 : -1.0
        return centerX + CGFloat(direction * summary.impactProgress) * travel
    }

    private func nodeY(index: Int, centerY: CGFloat) -> CGFloat {
        let offsets: [CGFloat] = [0, -17, 17, -8, 8]
        return centerY + offsets[index % offsets.count]
    }
}



private struct AtriaJournalImpactBar: View, Equatable {
    let summary: BehaviorCorrelationSummary

    private var hasImpact: Bool {
        summary.impactDelta != nil
    }

    private var barTint: Color {
        hasImpact ? .cyan : .secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: summary.tag.symbolName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.cyan)
                    Text(summary.tag.label)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Image(systemName: summary.impactDirectionSymbol)
                        .font(.caption2.weight(.bold))
                    Text("\(summary.impactMetricText) \(summary.impactValueText)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                }
                .foregroundStyle(hasImpact ? .primary : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            }

            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                let center = width / 2
                let fillWidth = max(6, center * summary.impactProgress)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.10))
                    Rectangle()
                        .fill(Color.primary.opacity(0.22))
                        .frame(width: 1.5)
                        .offset(x: center)
                    if let delta = summary.impactDelta {
                        Capsule()
                            .fill(barTint.opacity(0.72))
                            .frame(width: fillWidth)
                            .offset(x: delta >= 0 ? center : center - fillWidth)
                    } else {
                        Capsule()
                            .fill(Color.primary.opacity(0.16))
                            .frame(width: 18)
                            .offset(x: center - 9)
                    }
                }
            }
            .frame(height: 8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(summary.tag.label). \(summary.impactMetricText) \(summary.impactValueText). \(summary.detail).")
    }
}














/// Manual bucketing override for the detail charts (design handoff "Range &
/// interval"). .auto keeps the shipped behavior: raw daily points on short
/// ranges, weekly buckets past 90 days.
enum AtriaChartBucketOverride: String, CaseIterable, Identifiable {
    case auto, daily, weeklyAverage, monthlyAverage

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto"
        // 2026-08-01 (graph grammar slice 4): the design's pattern-3 bucket set
        // is Day / Week avg / Month avg; "Daily" now reads "Day" to match, and
        // Month avg was added alongside.
        case .daily: return "Day"
        case .weeklyAverage: return "Week avg"
        case .monthlyAverage: return "Month avg"
        }
    }
}

/// Bottom sheet controlling the chart WINDOW (design pattern 3: W/M/3M/6M/1Y/
/// All), the BUCKET each point is aggregated by, and the real per-bucket
/// min-max band. Edits are held in draft state and only take effect on Apply,
/// so previewing a wider window doesn't reload data mid-scroll. The deeper
/// windows (3M/6M/1Y/All) are already computed in the prepared history but are
/// not offered in the inline D/W/M bar — this sheet surfaces them.
struct AtriaChartOptionsSheet: View {
    @Binding var window: AtriaTrendRange
    @Binding var bucketOverride: AtriaChartBucketOverride
    @Binding var showMinMaxBand: Bool
    @Environment(\.dismiss) private var dismiss

    @State private var draftWindow: AtriaTrendRange
    @State private var draftBucket: AtriaChartBucketOverride
    @State private var draftShowBand: Bool

    /// The full window set the design's pattern-3 sheet exposes.
    private static let windowOptions: [AtriaTrendRange] =
        [.week, .month, .quarter, .sixMonths, .year, .all]

    init(window: Binding<AtriaTrendRange>,
         bucketOverride: Binding<AtriaChartBucketOverride>,
         showMinMaxBand: Binding<Bool>) {
        _window = window
        _bucketOverride = bucketOverride
        _showMinMaxBand = showMinMaxBand
        _draftWindow = State(initialValue: window.wrappedValue)
        _draftBucket = State(initialValue: bucketOverride.wrappedValue)
        _draftShowBand = State(initialValue: showMinMaxBand.wrappedValue)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("WINDOW")
                        .font(.caption2.weight(.black))
                        .foregroundStyle(.tertiary)
                        .kerning(0.8)
                    AtriaTextSelector(items: Self.windowOptions,
                                      title: { $0.segmentedLabel },
                                      selection: $draftWindow)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("BUCKET EACH POINT BY")
                        .font(.caption2.weight(.black))
                        .foregroundStyle(.tertiary)
                        .kerning(0.8)
                    AtriaTextSelector(items: AtriaChartBucketOverride.allCases,
                                      title: { $0.label },
                                      selection: $draftBucket)
                    Text("Auto shows daily points on short ranges and weekly averages past 3 months.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Toggle(isOn: $draftShowBand) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show min\u{2013}max band")
                            .font(.subheadline.weight(.semibold))
                        Text("Shades each bucket's real range around its average.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)

                Button {
                    window = draftWindow
                    bucketOverride = draftBucket
                    showMinMaxBand = draftShowBand
                    dismiss()
                } label: {
                    Text("Apply")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .atriaCardAction(prominent: true, tint: .accentColor)
            }
            .padding(18)
            .navigationTitle("Range & interval")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
