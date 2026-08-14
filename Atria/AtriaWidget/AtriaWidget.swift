import SwiftUI
import WidgetKit
import ActivityKit
import AppIntents

private let snapshotKey = "atria.widgetSnapshot.v1"
private let appGroupID = "group.com.adidshaft.atria"
private let atriaOverviewURL = URL(string: "atria://tab/overview")!
private let atriaVitalsURL = URL(string: "atria://tab/vitals")!
// Fixed identity hue shared with AtriaRingMetricProjection. This names Strain;
// it does not grade load against a Recovery-derived target.
private let atriaWidgetStrainIdentityColor = Color(red: 0,
                                                   green: 147.0 / 255.0,
                                                   blue: 231.0 / 255.0)

// Single source of truth for the recovery zone tint used by the ring gauges,
// the header percent, and the Lock Screen accessory gauge. Gray/secondary
// means "learning" — never a fabricated color for an unknown percent.
private func atriaRecoveryZoneColor(_ percent: Int?, zone: String? = nil) -> Color {
    guard let percent else { return .secondary }
    switch zone {
    case "green": return .green
    case "yellow": return .yellow
    case "red": return .red
    default: break
    }
    if percent >= 67 { return .green }
    if percent >= 34 { return .yellow }
    return .red
}

// Widget snapshots are local-only and can go stale if Atria hasn't been
// opened in a while. Anything 6h+ old is called out honestly instead of
// silently showing a number that may no longer be true.
private func atriaSnapshotAgeMinutes(_ snapshot: AtriaWidgetSnapshot, now: Date = Date()) -> Int {
    max(0, Int(now.timeIntervalSince(snapshot.createdAt) / 60))
}

private func atriaSnapshotIsStale(_ snapshot: AtriaWidgetSnapshot, now: Date = Date()) -> Bool {
    atriaSnapshotAgeMinutes(snapshot, now: now) >= 6 * 60
}

/// Static WidgetKit snapshots may be rewritten by unrelated fields. Sensor
/// values therefore age from their own capture clock, never `createdAt`.
// Home-screen widgets are not a continuous telemetry surface: WidgetKit may
// coalesce reload requests to the app's bounded one-minute delivery cadence.
// Keep the exact capture clock and label this as a last reading. Live Activity
// uses the stricter six-second source window below.
private let atriaStaticHeartRateFreshness: TimeInterval = 65
private let atriaLiveHeartRateFreshness: TimeInterval = 6
// R10 motion arrives at roughly one accepted frame per second. Fifteen seconds
// tolerates a short radio hiccup without leaving a frozen step count looking
// live for the full HR freshness window.
// Static WidgetKit delivery is intentionally coalesced to one minute by the
// app. Keep the cumulative day-step snapshot valid across that delivery window
// so a continuously healthy stream does not flicker to `--` between reloads.
// Live Activity remains stricter because ActivityKit receives its own frequent
// workout updates.
private let atriaStaticStepFreshness: TimeInterval = 90
private let atriaQualifiedStepAuthorityVersion = "strap-steps-release-v1"
private let atriaBatteryFreshness: TimeInterval = 10 * 60
private let atriaBatteryChargeFreshness: TimeInterval = 90
// Cumulative day strain is a durable wake-to-wake aggregate, not a live HR
// packet. Its value remains displayable when the strap stream pauses; this
// clock only describes how recently Atria recomputed the aggregate. Active
// workout strain below retains the strict sensor-bound 90-second freshness.
private let atriaCumulativeDayStrainFreshness: TimeInterval = 6 * 60 * 60
private let atriaActiveWorkoutStrainFreshness: TimeInterval = 90
private let atriaLiveActivityStepFreshness: TimeInterval = 15
// Keep the source-specific gate explicit at the point of use. This alias also
// prevents static-widget freshness rules from being mistaken for the tighter
// Live Activity transport window.
private let atriaStepFreshness = atriaLiveActivityStepFreshness
private let atriaStaticSensorFutureTolerance: TimeInterval = 5

private func atriaCivilDayKey(_ date: Date, calendar: Calendar) -> String {
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    return String(
        format: "%04d-%02d-%02d",
        components.year ?? 0,
        components.month ?? 0,
        components.day ?? 0
    )
}

private func atriaCumulativeDayStrainIsCurrent(_ snapshot: AtriaWidgetSnapshot,
                                               now: Date) -> Bool {
    guard let capturedAt = snapshot.strainCapturedAt,
          let cycleStart = snapshot.strainCycleStart,
          let cycleExpiresAt = snapshot.strainCycleExpiresAt,
          cycleExpiresAt > cycleStart else { return false }
    let evidenceAge = now.timeIntervalSince(capturedAt)
    return evidenceAge >= -atriaStaticSensorFutureTolerance
        && evidenceAge <= atriaCumulativeDayStrainFreshness
        && now >= cycleStart.addingTimeInterval(-atriaStaticSensorFutureTolerance)
        && capturedAt >= cycleStart.addingTimeInterval(-atriaStaticSensorFutureTolerance)
        && capturedAt < cycleExpiresAt
        && now < cycleExpiresAt
}

private func atriaFreshStaticSensorValue<Value>(_ value: Value?,
                                                capturedAt: Date?,
                                                freshness: TimeInterval,
                                                now: Date) -> Value? {
    guard let value, let capturedAt else { return nil }
    let age = now.timeIntervalSince(capturedAt)
    guard age >= -atriaStaticSensorFutureTolerance,
          age <= freshness else { return nil }
    return value
}

/// Canonical step evidence is a durable wake-to-wake subtotal/total. It is
/// bounded by its physiological cycle, not by the 90-second live radio clock.
/// Legacy snapshots lack the current release-authority revision and fail
/// closed even if a pre-update v15 subtotal was marked canonical.
private func atriaCurrentStepValue(_ snapshot: AtriaWidgetSnapshot,
                                   now: Date) -> Int? {
    guard snapshot.stepsAuthorityVersion
            == atriaQualifiedStepAuthorityVersion else {
        return nil
    }
    if snapshot.stepsSource == "verifiedCanonical" {
        guard let steps = snapshot.steps,
              let cycleStart = snapshot.stepsCycleStart,
              let cycleExpiresAt = snapshot.stepsCycleExpiresAt,
              cycleExpiresAt > cycleStart,
              now >= cycleStart.addingTimeInterval(-atriaStaticSensorFutureTolerance),
              now < cycleExpiresAt else { return nil }
        return steps
    }
    return atriaFreshStaticSensorValue(snapshot.steps,
                                       capturedAt: snapshot.stepsCapturedAt,
                                       freshness: atriaStaticStepFreshness,
                                       now: now)
}

private func atriaStepValueText(_ snapshot: AtriaWidgetSnapshot,
                                steps: Int) -> String {
    let value = steps >= 1000
        ? String(format: "%.1fk", Double(steps) / 1000)
        : "\(steps)"
    if snapshot.stepsSource == "verifiedCanonical",
       snapshot.stepsCompleteness == "partial" {
        return "≥\(value)"
    }
    return snapshot.stepsAreEstimated == false ? value : "~\(value)"
}

private func atriaBatteryEvidenceDate(_ snapshot: AtriaWidgetSnapshot) -> Date? {
    switch (snapshot.batteryCapturedAt, snapshot.batteryCorroboratedAt) {
    case let (captured?, corroborated?): return max(captured, corroborated)
    case let (captured?, nil): return captured
    case let (nil, corroborated?): return corroborated
    case (nil, nil): return nil
    }
}

/// Charging/full are transient sensor claims and require their own fresh
/// evidence. A fresh level or notification corroboration cannot keep the bolt
/// or full-state tint alive after charger evidence expires.
private func atriaFreshBatteryChargeStatus(_ snapshot: AtriaWidgetSnapshot,
                                           now: Date) -> String? {
    guard let status = snapshot.batteryChargeStatus else { return nil }
    guard status == "charging" || status == "full" else { return status }
    guard atriaFreshStaticSensorValue(true,
                                      capturedAt: snapshot.batteryChargeCapturedAt,
                                      freshness: atriaBatteryChargeFreshness,
                                      now: now) != nil else { return nil }
    return status
}

private func atriaFormattedSleepHours(_ hours: Double?) -> String {
    guard let hours, hours > 0 else { return "--" }
    return String(format: "%.1fh", hours)
}

private let atriaTimeOfDayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    return formatter
}()

private func atriaCaptureTimeText(_ capturedAt: Date) -> String {
    atriaTimeOfDayFormatter.string(from: capturedAt)
}

/// 2026-08-14 (§13.6): decode-side mirror of the app target's
/// WidgetWhiteboardRow. Strings only — the extension never recomputes bands.
struct AtriaWidgetWhiteboardRow: Codable, Equatable {
    let id: String
    let symbol: String
    let value: String
    let sentence: String
    let tone: String
}

struct AtriaWidgetSnapshot: Codable {
    let schema: Int
    let createdAt: Date
    var recoveryPercent: Int?
    let recoveryConfidence: String
    var recoveryDetail: String
    var strain: Double
    /// Additive optional evidence qualifier in the schema-4 payload.
    var strainDetail: String? = nil
    /// Cumulative day-strain computation time, not the live-HR packet clock.
    var strainCapturedAt: Date? = nil
    var strainCycleStart: Date? = nil
    var strainCycleExpiresAt: Date? = nil
    var restingHR: Int?
    var hrvRMSSD: Int?
    var hrvState: String
    let maxHR: Int
    // Optional so schema-1 payloads still decode (missing keys -> nil).
    var sleepHours: Double?
    /// Additive optional display-only sleep provenance in schema 4.
    var sleepDetail: String? = nil
    /// Handoff-10 CP1: presentation identity for recovery/sleep. Past the
    /// expiry (end of the display civil day) the extension blanks these
    /// values instead of wearing a prior day's numbers under today's label.
    var displayCivilDay: Date? = nil
    var displayCivilDayKey: String? = nil
    var displayTimeZoneIdentifier: String? = nil
    var recoveryValueState: String? = nil
    var recoveryExpiresAt: Date? = nil
    var sleepExpiresAt: Date? = nil

    // 2026-08-14 (§13.6): additive pre-rendered whiteboard mirror.
    var whiteboardRows: [AtriaWidgetWhiteboardRow]? = nil
    var whiteboardExpiresAt: Date? = nil
    var sleepNeedHours: Double? = nil
    var sleepFillFraction: Double? = nil
    var sleepFillAuthority: String? = nil
    var recoveryZone: String? = nil
    var hrvCapturedAt: Date? = nil
    var biomarkerExpiresAt: Date? = nil

    /// Fail closed at the local civil-day boundary. New payloads compare the
    /// explicit publisher day key; legacy payloads remain decodable but only
    /// survive while `createdAt` is still on the reader's current local day.
    mutating func atriaEnforceCurrentDayIdentity(
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        let currentDayKey = atriaCivilDayKey(now, calendar: calendar)
        let belongsToCurrentDay: Bool
        if let displayCivilDayKey {
            let belongsToCurrentTimeZone = displayTimeZoneIdentifier.map {
                $0 == calendar.timeZone.identifier
            } ?? true
            belongsToCurrentDay = displayCivilDayKey == currentDayKey
                && belongsToCurrentTimeZone
        } else {
            belongsToCurrentDay = calendar.isDate(createdAt, inSameDayAs: now)
        }
        if !belongsToCurrentDay {
            recoveryPercent = nil
            recoveryDetail = "Awaiting today's data"
            sleepHours = nil
            sleepDetail = "Awaiting current sleep"
            whiteboardRows = nil
            sleepNeedHours = nil
            sleepFillFraction = nil
            sleepFillAuthority = nil
            restingHR = nil
            hrvRMSSD = nil
            hrvState = "learning"
            hrvCapturedAt = nil
            strain = 0
            strainDetail = "Awaiting today's data"
            strainCapturedAt = nil
            strainCycleStart = nil
            strainCycleExpiresAt = nil
            steps = nil
            stepsCapturedAt = nil
            stepsSource = nil
            stepsCompleteness = nil
            stepsCoverageFraction = nil
            stepsCycleStart = nil
            stepsCycleExpiresAt = nil
            stepsPriorCycleSteps = nil
            stepsPriorCycleEndedAt = nil
        }
        if let expires = recoveryExpiresAt, now >= expires {
            recoveryPercent = nil
            recoveryDetail = "Awaiting today's data"
        }
        if let expires = sleepExpiresAt, now >= expires {
            sleepHours = nil
            sleepDetail = "Awaiting current sleep"
            sleepFillFraction = nil
            sleepFillAuthority = nil
        }
        // 2026-08-14 (§13.6): the mirror expires with the display civil day.
        if let expires = whiteboardExpiresAt, now >= expires {
            whiteboardRows = nil
            sleepNeedHours = nil
        }
        if let expires = biomarkerExpiresAt, now >= expires {
            restingHR = nil
            hrvRMSSD = nil
            hrvState = "learning"
            hrvCapturedAt = nil
        }
    }
    var steps: Int?
    /// Optional for snapshots written before preliminary strap steps were
    /// exposed honestly in widgets.
    var stepsAreEstimated: Bool? = nil
    var stepsCapturedAt: Date?
    var stepsSource: String? = nil
    var stepsCompleteness: String? = nil
    var stepsCoverageFraction: Double? = nil
    var stepsAuthorityVersion: String? = nil
    var stepsCycleStart: Date? = nil
    var stepsCycleExpiresAt: Date? = nil
    /// 2026-07-31: additive prior-cycle disclosure. Only written while `steps`
    /// is nil; the widget may name the prior count in its detail line but the
    /// step value itself stays "--".
    var stepsPriorCycleSteps: Int? = nil
    var stepsPriorCycleEndedAt: Date? = nil
    var dailyStepGoal: Int? = nil
    let heartRate: Int?
    let heartRateCapturedAt: Date?
    var heartRateZoneIndex: Int? = nil
    var heartRateZoneName: String? = nil
    let batteryLevel: Int?
    var batteryCapturedAt: Date? = nil
    var batteryCorroboratedAt: Date? = nil
    /// Charger evidence has its own clock. Battery percentage/corroboration may
    /// stay current without making an old charging or full state current again.
    var batteryChargeCapturedAt: Date? = nil
    let batteryChargeStatus: String?
    let batteryChargeText: String?
    let layoutGlanceMetrics: [String]?
    let layoutRingCenterMetric: String?
    let layoutLegendStatStyle: String?
    let layoutAccent: String?
    let storage: String
    let appGroupEnabled: Bool
    let widgetTargetPresent: Bool
    let complicationTargetPresent: Bool
}

