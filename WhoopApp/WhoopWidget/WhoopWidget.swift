import SwiftUI
import WidgetKit

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

@main
struct WhoopWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WhoopWidget", provider: WhoopWidgetProvider()) { entry in
            WhoopWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Atria")
        .description("Shows local recovery and strain status when shared widget storage is enabled.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
