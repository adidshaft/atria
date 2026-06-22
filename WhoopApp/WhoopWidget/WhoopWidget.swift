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
        }
        .containerBackground(.background, for: .widget)
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
        guard let snapshot = entry.snapshot else { return "HRV reference pending" }
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
                    HStack {
                        Label(elapsedText(since: context.attributes.startedAt), systemImage: "timer")
                        Spacer(minLength: 10)
                        Label(context.state.batteryLevel >= 0 ? "\(context.state.batteryLevel)%" : "Battery", systemImage: "battery.100")
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
                Text("\(context.state.sampleCount) samples · \(elapsedText(since: context.attributes.startedAt))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
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

@main
struct WhoopWidgetBundle: WidgetBundle {
    var body: some Widget {
        WhoopStatusWidget()
        AtriaLiveActivityWidget()
        AtriaStartCaptureControl()
        AtriaStopCaptureControl()
    }
}