struct AtriaWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: AtriaWidgetSnapshot?
}

enum AtriaWidgetOverviewLayout {
    case concentric
    case separate
}

struct AtriaWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> AtriaWidgetEntry {
        AtriaWidgetEntry(date: Date(), snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (AtriaWidgetEntry) -> Void) {
        completion(AtriaWidgetEntry(date: Date(), snapshot: Self.loadSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AtriaWidgetEntry>) -> Void) {
        let now = Date()
        let refreshAt = now.addingTimeInterval(15 * 60)
        let snapshot = Self.loadSnapshot()
        var entryDates = [now]
        let batteryEvidenceAt: Date?
        if let snapshot {
            batteryEvidenceAt = atriaBatteryEvidenceDate(snapshot)
        } else {
            batteryEvidenceAt = nil
        }
        // Schedule a second entry at the exact sensor-expiry boundary. Without
        // it, an on-screen widget can retain a value until the normal 15-minute
        // provider refresh even though its source became stale first.
        var expirySources: [(Date?, TimeInterval)] = [
            (snapshot?.heartRateCapturedAt, atriaStaticHeartRateFreshness),
            (batteryEvidenceAt, atriaBatteryFreshness),
            (snapshot?.batteryChargeCapturedAt, atriaBatteryChargeFreshness),
            (snapshot?.strainCapturedAt, atriaCumulativeDayStrainFreshness)
        ]
        if snapshot?.stepsSource != "verifiedCanonical" {
            expirySources.append((snapshot?.stepsCapturedAt, atriaStaticStepFreshness))
        }
        for (capturedAt, freshness) in expirySources {
            guard let capturedAt else { continue }
            let staleAt = capturedAt.addingTimeInterval(freshness + 0.001)
            if staleAt > now, staleAt < refreshAt {
                entryDates.append(staleAt)
            }
        }
        if let cycleExpiresAt = snapshot?.strainCycleExpiresAt,
           cycleExpiresAt > now,
           cycleExpiresAt < refreshAt {
            entryDates.append(cycleExpiresAt)
        }
        if let cycleExpiresAt = snapshot?.stepsCycleExpiresAt,
           cycleExpiresAt > now,
           cycleExpiresAt < refreshAt {
            entryDates.append(cycleExpiresAt)
        }
        // Handoff-10 CP1: reload exactly when the display-day identity expires
        // so a retained snapshot blanks recovery/sleep on its own.
        for identityExpiry in [snapshot?.recoveryExpiresAt,
                               snapshot?.sleepExpiresAt,
                               snapshot?.biomarkerExpiresAt,
                               snapshot?.whiteboardExpiresAt] {
            if let identityExpiry, identityExpiry > now, identityExpiry < refreshAt {
                entryDates.append(identityExpiry)
            }
        }
        let entries = Set(entryDates).sorted().map { date in
            var entrySnapshot = snapshot
            entrySnapshot?.atriaEnforceCurrentDayIdentity(now: date)
            return AtriaWidgetEntry(date: date, snapshot: entrySnapshot)
        }
        completion(Timeline(entries: entries, policy: .after(refreshAt)))
    }

    private static func loadSnapshot() -> AtriaWidgetSnapshot? {
        guard FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) != nil,
              let data = UserDefaults(suiteName: appGroupID)?.data(
                forKey: snapshotKey
              ) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var snapshot = try? decoder.decode(AtriaWidgetSnapshot.self, from: data) else {
            return nil
        }
        snapshot.atriaEnforceCurrentDayIdentity()
        return snapshot
    }
}

