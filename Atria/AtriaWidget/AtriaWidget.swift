import SwiftUI
import WidgetKit
import ActivityKit
import AppIntents

private let snapshotKey = "atria.widgetSnapshot.v1"
private let appGroupID = "group.com.adidshaft.atria"
private let atriaOverviewURL = URL(string: "atria://tab/overview")!
private let atriaVitalsURL = URL(string: "atria://tab/vitals")!

struct AtriaWidgetSnapshot: Codable {
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
    let batteryLevel: Int?
    let batteryChargeStatus: String?
    let batteryChargeText: String?
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
        let entry = AtriaWidgetEntry(date: Date(), snapshot: Self.loadSnapshot())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
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
            switch family {
            case .systemSmall:
                systemSmallWidget
            case .systemMedium:
                systemMediumWidget
            default:
                systemMediumWidget
            }
        }
        .containerBackground(.background, for: .widget)
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
                                  value: entry.snapshot.map { String(format: "%.1f", $0.strain) } ?? "--",
                                  icon: "bolt.fill",
                                  tint: .orange,
                                  deepLinkURL: AtriaWidgetMetric.strain.deepLinkURL)
                    compactMetric("BPM",
                                  value: entry.snapshot?.heartRate.map(String.init) ?? "--",
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
                    widgetMetricLink(.strain, tint: .orange)
                    widgetMetricLink(.bpm, tint: .red)
                }
                HStack(spacing: 8) {
                    widgetMetricLink(.hrv, tint: .pink)
                    widgetMetricLink(.steps, tint: .blue)
                }
            }
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

    private func widgetMetricLink(_ metric: AtriaWidgetMetric, tint: Color) -> some View {
        Link(destination: metric.deepLinkURL) {
            widgetMetricTile(metric.title,
                             value: metric.value(entry.snapshot),
                             icon: metric.icon,
                             tint: tint)
        }
        .accessibilityLabel("\(metric.title) \(metric.value(entry.snapshot))")
    }

    private func widgetMetricTile(_ title: String, value: String, icon: String, tint: Color) -> some View {
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
        }
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var stepsText: String {
        guard let steps = entry.snapshot?.steps else { return "--" }
        return steps >= 1000 ? String(format: "%.1fk", Double(steps) / 1000) : "\(steps)"
    }

    private var batteryHeaderText: String? {
        guard let level = entry.snapshot?.batteryLevel else { return nil }
        if entry.snapshot?.batteryChargeStatus == "levelOnly" {
            return "\(level)%"
        }
        return "\(level)%"
    }

    private var batterySymbol: String {
        guard let snapshot = entry.snapshot else { return "battery.0percent" }
        if snapshot.batteryChargeStatus == "charging" { return "battery.100percent.bolt" }
        if snapshot.batteryChargeStatus == "full" { return "battery.100percent" }
        guard let level = snapshot.batteryLevel else { return "battery.0percent" }
        switch level {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private var batteryTint: Color {
        switch entry.snapshot?.batteryChargeStatus {
        case "charging", "full": return .green
        default: return .secondary
        }
    }

    private func recoveryColor(_ percent: Int) -> Color {
        if percent >= 67 { return .green }
        if percent >= 34 { return .yellow }
        return .red
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

private struct AtriaWidgetRecoveryGauge: View {
    let percent: Int?

    private var progress: Double {
        guard let percent else { return 0 }
        return min(1, max(0, Double(percent) / 100))
    }

    private var tint: Color {
        guard let percent else { return .secondary }
        if percent >= 67 { return .green }
        if percent >= 34 { return .yellow }
        return .red
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

// MARK: - Single-metric widgets (Home Screen + Lock Screen)

enum AtriaWidgetMetric {
    case steps, strain, hrv, bpm

    var deepLinkURL: URL {
        switch self {
        case .steps, .strain:
            return atriaOverviewURL
        case .hrv, .bpm:
            return atriaVitalsURL
        }
    }

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

    var tint: Color {
        switch self {
        case .steps: return .blue
        case .strain: return .orange
        case .hrv: return .pink
        case .bpm: return .red
        }
    }

    var unit: String {
        switch self {
        case .steps: return "today"
        case .strain: return "day load"
        case .hrv: return "ms"
        case .bpm: return "live"
        }
    }

    func value(_ s: AtriaWidgetSnapshot?) -> String {
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
    let entry: AtriaWidgetEntry

    private var value: String { metric.value(entry.snapshot) }

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
                    }
                    Spacer(minLength: 0)
                }
                .containerBackground(.clear, for: .widget)
            case .systemSmall:
                systemSmallMetric
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

    private var metricFooterText: String {
        guard let snapshot = entry.snapshot else { return "Open Atria" }
        let age = max(0, Int(Date().timeIntervalSince(snapshot.createdAt) / 60))
        if age < 1 { return "Updated now" }
        if age < 60 { return "Updated \(age)m ago" }
        return "Open Atria to refresh"
    }
}

struct AtriaStepsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AtriaStepsWidget", provider: AtriaWidgetProvider()) { entry in
            AtriaMetricWidgetEntryView(metric: .steps, entry: entry)
        }
        .configurationDisplayName("Atria Steps")
        .description("Today's steps on your Home Screen or Lock Screen.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryInline, .accessoryRectangular])
    }
}

struct AtriaStrainWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AtriaStrainWidget", provider: AtriaWidgetProvider()) { entry in
            AtriaMetricWidgetEntryView(metric: .strain, entry: entry)
        }
        .configurationDisplayName("Atria Strain")
        .description("Today's strain on your Home Screen or Lock Screen.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryInline, .accessoryRectangular])
    }
}

struct AtriaHRVWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AtriaHRVWidget", provider: AtriaWidgetProvider()) { entry in
            AtriaMetricWidgetEntryView(metric: .hrv, entry: entry)
        }
        .configurationDisplayName("Atria HRV")
        .description("Latest HRV on your Home Screen or Lock Screen.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryInline, .accessoryRectangular])
    }
}

struct AtriaBPMWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AtriaBPMWidget", provider: AtriaWidgetProvider()) { entry in
            AtriaMetricWidgetEntryView(metric: .bpm, entry: entry)
        }
        .configurationDisplayName("Atria BPM")
        .description("Latest heart rate on your Home Screen or Lock Screen.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryInline, .accessoryRectangular])
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
