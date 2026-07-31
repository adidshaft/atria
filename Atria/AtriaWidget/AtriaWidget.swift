import SwiftUI
import WidgetKit
import ActivityKit
import AppIntents

private let snapshotKey = "atria.widgetSnapshot.v1"
private let appGroupID = "group.com.adidshaft.atria"
private let atriaOverviewURL = URL(string: "atria://tab/overview")!
private let atriaVitalsURL = URL(string: "atria://tab/vitals")!

// Single source of truth for the recovery zone tint used by the ring gauges,
// the header percent, and the Lock Screen accessory gauge. Gray/secondary
// means "learning" — never a fabricated color for an unknown percent.
private func atriaRecoveryZoneColor(_ percent: Int?) -> Color {
    guard let percent else { return .secondary }
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
private let atriaHeartRateFreshness: TimeInterval = 90
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

struct AtriaWidgetSnapshot: Codable {
    let schema: Int
    let createdAt: Date
    let recoveryPercent: Int?
    let recoveryConfidence: String
    let recoveryDetail: String
    let strain: Double
    /// Additive optional evidence qualifier in the schema-4 payload.
    var strainDetail: String? = nil
    /// Cumulative day-strain computation time, not the live-HR packet clock.
    var strainCapturedAt: Date? = nil
    var strainCycleStart: Date? = nil
    var strainCycleExpiresAt: Date? = nil
    let restingHR: Int?
    let hrvRMSSD: Int?
    let hrvState: String
    let maxHR: Int
    // Optional so schema-1 payloads still decode (missing keys -> nil).
    let sleepHours: Double?
    /// Additive optional display-only sleep provenance in schema 4.
    var sleepDetail: String? = nil
    let steps: Int?
    /// Optional for snapshots written before preliminary strap steps were
    /// exposed honestly in widgets.
    var stepsAreEstimated: Bool? = nil
    let stepsCapturedAt: Date?
    var stepsSource: String? = nil
    var stepsCompleteness: String? = nil
    var stepsCoverageFraction: Double? = nil
    var stepsAuthorityVersion: String? = nil
    var stepsCycleStart: Date? = nil
    var stepsCycleExpiresAt: Date? = nil
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
            (snapshot?.heartRateCapturedAt, atriaHeartRateFreshness),
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
        let entries = Set(entryDates).sorted().map {
            AtriaWidgetEntry(date: $0, snapshot: snapshot)
        }
        completion(Timeline(entries: entries, policy: .after(refreshAt)))
    }

    private static func loadSnapshot() -> AtriaWidgetSnapshot? {
        guard let data = UserDefaults(suiteName: appGroupID)?.data(forKey: snapshotKey) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AtriaWidgetSnapshot.self, from: data)
    }
}