struct AtriaWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let entry: AtriaWidgetEntry
    var mediumOverviewLayout: AtriaWidgetOverviewLayout = .concentric

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                accessoryCircular
            case .accessoryRectangular:
                accessoryRectangular
            case .accessoryInline:
                Text(inlineText)
            default:
                systemWidget
            }
        }
        .widgetURL(atriaOverviewURL)
    }

    private var systemWidget: some View {
        Group {
            if entry.snapshot == nil {
                missingSnapshotWidget
            } else {
                switch family {
                case .systemSmall:
                    systemSmallWidget
                case .systemMedium:
                    systemMediumWidget
                case .systemLarge:
                    systemLargeWidget
                default:
                    systemMediumWidget
                }
            }
        }
        .containerBackground(.background, for: .widget)
    }

    /// A blank widget reads like a broken widget. Make the first-run state
    /// explicit, actionable, and visually distinct from a normal-but-learning
    /// recovery score. This is shared by the Home Screen widget families; Lock
    /// Screen accessories stay deliberately terse because the system owns their
    /// available space.
    private var missingSnapshotWidget: some View {
        VStack(alignment: .leading, spacing: 10) {
            widgetHeader

            Spacer(minLength: 0)

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2.weight(.bold))
                .foregroundStyle(.orange)
                .frame(width: 38, height: 38)
                .background(.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text("Snapshot missing")
                .font(.headline.weight(.bold))
                .lineLimit(1)

            Text("Open Atria to start local tracking.")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(family == .systemLarge ? 2 : 1)
                .minimumScaleFactor(0.75)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Atria snapshot missing. Open Atria to start local tracking.")
    }

    private var systemSmallWidget: some View {
        ViewThatFits(in: .vertical) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    accessibleSmallWidget
                } else {
                    standardSmallWidget
                }
            }
            recoveryOnlyWidget
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    // 2026-08-14 (§13.6): the small aggregate face leads with the morning
    // whiteboard mirror; the Recovery gauge is demoted to an index elsewhere.
    // recoveryOnlyWidget stays the pin-anchored extreme-constraint terminal.
    private var standardSmallWidget: some View {
        VStack(alignment: .leading, spacing: 6) {
            widgetHeader

            AtriaWidgetWhiteboardList(rows: entry.snapshot?.whiteboardRows,
                                      compact: true)

            Text(widgetStatusFooter)
                .font(.caption2.weight(.medium))
                .foregroundStyle(widgetStatusTint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Dynamic Type needs a text-first fallback. Removing the decorative ring
    /// preserves the same values and evidence without pushing either edge past
    /// WidgetKit's content margins.
    private var accessibleSmallWidget: some View {
        VStack(alignment: .leading, spacing: 4) {
            widgetHeader
            AtriaWidgetWhiteboardList(rows: entry.snapshot?.whiteboardRows,
                                      compact: true)
            Text(widgetStatusFooter)
                .font(.caption2.weight(.medium))
                .foregroundStyle(widgetStatusTint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var systemMediumWidget: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                accessibleMediumWidget
            } else {
                standardMediumWidget
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var standardMediumWidget: some View {
        ViewThatFits(in: .vertical) {
            Group {
                switch mediumOverviewLayout {
                case .concentric:
                    concentricMediumOverview
                case .separate:
                    separateMediumOverview
                }
            }
            dailyOverviewTextLayout(compact: false)
            dailyOverviewTextLayout(compact: true)
        }
    }

    private var concentricMediumOverview: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 13) {
                AtriaWidgetDailyConcentricRings(
                    recovery: dailyRingPresentation(.recovery),
                    strain: dailyRingPresentation(.strain),
                    sleep: dailyRingPresentation(.sleep),
                    recoveryTint: dailyTint(.recovery)
                )
                .frame(width: 88, height: 88)

                dailyOverviewLegend
            }
            mediumOverviewFooter
        }
    }

    private var separateMediumOverview: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(AtriaDailyOverviewMetric.allCases) { metric in
                    dailySeparateRing(metric)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)

            Divider()
                .opacity(0.45)

            mediumOverviewFooter
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var accessibleMediumWidget: some View {
        ViewThatFits(in: .vertical) {
            dailyOverviewTextLayout(compact: false)
            dailyOverviewTextLayout(compact: true)
        }
    }

    private var dailyOverviewLegend: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(AtriaDailyOverviewMetric.allCases) { metric in
                dailyOverviewLegendRow(metric)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dailyOverviewLegendRow(_ metric: AtriaDailyOverviewMetric) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Circle()
                    .fill(dailyTint(metric))
                    .frame(width: 5, height: 5)
                    .accessibilityHidden(true)
                Text(metric.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(dailyValue(metric))
                    .font(.subheadline.monospacedDigit().weight(.bold))
                    .foregroundStyle(dailyValueTint(metric))
                    .minimumScaleFactor(0.75)
                    .atriaLiveActivityValueTransition(dailyValue(metric))
            }
            Text(dailyDetail(metric))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 10)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(dailyAccessibilityLabel(metric))
    }

    private func dailySeparateRing(_ metric: AtriaDailyOverviewMetric) -> some View {
        VStack(spacing: 3) {
            ZStack {
                AtriaWidgetDailyRing(
                    presentation: dailyRingPresentation(metric),
                    tint: dailyTint(metric),
                    lineWidth: 6.5
                )
                Text(dailyValue(metric))
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(dailyValueTint(metric))
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                    .padding(8)
                    .atriaLiveActivityValueTransition(dailyValue(metric))
            }
            .frame(width: 58, height: 58)

            HStack(spacing: 4) {
                Circle()
                    .fill(dailyTint(metric))
                    .frame(width: 5, height: 5)
                    .accessibilityHidden(true)
                Text(metric.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(dailyDetail(metric))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.86)
                .frame(maxWidth: .infinity, minHeight: 22, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(dailyAccessibilityLabel(metric))
    }

    /// Text-first fallback for accessibility sizes and any medium-widget height
    /// that cannot preserve all three rings plus their evidence. The terminal
    /// variant uses fixed compact type so qualifiers never disappear behind an
    /// ellipsis at the WidgetKit margins.
    private func dailyOverviewTextLayout(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 4) {
            ForEach(AtriaDailyOverviewMetric.allCases) { metric in
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Circle()
                        .fill(dailyTint(metric))
                        .frame(width: compact ? 4 : 5, height: compact ? 4 : 5)
                        .accessibilityHidden(true)
                    Text(metric.title)
                        .font(compact ? .system(size: 10, weight: .semibold) : .caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(dailyValue(metric))
                        .font(compact ? .system(size: 12, weight: .bold, design: .rounded) : .headline.monospacedDigit().weight(.bold))
                        .foregroundStyle(dailyValueTint(metric))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Spacer(minLength: 4)
                    Text(dailyDetail(metric))
                        .font(compact ? .system(size: 9, weight: .medium) : .caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(dailyAccessibilityLabel(metric))
            }
            mediumOverviewFooter
        }
    }

    private var mediumOverviewFooter: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(widgetFreshnessFooter)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(widgetStatusTint)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let battery = batteryHeaderText {
                Label(battery, systemImage: batterySymbol)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(batteryTint)
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
            }
        }
    }

    private func dailyValue(_ metric: AtriaDailyOverviewMetric) -> String {
        switch metric {
        case .recovery:
            return entry.snapshot?.recoveryPercent.map { "\($0)%" } ?? "--"
        case .strain:
            return AtriaWidgetMetric.strain.value(entry.snapshot, now: entry.date)
        case .sleep:
            return atriaFormattedSleepHours(entry.snapshot?.sleepHours)
        }
    }

    private func dailyDetail(_ metric: AtriaDailyOverviewMetric) -> String {
        guard let snapshot = entry.snapshot else { return "Learning" }
        switch metric {
        case .recovery:
            guard snapshot.recoveryPercent != nil else { return "Learning" }
            return displayRecoveryEvidence(snapshot)
        case .strain:
            guard AtriaWidgetMetric.strain.value(snapshot, now: entry.date) != "--" else {
                return "Learning"
            }
            if let detail = snapshot.strainDetail,
               detail.localizedCaseInsensitiveContains("partial") {
                return detail
            }
            return "Current day load"
        case .sleep:
            guard snapshot.sleepHours.map({ $0 > 0 }) == true else { return "Learning" }
            if let detail = snapshot.sleepDetail,
               !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return detail
            }
            return "Sleep recorded"
        }
    }

    private func dailyTint(_ metric: AtriaDailyOverviewMetric) -> Color {
        switch metric {
        case .recovery:
            return atriaRecoveryZoneColor(
                entry.snapshot?.recoveryPercent,
                zone: entry.snapshot?.recoveryZone
            )
        case .strain: return atriaWidgetStrainIdentityColor
        case .sleep: return .indigo
        }
    }

    private func dailyValueTint(_ metric: AtriaDailyOverviewMetric) -> Color {
        dailyValue(metric) == "--" ? .secondary : dailyTint(metric)
    }

    private func dailyRingPresentation(_ metric: AtriaDailyOverviewMetric) -> AtriaDailyRingPresentation {
        guard let snapshot = entry.snapshot else { return .unavailable }
        switch metric {
        case .recovery:
            guard let percent = snapshot.recoveryPercent else { return .unavailable }
            return .progress(min(1, max(0, Double(percent) / 100)))
        case .strain:
            guard AtriaWidgetMetric.strain.value(snapshot, now: entry.date) != "--" else {
                return .unavailable
            }
            if snapshot.strainDetail?.localizedCaseInsensitiveContains("partial") == true {
                return .partial
            }
            return .progress(min(1, max(0, snapshot.strain / 21)))
        case .sleep:
            guard let hours = snapshot.sleepHours, hours > 0 else {
                return .unavailable
            }
            if let fill = snapshot.sleepFillFraction {
                return .progress(min(1, max(0, fill)))
            }
            // Backward-only fallback for payloads written before the exact
            // Today presentation was serialized.
            guard let need = snapshot.sleepNeedHours, need > 0 else {
                return .presence
            }
            return .progress(min(1, max(0, hours / need)))
        }
    }

    private func dailyAccessibilityLabel(_ metric: AtriaDailyOverviewMetric) -> String {
        let value: String
        switch metric {
        case .recovery:
            value = entry.snapshot?.recoveryPercent.map { "\($0) percent" } ?? "unavailable"
        case .strain:
            let rendered = dailyValue(.strain)
            value = rendered.hasPrefix("≥")
                ? "at least \(rendered.dropFirst().trimmingCharacters(in: .whitespaces))"
                : (rendered == "--" ? "unavailable" : rendered)
        case .sleep:
            value = entry.snapshot?.sleepHours.map { String(format: "%.1f hours", $0) } ?? "unavailable"
        }
        return "\(metric.title) \(value). \(dailyDetail(metric))."
    }

    /// Guaranteed terminal layout for constrained Small/Medium widgets. The
    /// evidence and generic widget clock are separate Text values so neither can
    /// be hidden by an ellipsis when the user selects an accessibility size.
    private var recoveryOnlyWidget: some View {
        VStack(alignment: .leading, spacing: 4) {
            widgetHeader
            recoverySummaryRow
            Text(recoveryEvidenceFooter)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(widgetFreshnessFooter)
                .font(.caption2.weight(.medium))
                .foregroundStyle(widgetStatusTint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var systemLargeWidget: some View {
        VStack(alignment: .leading, spacing: 14) {
            widgetHeader

            // 2026-08-14 (§13.6): the whiteboard mirror leads the large face;
            // Recovery stays visible below as a one-line index ("keep as
            // index"), reusing the pin-anchored recoverySummaryRow.
            AtriaWidgetWhiteboardList(rows: entry.snapshot?.whiteboardRows,
                                      compact: false)
            recoverySummaryRow

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(widgetMetrics) { metric in
                    widgetMetricLink(metric)
                }
            }

            Spacer(minLength: 0)

            controlButtons

            Text(largeFooterText)
                .font(.caption2.weight(.medium))
                .foregroundStyle(entry.snapshot == nil ? .orange : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
    }

    private var widgetHeader: some View {
        HStack(spacing: 6) {
            Text("Atria")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let battery = batteryHeaderText {
                Label(battery, systemImage: batterySymbol)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(batteryTint)
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
    }

    private var recoverySummaryRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Recovery")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(entry.snapshot?.recoveryPercent.map { "\($0)%" } ?? "Learning")
                .font(.headline.monospacedDigit().weight(.bold))
                .foregroundStyle(atriaRecoveryZoneColor(
                    entry.snapshot?.recoveryPercent,
                    zone: entry.snapshot?.recoveryZone
                ))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .atriaLiveActivityValueTransition(entry.snapshot?.recoveryPercent ?? -1)
        }
        .accessibilityElement(children: .combine)
    }

    private var widgetMetrics: [AtriaWidgetMetric] {
        AtriaWidgetMetric.ordered(from: entry.snapshot?.layoutGlanceMetrics)
    }

    /// A missing transient metric (most often BPM between strap samples) must
    /// yield its space. Three readable rows are more useful than four tiny
    /// dashboard cards, and configured ordering still decides which rows win.
    private var availableWidgetMetrics: [AtriaWidgetMetric] {
        widgetMetrics.filter { $0.value(entry.snapshot, now: entry.date) != "--" }
    }

    private var mediumWidgetMetrics: [AtriaWidgetMetric] {
        let candidates = availableWidgetMetrics.isEmpty ? widgetMetrics : availableWidgetMetrics
        return Array(candidates.prefix(3))
    }

    private var smallWidgetMetric: AtriaWidgetMetric? {
        if AtriaWidgetMetric.strain.value(entry.snapshot, now: entry.date) != "--" {
            return .strain
        }
        return availableWidgetMetrics.first
    }

    @ViewBuilder
    private func smallMetricSummary(_ metric: AtriaWidgetMetric) -> some View {
        let value = metric.value(entry.snapshot, now: entry.date)
        VStack(alignment: .leading, spacing: 2) {
            Label(metric.title, systemImage: metric.icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(metric.tint)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.title3.monospacedDigit().weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .atriaLiveActivityValueTransition(value)
                if let unit = compactUnit(for: metric) {
                    Text(unit)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            if let evidence = metric.evidenceNote(entry.snapshot) {
                Text(evidence)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(metric.title) \(metricAccessibilityValue(metric, value: value)). \(metric.statusText(entry.snapshot, now: entry.date))")
    }

    private func flatMetricRow(_ metric: AtriaWidgetMetric) -> some View {
        let value = metric.value(entry.snapshot, now: entry.date)
        return Link(destination: metric.deepLinkURL) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Label(metric.title, systemImage: metric.icon)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(metric.tint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                    Spacer(minLength: 4)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(value)
                            .font(.headline.monospacedDigit().weight(.bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                            .atriaLiveActivityValueTransition(value)
                        if let unit = compactUnit(for: metric) {
                            Text(unit)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let evidence = metric.evidenceNote(entry.snapshot) {
                    Text(evidence)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityLabel("\(metric.title) \(metricAccessibilityValue(metric, value: value)). \(metric.statusText(entry.snapshot, now: entry.date))")
    }

    private func compactUnit(for metric: AtriaWidgetMetric) -> String? {
        switch metric {
        case .hrv: return "ms"
        case .bpm, .rhr: return "bpm"
        case .sleep, .steps, .strain: return nil
        }
    }

    private func metricAccessibilityValue(_ metric: AtriaWidgetMetric,
                                          value: String) -> String {
        guard value != "--" else { return "unavailable" }
        switch metric {
        case .hrv: return "\(value) milliseconds"
        case .bpm, .rhr: return "\(value) beats per minute"
        case .steps, .strain, .sleep: return value
        }
    }

    private func widgetMetricLink(_ metric: AtriaWidgetMetric) -> some View {
        Link(destination: metric.deepLinkURL) {
            widgetMetricTile(metric.title,
                             value: metric.value(entry.snapshot, now: entry.date),
                             evidenceNote: metric.evidenceNote(entry.snapshot),
                             icon: metric.icon,
                             tint: metric.tint)
        }
        .accessibilityLabel("\(metric.title) \(metric.value(entry.snapshot, now: entry.date)). \(metric.statusText(entry.snapshot, now: entry.date))")
    }

    private func widgetMetricTile(_ title: String,
                                  value: String,
                                  evidenceNote: String?,
                                  icon: String,
                                  tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(value)
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .atriaLiveActivityValueTransition(value)
            if let evidenceNote {
                Text(evidenceNote)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var stepsText: String {
        guard let snapshot = entry.snapshot,
              let steps = atriaCurrentStepValue(snapshot, now: entry.date) else { return "--" }
        return atriaStepValueText(snapshot, steps: steps)
    }

    private var batteryHeaderText: String? {
        guard let snapshot = entry.snapshot,
              let level = atriaFreshStaticSensorValue(snapshot.batteryLevel,
                                                      capturedAt: atriaBatteryEvidenceDate(snapshot),
                                                      freshness: atriaBatteryFreshness,
                                                      now: entry.date) else { return nil }
        if entry.snapshot?.batteryChargeStatus == "levelOnly" {
            return "\(level)%"
        }
        return "\(level)%"
    }

    private var batterySymbol: String {
        guard let snapshot = entry.snapshot,
              atriaFreshStaticSensorValue(snapshot.batteryLevel,
                                          capturedAt: atriaBatteryEvidenceDate(snapshot),
                                          freshness: atriaBatteryFreshness,
                                          now: entry.date) != nil else { return "questionmark.circle" }
        if atriaFreshBatteryChargeStatus(snapshot, now: entry.date) == "charging" {
            return "battery.100percent.bolt"
        }
        if atriaFreshBatteryChargeStatus(snapshot, now: entry.date) == "full" {
            return "battery.100percent"
        }
        guard let level = snapshot.batteryLevel else { return "questionmark.circle" }
        switch level {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private var batteryTint: Color {
        guard let snapshot = entry.snapshot,
              atriaFreshStaticSensorValue(snapshot.batteryLevel,
                                          capturedAt: atriaBatteryEvidenceDate(snapshot),
                                          freshness: atriaBatteryFreshness,
                                          now: entry.date) != nil else { return .secondary }
        switch atriaFreshBatteryChargeStatus(snapshot, now: entry.date) {
        case "charging", "full": return .green
        default: return .secondary
        }
    }

    private var largeBatteryText: String {
        guard let snapshot = entry.snapshot,
              atriaFreshStaticSensorValue(snapshot.batteryLevel,
                                          capturedAt: atriaBatteryEvidenceDate(snapshot),
                                          freshness: atriaBatteryFreshness,
                                          now: entry.date) != nil else { return "Battery unavailable" }
        if atriaFreshBatteryChargeStatus(snapshot, now: entry.date) != nil,
           let chargeText = snapshot.batteryChargeText,
           !chargeText.isEmpty {
            return chargeText
        }
        return snapshot.batteryLevel.map { "Battery \($0)%" } ?? "Battery unknown"
    }

    private func recoveryColor(_ percent: Int) -> Color {
        atriaRecoveryZoneColor(percent, zone: entry.snapshot?.recoveryZone)
    }

    private var controlButtons: some View {
        HStack(spacing: 8) {
            Button(intent: AtriaControlCaptureIntent(command: .start)) {
                Label("Start", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .tint(.green)

            Button(intent: AtriaControlCaptureIntent(command: .stop)) {
                Label("Stop", systemImage: "stop.circle")
                    .frame(maxWidth: .infinity)
            }
            .tint(.red)
        }
        .font(.caption.weight(.semibold))
        .labelStyle(.titleAndIcon)
    }

    /// Recovery gauge for the Lock Screen. Falls back honestly to "--" and a
    /// gray ring while recovery is still learning — never a fabricated percent.
    /// A stale snapshot keeps its real number (matching the medium widget) but
    /// loses the zone color and gains an age disclosure, so an old score can
    /// never pass for a live one.
    // 2026-08-14 (§13.6): the circular complication shows sleep-vs-need — the
    // one whiteboard fact with an honest 0–1 denominator (the frozen need).
    // Missing sleep or need renders a gray zero gauge: no verdict, never an
    // invented denominator. A stale snapshot keeps the gray-out rule.
    private var accessoryCircular: some View {
        let stale = entry.snapshot.map { atriaSnapshotIsStale($0, now: entry.date) } == true
        return Gauge(value: accessoryCircularProgress) {
            Text("SLP")
        } currentValueLabel: {
            Text(accessoryCircularCenterText)
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .tint(stale || accessoryCircularProgress == 0 ? Color.secondary : .cyan)
        .containerBackground(.background, for: .widget)
        .accessibilityLabel(accessoryCircularAccessibilityLabel(stale: stale))
    }

    private var accessoryCircularCenterText: String {
        guard let hours = entry.snapshot?.sleepHours else { return "--" }
        return String(format: "%.1f", hours)
    }

    private func accessoryCircularAccessibilityLabel(stale: Bool) -> String {
        guard let snapshot = entry.snapshot,
              let hours = snapshot.sleepHours else { return "Sleep learning" }
        let base: String
        if snapshot.sleepFillAuthority == "nightlyNeed",
           let need = snapshot.sleepNeedHours {
            base = String(format: "Sleep %.1f hours of %.1f needed", hours, need)
        } else if snapshot.sleepFillAuthority == "nightlyNeed",
                  let fill = snapshot.sleepFillFraction {
            base = String(format: "Sleep %.1f hours, %.0f percent of nightly need",
                          hours, fill * 100)
        } else if let fill = snapshot.sleepFillFraction {
            base = String(format: "Sleep %.1f hours, %.0f percent of goal",
                          hours, fill * 100)
        } else {
            base = String(format: "Sleep %.1f hours", hours)
        }
        guard stale else { return base }
        let age = atriaSnapshotAgeMinutes(snapshot, now: entry.date) / 60
        return "\(base), stale, from \(age) hours ago"
    }

    private var accessoryCircularProgress: Double {
        guard let snapshot = entry.snapshot,
              snapshot.sleepHours != nil else { return 0 }
        if let fill = snapshot.sleepFillFraction {
            return min(1, max(0, fill))
        }
        guard let hours = snapshot.sleepHours,
              let need = snapshot.sleepNeedHours,
              need > 0 else { return 0 }
        return min(1, max(0, hours / need))
    }

    /// 2026-08-14 (§13.6): whiteboard three-line summary for the Lock Screen —
    /// HRV·RHR, sleep vs need, then staleness disclosure or yesterday's load.
    /// The Recovery-gauge lead is gone; accessoryRecoveryLine/accessoryStrainLine
    /// stay as retained vocabulary.
    private var accessoryRectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(accessoryWhiteboardLine1)
                .font(.caption.monospacedDigit().weight(.bold))
                .lineLimit(1)
            Text(accessoryWhiteboardLine2)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            // At 6h+ old, the staleness disclosure outranks the third row so
            // old numbers never read as live (same rule the larger families
            // follow).
            Text(accessoryStaleLine ?? accessoryWhiteboardLine3)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .containerBackground(.background, for: .widget)
    }

    private func whiteboardRowValue(_ id: String) -> String? {
        entry.snapshot?.whiteboardRows?.first { $0.id == id }?.value
    }

    private var accessoryWhiteboardLine1: String {
        "\(whiteboardRowValue("hrv") ?? "HRV --") · \(whiteboardRowValue("rhr") ?? "RHR --")"
    }

    private var accessoryWhiteboardLine2: String {
        guard let row = entry.snapshot?.whiteboardRows?.first(where: { $0.id == "sleep" }) else {
            return "Sleep --"
        }
        return "\(row.value) \(row.sentence)"
    }

    private var accessoryWhiteboardLine3: String {
        guard let row = entry.snapshot?.whiteboardRows?.first(where: { $0.id == "yesterday" }) else {
            return accessoryHRLine
        }
        return "\(row.value) · \(row.sentence)"
    }

    private var accessoryStaleLine: String? {
        guard let snapshot = entry.snapshot,
              atriaSnapshotIsStale(snapshot, now: entry.date) else { return nil }
        return "Stale · \(atriaSnapshotAgeMinutes(snapshot, now: entry.date) / 60)h old"
    }

    private var accessoryRecoveryLine: String {
        guard let snapshot = entry.snapshot else { return "Rec --" }
        return "Rec " + (snapshot.recoveryPercent.map { "\($0)%" } ?? "--")
    }

    private var accessoryStrainLine: String {
        "Strain \(AtriaWidgetMetric.strain.value(entry.snapshot, now: entry.date))"
    }

    private var accessoryHRLine: String {
        guard let snapshot = entry.snapshot else { return "HR --" }
        let heartRate = atriaFreshStaticSensorValue(snapshot.heartRate,
                                                    capturedAt: snapshot.heartRateCapturedAt,
                                                    freshness: atriaStaticHeartRateFreshness,
                                                    now: entry.date)
        return "HR " + (heartRate.map { "\($0) bpm" } ?? "--")
    }

    private var secondaryText: String {
        guard let snapshot = entry.snapshot else { return "Open app for live strap status" }
        if let recovery = snapshot.recoveryPercent {
            return "Recovery \(recovery)% · \(displayRecoveryEvidence(snapshot))"
        }
        return "Recovery learning · \(displayRecoveryEvidence(snapshot))"
    }

    /// One bounded footer replaces the two stacked captions that overflowed the
    /// physical medium widget. `createdAt` is only the delivery clock: live-only
    /// patches advance it without recomputing Recovery, so the copy explicitly
    /// qualifies the widget rather than dating or staling the score itself.
    private var widgetStatusFooter: String {
        "\(recoveryEvidenceFooter) · \(widgetFreshnessFooter)"
    }

    private var recoveryEvidenceFooter: String {
        guard let snapshot = entry.snapshot else { return "Recovery learning" }
        return displayRecoveryEvidence(snapshot)
    }

    private var widgetFreshnessFooter: String {
        guard let snapshot = entry.snapshot else { return "Open Atria to start tracking" }
        if atriaSnapshotIsStale(snapshot, now: entry.date) {
            let hours = atriaSnapshotAgeMinutes(snapshot, now: entry.date) / 60
            return "Widget stale \(hours)h · Open Atria"
        }
        return "Widget updated \(atriaTimeOfDayFormatter.string(from: snapshot.createdAt))"
    }

    private var widgetStatusTint: Color {
        guard let snapshot = entry.snapshot else { return .orange }
        return atriaSnapshotIsStale(snapshot, now: entry.date) ? .orange : .secondary
    }

    private func displayRecoveryEvidence(_ snapshot: AtriaWidgetSnapshot) -> String {
        let evidence = recoveryEvidenceText(snapshot)
        switch evidence.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "learning": return "Recovery learning"
        case "unverified": return "Early estimate"
        case "personal_baseline", "personal baseline": return "Personal baseline"
        // 2026-08-14 (assessment P0.3): a stale snapshot minted while the
        // reserved tier was reachable renders the strongest honest claim.
        case "validated": return "Personal baseline"
        default: return evidence
        }
    }

    /// Keep the widget aligned with the in-app recovery card. A useful day-one
    /// score must not lose its evidence disclaimer merely because WidgetKit is
    /// rendering a compact surface; `unverified` alone does not tell the user
    /// that HRV was excluded rather than silently treated as neutral.
    ///
    /// The disclaimer is the SPECIFIC half. "Recovery 46% · Limited confidence
    /// · HRV unavailable" is fifty characters on a medium widget's secondary
    /// line, so it rendered as "Recovery 46% · Limited…" — which drops the
    /// evidence this function exists to preserve and leaves a hedge with no
    /// subject. "HRV unavailable" fits, and is the part that says what is
    /// actually missing.
    private func recoveryEvidenceText(_ snapshot: AtriaWidgetSnapshot) -> String {
        if snapshot.recoveryDetail.localizedCaseInsensitiveContains("HRV unavailable") {
            return "HRV unavailable"
        }
        return snapshot.recoveryConfidence
    }

    private var footerText: String {
        guard let snapshot = entry.snapshot else { return "Sleep learning" }
        if atriaSnapshotIsStale(snapshot, now: entry.date) {
            return "Stale · \(atriaSnapshotAgeMinutes(snapshot, now: entry.date) / 60)h old"
        }
        if let sleepDetail = snapshot.sleepDetail,
           sleepDetail.localizedCaseInsensitiveContains("review") {
            return "Sleep \(atriaFormattedSleepHours(snapshot.sleepHours)) · \(sleepDetail)"
        }
        return "Sleep \(atriaFormattedSleepHours(snapshot.sleepHours)) · RHR \(snapshot.restingHR.map(String.init) ?? "learning")"
    }

    /// "Rec 64% · 12.3 strain" — honestly falls back to "--" while recovery
    /// is still learning rather than fabricating a percent, and discloses the
    /// snapshot age once it crosses the stale threshold.
    // 2026-08-14 (§13.6): inline speaks the whiteboard's measured numbers.
    private var inlineText: String {
        guard let snapshot = entry.snapshot else { return "Atria learning" }
        let hrv = whiteboardRowValue("hrv") ?? "HRV --"
        if atriaSnapshotIsStale(snapshot, now: entry.date) {
            return "\(hrv) · \(atriaSnapshotAgeMinutes(snapshot, now: entry.date) / 60)h old"
        }
        return "\(hrv) · \(whiteboardRowValue("rhr") ?? "RHR --")"
    }

    private var largeFooterText: String {
        guard let snapshot = entry.snapshot else { return "Open Atria to start local tracking" }
        let age = atriaSnapshotAgeMinutes(snapshot, now: entry.date)
        if age < 1 { return "Updated now · local snapshot" }
        if age < 60 { return "Updated \(age)m ago · local snapshot" }
        if atriaSnapshotIsStale(snapshot, now: entry.date) {
            return "Stale · updated \(age / 60)h ago, open Atria to refresh"
        }
        return "Updated \(age / 60)h ago · local snapshot"
    }
}

private enum AtriaDailyOverviewMetric: String, CaseIterable, Identifiable {
    case sleep
    case recovery
    case strain

    var id: String { rawValue }

    var title: String {
        rawValue.capitalized
    }
}

private enum AtriaDailyRingPresentation {
    /// A real, bounded scale: Recovery percent or current complete Strain / 21.
    case progress(Double)
    /// A current lower bound. The full dashed rail communicates evidence
    /// presence without pretending the partial value is target completion.
    case partial
    /// A value exists but the payload has no truthful denominator (Sleep).
    case presence
    case unavailable
}

private struct AtriaWidgetDailyRing: View {
    let presentation: AtriaDailyRingPresentation
    let tint: Color
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.14), lineWidth: lineWidth)
            ringEvidence
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var ringEvidence: some View {
        switch presentation {
        case .progress(let progress):
            Circle()
                .trim(from: 0, to: min(1, max(0, progress)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        case .partial:
            Circle()
                .stroke(tint.opacity(0.72),
                        style: StrokeStyle(lineWidth: lineWidth,
                                           lineCap: .round,
                                           dash: [5, 4]))
        case .presence:
            Circle()
                .stroke(tint.opacity(0.72),
                        style: StrokeStyle(lineWidth: lineWidth,
                                           lineCap: .round,
                                           dash: [1, 4]))
        case .unavailable:
            EmptyView()
        }
    }
}

private struct AtriaWidgetDailyConcentricRings: View {
    let recovery: AtriaDailyRingPresentation
    let strain: AtriaDailyRingPresentation
    let sleep: AtriaDailyRingPresentation
    let recoveryTint: Color

    var body: some View {
        ZStack {
            // Match AtriaTriRingSlot.defaultOrder in the app: Sleep is outer,
            // Recovery is middle, and Strain is inner.
            AtriaWidgetDailyRing(presentation: sleep,
                                 tint: .indigo,
                                 lineWidth: 6)
                .frame(width: 88, height: 88)
            AtriaWidgetDailyRing(presentation: recovery,
                                 tint: recoveryTint,
                                 lineWidth: 6)
                .frame(width: 68, height: 68)
            AtriaWidgetDailyRing(presentation: strain,
                                 tint: atriaWidgetStrainIdentityColor,
                                 lineWidth: 6)
                .frame(width: 48, height: 48)
        }
        .accessibilityHidden(true)
    }
}

/// 2026-08-14 (§13.6): no aggregate face leads with this gauge anymore — the
/// whiteboard mirror does. The struct is retained (a) as the terminal
/// extreme-constraint fallback vocabulary and (b) because three green source
/// range-anchors end on this declaration; remove only with a pin migration.
private struct AtriaWidgetRecoveryGauge: View {
    let percent: Int?

    private var progress: Double {
        guard let percent else { return 0 }
        return min(1, max(0, Double(percent) / 100))
    }

    private var tint: Color {
        atriaRecoveryZoneColor(percent)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.16), lineWidth: 9)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(tint, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(percent.map { "\($0)" } ?? "--")
                    .font(.title3.monospacedDigit().weight(.heavy))
                    .minimumScaleFactor(0.55)
                    .lineLimit(1)
                    .atriaLiveActivityValueTransition(percent ?? -1)
                Text("REC")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(percent.map { "Recovery \($0) percent" } ?? "Recovery learning")
    }
}

/// 2026-08-14 (§13.6): whiteboard tone → tint, mirroring the Today card.
private func atriaWhiteboardToneColor(_ tone: String) -> Color {
    switch tone {
    case "supportive": return .green
    case "caution": return .orange
    case "strained": return .red
    default: return .secondary
    }
}

/// 2026-08-14 (§13.6): the widget face of the morning whiteboard. Renders the
/// pre-serialized rows verbatim; nil/empty rows show one honest placeholder
/// instead of resurrecting a Recovery lead.
private struct AtriaWidgetWhiteboardList: View {
    let rows: [AtriaWidgetWhiteboardRow]?
    let compact: Bool

    var body: some View {
        if let rows, !rows.isEmpty {
            VStack(alignment: .leading, spacing: compact ? 4 : 7) {
                ForEach(rows, id: \.id) { row in
                    HStack(spacing: 6) {
                        if compact {
                            Circle()
                                .fill(atriaWhiteboardToneColor(row.tone))
                                .frame(width: 5, height: 5)
                        } else {
                            Image(systemName: row.symbol)
                                .font(.caption2)
                                .foregroundStyle(atriaWhiteboardToneColor(row.tone))
                                .frame(width: 14)
                        }
                        Text(row.value)
                            .font(compact ? .caption2.weight(.bold) : .caption.weight(.bold))
                            .foregroundStyle(atriaWhiteboardToneColor(row.tone))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        if !compact {
                            Text(row.sentence)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(row.value), \(row.sentence)")
                }
            }
        } else {
            Text("Whiteboard awaiting data · Open Atria")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct AtriaStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AtriaWidget", provider: AtriaWidgetProvider()) { entry in
            AtriaWidgetEntryView(entry: entry, mediumOverviewLayout: .concentric)
        }
        .configurationDisplayName("Atria")
        .description("Shows daily Recovery, Strain, and Sleep from Atria's local snapshot.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

/// A distinct static kind preserves every installed `AtriaWidget` instance.
/// It shares the same local timeline and only changes the medium presentation.
struct AtriaSeparateOverviewWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AtriaSeparateOverviewWidget", provider: AtriaWidgetProvider()) { entry in
            AtriaWidgetEntryView(entry: entry, mediumOverviewLayout: .separate)
        }
        .configurationDisplayName("Atria Separate Rings")
        .description("Recovery, strain, and sleep in three separate daily rings.")
        .supportedFamilies([.systemMedium])
    }
}

#if DEBUG
private enum AtriaDailyOverviewPreviewFixture {
    static let now = Date(timeIntervalSince1970: 1_786_214_400)
    static let entry = AtriaWidgetEntry(
        date: now,
        snapshot: AtriaWidgetSnapshot(
            schema: 4,
            createdAt: now,
            recoveryPercent: 53,
            recoveryConfidence: "unverified",
            recoveryDetail: "Limited confidence · HRV unavailable",
            strain: 4.2,
            strainDetail: "Partial · 52% tracked",
            strainCapturedAt: now.addingTimeInterval(-60),
            strainCycleStart: now.addingTimeInterval(-8 * 60 * 60),
            strainCycleExpiresAt: now.addingTimeInterval(16 * 60 * 60),
            restingHR: 58,
            hrvRMSSD: nil,
            hrvState: "unavailable",
            maxHR: 190,
            sleepHours: 7.4,
            sleepDetail: "Review sleep",
            // 2026-08-14 (§13.6): sample whiteboard mirror for previews.
            whiteboardRows: [
                .init(id: "hrv", symbol: "waveform.path.ecg",
                      value: "HRV 52 ms", sentence: "typical 48–61 ms",
                      tone: "supportive"),
                .init(id: "rhr", symbol: "heart",
                      value: "RHR 55 bpm", sentence: "typical 53–61 bpm",
                      tone: "supportive"),
                .init(id: "sleep", symbol: "moon.zzz.fill",
                      value: "Slept 7h 24m", sentence: "of 8h 20m need",
                      tone: "supportive"),
                .init(id: "yesterday", symbol: "flame",
                      value: "TRIMP 188 (15.0)", sentence: "yesterday",
                      tone: "neutral"),
            ],
            whiteboardExpiresAt: Date().addingTimeInterval(12 * 3_600),
            sleepNeedHours: 8.3,
            steps: nil,
            stepsAreEstimated: nil,
            stepsCapturedAt: nil,
            stepsSource: nil,
            stepsCompleteness: nil,
            stepsCoverageFraction: nil,
            stepsAuthorityVersion: nil,
            stepsCycleStart: nil,
            stepsCycleExpiresAt: nil,
            stepsPriorCycleSteps: nil,
            stepsPriorCycleEndedAt: nil,
            dailyStepGoal: 8_000,
            heartRate: nil,
            heartRateCapturedAt: nil,
            heartRateZoneIndex: nil,
            heartRateZoneName: nil,
            batteryLevel: 53,
            batteryCapturedAt: now.addingTimeInterval(-30),
            batteryCorroboratedAt: now.addingTimeInterval(-30),
            batteryChargeCapturedAt: now.addingTimeInterval(-30),
            batteryChargeStatus: "notCharging",
            batteryChargeText: "Not charging",
            layoutGlanceMetrics: nil,
            layoutRingCenterMetric: nil,
            layoutLegendStatStyle: nil,
            layoutAccent: nil,
            storage: "preview",
            appGroupEnabled: true,
            widgetTargetPresent: true,
            complicationTargetPresent: true
        )
    )
}

#Preview("Daily Overview · Concentric", as: .systemMedium) {
    AtriaStatusWidget()
} timeline: {
    AtriaDailyOverviewPreviewFixture.entry
}

#Preview("Daily Overview · Separate · Partial", as: .systemMedium) {
    AtriaSeparateOverviewWidget()
} timeline: {
    AtriaDailyOverviewPreviewFixture.entry
}
#endif

private struct AtriaLiveActivityValueTransition<Value: Equatable>: ViewModifier {
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.22), value: value)
        }
    }
}

private extension View {
    func atriaLiveActivityValueTransition<Value: Equatable>(_ value: Value) -> some View {
        modifier(AtriaLiveActivityValueTransition(value: value))
    }
}

private struct AtriaDynamicIslandCompactHeartRate: View {
    let heartRate: Int
    let isLive: Bool

    var body: some View {
        Text(isLive ? "\(heartRate)" : "--")
            .font(.system(size: 15, weight: .black, design: .rounded))
            .monospacedDigit()
            .atriaLiveActivityValueTransition(isLive ? heartRate : -1)
        .lineLimit(1)
        .minimumScaleFactor(0.82)
        .allowsTightening(true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isLive
                            ? "Heart rate \(heartRate) beats per minute"
                            : "Heart rate unavailable")
    }
}

private struct AtriaDynamicIslandMinimalHeartRate: View {
    let heartRate: Int
    let activityName: String
    let zoneLabel: String
    let tint: Color

    var body: some View {
        Text("\(heartRate)")
            .font(.system(size: 14, weight: .black, design: .rounded))
            .monospacedDigit()
            .atriaLiveActivityValueTransition(heartRate)
        .foregroundStyle(tint)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .allowsTightening(true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(activityName) workout, live heart rate \(heartRate) beats per minute, \(zoneLabel)")
    }
}

private struct AtriaDynamicIslandActivityGlyph: View {
    let symbol: String
    let tint: Color
    let isPaused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                glyph
            } else {
                glyph
                    .symbolEffect(.bounce, options: .nonRepeating, value: isPaused)
            }
        }
    }

    private var glyph: some View {
        Image(systemName: symbol)
            .foregroundStyle(tint)
    }
}

private struct AtriaLiveActivityStatusPresentation {
    let text: String
    let systemImage: String
    let tint: Color
    let accessibilityText: String
}

private func liveActivityStatusPresentation(
    for state: AtriaLiveActivityAttributes.ContentState,
    heartRateAvailability: AtriaLiveSensorAvailability
) -> AtriaLiveActivityStatusPresentation {
    if state.isEnding ?? false {
        return .init(text: "Ending",
                     systemImage: "stop.circle.fill",
                     tint: .red,
                     accessibilityText: "Workout ending")
    }
    if state.isPaused ?? false {
        return .init(text: "Paused",
                     systemImage: "pause.circle.fill",
                     tint: .orange,
                     accessibilityText: "Workout paused")
    }
    switch heartRateAvailability {
    case .live:
        return .init(text: "Live",
                     systemImage: "circle.fill",
                     tint: .green,
                     accessibilityText: "Workout live")
    case .reconnecting:
        return .init(text: "Reconnecting",
                     systemImage: "antenna.radiowaves.left.and.right",
                     tint: .orange,
                     accessibilityText: "Workout active, strap reconnecting")
    case .stale:
        return .init(text: "Signal stale",
                     systemImage: "exclamationmark.triangle.fill",
                     tint: .orange,
                     accessibilityText: "Workout active, heart rate signal stale")
    case .unavailable:
        return .init(text: "No signal",
                     systemImage: "exclamationmark.circle",
                     tint: .secondary,
                     accessibilityText: "Workout active, heart rate unavailable")
    }
}

struct AtriaLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AtriaLiveActivityAttributes.self) { context in
            AtriaLiveActivityLockScreenView(context: context)
                .activityBackgroundTint(Color(.systemBackground))
                .activitySystemActionForegroundColor(.primary)
                .widgetURL(atriaVitalsURL)
        } dynamicIsland: { context in
            // ActivityKit owns this stale transition. Once it fires, fail all
            // transient sensor values closed even if SwiftUI has not received
            // another app-authored update for each independent evidence clock.
            let activityIsStale = context.isStale
            let now = activityIsStale ? Date.distantFuture : Date()
            let heartAvailability = liveActivityHeartRateAvailability(for: context.state, now: now)
            let signalFresh = heartAvailability == .live
            let status = liveActivityStatusPresentation(for: context.state,
                                                        heartRateAvailability: heartAvailability)
            let nominalState = heartAvailability == .live
                && context.state.isPaused != true
                && context.state.isEnding != true
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    AtriaDynamicIslandExpandedHeader(state: context.state,
                                                     status: status,
                                                     nominalState: nominalState)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    liveActivityTimer(state: context.state,
                                      startedAt: context.attributes.startedAt)
                        .font(.headline.monospacedDigit().weight(.bold))
                        .foregroundStyle((context.state.isPaused ?? false) ? .orange : .primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                        .frame(minWidth: 54, alignment: .trailing)
                        .layoutPriority(2)
                        .accessibilityLabel(liveActivityDurationAccessibilityText(
                            state: context.state,
                            startedAt: context.attributes.startedAt
                        ))
                }

                DynamicIslandExpandedRegion(.bottom) {
                    AtriaDynamicIslandExpandedBottom(
                        state: context.state,
                        startedAt: context.attributes.startedAt,
                        heartRateAvailability: heartAvailability,
                        now: now,
                        activityIsStale: activityIsStale
                    )
                }
            } compactLeading: {
                if !nominalState {
                    Image(systemName: status.systemImage)
                        .font(.caption.weight(.black))
                        .foregroundStyle(status.tint)
                        .accessibilityLabel(status.accessibilityText)
                } else if let target = liveActivityTargetZoneLabel(for: context.state) {
                    Text("T \(target)")
                        .font(.caption2.monospacedDigit().weight(.black))
                        .foregroundStyle(.cyan)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        .atriaLiveActivityValueTransition(target)
                        .accessibilityLabel("Target heart rate \(target)")
                } else {
                    AtriaDynamicIslandActivityGlyph(
                        symbol: context.state.activitySystemImage ?? "figure.mixed.cardio",
                        tint: liveActivityZoneColor(for: context.state,
                                                    availability: heartAvailability),
                        isPaused: context.state.isPaused ?? false
                    )
                        .accessibilityLabel("\(context.state.activityName ?? "Workout") workout")
                }
            } compactTrailing: {
                AtriaDynamicIslandCompactHeartRate(heartRate: context.state.heartRate,
                                                    isLive: signalFresh)
            } minimal: {
                if nominalState {
                    AtriaDynamicIslandMinimalHeartRate(
                        heartRate: context.state.heartRate,
                        activityName: context.state.activityName ?? "Workout",
                        zoneLabel: liveActivityZoneLabel(for: context.state,
                                                        availability: heartAvailability),
                        tint: liveActivityZoneColor(for: context.state,
                                                    availability: heartAvailability)
                    )
                } else {
                    Image(systemName: status.systemImage)
                        .foregroundStyle(status.tint)
                        .accessibilityLabel(status.accessibilityText)
                }
            }
            .widgetURL(atriaVitalsURL)
            .keylineTint(nominalState
                         ? liveActivityZoneColor(for: context.state,
                                                 availability: heartAvailability)
                         : status.tint)
        }
    }
}

private struct AtriaDynamicIslandExpandedHeader: View {
    let state: AtriaLiveActivityAttributes.ContentState
    let status: AtriaLiveActivityStatusPresentation
    let nominalState: Bool

    private var title: String {
        nominalState ? (state.activityName ?? "Workout") : status.text
    }

    private var symbol: String {
        nominalState
            ? (state.activitySystemImage ?? "figure.mixed.cardio")
            : status.systemImage
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Label(title, systemImage: symbol)
            Label(nominalState ? "Workout" : status.text, systemImage: symbol)
            Image(systemName: symbol)
        }
        .font(.caption.weight(.bold))
        .foregroundStyle(nominalState ? .primary : status.tint)
        .lineLimit(1)
        .minimumScaleFactor(0.82)
        .allowsTightening(true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(nominalState
                            ? "\(state.activityName ?? "Workout") workout"
                            : status.accessibilityText)
    }
}

private struct AtriaDynamicIslandExpandedBottom: View {
    let state: AtriaLiveActivityAttributes.ContentState
    let startedAt: Date
    let heartRateAvailability: AtriaLiveSensorAvailability
    let now: Date
    let activityIsStale: Bool

    private var signalFresh: Bool { heartRateAvailability == .live }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            expandedMetricRail(showsSupportingFacts: true)
            expandedMetricRail(showsSupportingFacts: false)
        }
    }

    private func expandedMetricRail(showsSupportingFacts: Bool) -> some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Image(systemName: "heart.fill")
                    .font(.caption.weight(.black))
                Text(signalFresh ? "\(state.heartRate)" : "--")
                    .font(.system(size: 27, weight: .black, design: .rounded))
                    .monospacedDigit()
                Text("BPM")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(signalFresh ? .red : .secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .layoutPriority(2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(signalFresh
                                ? "Heart rate \(state.heartRate) beats per minute"
                                : "Heart rate unavailable")

            if showsSupportingFacts {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(zoneValue)
                            .font(.headline.monospacedDigit().weight(.black))
                            .foregroundStyle(liveActivityZoneColor(for: state,
                                                                   availability: heartRateAvailability))
                        if let target = liveActivityTargetZoneLabel(for: state) {
                            Text("T \(target)")
                                .font(.caption2.monospacedDigit().weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(zoneAccessibilityLabel)

                    HStack(spacing: 4) {
                        Text(strainValue)
                            .font(.caption.monospacedDigit().weight(.black))
                            .foregroundStyle(liveActivityStrainProgressColor(for: state, now: now))
                        Text(strainCaption)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Workout strain \(strainAccessibilityValue)")
                }
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .layoutPriority(1)
            }

            Spacer(minLength: 0)

            AtriaLiveActivityControls(state: state,
                                      startedAt: startedAt)
                .frame(width: 96)
                .layoutPriority(3)
        }
    }

    private var zoneValue: String {
        guard heartRateAvailability == .live else { return "--" }
        guard let zone = state.heartRateZoneIndex, zone > 0 else { return "<Z1" }
        return "Z\(zone)"
    }

    private var strainCaption: String { "strain" }

    private var zoneAccessibilityLabel: String {
        guard heartRateAvailability == .live else { return "Heart rate zone unavailable" }
        let current = liveActivityZoneLabel(for: state, availability: heartRateAvailability)
        guard let target = liveActivityTargetZoneLabel(for: state) else { return current }
        return "\(current). Target heart rate \(target)"
    }

    private var strainValue: String {
        guard let strain = liveActivityFreshWorkoutStrain(state, now: now),
              !activityIsStale else { return "--" }
        return String(format: "%.1f", strain)
    }

    private var strainAccessibilityValue: String {
        liveActivityStrainProgressText(for: state, now: now)
    }
}

private func liveActivityBatteryAvailability(
    for state: AtriaLiveActivityAttributes.ContentState,
    now: Date = Date()
) -> AtriaLiveSensorAvailability {
    if state.batteryAvailability == .reconnecting { return .reconnecting }
    if state.batteryAvailability == .unavailable { return .unavailable }
    guard state.batteryLevel >= 0,
          let capturedAt = state.batteryCapturedAt else { return .unavailable }
    let age = now.timeIntervalSince(capturedAt)
    guard age >= -atriaStaticSensorFutureTolerance else { return .unavailable }
    if age > atriaBatteryFreshness || state.batteryAvailability == .stale { return .stale }
    return .live
}

private func liveActivityChargeStatusIsFresh(
    for state: AtriaLiveActivityAttributes.ContentState,
    now: Date = Date()
) -> Bool {
    guard liveActivityBatteryAvailability(for: state, now: now) == .live,
          state.batteryChargeStatus == "charging"
            || state.batteryChargeStatus == "full",
          let capturedAt = state.batteryChargeCapturedAt else { return false }
    let age = now.timeIntervalSince(capturedAt)
    return age >= -atriaStaticSensorFutureTolerance && age <= atriaBatteryChargeFreshness
}

private func liveActivityBatteryText(
    for state: AtriaLiveActivityAttributes.ContentState,
    now: Date = Date()
) -> String {
    switch liveActivityBatteryAvailability(for: state, now: now) {
    case .reconnecting: return "Battery reconnecting"
    case .stale: return "Battery stale"
    case .unavailable: return "Battery unavailable"
    case .live: break
    }
    if liveActivityChargeStatusIsFresh(for: state, now: now) {
        return state.batteryChargeStatus == "full"
            ? "\(state.batteryLevel)% · Fully charged"
            : "\(state.batteryLevel)% · Charging"
    }
    switch state.batteryChargeStatus {
    case "notCharging":
        return state.batteryLevel <= 20
            ? "\(state.batteryLevel)% · Low"
            : "\(state.batteryLevel)% · Not charging"
    default:
        return state.batteryLevel <= 20
            ? "\(state.batteryLevel)% · Low"
            : "\(state.batteryLevel)%"
    }
}

private func liveActivityBatterySymbol(
    for state: AtriaLiveActivityAttributes.ContentState,
    now: Date = Date()
) -> String {
    guard liveActivityBatteryAvailability(for: state, now: now) == .live else {
        return "questionmark.circle"
    }
    if liveActivityChargeStatusIsFresh(for: state, now: now) {
        return state.batteryChargeStatus == "full"
            ? "battery.100percent"
            : "battery.100percent.bolt"
    }
    guard state.batteryLevel >= 0 else { return "questionmark.circle" }
    switch state.batteryLevel {
    case ..<13: return "battery.0percent"
    case ..<38: return "battery.25percent"
    case ..<63: return "battery.50percent"
    case ..<88: return "battery.75percent"
    default: return "battery.100percent"
    }
}

private func liveActivityBatteryTint(
    for state: AtriaLiveActivityAttributes.ContentState,
    now: Date = Date()
) -> Color {
    guard liveActivityBatteryAvailability(for: state, now: now) == .live else {
        return .secondary
    }
    if liveActivityChargeStatusIsFresh(for: state, now: now) { return .green }
    return state.batteryLevel >= 0 && state.batteryLevel <= 20 ? .red : .secondary
}

private func liveActivityHeartRateAvailability(
    for state: AtriaLiveActivityAttributes.ContentState,
    now: Date = Date()
) -> AtriaLiveSensorAvailability {
    if state.heartRateAvailability == .reconnecting { return .reconnecting }
    if state.heartRateAvailability == .unavailable { return .unavailable }
    // A legacy activity without a source clock must fail closed. `updatedAt`
    // also changes for battery, timer and media updates, so using it here would
    // make an old HR and zone look live again.
    guard let capturedAt = state.heartRateCapturedAt else {
        return state.heartRate > 0 ? .stale : .unavailable
    }
    let isFresh = state.heartRate > 0
        && state.sensorHasContact != false
        && capturedAt <= now.addingTimeInterval(5)
        && now.timeIntervalSince(capturedAt) <= atriaLiveHeartRateFreshness
    if isFresh, state.heartRateAvailability != .stale { return .live }
    if state.heartRateCapturedAt != nil || state.heartRate > 0
        || state.heartRateAvailability == .stale {
        return .stale
    }
    return .unavailable
}

private func liveActivityZoneLabel(for state: AtriaLiveActivityAttributes.ContentState,
                                   availability: AtriaLiveSensorAvailability) -> String {
    switch availability {
    case .reconnecting: return "Reconnecting"
    case .stale: return "HR stale"
    case .unavailable: return "Unavailable"
    case .live: break
    }
    let index = state.heartRateZoneIndex ?? 0
    if index <= 0 { return "Below Z1" }
    return "Z\(index) · \(state.heartRateZoneName ?? "Zone")"
}

/// A compact, stable target label. Invalid persisted values fail closed, while
/// reversed picker bounds normalize to the same range the workout UI uses.
private func liveActivityTargetZoneLabel(for state: AtriaLiveActivityAttributes.ContentState) -> String? {
    guard let first = state.targetLowerHeartRateZone,
          let second = state.targetUpperHeartRateZone,
          (1...5).contains(first),
          (1...5).contains(second) else { return nil }
    let lower = min(first, second)
    let upper = max(first, second)
    return lower == upper ? "Z\(lower)" : "Z\(lower)–Z\(upper)"
}

private func liveActivityZoneColor(for state: AtriaLiveActivityAttributes.ContentState,
                                   availability: AtriaLiveSensorAvailability) -> Color {
    guard availability == .live else {
        return availability == .reconnecting ? .orange : .secondary
    }
    switch state.heartRateZoneIndex ?? 0 {
    case 1: return .blue
    case 2: return .green
    case 3: return .yellow
    case 4: return .orange
    case 5: return .red
    default: return .secondary
    }
}

/// Per-segment color for the Dynamic Island HR-zone bar. The active zone is
/// full-strength in its zone color; the rest are dimmed so the bar reads as a
/// glanceable "where am I on the 1-5 scale" without a number.
private func liveActivityZoneSegmentColor(zone: Int,
                                          state: AtriaLiveActivityAttributes.ContentState,
                                          availability: AtriaLiveSensorAvailability) -> Color {
    let base: Color
    switch zone {
    case 1: base = .blue
    case 2: base = .green
    case 3: base = .yellow
    case 4: base = .orange
    default: base = .red
    }
    guard availability == .live, let active = state.heartRateZoneIndex, active >= 1 else {
        return Color.secondary.opacity(0.22)
    }
    return zone == active ? base : base.opacity(0.22)
}

/// Five-segment HR-zone bar for the Dynamic Island expanded region (design
/// 2026-08-05): mirrors the in-app live-workout zone bar. Callers gate it on a
/// live signal so it never grows the island in the waiting/stale state.
@ViewBuilder
private func liveActivityZoneBar(for state: AtriaLiveActivityAttributes.ContentState,
                                 availability: AtriaLiveSensorAvailability) -> some View {
    HStack(spacing: 3) {
        ForEach(1...5, id: \.self) { zone in
            Capsule(style: .continuous)
                .fill(liveActivityZoneSegmentColor(zone: zone, state: state, availability: availability))
                .frame(height: 4)
        }
    }
    .frame(maxWidth: .infinity)
    .accessibilityHidden(true)
}

private struct AtriaLiveActivityStepsPresentation {
    let compactText: String
    let labelText: String
    let tint: Color
    let accessibilityText: String
}

private struct AtriaLiveActivityGoalPresentation {
    let text: String
    let tint: Color
    let fraction: Double?
    let accessibilityText: String
}

private func liveActivityStepsAvailability(
    for state: AtriaLiveActivityAttributes.ContentState,
    now: Date = Date()
) -> AtriaLiveSensorAvailability {
    if state.stepsAvailability == .reconnecting { return .reconnecting }
    if state.stepsAvailability == .unavailable { return .unavailable }
    guard let capturedAt = state.stepsCapturedAt else {
        return state.steps != nil ? .stale : .unavailable
    }
    let isFresh = capturedAt <= now.addingTimeInterval(5)
        && now.timeIntervalSince(capturedAt) <= atriaStepFreshness
    if isFresh, state.steps != nil, state.stepsAvailability != .stale { return .live }
    return .stale
}

/// Healthy live metrics already communicate their state through color and
/// value. Reserve the extra status row for an actionable stale/reconnecting/
/// unavailable source so the Lock Screen stays glanceable during normal use.
private func liveActivitySensorStatusText(
    state: AtriaLiveActivityAttributes.ContentState,
    heartRateAvailability: AtriaLiveSensorAvailability,
    now: Date = Date()
) -> String? {
    let stepsAvailability = liveActivityStepsAvailability(for: state, now: now)
    var statuses: [String] = []
    if heartRateAvailability != .live {
        statuses.append(liveActivitySourceFreshnessText(
            label: "HR",
            capturedAt: state.heartRateCapturedAt,
            availability: heartRateAvailability
        ))
    }
    if stepsAvailability != .live {
        statuses.append(liveActivitySourceFreshnessText(
            label: "Steps",
            capturedAt: state.stepsCapturedAt,
            availability: stepsAvailability
        ))
    }
    return statuses.isEmpty ? nil : statuses.joined(separator: " · ")
}

private func liveActivitySourceFreshnessText(
    label: String,
    capturedAt: Date?,
    availability: AtriaLiveSensorAvailability
) -> String {
    switch availability {
    case .live:
        return capturedAt.map { "\(label) \(atriaCaptureTimeText($0))" } ?? "\(label) --"
    case .reconnecting:
        return "\(label) syncing"
    case .stale:
        return capturedAt.map { "\(label) last \(atriaCaptureTimeText($0))" } ?? "\(label) stale"
    case .unavailable:
        return "\(label) --"
    }
}

private func liveActivityStepsPresentation(
    for state: AtriaLiveActivityAttributes.ContentState,
    now: Date = Date()
) -> AtriaLiveActivityStepsPresentation {
    let sourceAvailability = liveActivityStepsAvailability(for: state, now: now)
    if sourceAvailability == .reconnecting {
        return AtriaLiveActivityStepsPresentation(compactText: "--",
                                                  labelText: "Steps reconnecting",
                                                  tint: .orange,
                                                  accessibilityText: "Strap steps reconnecting")
    }
    if sourceAvailability == .unavailable {
        return AtriaLiveActivityStepsPresentation(compactText: "--",
                                                  labelText: "Steps unavailable",
                                                  tint: .secondary,
                                                  accessibilityText: "Strap steps unavailable")
    }
    if sourceAvailability == .live, let steps = state.steps {
        let estimated = state.stepsAreEstimated != false
        let value = estimated ? "~\(steps)" : "\(steps)"
        return AtriaLiveActivityStepsPresentation(
            compactText: value,
            labelText: "\(value) steps",
            tint: .mint,
            accessibilityText: estimated
                ? "Approximately \(steps) strap-derived workout steps"
                : "\(steps) strap-derived workout steps"
        )
    }
    if sourceAvailability == .stale {
        return AtriaLiveActivityStepsPresentation(compactText: "--",
                                                  labelText: "Steps stale",
                                                  tint: .orange,
                                                  accessibilityText: "Strap step signal stale")
    }
    return AtriaLiveActivityStepsPresentation(compactText: "--",
                                              labelText: "Steps unavailable",
                                              tint: .secondary,
                                              accessibilityText: "Strap steps unavailable")
}

private func liveActivityDailyStepGoalPresentation(
    for state: AtriaLiveActivityAttributes.ContentState,
    now: Date = Date()
) -> AtriaLiveActivityGoalPresentation? {
    guard let goal = state.dailyStepGoal, goal > 0 else { return nil }
    // Workout-local motion has a different clock and availability state. It
    // must never make an all-day receipt look fresh (or unavailable).
    guard let steps = state.dailySteps else {
        return AtriaLiveActivityGoalPresentation(text: "Step goal --",
                                                 tint: .secondary,
                                                 fraction: nil,
                                                 accessibilityText: "Daily strap step goal unavailable")
    }
    guard let capturedAt = state.dailyStepsCapturedAt,
          capturedAt <= now.addingTimeInterval(5),
          now.timeIntervalSince(capturedAt) <= atriaLiveActivityStepFreshness else {
        return AtriaLiveActivityGoalPresentation(text: "Step goal stale",
                                                 tint: .orange,
                                                 fraction: nil,
                                                 accessibilityText: "Daily strap step goal stale")
    }
    let estimated = state.dailyStepsAreEstimated != false
    // Missing lower-bound provenance belongs to an older activity payload and
    // therefore fails closed. Only an explicit false value can claim exactness.
    let lowerBound = state.dailyStepsIsLowerBound != false
    let exact = !estimated && !lowerBound
    let prefix = lowerBound ? "≥" : estimated ? "~" : ""
    let reached = steps >= goal
    let text = reached && exact
        ? "Goal ✓ · \(steps)"
        : "\(prefix)\(steps) / \(goal)"
    let accessibility = lowerBound
        ? "At least \(steps) of \(goal) verified daily strap steps"
        : estimated
        ? "Approximately \(steps) of \(goal) daily strap steps"
        : reached
            ? "Daily strap step goal reached with \(steps) steps"
            : "\(steps) of \(goal) daily strap steps"
    return AtriaLiveActivityGoalPresentation(text: text,
                                             tint: reached && exact ? .green : .mint,
                                             fraction: min(max(Double(steps) / Double(goal), 0), 1),
                                             accessibilityText: accessibility)
}

private func liveActivityStrainProgressText(
    for state: AtriaLiveActivityAttributes.ContentState,
    now: Date = Date()
) -> String {
    guard let strain = liveActivityFreshWorkoutStrain(state, now: now) else { return "Strain --" }
    guard let target = state.targetWorkoutStrain, target > 0 else {
        return String(format: "%.1f", strain)
    }
    if strain >= target {
        return String(format: "Goal ✓ · %.1f", strain)
    }
    return String(format: "%.1f / %.1f", strain, target)
}

private func liveActivityStrainProgressColor(
    for state: AtriaLiveActivityAttributes.ContentState,
    now: Date = Date()
) -> Color {
    guard let strain = liveActivityFreshWorkoutStrain(state, now: now) else { return .secondary }
    guard let target = state.targetWorkoutStrain, target > 0,
          strain >= target else { return .orange }
    return .green
}

private func liveActivityStrainProgressFraction(
    for state: AtriaLiveActivityAttributes.ContentState,
    now: Date = Date()
) -> Double {
    guard let strain = liveActivityFreshWorkoutStrain(state, now: now) else { return 0 }
    guard let target = state.targetWorkoutStrain, target > 0 else { return 0 }
    return min(max(strain / target, 0), 1)
}

private func liveActivityFreshWorkoutStrain(
    _ state: AtriaLiveActivityAttributes.ContentState,
    now: Date = Date()
) -> Double? {
    guard state.workoutStrainAvailability == .live,
          let capturedAt = state.workoutStrainCapturedAt,
          capturedAt <= now.addingTimeInterval(5),
          now.timeIntervalSince(capturedAt) <= atriaActiveWorkoutStrainFreshness,
          let strain = state.workoutStrain else { return nil }
    return max(0, strain)
}

private func liveActivityCaloriesText(for state: AtriaLiveActivityAttributes.ContentState) -> String {
    guard let calories = state.activeEnergyKilocalories,
          calories.isFinite,
          calories >= 0 else { return "-- kcal" }
    return "~\(Int(calories.rounded())) kcal"
}

private func liveActivityCaloriesAccessibilityText(
    for state: AtriaLiveActivityAttributes.ContentState
) -> String {
    guard let calories = state.activeEnergyKilocalories,
          calories.isFinite,
          calories >= 0 else { return "Active calories unavailable" }
    return "Approximately \(Int(calories.rounded())) active calories"
}

@ViewBuilder
private func liveActivityTimer(state: AtriaLiveActivityAttributes.ContentState,
                               startedAt: Date) -> some View {
    if state.isEnding ?? false {
        Text("Ending…")
            .monospacedDigit()
    } else if state.isPaused ?? false {
        Text(liveActivityDurationText(liveActivityElapsedDuration(state: state,
                                                                  startedAt: startedAt)))
            .monospacedDigit()
    } else {
        Text(state.timerAnchor ?? startedAt, style: .timer)
            .monospacedDigit()
    }
}

private func liveActivityElapsedDuration(
    state: AtriaLiveActivityAttributes.ContentState,
    startedAt: Date,
    now: Date = Date()
) -> TimeInterval {
    let isFrozen = (state.isPaused ?? false) || (state.isEnding ?? false)
    if isFrozen, let elapsedDuration = state.elapsedDuration {
        return max(0, elapsedDuration)
    }

    let anchor = state.timerAnchor ?? startedAt
    let endpoint = isFrozen ? state.updatedAt : now
    return max(0, endpoint.timeIntervalSince(anchor))
}

private func liveActivityDurationAccessibilityText(
    state: AtriaLiveActivityAttributes.ContentState,
    startedAt: Date,
    now: Date = Date()
) -> String {
    let total = max(0, Int(liveActivityElapsedDuration(state: state,
                                                       startedAt: startedAt,
                                                       now: now).rounded(.down)))
    let hours = total / 3_600
    let minutes = (total % 3_600) / 60
    let seconds = total % 60
    let hourUnit = hours == 1 ? "hour" : "hours"
    let minuteUnit = minutes == 1 ? "minute" : "minutes"
    let secondUnit = seconds == 1 ? "second" : "seconds"

    if hours > 0 {
        return "Workout duration \(hours) \(hourUnit), "
            + "\(minutes) \(minuteUnit), \(seconds) \(secondUnit)"
    }
    if minutes > 0 {
        return "Workout duration \(minutes) \(minuteUnit), \(seconds) \(secondUnit)"
    }
    return "Workout duration \(seconds) \(secondUnit)"
}

private func liveActivityDurationText(_ duration: TimeInterval) -> String {
    let total = max(0, Int(duration.rounded(.down)))
    let hours = total / 3_600
    let minutes = (total % 3_600) / 60
    let seconds = total % 60
    return hours > 0
        ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
        : String(format: "%02d:%02d", minutes, seconds)
}

private struct AtriaLiveActivityControls: View {
    let state: AtriaLiveActivityAttributes.ContentState
    let startedAt: Date

    private var primaryTint: Color {
        (state.isPaused ?? false) ? .green : .orange
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(intent: AtriaLiveWorkoutControlIntent(
                action: (state.isPaused ?? false) ? .resume : .pause,
                workoutStartedAt: startedAt
            )) {
                Image(systemName: (state.isPaused ?? false) ? "play.fill" : "pause.fill")
                    .font(.caption.weight(.black))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .contentShape(Circle())
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .controlSize(.small)
            .frame(width: 44, height: 44)
            .tint(primaryTint)
            .accessibilityLabel((state.isPaused ?? false) ? "Resume workout" : "Pause workout")
            .accessibilityHint((state.isPaused ?? false)
                               ? "Resumes workout time and route tracking"
                               : "Pauses workout time and route tracking")

            Button(intent: AtriaLiveWorkoutControlIntent(action: .end,
                                                         workoutStartedAt: startedAt)) {
                Image(systemName: "stop.fill")
                    .font(.caption.weight(.black))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .contentShape(Circle())
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .controlSize(.small)
            .frame(width: 44, height: 44)
            .tint(.red)
            .accessibilityLabel("End workout")
            .accessibilityHint("Ends the active workout")
        }
        .disabled(state.isEnding ?? false)
        .accessibilityElement(children: .contain)
    }
}

struct AtriaStartCaptureControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "AtriaStartCaptureControl") {
            ControlWidgetButton(action: AtriaControlCaptureIntent(command: .start)) {
                Label("Start Atria", systemImage: "record.circle")
            } actionLabel: { isRunning in
                Text(isRunning ? "Starting" : "Start")
            }
        }
        .displayName("Start Atria capture")
        .description("Start local Atria collection from Control Center, Lock Screen, or the Action button.")
    }
}

struct AtriaStopCaptureControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "AtriaStopCaptureControl") {
            ControlWidgetButton(action: AtriaControlCaptureIntent(command: .stop)) {
                Label("Stop Atria", systemImage: "stop.circle")
            } actionLabel: { isRunning in
                Text(isRunning ? "Stopping" : "Stop")
            }
        }
        .displayName("Stop Atria capture")
        .description("Stop local Atria collection from Control Center, Lock Screen, or the Action button.")
    }
}

private struct AtriaLiveActivityLockScreenView: View {
    let context: ActivityViewContext<AtriaLiveActivityAttributes>
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var presentationNow: Date {
        context.isStale ? .distantFuture : Date()
    }

    private var heartRateAvailability: AtriaLiveSensorAvailability {
        liveActivityHeartRateAvailability(for: context.state, now: presentationNow)
    }
    private var signalFresh: Bool {
        heartRateAvailability == .live
    }
    private var batteryAvailability: AtriaLiveSensorAvailability {
        liveActivityBatteryAvailability(for: context.state, now: presentationNow)
    }
    private var liveStatus: AtriaLiveActivityStatusPresentation {
        liveActivityStatusPresentation(for: context.state,
                                       heartRateAvailability: heartRateAvailability)
    }

    var body: some View {
        ViewThatFits(in: .vertical) {
            if dynamicTypeSize.isAccessibilitySize {
                compactLockScreenContent
            } else {
                regularLockScreenContent
            }
            compactLockScreenContent
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var regularLockScreenContent: some View {
        let steps = liveActivityStepsPresentation(for: context.state, now: presentationNow)
        VStack(alignment: .leading, spacing: 8) {
            lockScreenHeader(showsBattery: true)

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                lockScreenHeartRateHero
                    .frame(width: 112, alignment: .leading)
                    .layoutPriority(2)

                lockScreenZoneSummary
                    .layoutPriority(1)

                liveActivityTimer(state: context.state,
                                  startedAt: context.attributes.startedAt)
                    .font(.headline.monospacedDigit().weight(.bold))
                    .foregroundStyle((context.state.isPaused ?? false) ? .orange : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .frame(width: 74, alignment: .trailing)
                    .layoutPriority(3)
                    .accessibilityLabel(liveActivityDurationAccessibilityText(
                        state: context.state,
                        startedAt: context.attributes.startedAt
                    ))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(lockScreenHeroAccessibilityLabel)

            HStack(spacing: 8) {
                HStack(spacing: 9) {
                    lockScreenCompactMetric(value: workoutStrainText,
                                            systemImage: "bolt.fill",
                                            tint: liveActivityStrainProgressColor(for: context.state,
                                                                                  now: presentationNow))
                    lockScreenCompactMetric(value: steps.compactText,
                                            systemImage: "figure.walk",
                                            tint: steps.tint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Workout strain \(workoutStrainText). \(steps.accessibilityText).")

                AtriaLiveActivityControls(state: context.state,
                                          startedAt: context.attributes.startedAt)
                    .frame(width: 96, height: 44)
                    .layoutPriority(2)
            }
        }
    }

    /// Guaranteed terminal layout for the 160pt ActivityKit height ceiling and
    /// Accessibility Dynamic Type. It keeps state, HR, duration, and both
    /// direct actions; secondary battery/step/strain facts yield first.
    private var compactLockScreenContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            lockScreenHeader(showsBattery: false)
            HStack(spacing: 8) {
                lockScreenHeartRateHero
                    .frame(width: 112, alignment: .leading)
                    .layoutPriority(2)

                liveActivityTimer(state: context.state,
                                  startedAt: context.attributes.startedAt)
                    .font(.headline.monospacedDigit().weight(.bold))
                    .foregroundStyle((context.state.isPaused ?? false) ? .orange : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .frame(width: 74, alignment: .trailing)
                    .layoutPriority(1)
                    .accessibilityLabel(liveActivityDurationAccessibilityText(
                        state: context.state,
                        startedAt: context.attributes.startedAt
                    ))

                AtriaLiveActivityControls(state: context.state,
                                          startedAt: context.attributes.startedAt)
                    .frame(width: 96, height: 44)
                    .layoutPriority(3)
            }
        }
    }

    private func lockScreenHeader(showsBattery: Bool) -> some View {
        HStack(spacing: 8) {
            ViewThatFits(in: .horizontal) {
                Label(context.state.activityName ?? "Workout",
                      systemImage: context.state.activitySystemImage ?? "figure.mixed.cardio")
                Label("Workout",
                      systemImage: context.state.activitySystemImage ?? "figure.mixed.cardio")
                Image(systemName: context.state.activitySystemImage ?? "figure.mixed.cardio")
            }
                .font(.subheadline.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .allowsTightening(true)
                .layoutPriority(0)
            Spacer(minLength: 4)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Label(liveStatus.text, systemImage: liveStatus.systemImage)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(liveStatus.tint)
                    if showsBattery, batteryAvailability == .live {
                        Label("\(context.state.batteryLevel)%",
                              systemImage: liveActivityBatterySymbol(for: context.state,
                                                                     now: presentationNow))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(liveActivityBatteryTint(for: context.state,
                                                                     now: presentationNow))
                            .accessibilityLabel(liveActivityBatteryText(for: context.state,
                                                                        now: presentationNow))
                    }
                }
                Label(liveStatus.text, systemImage: liveStatus.systemImage)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(liveStatus.tint)
                Image(systemName: liveStatus.systemImage)
                    .font(.caption.weight(.black))
                    .foregroundStyle(liveStatus.tint)
            }
            .lineLimit(1)
            .layoutPriority(2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(lockScreenStatusAccessibilityLabel(showsBattery: showsBattery))
        }
    }

    private func lockScreenStatusAccessibilityLabel(showsBattery: Bool) -> String {
        guard showsBattery, batteryAvailability == .live else {
            return liveStatus.accessibilityText
        }
        let batteryText = liveActivityBatteryText(for: context.state, now: presentationNow)
        return "\(liveStatus.accessibilityText). \(batteryText)"
    }

    private var lockScreenHeartRateHero: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Image(systemName: "heart.fill")
                .font(.caption.weight(.black))
            Text(signalFresh ? "\(context.state.heartRate)" : "--")
                .font(.system(size: 29, weight: .black, design: .rounded))
                .monospacedDigit()
            Text("BPM")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(signalFresh ? .red : .secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(signalFresh
                            ? "Heart rate \(context.state.heartRate) beats per minute"
                            : "Heart rate unavailable")
    }

    private var lockScreenZoneSummary: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(lockScreenZoneValue)
                .font(.headline.monospacedDigit().weight(.black))
                .foregroundStyle(liveActivityZoneColor(for: context.state,
                                                        availability: heartRateAvailability))
            if let target = liveActivityTargetZoneLabel(for: context.state) {
                Text("T \(target)")
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.78)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(zoneAccessibilityLabel)
    }

    private var lockScreenZoneValue: String {
        guard signalFresh else { return "--" }
        guard let zone = context.state.heartRateZoneIndex, zone > 0 else { return "<Z1" }
        return "Z\(zone)"
    }

    private var lockScreenHeroAccessibilityLabel: String {
        let heart = signalFresh
            ? "Heart rate \(context.state.heartRate) beats per minute"
            : "Heart rate unavailable"
        let duration = liveActivityDurationAccessibilityText(
            state: context.state,
            startedAt: context.attributes.startedAt
        )
        return "\(heart). \(zoneAccessibilityLabel). \(duration)."
    }

    private func lockScreenCompactMetric(value: String,
                                         systemImage: String,
                                         tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
            Text(value)
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
        }
    }

    private var workoutStrainText: String {
        guard let strain = liveActivityFreshWorkoutStrain(context.state,
                                                          now: presentationNow) else { return "--" }
        return String(format: "%.1f", strain)
    }

    private var zoneAccessibilityLabel: String {
        guard heartRateAvailability == .live else { return "Heart rate zone unavailable" }
        let current = liveActivityZoneLabel(for: context.state,
                                            availability: heartRateAvailability)
        guard let target = liveActivityTargetZoneLabel(for: context.state) else { return current }
        return "\(current). Target heart rate \(target)"
    }

}

#if DEBUG
private enum AtriaLiveActivityPreviewFixture {
    static let startedAt = Date().addingTimeInterval(-24 * 60)
    static let attributes = AtriaLiveActivityAttributes(startedAt: startedAt)

    static var live: AtriaLiveActivityAttributes.ContentState {
        let now = Date()
        return .init(heartRate: 146,
                     strain: 7.4,
                     batteryLevel: 68,
                     batteryChargeStatus: "notCharging",
                     batteryChargeText: "Not charging",
                     batteryCapturedAt: now.addingTimeInterval(-20),
                     batteryAvailability: .live,
                     readingCount: 1_440,
                     updatedAt: now,
                     heartRateCapturedAt: now.addingTimeInterval(-2),
                     sensorHasContact: true,
                     heartRateAvailability: .live,
                     activityName: "Running",
                     activitySystemImage: "figure.run",
                     heartRateZoneIndex: 3,
                     heartRateZoneName: "Aerobic",
                     steps: 2_184,
                     stepsAreEstimated: false,
                     stepsCapturedAt: now.addingTimeInterval(-2),
                     stepsAvailability: .live,
                     workoutStrain: 7.4,
                     workoutStrainCapturedAt: now.addingTimeInterval(-2),
                     workoutStrainAvailability: .live,
                     targetWorkoutStrain: 10,
                     activeEnergyKilocalories: 186,
                     targetLowerHeartRateZone: 2,
                     targetUpperHeartRateZone: 4,
                     isPaused: false,
                     isEnding: false,
                     timerAnchor: startedAt,
                     elapsedDuration: 24 * 60)
    }

    static var paused: AtriaLiveActivityAttributes.ContentState {
        var state = live
        state.isPaused = true
        state.elapsedDuration = 24 * 60
        return state
    }

    static var aboveTarget: AtriaLiveActivityAttributes.ContentState {
        var state = live
        state.heartRate = 178
        state.heartRateZoneIndex = 5
        state.heartRateZoneName = "Peak"
        state.activityName = "Outdoor Interval Run"
        state.timerAnchor = Date().addingTimeInterval(-(68 * 60 + 42))
        state.elapsedDuration = 68 * 60 + 42
        return state
    }

    static var reconnecting: AtriaLiveActivityAttributes.ContentState {
        var state = live
        state.heartRateAvailability = .reconnecting
        state.sensorHasContact = false
        state.heartRateCapturedAt = Date().addingTimeInterval(-35)
        state.stepsAvailability = .reconnecting
        state.workoutStrainAvailability = .reconnecting
        return state
    }

    static var stale: AtriaLiveActivityAttributes.ContentState {
        var state = live
        state.heartRateAvailability = .stale
        state.sensorHasContact = false
        state.heartRateCapturedAt = Date().addingTimeInterval(-3 * 60)
        state.stepsAvailability = .stale
        state.stepsCapturedAt = Date().addingTimeInterval(-3 * 60)
        state.workoutStrainAvailability = .stale
        return state
    }

    static var unavailable: AtriaLiveActivityAttributes.ContentState {
        var state = live
        state.heartRate = 0
        state.heartRateAvailability = .unavailable
        state.heartRateCapturedAt = nil
        state.sensorHasContact = false
        state.steps = nil
        state.stepsAvailability = .unavailable
        state.stepsCapturedAt = nil
        state.workoutStrain = nil
        state.workoutStrainAvailability = .unavailable
        state.workoutStrainCapturedAt = nil
        return state
    }

    static var ending: AtriaLiveActivityAttributes.ContentState {
        var state = live
        state.isEnding = true
        return state
    }
}

#Preview("Live Activity · Lock Screen", as: .content,
         using: AtriaLiveActivityPreviewFixture.attributes) {
    AtriaLiveActivityWidget()
} contentStates: {
    AtriaLiveActivityPreviewFixture.live
    AtriaLiveActivityPreviewFixture.aboveTarget
    AtriaLiveActivityPreviewFixture.paused
    AtriaLiveActivityPreviewFixture.reconnecting
    AtriaLiveActivityPreviewFixture.stale
    AtriaLiveActivityPreviewFixture.unavailable
    AtriaLiveActivityPreviewFixture.ending
}

#Preview("Live Activity · Expanded", as: .dynamicIsland(.expanded),
         using: AtriaLiveActivityPreviewFixture.attributes) {
    AtriaLiveActivityWidget()
} contentStates: {
    AtriaLiveActivityPreviewFixture.live
    AtriaLiveActivityPreviewFixture.aboveTarget
    AtriaLiveActivityPreviewFixture.paused
    AtriaLiveActivityPreviewFixture.reconnecting
    AtriaLiveActivityPreviewFixture.stale
    AtriaLiveActivityPreviewFixture.unavailable
    AtriaLiveActivityPreviewFixture.ending
}

#Preview("Live Activity · Compact", as: .dynamicIsland(.compact),
         using: AtriaLiveActivityPreviewFixture.attributes) {
    AtriaLiveActivityWidget()
} contentStates: {
    AtriaLiveActivityPreviewFixture.live
    AtriaLiveActivityPreviewFixture.aboveTarget
    AtriaLiveActivityPreviewFixture.paused
    AtriaLiveActivityPreviewFixture.reconnecting
    AtriaLiveActivityPreviewFixture.stale
    AtriaLiveActivityPreviewFixture.unavailable
    AtriaLiveActivityPreviewFixture.ending
}

#Preview("Live Activity · Minimal", as: .dynamicIsland(.minimal),
         using: AtriaLiveActivityPreviewFixture.attributes) {
    AtriaLiveActivityWidget()
} contentStates: {
    AtriaLiveActivityPreviewFixture.live
    AtriaLiveActivityPreviewFixture.aboveTarget
    AtriaLiveActivityPreviewFixture.paused
    AtriaLiveActivityPreviewFixture.reconnecting
    AtriaLiveActivityPreviewFixture.stale
    AtriaLiveActivityPreviewFixture.unavailable
    AtriaLiveActivityPreviewFixture.ending
}

#endif

private func elapsedText(since start: Date) -> String {
    let seconds = max(0, Int(Date().timeIntervalSince(start)))
    let minutes = seconds / 60
    let hours = minutes / 60
    if hours > 0 {
        return "\(hours)h \(minutes % 60)m"
    }
    return "\(minutes)m"
}

// MARK: - Single-metric widgets (Home Screen + Lock Screen)

enum AtriaWidgetMetric: String, Identifiable {
    case steps, strain, hrv, bpm, sleep, rhr

    var id: String { rawValue }

    // Strain, Sleep, and RHR are the default widget-overhaul column trio;
    // BPM rounds out a 4th slot. Any explicit Today-screen customization
    // (layoutGlanceMetrics) still wins via ordered(from:) below.
    static let fallbackOrder: [AtriaWidgetMetric] = [.strain, .sleep, .rhr, .bpm]

    static func ordered(from layoutGlanceMetrics: [String]?) -> [AtriaWidgetMetric] {
        var ordered: [AtriaWidgetMetric] = []
        for key in layoutGlanceMetrics ?? [] {
            guard let metric = widgetMetric(for: key), !ordered.contains(metric) else { continue }
            ordered.append(metric)
        }
        for metric in fallbackOrder where !ordered.contains(metric) {
            ordered.append(metric)
        }
        return Array(ordered.prefix(4))
    }

    private static func widgetMetric(for key: String) -> AtriaWidgetMetric? {
        switch key {
        case "strain", "load":
            return .strain
        case "hrv":
            return .hrv
        case "steps":
            return .steps
        case "sleep":
            return .sleep
        case "rhr":
            return .rhr
        case "heartRate", "bpm", "respiratoryRate":
            return .bpm
        default:
            return nil
        }
    }

    var deepLinkURL: URL {
        switch self {
        case .steps, .strain:
            return atriaOverviewURL
        case .hrv, .bpm:
            return atriaVitalsURL
        case .sleep:
            return atriaOverviewURL
        case .rhr:
            return atriaVitalsURL
        }
    }

    var title: String {
        switch self {
        case .steps: return "Strap steps"
        case .strain: return "Strain"
        case .hrv: return "HRV"
        case .bpm: return "Last HR"
        case .sleep: return "Sleep"
        case .rhr: return "RHR"
        }
    }

    var icon: String {
        switch self {
        case .steps: return "figure.walk"
        case .strain: return "bolt.fill"
        case .hrv: return "waveform.path.ecg"
        case .bpm: return "heart.fill"
        case .sleep: return "bed.double.fill"
        case .rhr: return "heart.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .steps: return .blue
        case .strain: return .orange
        case .hrv: return .pink
        case .bpm: return .red
        case .sleep: return .indigo
        case .rhr: return .mint
        }
    }

    var unit: String {
        switch self {
        case .steps: return "strap"
        case .strain: return "day load"
        case .hrv: return "ms"
        case .bpm: return "last reading"
        case .sleep: return "hrs"
        case .rhr: return "resting"
        }
    }

    func value(_ s: AtriaWidgetSnapshot?, now: Date) -> String {
        guard let s else { return "--" }
        switch self {
        case .steps:
            guard let steps = atriaCurrentStepValue(s, now: now) else { return "--" }
            return atriaStepValueText(s, steps: steps)
        case .strain:
            // This is accumulated day load, independent of the live-HR clock,
            // but it still belongs to one bounded physiological cycle.
            guard atriaCumulativeDayStrainIsCurrent(s, now: now) else { return "--" }
            let numeric = String(format: "%.1f", max(0, s.strain))
            return s.strainDetail?.localizedCaseInsensitiveContains("partial") == true
                ? "≥ \(numeric)"
                : numeric
        case .hrv:
            return s.hrvRMSSD.map(String.init) ?? "--"
        case .bpm:
            return atriaFreshStaticSensorValue(s.heartRate,
                                               capturedAt: s.heartRateCapturedAt,
                                               freshness: atriaStaticHeartRateFreshness,
                                               now: now).map(String.init) ?? "--"
        case .sleep:
            return atriaFormattedSleepHours(s.sleepHours)
        case .rhr:
            return s.restingHR.map(String.init) ?? "--"
        }
    }

    func statusText(_ snapshot: AtriaWidgetSnapshot?, now: Date) -> String {
        guard let snapshot else { return "Open Atria" }
        switch self {
        case .steps:
            if snapshot.stepsSource == "verifiedCanonical" {
                guard let steps = atriaCurrentStepValue(snapshot, now: now) else {
                    return "Step archive expired"
                }
                if snapshot.stepsCompleteness == "partial" {
                    // 2026-08-12: never lead with a coverage percent — it
                    // reads as "the strap detects steps wrong" (it is data
                    // coverage of the elapsed day, legitimately low on the
                    // HR-only radio mode). The capture frontier carries the
                    // same truth without the failure connotation.
                    let frontier = snapshot.stepsCapturedAt.map {
                        "through \(atriaCaptureTimeText($0))"
                    }
                    let progress = snapshot.dailyStepGoal.flatMap { goal -> String? in
                        guard goal > 0 else { return nil }
                        let percent = min(999, max(0, Int((Double(steps) / Double(goal) * 100).rounded())))
                        return "\(percent)% goal"
                    }
                    return (["Counted", frontier, progress].compactMap { $0 })
                        .joined(separator: " · ")
                }
                if let cycleExpiresAt = snapshot.stepsCycleExpiresAt,
                   cycleExpiresAt > now {
                    guard let capturedAt = snapshot.stepsCapturedAt else {
                        return "Verified earlier in this cycle"
                    }
                    let age = now.timeIntervalSince(capturedAt)
                    return age >= -atriaStaticSensorFutureTolerance
                        && age <= atriaStaticStepFreshness
                        ? "Today so far · verified"
                        : "Verified through \(atriaCaptureTimeText(capturedAt))"
                }
                return "Verified complete day"
            }
            guard let capturedAt = snapshot.stepsCapturedAt else {
                guard snapshot.steps == nil else { return "Step signal stale" }
                // 2026-07-31: after a no-sleep cycle rollover the new cycle
                // honestly has no count yet; name the prior cycle's verified
                // lower bound instead of an unexplained wait state.
                if let priorSteps = snapshot.stepsPriorCycleSteps,
                   let priorEndedAt = snapshot.stepsPriorCycleEndedAt {
                    return "Prior cycle: ≥\(priorSteps) · ended \(atriaCaptureTimeText(priorEndedAt))"
                }
                return "Waiting for strap"
            }
            guard let steps = atriaFreshStaticSensorValue(snapshot.steps,
                                                           capturedAt: capturedAt,
                                                           freshness: atriaStaticStepFreshness,
                                                           now: now) else {
                return "Step stale · last \(atriaCaptureTimeText(capturedAt))"
            }
            let accuracy = snapshot.stepsAreEstimated == false ? "Confirmed" : "Estimated"
            let captured = atriaCaptureTimeText(capturedAt)
            guard let goal = snapshot.dailyStepGoal, goal > 0 else {
                return "\(accuracy) · \(captured)"
            }
            if steps >= goal, snapshot.stepsAreEstimated == false {
                return "Goal ✓ · confirmed · \(captured)"
            }
            let percent = min(999, max(0, Int((Double(steps) / Double(goal) * 100).rounded())))
            return "\(accuracy) · \(percent)% goal · \(captured)"
        case .bpm:
            guard let capturedAt = snapshot.heartRateCapturedAt else {
                return snapshot.heartRate == nil ? "Waiting for strap" : "HR stale"
            }
            guard atriaFreshStaticSensorValue(snapshot.heartRate,
                                               capturedAt: capturedAt,
                                               freshness: atriaStaticHeartRateFreshness,
                                               now: now) != nil else {
                return "HR stale · last \(atriaCaptureTimeText(capturedAt))"
            }
            let zone: String
            if let index = snapshot.heartRateZoneIndex {
                zone = index <= 0
                    ? "Below Z1"
                    : "Z\(index) \(snapshot.heartRateZoneName ?? "Zone")"
            } else {
                zone = "Zone unavailable"
            }
            return "Last reading · \(zone) · \(atriaCaptureTimeText(capturedAt))"
        case .strain:
            guard let capturedAt = snapshot.strainCapturedAt,
                  snapshot.strainCycleStart != nil,
                  snapshot.strainCycleExpiresAt != nil else {
                return "Open Atria to refresh day load"
            }
            let age = max(0, now.timeIntervalSince(capturedAt))
            if atriaCumulativeDayStrainIsCurrent(snapshot, now: now) {
                return snapshot.strainDetail ?? "Updated · \(atriaCaptureTimeText(capturedAt))"
            }
            return "Day load expired · \(Int(age / 3_600))h old"
        case .sleep:
            if let detail = snapshot.sleepDetail,
               detail.localizedCaseInsensitiveContains("review") {
                return detail
            }
            return snapshot.sleepHours == nil ? "Awaiting current sleep" : "Current cycle"
        case .hrv:
            guard snapshot.hrvRMSSD != nil else { return "Calibrating" }
            if let capturedAt = snapshot.hrvCapturedAt {
                return "Measured \(atriaCaptureTimeText(capturedAt))"
            }
            return "Current cycle"
        case .rhr:
            return snapshot.restingHR == nil ? "Awaiting current sleep" : "Current cycle"
        }
    }

    /// Compact aggregate-widget note. Only limitations are repeated under the
    /// value; complete/current metrics keep the existing uncluttered tile.
    func evidenceNote(_ snapshot: AtriaWidgetSnapshot?) -> String? {
        guard let snapshot else { return nil }
        switch self {
        case .steps:
            guard snapshot.stepsSource == "verifiedCanonical",
                  snapshot.stepsCompleteness == "partial" else { return nil }
            // Frontier over percent (2026-08-12): a coverage % on the tile
            // reads as bad step detection. See statusText for the rationale.
            if let capturedAt = snapshot.stepsCapturedAt {
                return "Partial day · counted through \(atriaCaptureTimeText(capturedAt))"
            }
            return "Partial day so far"
        case .strain:
            guard snapshot.strainDetail?.localizedCaseInsensitiveContains("partial") == true else { return nil }
            return snapshot.strainDetail
        case .sleep:
            guard snapshot.sleepDetail?.localizedCaseInsensitiveContains("review") == true else { return nil }
            return snapshot.sleepDetail
        default:
            return nil
        }
    }
}

struct AtriaMetricWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let metric: AtriaWidgetMetric
    let entry: AtriaWidgetEntry

    private var value: String { metric.value(entry.snapshot, now: entry.date) }

    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                Label("\(metric.title) \(value)", systemImage: metric.icon)
            case .accessoryRectangular:
                HStack(spacing: 8) {
                    Image(systemName: metric.icon)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(metric.title.uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(value)
                            .font(.title2.weight(.bold))
                            .monospacedDigit()
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                            .atriaLiveActivityValueTransition(value)
                        Text(metricFooterText)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                    }
                    Spacer(minLength: 0)
                }
                .containerBackground(.clear, for: .widget)
            case .systemSmall:
                systemSmallMetric
            case .systemMedium:
                systemMediumMetric
            default:
                VStack(spacing: 0) {
                    Image(systemName: metric.icon)
                        .font(.system(size: 12, weight: .semibold))
                    Text(value)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                        .atriaLiveActivityValueTransition(value)
                }
                .containerBackground(for: .widget) { AccessoryWidgetBackground() }
                .widgetAccentable()
            }
        }
        .widgetURL(metric.deepLinkURL)
    }

    private var systemSmallMetric: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: metric.icon)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(metric.tint)
                    .frame(width: 30, height: 30)
                    .background(metric.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                Spacer(minLength: 0)

                Text(metric.unit.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            Spacer(minLength: 0)

            Text(value)
                .font(.system(size: 42, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.45)
                .atriaLiveActivityValueTransition(value)

            Text(metric.title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text(metricFooterText)
                .font(.caption2.weight(.medium))
                .foregroundStyle(entry.snapshot == nil ? .orange : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(.background, for: .widget)
        .accessibilityLabel("\(metric.title) \(value), \(metricFooterText)")
    }

    private var systemMediumMetric: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: metric.icon)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(metric.tint)
                        .frame(width: 34, height: 34)
                        .background(metric.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    Text(metric.title)
                        .font(.headline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }

                Spacer(minLength: 0)

                Text(value)
                    .font(.system(size: 48, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.45)
                    .atriaLiveActivityValueTransition(value)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 8) {
                Text(metric.unit.uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(metric.tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Spacer(minLength: 0)

                Text(metricFooterText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(entry.snapshot == nil ? .orange : .secondary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)
            }
            .frame(width: 104, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(.background, for: .widget)
        .accessibilityLabel("\(metric.title) \(value), \(metric.unit), \(metricFooterText)")
    }

    private var metricFooterText: String {
        metric.statusText(entry.snapshot, now: entry.date)
    }
}

struct AtriaStepsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AtriaStepsWidget", provider: AtriaWidgetProvider()) { entry in
            AtriaMetricWidgetEntryView(metric: .steps, entry: entry)
        }
        .configurationDisplayName("Atria Strap Steps")
        .description("Strap-derived steps on your Home Screen or Lock Screen.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryInline, .accessoryRectangular])
    }
}

struct AtriaStrainWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AtriaStrainWidget", provider: AtriaWidgetProvider()) { entry in
            AtriaMetricWidgetEntryView(metric: .strain, entry: entry)
        }
        .configurationDisplayName("Atria Strain")
        .description("Today's strain on your Home Screen or Lock Screen.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryInline, .accessoryRectangular])
    }
}

struct AtriaHRVWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AtriaHRVWidget", provider: AtriaWidgetProvider()) { entry in
            AtriaMetricWidgetEntryView(metric: .hrv, entry: entry)
        }
        .configurationDisplayName("Atria HRV")
        .description("Latest HRV on your Home Screen or Lock Screen.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryInline, .accessoryRectangular])
    }
}

struct AtriaBPMWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AtriaBPMWidget", provider: AtriaWidgetProvider()) { entry in
            AtriaMetricWidgetEntryView(metric: .bpm, entry: entry)
        }
        .configurationDisplayName("Atria BPM")
        .description("Latest heart rate on your Home Screen or Lock Screen.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryInline, .accessoryRectangular])
    }
}

@main
struct AtriaWidgetBundle: WidgetBundle {
    var body: some Widget {
        AtriaStatusWidget()
        AtriaSeparateOverviewWidget()
        AtriaStepsWidget()
        AtriaStrainWidget()
        AtriaHRVWidget()
        AtriaBPMWidget()
        AtriaLiveActivityWidget()
        AtriaStartCaptureControl()
        AtriaStopCaptureControl()
    }
}
