import SwiftUI

struct AtriaWidgetProofSheet: View {
    let snapshot: WidgetSnapshot?
    let layoutConfig: AtriaHomeLayoutConfig
    @Environment(\.dismiss) private var dismiss

    private var validatedLayout: AtriaHomeLayoutConfig {
        layoutConfig.validated()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    proofHeader
                    widgetPreview(title: "Home Screen · medium", compact: true)
                        .frame(height: 236)
                    familyProofRow
                    lockScreenProof
                    snapshotFacts
                }
                .padding(18)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Widget proof")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("atria-widget-proof-sheet")
    }

    private var proofHeader: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(snapshot == nil ? "Snapshot missing" : "Widget timeline snapshot ready",
                  systemImage: snapshot == nil ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                .font(.headline.weight(.semibold))
                .foregroundStyle(snapshot == nil ? .orange : .green)
            Text(snapshot == nil
                 ? "Open Atria once to publish a local snapshot. Widgets will not invent a reading until one exists."
                 : "Uses the same `atria.widgetSnapshot.v1` payload and saved Customize metric order that WidgetKit reads.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func widgetPreview(title: String, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(validatedLayout.accent.rawValue)
                    .font(.caption2.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(accentColor)
            }

            if compact {
                HStack(spacing: 14) {
                    recoveryGauge(size: 86)
                    metricGrid(columns: 2)
                }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 16) {
                        recoveryGauge(size: 112)
                        VStack(alignment: .leading, spacing: 7) {
                            Text(recoveryLine)
                                .font(.headline.weight(.semibold))
                                .lineLimit(2)
                            Text(footerLine)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Label(batteryLine, systemImage: batterySymbol)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    metricGrid(columns: 2)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private var familyProofRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Other families")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                smallWidgetProof
                largeWidgetProof
            }
        }
    }

    private var smallWidgetProof: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Small")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                recoveryGauge(size: 54)
                VStack(alignment: .leading, spacing: 2) {
                    Text(widgetMetrics.first?.value(snapshot) ?? "--")
                        .font(.title3.monospacedDigit().weight(.bold))
                    Text(widgetMetrics.first?.title ?? "Strain")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            Text(snapshot == nil ? "Snapshot missing" : freshnessText)
                .font(.caption2.weight(.medium))
                .foregroundStyle(snapshot == nil ? .orange : .secondary)
                .lineLimit(1)
        }
        .padding(13)
        .frame(maxWidth: .infinity, minHeight: 126, alignment: .leading)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private var largeWidgetProof: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Large")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Controls")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.green)
            }
            Text(recoveryLine)
                .font(.subheadline.weight(.bold))
                .lineLimit(1)
            HStack(spacing: 6) {
                proofControl("Start", symbol: "record.circle", tint: .green)
                proofControl("Stop", symbol: "stop.circle", tint: .red)
            }
            Text("Start and Stop use the same App Intents exposed to Control Center and Lock Screen.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(13)
        .frame(maxWidth: .infinity, minHeight: 126, alignment: .leading)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private func proofControl(_ title: String, symbol: String, tint: Color) -> some View {
        Label(title, systemImage: symbol)
            .font(.caption2.weight(.bold))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(tint.opacity(0.12), in: Capsule())
    }

    private var lockScreenProof: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Lock Screen accessories", systemImage: "lock.fill")
                    .font(.subheadline.weight(.bold))
                Spacer()
                Text("Circular · Rectangular · Inline")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                recoveryGauge(size: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Rec \(snapshot?.recoveryPercent.map { "\($0)%" } ?? "--")")
                        .font(.caption.monospacedDigit().weight(.bold))
                    Text("Strain \(AtriaWidgetProofMetric.strain.value(snapshot))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("HR \(AtriaWidgetProofMetric.bpm.value(snapshot)) bpm")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text(inlineLockScreenText)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func metricGrid(columns: Int) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
            ForEach(widgetMetrics) { metric in
                metricTile(metric)
            }
        }
    }

    private func metricTile(_ metric: AtriaWidgetProofMetric) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(metric.title, systemImage: metric.icon)
                .font(.caption2.weight(.bold))
                .foregroundStyle(metric.tint)
                .lineLimit(1)
                .minimumScaleFactor(0.74)
            Text(metric.value(snapshot))
                .font(.title3.monospacedDigit().weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.58)
            Text(metric.unit)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(9)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .background(metric.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func recoveryGauge(size: CGFloat) -> some View {
        ZStack {
            Circle()
                .stroke(recoveryTint.opacity(0.16), lineWidth: 10)
            Circle()
                .trim(from: 0, to: recoveryProgress)
                .stroke(recoveryTint, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(snapshot?.recoveryPercent.map { "\($0)" } ?? "--")
                    .font(.title2.monospacedDigit().weight(.heavy))
                Text("REC")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }

    private var snapshotFacts: some View {
        VStack(alignment: .leading, spacing: 10) {
            factRow("Updated", freshnessText)
            factRow("Storage", snapshot?.storage ?? "missing")
            factRow("App Group", snapshot?.appGroupEnabled == true ? "enabled" : "unavailable")
            factRow("Widget target", snapshot?.widgetTargetPresent == true ? "installed" : "unavailable")
            factRow("Lock Screen", snapshot?.complicationTargetPresent == true ? "supported" : "unavailable")
            factRow("Schema", snapshot.map { "\($0.schema)" } ?? "--")
            factRow("Layout order", widgetMetrics.map(\.title).joined(separator: " / "))
            factRow("Ring center", snapshot?.layoutRingCenterMetric ?? validatedLayout.ringCenterMetric.rawValue)
            factRow("Legend", snapshot?.layoutLegendStatStyle ?? validatedLayout.legendStatStyle.rawValue)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func factRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
                .multilineTextAlignment(.trailing)
        }
    }

    private var widgetMetrics: [AtriaWidgetProofMetric] {
        AtriaWidgetProofMetric.ordered(from: snapshot?.layoutGlanceMetrics ?? validatedLayout.glanceMetrics)
    }

    private var recoveryProgress: Double {
        min(max(Double(snapshot?.recoveryPercent ?? 0) / 100.0, 0), 1)
    }

    private var recoveryTint: Color {
        guard let recovery = snapshot?.recoveryPercent else { return .secondary }
        if recovery >= 67 { return .green }
        if recovery >= 34 { return .yellow }
        return .red
    }

    private var recoveryLine: String {
        if let recovery = snapshot?.recoveryPercent {
            return "Recovery \(recovery)% · \(snapshot?.recoveryConfidence ?? "learning")"
        }
        return "Recovery learning"
    }

    private var footerLine: String {
        guard let snapshot else { return "Open Atria to publish a local widget snapshot." }
        if let hrv = snapshot.hrvRMSSD {
            return "HRV \(hrv) ms · RHR \(snapshot.restingHR.map(String.init) ?? "learning")"
        }
        return "\(snapshot.hrvState.replacingOccurrences(of: "_", with: " ")) · RHR \(snapshot.restingHR.map(String.init) ?? "learning")"
    }

    private var batteryLine: String {
        snapshot?.batteryChargeText ?? snapshot?.batteryLevel.map { "Battery \($0)%" } ?? "Battery unknown"
    }

    private var freshnessText: String {
        guard let snapshot else { return "not published" }
        let seconds = max(0, Int(Date().timeIntervalSince(snapshot.createdAt)))
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3_600)h ago"
    }

    private var inlineLockScreenText: String {
        guard let snapshot else { return "Atria · open app" }
        return "Rec \(snapshot.recoveryPercent.map { "\($0)%" } ?? "--") · \(AtriaWidgetProofMetric.strain.value(snapshot)) strain"
    }

    private var batterySymbol: String {
        guard let level = snapshot?.batteryLevel else { return "questionmark.circle" }
        switch level {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private var accentColor: Color {
        switch validatedLayout.accent {
        case .atria: return .cyan
        case .mint: return .green
        case .cyan: return .cyan
        case .coral: return .orange
        case .violet: return .purple
        }
    }
}

private enum AtriaWidgetProofMetric: String, Identifiable {
    case steps, strain, hrv, bpm

    var id: String { rawValue }

    static let fallbackOrder: [AtriaWidgetProofMetric] = [.strain, .bpm, .hrv, .steps]

    static func ordered(from layoutGlanceMetrics: [String]?) -> [AtriaWidgetProofMetric] {
        var ordered: [AtriaWidgetProofMetric] = []
        for key in layoutGlanceMetrics ?? [] {
            guard let metric = widgetMetric(for: key), !ordered.contains(metric) else { continue }
            ordered.append(metric)
        }
        for metric in fallbackOrder where !ordered.contains(metric) {
            ordered.append(metric)
        }
        return Array(ordered.prefix(4))
    }

    private static func widgetMetric(for key: String) -> AtriaWidgetProofMetric? {
        switch key {
        case "strain", "load": return .strain
        case "hrv": return .hrv
        case "steps": return .steps
        case "heartRate", "bpm", "rhr", "respiratoryRate": return .bpm
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .steps: return "Strap steps"
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
        case .steps: return "strap"
        case .strain: return "day load"
        case .hrv: return "ms"
        case .bpm: return "live"
        }
    }

    func value(_ snapshot: WidgetSnapshot?) -> String {
        guard let snapshot else { return "--" }
        switch self {
        case .steps:
            guard let steps = snapshot.steps else { return "--" }
            return steps >= 1000 ? String(format: "%.1fk", Double(steps) / 1000) : "\(steps)"
        case .strain:
            return String(format: "%.1f", snapshot.strain)
        case .hrv:
            return snapshot.hrvRMSSD.map(String.init) ?? "--"
        case .bpm:
            return snapshot.heartRate.map(String.init) ?? "--"
        }
    }
}