struct AtriaWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: AtriaWidgetEntry

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
        VStack(alignment: .leading, spacing: 8) {
            widgetHeader

            Spacer(minLength: 0)

            HStack(alignment: .center, spacing: 10) {
                AtriaWidgetRecoveryGauge(percent: entry.snapshot?.recoveryPercent)
                    .frame(width: 72, height: 72)

                VStack(alignment: .leading, spacing: 8) {
                    compactMetric("Strain",
                                  value: AtriaWidgetMetric.strain.value(entry.snapshot,
                                                                        now: entry.date),
                                  icon: "bolt.fill",
                                  tint: .orange,
                                  deepLinkURL: AtriaWidgetMetric.strain.deepLinkURL)
                    compactMetric("BPM",
                                  value: AtriaWidgetMetric.bpm.value(entry.snapshot, now: entry.date),
                                  icon: "heart.fill",
                                  tint: .red,
                                  deepLinkURL: AtriaWidgetMetric.bpm.deepLinkURL)
                }
            }

            Spacer(minLength: 0)

            Text(footerText)
                .font(.caption2.weight(.medium))
                .foregroundStyle(entry.snapshot == nil ? .orange : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    private var systemMediumWidget: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    widgetHeader

                    Spacer(minLength: 0)

                    AtriaWidgetRecoveryGauge(percent: entry.snapshot?.recoveryPercent)
                        .frame(width: 92, height: 92)

                    Spacer(minLength: 0)

                    Text(secondaryText)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                }
                .frame(width: 108, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        widgetMetricLink(widgetMetrics[0])
                        widgetMetricLink(widgetMetrics[1])
                    }
                    HStack(spacing: 8) {
                        widgetMetricLink(widgetMetrics[2])
                        widgetMetricLink(widgetMetrics[3])
                    }
                }
            }

            Text(freshnessFooterText)
                .font(.caption2.weight(.medium))
                .foregroundStyle(entry.snapshot.map { atriaSnapshotIsStale($0, now: entry.date) } ?? false ? .orange : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    /// "as of HH:mm" while the snapshot is fresh; honestly calls out staleness
    /// (6h+ since the app last published) rather than implying a live reading.
    private var freshnessFooterText: String {
        guard let snapshot = entry.snapshot else { return "Open Atria to start local tracking" }
        let age = atriaSnapshotAgeMinutes(snapshot, now: entry.date)
        if atriaSnapshotIsStale(snapshot, now: entry.date) {
            return "Stale · \(age / 60)h old, open Atria"
        }
        return "as of \(atriaTimeOfDayFormatter.string(from: snapshot.createdAt))"
    }

    private var systemLargeWidget: some View {
        VStack(alignment: .leading, spacing: 14) {
            widgetHeader

            HStack(alignment: .center, spacing: 16) {
                AtriaWidgetRecoveryGauge(percent: entry.snapshot?.recoveryPercent)
                    .frame(width: 118, height: 118)

                VStack(alignment: .leading, spacing: 8) {
                    Text(secondaryText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.72)
                    Text(footerText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.72)
                    if entry.snapshot?.batteryLevel != nil {
                        Label(largeBatteryText, systemImage: batterySymbol)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(batteryTint)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

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
            if let recovery = entry.snapshot?.recoveryPercent {
                Text("\(recovery)%")
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(recoveryColor(recovery))
            }
        }
    }

    private func compactMetric(_ title: String,
                               value: String,
                               icon: String,
                               tint: Color,
                               deepLinkURL: URL) -> some View {
        Link(destination: deepLinkURL) {
            VStack(alignment: .leading, spacing: 1) {
                Image(systemName: icon)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                Text(value)
                    .font(.headline.weight(.bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var widgetMetrics: [AtriaWidgetMetric] {
        AtriaWidgetMetric.ordered(from: entry.snapshot?.layoutGlanceMetrics)
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
        atriaRecoveryZoneColor(percent)
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
    private var accessoryCircular: some View {
        let stale = entry.snapshot.map { atriaSnapshotIsStale($0, now: entry.date) } == true
        return Gauge(value: accessoryCircularProgress) {
            Text("REC")
        } currentValueLabel: {
            Text(entry.snapshot?.recoveryPercent.map { "\($0)" } ?? "--")
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .tint(stale ? Color.secondary : atriaRecoveryZoneColor(entry.snapshot?.recoveryPercent))
        .containerBackground(.background, for: .widget)
        .accessibilityLabel(accessoryCircularAccessibilityLabel(stale: stale))
    }

    private func accessoryCircularAccessibilityLabel(stale: Bool) -> String {
        guard let snapshot = entry.snapshot,
              let percent = snapshot.recoveryPercent else { return "Recovery learning" }
        guard stale else { return "Recovery \(percent) percent" }
        let hours = atriaSnapshotAgeMinutes(snapshot, now: entry.date) / 60
        return "Recovery \(percent) percent, stale, from \(hours) hours ago"
    }

    private var accessoryCircularProgress: Double {
        guard let percent = entry.snapshot?.recoveryPercent else { return 0 }
        return min(1, max(0, Double(percent) / 100))
    }

    /// Recovery / Strain / HR three-line summary for the Lock Screen.
    private var accessoryRectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(accessoryRecoveryLine)
                .font(.caption.monospacedDigit().weight(.bold))
                .lineLimit(1)
            Text(accessoryStrainLine)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            // At 6h+ the HR line is "HR --" anyway (its own capture clock);
            // spend that line on the staleness disclosure the larger families
            // already show, so old recovery/strain never read as live.
            Text(accessoryStaleLine ?? accessoryHRLine)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .containerBackground(.background, for: .widget)
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
                                                    freshness: atriaHeartRateFreshness,
                                                    now: entry.date)
        return "HR " + (heartRate.map { "\($0) bpm" } ?? "--")
    }

    private var secondaryText: String {
        guard let snapshot = entry.snapshot else { return "Open app for live strap status" }
        if let recovery = snapshot.recoveryPercent {
            return "Recovery \(recovery)% · \(recoveryEvidenceText(snapshot))"
        }
        return "Recovery learning · \(recoveryEvidenceText(snapshot))"
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
    private var inlineText: String {
        guard let snapshot = entry.snapshot else { return "Atria learning" }
        let recovery = snapshot.recoveryPercent.map { "\($0)%" } ?? "--"
        let strain = AtriaWidgetMetric.strain.value(snapshot, now: entry.date)
        if atriaSnapshotIsStale(snapshot, now: entry.date) {
            return "Rec \(recovery) · \(atriaSnapshotAgeMinutes(snapshot, now: entry.date) / 60)h old"
        }
        return "Rec \(recovery) · \(strain) strain"
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
                Text("REC")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(percent.map { "Recovery \($0) percent" } ?? "Recovery learning")
    }
}

struct AtriaStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AtriaWidget", provider: AtriaWidgetProvider()) { entry in
            AtriaWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Atria")
        .description("Shows local recovery and strain status when shared widget storage is enabled.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 3) {
            Group {
                if reduceMotion {
                    heartIcon
                } else {
                    heartIcon
                        .symbolEffect(.pulse, options: .nonRepeating, value: heartRate)
                }
            }
            Text(isLive ? "\(heartRate)" : "--")
                .monospacedDigit()
                .atriaLiveActivityValueTransition(isLive ? heartRate : -1)
        }
        .font(.caption.weight(.bold))
        .lineLimit(1)
        .minimumScaleFactor(0.55)
        .allowsTightening(true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isLive
                            ? "Heart rate \(heartRate) beats per minute"
                            : "Heart rate unavailable")
    }

    private var heartIcon: some View {
        Image(systemName: "heart.fill")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.red)
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

struct AtriaLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AtriaLiveActivityAttributes.self) { context in
            AtriaLiveActivityLockScreenView(context: context)
                .activityBackgroundTint(Color(.systemBackground))
                .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            let heartAvailability = liveActivityHeartRateAvailability(for: context.state)
            let signalFresh = heartAvailability == .live
            let steps = liveActivityStepsPresentation(for: context.state)
            let dailyStepGoal = liveActivityDailyStepGoalPresentation(for: context.state)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(context.state.activityName ?? "Workout",
                              systemImage: context.state.activitySystemImage ?? "figure.mixed.cardio")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(signalFresh ? "\(context.state.heartRate) bpm" : "-- bpm")
                            .font(.title3.monospacedDigit().weight(.bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.62)
                            .allowsTightening(true)
                            .layoutPriority(2)
                            .atriaLiveActivityValueTransition(signalFresh ? context.state.heartRate : -1)
                            .accessibilityLabel(signalFresh
                                                ? "Heart rate \(context.state.heartRate) beats per minute"
                                                : "Heart rate unavailable")
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        if let target = liveActivityTargetZoneLabel(for: context.state) {
                            Text(target)
                                .font(.caption2.weight(.black))
                                .foregroundStyle(.cyan)
                                .accessibilityLabel("Target heart rate \(target)")
                        }
                        Text(liveActivityZoneLabel(for: context.state,
                                                   availability: heartAvailability))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(liveActivityZoneColor(for: context.state,
                                                                  availability: heartAvailability))
                            .atriaLiveActivityValueTransition(
                                liveActivityZoneLabel(for: context.state,
                                                      availability: heartAvailability)
                            )
                        Text(steps.compactText)
                            .font(.title3.monospacedDigit().weight(.bold))
                            .foregroundStyle(steps.tint)
                            .atriaLiveActivityValueTransition(steps.compactText)
                            .accessibilityLabel(steps.accessibilityText)
                    }
                }

                // Each Island region owns a distinct glance: activity/target
                // on the leading side, pulse and steps on the trailing side,
                // and the live or paused timer in the center.
                DynamicIslandExpandedRegion(.center) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill((context.state.isPaused ?? false) ? Color.orange : Color.green)
                            .frame(width: 6, height: 6)
                        Text((context.state.isPaused ?? false) ? "Paused" : "Live")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle((context.state.isPaused ?? false) ? .orange : .green)
                        liveActivityTimer(state: context.state,
                                          startedAt: context.attributes.startedAt)
                            .font(.caption2.monospacedDigit().weight(.bold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel((context.state.isPaused ?? false)
                                        ? "Workout paused"
                                        : "Workout live")
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        HStack(spacing: 12) {
                            Label {
                                liveActivityTimer(state: context.state,
                                                  startedAt: context.attributes.startedAt)
                            } icon: {
                                Image(systemName: (context.state.isPaused ?? false) ? "pause.fill" : "timer")
                            }
                            Spacer(minLength: 4)
                            Label(liveActivityStrainProgressText(for: context.state),
                                  systemImage: "bolt.fill")
                                .foregroundStyle(liveActivityStrainProgressColor(for: context.state))
                                .atriaLiveActivityValueTransition(
                                    liveActivityStrainProgressText(for: context.state)
                                )
                            Label(liveActivityCaloriesText(for: context.state),
                                  systemImage: "flame.fill")
                                .foregroundStyle(.pink)
                                .atriaLiveActivityValueTransition(
                                    liveActivityCaloriesText(for: context.state)
                                )
                                .accessibilityLabel(liveActivityCaloriesAccessibilityText(for: context.state))
                        }
                        if context.state.targetWorkoutStrain.map({ $0 > 0 }) == true
                            || dailyStepGoal?.fraction != nil {
                            HStack(spacing: 8) {
                                if let dailyStepGoal, let fraction = dailyStepGoal.fraction {
                                    HStack(spacing: 5) {
                                        Label(dailyStepGoal.text, systemImage: "target")
                                            .foregroundStyle(dailyStepGoal.tint)
                                        ProgressView(value: fraction)
                                            .tint(dailyStepGoal.tint)
                                    }
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityLabel("Daily strap step goal progress")
                                    .accessibilityValue(dailyStepGoal.accessibilityText)
                                }
                                if context.state.targetWorkoutStrain.map({ $0 > 0 }) == true {
                                    ProgressView(value: liveActivityStrainProgressFraction(for: context.state))
                                        .tint(liveActivityStrainProgressColor(for: context.state))
                                        .accessibilityLabel("Workout strain goal progress")
                                        .accessibilityValue(liveActivityStrainProgressText(for: context.state))
                                }
                            }
                        }
                        if let sensorStatus = liveActivitySensorStatusText(
                            state: context.state,
                            heartRateAvailability: heartAvailability
                        ) {
                            Text(sensorStatus)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .accessibilityLabel("Sensor status \(sensorStatus)")
                        }
                        AtriaLiveActivityControls(state: context.state,
                                                  startedAt: context.attributes.startedAt,
                                                  compact: true)
                    }
                    .font(.caption.weight(.medium))
                }
            } compactLeading: {
                if context.state.isPaused ?? false {
                    Image(systemName: "pause.fill")
                        .font(.caption.weight(.black))
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Workout paused")
                } else if let target = liveActivityTargetZoneLabel(for: context.state) {
                    Text(target)
                        .font(.caption2.monospacedDigit().weight(.black))
                        .foregroundStyle(.cyan)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
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
                AtriaDynamicIslandActivityGlyph(
                    symbol: context.state.activitySystemImage ?? "figure.mixed.cardio",
                    tint: liveActivityZoneColor(for: context.state,
                                                availability: heartAvailability),
                    isPaused: context.state.isPaused ?? false
                )
                    .accessibilityLabel("\(context.state.activityName ?? "Workout") workout")
            }
            .keylineTint(.red)
        }
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

private func liveActivityChargeIsFresh(
    for state: AtriaLiveActivityAttributes.ContentState,
    now: Date = Date()
) -> Bool {
    guard liveActivityBatteryAvailability(for: state, now: now) == .live,
          state.batteryChargeStatus == "charging",
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
    if liveActivityChargeIsFresh(for: state, now: now) {
        return "\(state.batteryLevel)% · Charging"
    }
    switch state.batteryChargeStatus {
    case "full":
        return "\(state.batteryLevel)% · Fully charged"
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
    if liveActivityChargeIsFresh(for: state, now: now) { return "battery.100percent.bolt" }
    if state.batteryChargeStatus == "full" { return "battery.100percent" }
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
    if liveActivityChargeIsFresh(for: state, now: now) { return .green }
    switch state.batteryChargeStatus {
    case "full": return .green
    default: return state.batteryLevel >= 0 && state.batteryLevel <= 20 ? .red : .secondary
    }
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
        && now.timeIntervalSince(capturedAt) <= atriaHeartRateFreshness
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
        return AtriaLiveActivityStepsPresentation(compactText: "Syncing",
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
        return AtriaLiveActivityStepsPresentation(compactText: "Stale",
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

private func liveActivityStrainProgressText(for state: AtriaLiveActivityAttributes.ContentState) -> String {
    guard let strain = liveActivityFreshWorkoutStrain(state) else { return "Strain --" }
    guard let target = state.targetWorkoutStrain, target > 0 else {
        return String(format: "%.1f", strain)
    }
    if strain >= target {
        return String(format: "Goal ✓ · %.1f", strain)
    }
    return String(format: "%.1f / %.1f", strain, target)
}

private func liveActivityStrainProgressColor(for state: AtriaLiveActivityAttributes.ContentState) -> Color {
    guard let strain = liveActivityFreshWorkoutStrain(state) else { return .secondary }
    guard let target = state.targetWorkoutStrain, target > 0,
          strain >= target else { return .orange }
    return .green
}

private func liveActivityStrainProgressFraction(
    for state: AtriaLiveActivityAttributes.ContentState
) -> Double {
    guard let strain = liveActivityFreshWorkoutStrain(state) else { return 0 }
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
        Text(liveActivityDurationText(state.elapsedDuration
                                      ?? max(0, state.updatedAt.timeIntervalSince(startedAt))))
            .monospacedDigit()
    } else {
        Text(state.timerAnchor ?? startedAt, style: .timer)
            .monospacedDigit()
    }
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
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 8 : 10) {
            Button(intent: AtriaLiveWorkoutControlIntent(
                action: (state.isPaused ?? false) ? .resume : .pause,
                workoutStartedAt: startedAt
            )) {
                if compact {
                    Image(systemName: (state.isPaused ?? false) ? "play.fill" : "pause.fill")
                        .frame(maxWidth: .infinity)
                } else {
                    Label((state.isPaused ?? false) ? "Resume" : "Pause",
                          systemImage: (state.isPaused ?? false) ? "play.fill" : "pause.fill")
                        // Never wrap. Without this the label broke mid-word and
                        // the button rendered "Pau / se" over two lines.
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .allowsTightening(true)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
            .tint((state.isPaused ?? false) ? .green : .orange)
            .accessibilityLabel((state.isPaused ?? false) ? "Resume workout" : "Pause workout")
            .accessibilityHint((state.isPaused ?? false)
                               ? "Resumes workout time and route tracking"
                               : "Pauses workout time and route tracking")

            Button(intent: AtriaLiveWorkoutControlIntent(action: .end,
                                                         workoutStartedAt: startedAt)) {
                if compact {
                    Image(systemName: "stop.fill")
                        .frame(maxWidth: .infinity)
                } else {
                    Label("End", systemImage: "stop.fill")
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .allowsTightening(true)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
            .tint(.red)
            .accessibilityLabel("End workout")
            .accessibilityHint("Ends the active workout")
        }
        .buttonStyle(.borderedProminent)
        .labelStyle(.titleAndIcon)
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

    private var heartRateAvailability: AtriaLiveSensorAvailability {
        liveActivityHeartRateAvailability(for: context.state)
    }
    private var signalFresh: Bool {
        heartRateAvailability == .live
    }
    private var batteryAvailability: AtriaLiveSensorAvailability {
        liveActivityBatteryAvailability(for: context.state)
    }

    var body: some View {
        // Lock Screen Live Activities have a deliberately tight system-owned
        // height. Use one stable workout card hierarchy: identity and state,
        // the three metrics someone glances at mid-set, then signal + controls.
        // Detailed goal progress remains in the expanded Island and app so this
        // surface does not grow until iOS clips it.
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Atria · \(context.state.activityName ?? "Workout")",
                      systemImage: context.state.activitySystemImage ?? "figure.mixed.cardio")
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .allowsTightening(true)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                Label(liveStateText, systemImage: liveStateSymbol)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(liveStateTint)
                    .lineLimit(1)
                    .fixedSize()
                if batteryAvailability == .live {
                    Label("\(context.state.batteryLevel)%",
                          systemImage: liveActivityBatterySymbol(for: context.state))
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(liveActivityBatteryTint(for: context.state))
                        .lineLimit(1)
                        .fixedSize()
                        .accessibilityLabel(liveActivityBatteryText(for: context.state))
                }
            }

            HStack(alignment: .lastTextBaseline, spacing: 0) {
                lockScreenMetric(value: signalFresh ? "\(context.state.heartRate)" : "--",
                                 title: "BPM",
                                 systemImage: "heart.fill",
                                 tint: .red,
                                 emphasis: true)

                Divider()
                    .frame(height: 36)
                    .padding(.horizontal, 12)

                lockScreenMetric(value: workoutStrainText,
                                 title: "Strain",
                                 systemImage: "bolt.fill",
                                 tint: liveActivityStrainProgressColor(for: context.state))

                Divider()
                    .frame(height: 36)
                    .padding(.horizontal, 12)

                VStack(alignment: .leading, spacing: 2) {
                    liveActivityTimer(state: context.state,
                                      startedAt: context.attributes.startedAt)
                        .font(.title3.monospacedDigit().weight(.bold))
                        .foregroundStyle((context.state.isPaused ?? false) ? .orange : .primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.68)
                    Text("Duration")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(signalFresh
                                ? "Heart rate \(context.state.heartRate) beats per minute. \(liveActivityZoneLabel(for: context.state, availability: .live))."
                                : liveActivityZoneLabel(for: context.state,
                                                        availability: heartRateAvailability))

            HStack(spacing: 8) {
                if let sensorStatus = liveActivitySensorStatusText(
                    state: context.state,
                    heartRateAvailability: heartRateAvailability
                ) {
                    Label(sensorStatus, systemImage: "antenna.radiowaves.left.and.right")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .accessibilityLabel("Sensor status \(sensorStatus)")
                }
                Spacer(minLength: 2)
                AtriaLiveActivityControls(state: context.state,
                                          startedAt: context.attributes.startedAt,
                                          compact: false)
                    .controlSize(.small)
                    .frame(width: 154)
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
    }

    private func lockScreenMetric(value: String,
                                  title: String,
                                  systemImage: String,
                                  tint: Color,
                                  emphasis: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.caption2.weight(.bold))
                Text(value)
                    .font(emphasis
                          ? .system(size: 30, weight: .black, design: .rounded)
                          : .title3.weight(.bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.58)
            }
            .foregroundStyle(tint)
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The emphasized three-digit heart rate must win horizontal
        // compression before secondary strain and duration metrics.
        .layoutPriority(emphasis ? 3 : 0)
    }

    private var workoutStrainText: String {
        guard let strain = liveActivityFreshWorkoutStrain(context.state) else { return "--" }
        return String(format: "%.1f", strain)
    }

    private var liveStateText: String {
        if context.state.isEnding ?? false { return "Ending" }
        if context.state.isPaused ?? false { return "Paused" }
        return signalFresh ? "Live" : "Signal waiting"
    }

    private var liveStateSymbol: String {
        if context.state.isEnding ?? false { return "stop.circle.fill" }
        if context.state.isPaused ?? false { return "pause.circle.fill" }
        return signalFresh ? "circle.fill" : "antenna.radiowaves.left.and.right"
    }

    private var liveStateTint: Color {
        if context.state.isEnding ?? false { return .red }
        if context.state.isPaused ?? false { return .orange }
        return signalFresh ? .green : .secondary
    }

}

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
        case .bpm: return "BPM"
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
        case .bpm: return "live"
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
                                               freshness: atriaHeartRateFreshness,
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
                let coverage = snapshot.stepsCoverageFraction.map {
                    "\(Int(($0 * 100).rounded()))% covered"
                }
                if snapshot.stepsCompleteness == "partial" {
                    let progress = snapshot.dailyStepGoal.flatMap { goal -> String? in
                        guard goal > 0 else { return nil }
                        let percent = min(999, max(0, Int((Double(steps) / Double(goal) * 100).rounded())))
                        return "\(percent)% goal"
                    }
                    return (["Partial archive", coverage, progress].compactMap { $0 })
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
                return snapshot.steps == nil ? "Waiting for strap" : "Step signal stale"
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
                                               freshness: atriaHeartRateFreshness,
                                               now: now) != nil else {
                return "HR stale · last \(atriaCaptureTimeText(capturedAt))"
            }
            let zone: String
            if let index = snapshot.heartRateZoneIndex {
                zone = index <= 0
                    ? "Below Z1"
                    : "Z\(index) \(snapshot.heartRateZoneName ?? "Zone")"
            } else {
                zone = "Live"
            }
            return "\(zone) · \(atriaCaptureTimeText(capturedAt))"
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
            fallthrough
        case .hrv, .rhr:
            let age = atriaSnapshotAgeMinutes(snapshot, now: now)
            if age < 1 { return "Updated now" }
            if age < 60 { return "Updated \(age)m ago" }
            if atriaSnapshotIsStale(snapshot, now: now) {
                return "Stale · \(age / 60)h ago"
            }
            return "Updated \(age / 60)h ago"
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
            if let coverage = snapshot.stepsCoverageFraction {
                return "Partial archive · \(Int((coverage * 100).rounded()))% covered"
            }
            return "Partial archive coverage"
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
        AtriaStepsWidget()
        AtriaStrainWidget()
        AtriaHRVWidget()
        AtriaBPMWidget()
        AtriaLiveActivityWidget()
        AtriaStartCaptureControl()
        AtriaStopCaptureControl()
    }
}
