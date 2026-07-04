import SwiftUI
import UIKit

enum AtriaAlternateAppIcon: String, CaseIterable {
    case primary
    case mint
    case graphite

    var alternateName: String? {
        switch self {
        case .primary: return nil
        case .mint: return "AtriaMint"
        case .graphite: return "AtriaGraphite"
        }
    }

    var label: String {
        switch self {
        case .primary: return "Classic"
        case .mint: return "Mint"
        case .graphite: return "Graphite"
        }
    }

    var systemImage: String {
        switch self {
        case .primary: return "app.fill"
        case .mint: return "circle.hexagongrid.fill"
        case .graphite: return "circle.grid.cross.fill"
        }
    }

    static func current() -> AtriaAlternateAppIcon {
        allCases.first { $0.alternateName == UIApplication.shared.alternateIconName } ?? .primary
    }
}

struct AtriaCustomizeSheet: View {
    let initialConfig: AtriaHomeLayoutConfig
    let onCommit: (AtriaHomeLayoutConfig) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: AtriaHomeLayoutConfig
    @State private var showResetConfirmation = false
    @State private var selectedAppIcon: AtriaAlternateAppIcon = .primary
    @State private var iconErrorText: String?

    init(initialConfig: AtriaHomeLayoutConfig,
         onCommit: @escaping (AtriaHomeLayoutConfig) -> Void) {
        self.initialConfig = initialConfig.validated()
        self.onCommit = onCommit
        _draft = State(initialValue: initialConfig.validated())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AtriaCustomizePreview(config: draft.validated())
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                }

