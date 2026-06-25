import SwiftUI
import WidgetKit
import ActivityKit
import AppIntents

private let snapshotKey = "atria.widgetSnapshot.v1"
private let appGroupID = "group.com.adidshaft.atria"

struct WhoopWidgetSnapshot: Codable {
    let schema: Int
    let createdAt: Date
    let recoveryPercent: Int?
    let recoveryConfidence: String
    let recoveryDetail: String
    let strain: Double
    let restingHR: Int?
    let hrvRMSSD: Int?
    let hrvState: String
    let maxHR: Int
    // Optional so schema-1 payloads still decode (missing keys -> nil).
    let steps: Int?
    let heartRate: Int?
    let storage: String
    let appGroupEnabled: Bool
    let widgetTargetPresent: Bool
    let complicationTargetPresent: Bool
}

struct WhoopWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WhoopWidgetSnapshot?
}

struct WhoopWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> WhoopWidgetEntry {
        WhoopWidgetEntry(date: Date(), snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (WhoopWidgetEntry) -> Void) {
        completion(WhoopWidgetEntry(date: Date(), snapshot: Self.loadSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WhoopWidgetEntry>) -> Void) {
        let entry = WhoopWidgetEntry(date: Date(), snapshot: Self.loadSnapshot())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
    }

    private static func loadSnapshot() -> WhoopWidgetSnapshot? {
        guard let data = UserDefaults(suiteName: appGroupID)?.data(forKey: snapshotKey) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WhoopWidgetSnapshot.self, from: data)
    }
}

struct WhoopWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WhoopWidgetEntry

    var body: some View {
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

    private var systemWidget: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Atria")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(primaryText)
                .font(.title3.weight(.bold))
                .monospacedDigit()
            Text(secondaryText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
            Text(footerText)
                .font(.caption2.weight(.medium))
                .foregroundStyle(entry.snapshot == nil ? .orange : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if family == .systemMedium {
                controlButtons
            }
        }
        .containerBackground(.background, for: .widget)
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

    private var accessoryCircular: some View {
        VStack(spacing: 2) {
            Text("A")
                .font(.caption2.weight(.semibold))
            Text(accessoryCode)
                .font(.caption2.monospacedDigit().weight(.bold))
        }
        .containerBackground(.background, for: .widget)
    }

    private var accessoryRectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Atria")
                .font(.caption2.weight(.semibold))
            Text(primaryText)
                .font(.caption.monospacedDigit().weight(.bold))
            Text(footerText)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .containerBackground(.background, for: .widget)
    }

    private var primaryText: String {
        guard let snapshot = entry.snapshot else { return "Learning" }
        return "Strain \(String(format: "%.1f", snapshot.strain))"
    }

    private var secondaryText: String {
        guard let snapshot = entry.snapshot else { return "Open app for live strap status" }
        if let recovery = snapshot.recoveryPercent {
            return "Recovery \(recovery)% · \(snapshot.recoveryConfidence)"
        }
        return "Recovery learning · \(snapshot.recoveryConfidence)"
    }

    private var footerText: String {
        guard let snapshot = entry.snapshot else { return "HRV learning" }
        if let hrv = snapshot.hrvRMSSD {
            return "HRV \(hrv) ms · RHR \(snapshot.restingHR.map(String.init) ?? "learning")"
        }
        return "\(snapshot.hrvState.replacingOccurrences(of: "_", with: " ")) · RHR \(snapshot.restingHR.map(String.init) ?? "learning")"
    }

    private var inlineText: String {
        guard let snapshot = entry.snapshot else { return "Atria learning" }
        return "Atria strain \(String(format: "%.1f", snapshot.strain))"
    }

    private var accessoryCode: String {
        guard let snapshot = entry.snapshot else { return "LRN" }
        return String(format: "%.0f", snapshot.strain)
    }
}