                ringsSection
                cardsSection
                metricsSection
                metricToggleSection
                lookSection
                appIconSection
                resetSection
            }
            .navigationTitle("Customize Today")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    EditButton()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        onCommit(draft.validated())
                        dismiss()
                    }
                    .font(.body.weight(.semibold))
                }
            }
            .confirmationDialog("Reset Today layout?",
                                isPresented: $showResetConfirmation,
                                titleVisibility: .visible) {
                Button("Reset to defaults", role: .destructive) {
                    draft = .default
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear {
            selectedAppIcon = AtriaAlternateAppIcon.current()
        }
    }

    private var ringsSection: some View {
        Section {
            Picker("Center metric", selection: $draft.ringCenterMetric) {
                ForEach(AtriaHomeLayoutConfig.RingCenterMetric.allCases, id: \.self) { metric in
                    Label(metric.label, systemImage: metric.systemImage).tag(metric)
                }
            }
            .pickerStyle(.segmented)

            Picker("Legend", selection: $draft.legendStatStyle) {
                ForEach(AtriaHomeLayoutConfig.LegendStatStyle.allCases, id: \.self) { style in
                    Text(style.label).tag(style)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Rings")
        }
    }

    private var cardsSection: some View {
        Section {
            Toggle("Live strip", isOn: $draft.showLiveStrip)
            Toggle("Highlights", isOn: $draft.showHighlights)
            Toggle("Weekly plan", isOn: $draft.showPlan)
            Toggle("AI coach", isOn: $draft.showAICoach)
        } header: {
            Text("Cards")
        }
    }

    private var metricsSection: some View {
        Section {
            ForEach(selectedMetrics) { metric in
                Label(metric.label, systemImage: metric.systemImage)
            }
            .onMove(perform: moveSelectedMetrics)
        } header: {
            Text("Metric order")
        } footer: {
            Text("Use Edit to drag selected Today cards into the order you want.")
        }
    }

    private var metricToggleSection: some View {
        Section {
            ForEach(AtriaTodayMetric.defaultGlanceOrder) { metric in
                Toggle(isOn: metricBinding(metric)) {
                    Label(metric.label, systemImage: metric.systemImage)
                }
                .disabled(!isSelected(metric) && draft.glanceMetrics.count >= AtriaHomeLayoutConfig.maxTodayCards)
            }
        } header: {
            Text("Metrics")
        } footer: {
            Text("Up to eight Today cards.")
        }
    }

    private var selectedMetrics: [AtriaTodayMetric] {
        draft.validated().glanceMetrics.compactMap(AtriaTodayMetric.init(rawValue:))
    }

    private func moveSelectedMetrics(from source: IndexSet, to destination: Int) {
        var metrics = draft.validated().glanceMetrics
        metrics.move(fromOffsets: source, toOffset: destination)
        draft.glanceMetrics = metrics
    }

    private var lookSection: some View {
        Section {
            HStack(spacing: 12) {
                ForEach(AtriaHomeLayoutConfig.Accent.allCases, id: \.self) { accent in
                    Button {
                        draft.accent = accent
                    } label: {
                        Circle()
                            .fill(accent.color)
                            .frame(width: 34, height: 34)
                            .overlay {
                                if draft.accent == accent {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.black))
                                        .foregroundStyle(.white)
                                }
                            }
                            .accessibilityLabel(accent.label)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } header: {
            Text("Look")
        }
    }

    private var appIconSection: some View {
        Section {
            Picker("App icon", selection: $selectedAppIcon) {
                ForEach(AtriaAlternateAppIcon.allCases, id: \.self) { icon in
                    Label(icon.label, systemImage: icon.systemImage).tag(icon)
                }
            }
            .pickerStyle(.inline)
            .disabled(!UIApplication.shared.supportsAlternateIcons)
            .onChange(of: selectedAppIcon) { _, icon in
                applyAppIcon(icon)
            }

            if let iconErrorText {
                Text(iconErrorText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("App icon")
        } footer: {
            Text(UIApplication.shared.supportsAlternateIcons
                 ? "Changes the icon shown on the Home Screen."
                 : "Alternate icons are unavailable on this device.")
        }
    }

    private func applyAppIcon(_ icon: AtriaAlternateAppIcon) {
        guard UIApplication.shared.supportsAlternateIcons else { return }
        guard UIApplication.shared.alternateIconName != icon.alternateName else { return }
        UIApplication.shared.setAlternateIconName(icon.alternateName) { error in
            DispatchQueue.main.async {
                if let error {
                    iconErrorText = "Could not change icon: \(error.localizedDescription)"
                    selectedAppIcon = AtriaAlternateAppIcon.current()
                } else {
                    iconErrorText = nil
                }
            }
        }
    }

    private var resetSection: some View {
        Section {
            Button(role: .destructive) {
                showResetConfirmation = true
            } label: {
                Label("Reset to defaults", systemImage: "arrow.counterclockwise")
            }
        }
    }

    private func metricBinding(_ metric: AtriaTodayMetric) -> Binding<Bool> {
        Binding(
            get: { isSelected(metric) },
            set: { selected in
                var metrics = draft.validated().glanceMetrics
                if selected {
                    guard !metrics.contains(metric.rawValue),
                          metrics.count < AtriaHomeLayoutConfig.maxTodayCards else { return }
                    metrics.append(metric.rawValue)
                } else {
                    metrics.removeAll { $0 == metric.rawValue }
                }
                draft.glanceMetrics = metrics
            }
        )
    }

    private func isSelected(_ metric: AtriaTodayMetric) -> Bool {
        draft.glanceMetrics.contains(metric.rawValue)
    }
}

private struct AtriaCustomizePreview: View {
    let config: AtriaHomeLayoutConfig

    var body: some View {
        VStack(spacing: 14) {
            AtriaTriRing(sleep: sleepMetric,
                         recovery: recoveryMetric,
                         strain: strainMetric,
                         centerValue: centerValue,
                         centerState: centerState,
                         accessibilitySummary: "Customize preview",
                         onSleep: {},
                         onRecovery: {},
                         onStrain: {})
                .scaleEffect(0.60)
                .frame(height: 178)
                .allowsHitTesting(false)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                GridItem(.flexible(), spacing: 10)],
                      spacing: 10) {
                if config.showLiveStrip {
                    previewCard(title: "Live", value: "72", icon: "heart.fill", tint: .pink)
                }
                if config.showHighlights {
                    previewCard(title: "Highlight", value: "Good", icon: "lightbulb.max.fill", tint: config.accent.color)
                }
                if config.showPlan {
                    previewCard(title: "Plan", value: "2/3", icon: "checklist", tint: Metrics.electricGreen)
                }
                if config.showAICoach {
                    previewCard(title: "Coach", value: "Ready", icon: "bubble.left.and.text.bubble.right.fill", tint: .cyan)
                }
                ForEach(config.glanceMetrics.prefix(4), id: \.self) { key in
                    let metric = AtriaTodayMetric(rawValue: key)
                    previewCard(title: metric?.label ?? key,
                                value: sampleValue(for: metric),
                                icon: metric?.systemImage ?? "square.grid.2x2",
                                tint: tint(for: metric))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .atriaInsetCard(cornerRadius: 20, tint: config.accent.color)
    }

    private var sleepMetric: AtriaTriRingMetric {
        AtriaTriRingMetric(title: "Sleep",
                           value: "7:42",
                           detail: "Good",
                           systemImage: "moon.fill",
                           tint: Metrics.electricSleep,
                           fill: 0.88)
    }

    private var recoveryMetric: AtriaTriRingMetric {
        AtriaTriRingMetric(title: "Recovery",
                           value: "64%",
                           detail: "Good",
                           systemImage: "arrow.clockwise.heart",
                           tint: Metrics.recoveryColor(64),
                           fill: 0.64)
    }

    private var strainMetric: AtriaTriRingMetric {
        AtriaTriRingMetric(title: "Strain",
                           value: "8.4",
                           detail: "of 12",
                           systemImage: "flame.fill",
                           tint: Metrics.electricStrain,
                           fill: 0.70)
    }

    private var centerValue: String {
        switch config.ringCenterMetric {
        case .recovery: return "64%"
        case .sleep: return "88%"
        case .strain: return "8.4"
        }
    }

    private var centerState: String {
        switch config.ringCenterMetric {
        case .recovery, .sleep: return "Good"
        case .strain: return "Build"
        }
    }

    private func previewCard(title: String, value: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(value)
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(minHeight: 56)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func sampleValue(for metric: AtriaTodayMetric?) -> String {
        switch metric {
        case .recovery: return "64%"
        case .strain: return "8.4"
        case .load: return "0.9"
        case .hrZones: return "47m"
        case .workouts: return "3"
        case .strainCompare: return "4.2"
        case .hrv: return "48 ms"
        case .stress: return "Low"
        case .sleep: return "7:42"
        case .sleepHistory: return "5/7"
        case .sleepEfficiency: return "91%"
        case .rhr: return "58"
        case .respiratoryRate: return "14.2"
        case .steps: return "8.2k"
        case .calories: return "520"
        case .vo2max: return "42"
        case .bioAge: return "31"
        case .bloodOxygen: return "98%"
        case .bodyTemp: return "+0.1"
        case .trend: return "Steady"
        case .insights: return "2"
        case nil: return "On"
        }
    }

    private func tint(for metric: AtriaTodayMetric?) -> Color {
        switch metric {
        case .recovery: return Metrics.recoveryColor(64)
        case .strain, .load, .calories, .strainCompare: return Metrics.electricStrain
        case .sleep, .sleepHistory, .sleepEfficiency: return Metrics.electricSleep
        case .hrv, .rhr, .respiratoryRate, .bloodOxygen: return .pink
        case .stress: return .cyan
        case .steps, .vo2max, .bioAge: return Metrics.electricGreen
        case .bodyTemp, .hrZones: return .orange
        case .workouts: return .mint
        case .trend, .insights, nil: return config.accent.color
        }
    }
}

private extension AtriaHomeLayoutConfig.RingCenterMetric {
    var label: String {
        switch self {
        case .recovery: return "Recovery"
        case .sleep: return "Sleep"
        case .strain: return "Strain"
        }
    }

    var systemImage: String {
        switch self {
        case .recovery: return "arrow.clockwise.heart"
        case .sleep: return "moon.fill"
        case .strain: return "flame.fill"
        }
    }
}

private extension AtriaHomeLayoutConfig.LegendStatStyle {
    var label: String {
        switch self {
        case .value: return "Value"
        case .valueAndState: return "State"
        }
    }
}

extension AtriaHomeLayoutConfig.Accent {
    var label: String {
        switch self {
        case .atria: return "Atria"
        case .mint: return "Mint"
        case .cyan: return "Cyan"
        case .coral: return "Coral"
        case .violet: return "Violet"
        }
    }

    var color: Color {
        switch self {
        case .atria: return Metrics.electricGreen
        case .mint: return Color(red: 0.25, green: 0.82, blue: 0.64)
        case .cyan: return Color(red: 0.16, green: 0.68, blue: 0.95)
        case .coral: return Color(red: 1.0, green: 0.42, blue: 0.36)
        case .violet: return Metrics.electricSleep
        }
    }
}