struct WhoopStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WhoopWidget", provider: WhoopWidgetProvider()) { entry in
            WhoopWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Atria")
        .description("Shows local recovery and strain status when shared widget storage is enabled.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct AtriaLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AtriaLiveActivityAttributes.self) { context in
            AtriaLiveActivityLockScreenView(context: context)
                .activityBackgroundTint(Color(.systemBackground))
                .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("BPM", systemImage: "heart.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(context.state.heartRate > 0 ? "\(context.state.heartRate)" : "--")
                            .font(.title3.monospacedDigit().weight(.bold))
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Strain")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.1f", context.state.strain))
                            .font(.title3.monospacedDigit().weight(.bold))
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label(elapsedText(since: context.attributes.startedAt), systemImage: "timer")
                            Spacer(minLength: 10)
                            Label(context.state.batteryLevel >= 0 ? "\(context.state.batteryLevel)%" : "Battery", systemImage: "battery.100")
                            Button(intent: AtriaControlCaptureIntent(command: .stop)) {
                                Label("Stop", systemImage: "stop.circle")
                                    .labelStyle(.titleAndIcon)
                            }
                            .tint(.red)
                        }

                        if context.state.mediaHasNowPlayingInfo {
                            Label(mediaLine(for: context.state), systemImage: context.state.mediaIsPlaying ? "play.fill" : "pause.fill")
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                        }
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: "heart.fill")
                    .foregroundStyle(.red)
            } compactTrailing: {
                Text(context.state.heartRate > 0 ? "\(context.state.heartRate)" : "--")
                    .font(.caption.monospacedDigit().weight(.bold))
            } minimal: {
                Text(context.state.heartRate > 0 ? "\(context.state.heartRate)" : "A")
                    .font(.caption2.monospacedDigit().weight(.bold))
            }
            .keylineTint(.red)
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Atria live")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(context.state.heartRate > 0 ? "\(context.state.heartRate) BPM" : "Reading BPM")
                        .font(.title3.monospacedDigit().weight(.bold))
                }

                Spacer(minLength: 10)

                VStack(alignment: .trailing, spacing: 3) {
                    Text(String(format: "Strain %.1f", context.state.strain))
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                    Text("\(context.state.readingCount) readings · \(elapsedText(since: context.attributes.startedAt))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if context.state.mediaHasNowPlayingInfo {
                Label(mediaLine(for: context.state), systemImage: context.state.mediaIsPlaying ? "play.fill" : "pause.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            Button(intent: AtriaControlCaptureIntent(command: .stop)) {
                Label("Stop capture", systemImage: "stop.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding(.vertical, 4)
    }
}

private func mediaLine(for state: AtriaLiveActivityAttributes.ContentState) -> String {
    if state.mediaArtist.isEmpty || state.mediaArtist == "System player" {
        return state.mediaTitle
    }
    return "\(state.mediaTitle) · \(state.mediaArtist)"
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

// MARK: - Single-metric Lock Screen widgets (Steps / Strain / HRV / BPM)

enum AtriaWidgetMetric {
    case steps, strain, hrv, bpm

    var title: String {
        switch self {
        case .steps: return "Steps"
        case .strain: return "Strain"
        case .hrv: return "HRV"
        case .bpm: return "BPM"
        }
    }

    var icon: String {
        switch self {
        case .steps: return "figure.walk"
        case .strain: return "bolt.fill"
        case .hrv: return "waveform.path.ecg"
        case .bpm: return "heart.fill"
        }
    }

    func value(_ s: WhoopWidgetSnapshot?) -> String {
        guard let s else { return "--" }
        switch self {
        case .steps:
            guard let steps = s.steps else { return "--" }
            return steps >= 1000 ? String(format: "%.1fk", Double(steps) / 1000) : "\(steps)"
        case .strain:
            return String(format: "%.1f", s.strain)
        case .hrv:
            return s.hrvRMSSD.map(String.init) ?? "--"
        case .bpm:
            return s.heartRate.map(String.init) ?? "--"
        }
    }
}

struct AtriaMetricWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let metric: AtriaWidgetMetric
    let entry: WhoopWidgetEntry

    private var value: String { metric.value(entry.snapshot) }

    var body: some View {
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
                }
                Spacer(minLength: 0)
            }
            .containerBackground(.clear, for: .widget)
        default: // accessoryCircular
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
}

struct AtriaStepsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AtriaStepsWidget", provider: WhoopWidgetProvider()) { entry in
            AtriaMetricWidgetEntryView(metric: .steps, entry: entry)
        }
        .configurationDisplayName("Atria Steps")
        .description("Today's steps on your Lock Screen.")
        .supportedFamilies([.accessoryCircular, .accessoryInline, .accessoryRectangular])
    }
}

struct AtriaStrainWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AtriaStrainWidget", provider: WhoopWidgetProvider()) { entry in
            AtriaMetricWidgetEntryView(metric: .strain, entry: entry)
        }
        .configurationDisplayName("Atria Strain")
        .description("Today's strain on your Lock Screen.")
        .supportedFamilies([.accessoryCircular, .accessoryInline, .accessoryRectangular])
    }
}

struct AtriaHRVWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AtriaHRVWidget", provider: WhoopWidgetProvider()) { entry in
            AtriaMetricWidgetEntryView(metric: .hrv, entry: entry)
        }
        .configurationDisplayName("Atria HRV")
        .description("Latest HRV on your Lock Screen.")
        .supportedFamilies([.accessoryCircular, .accessoryInline, .accessoryRectangular])
    }
}

struct AtriaBPMWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AtriaBPMWidget", provider: WhoopWidgetProvider()) { entry in
            AtriaMetricWidgetEntryView(metric: .bpm, entry: entry)
        }
        .configurationDisplayName("Atria BPM")
        .description("Latest heart rate on your Lock Screen.")
        .supportedFamilies([.accessoryCircular, .accessoryInline, .accessoryRectangular])
    }
}

@main
struct WhoopWidgetBundle: WidgetBundle {
    var body: some Widget {
        WhoopStatusWidget()
        AtriaStepsWidget()
        AtriaStrainWidget()
        AtriaHRVWidget()
        AtriaBPMWidget()
        AtriaLiveActivityWidget()
        AtriaStartCaptureControl()
        AtriaStopCaptureControl()
    }
}
