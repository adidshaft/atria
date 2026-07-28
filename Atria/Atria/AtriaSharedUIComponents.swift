import SwiftUI

enum AtriaMetricFormat {
    static func hrv(_ value: Double?) -> String {
        guard let value else { return "--" }
        return "\(Int(value.rounded())) ms"
    }

    static func restingHeartRate(_ value: Double?) -> String {
        guard let value else { return "--" }
        return "\(Int(value.rounded())) bpm"
    }

    static func strain(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.1f", min(max(value, 0), 21))
    }

    static func recovery(_ value: Double?) -> String {
        guard let value else { return "--" }
        return "\(Int(value.rounded()))%"
    }

    static func sleepDuration(seconds: TimeInterval?) -> String {
        guard let seconds else { return "--" }
        let totalMinutes = max(0, Int((seconds / 60).rounded()))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return minutes > 0 ? "\(hours) h \(minutes) m" : "\(hours) h"
        }
        return "\(minutes) m"
    }

    static func sleepHours(_ hours: Double?) -> String {
        guard let hours else { return "--" }
        return sleepDuration(seconds: max(0, hours) * 3_600)
    }

    static func value(_ value: Double?, metric: AtriaMetricUnit) -> String {
        switch metric {
        case .recovery:
            return recovery(value)
        case .hrv:
            return hrv(value)
        case .restingHeartRate:
            return restingHeartRate(value)
        case .strain:
            return strain(value)
        case .sleep:
            return sleepHours(value)
        }
    }

    static func change(_ value: Double, metric: AtriaMetricUnit) -> String {
        let prefix = value > 0 ? "+" : ""
        switch metric {
        case .recovery:
            return "\(prefix)\(Int(value.rounded()))%"
        case .hrv:
            return "\(prefix)\(Int(value.rounded())) ms"
        case .restingHeartRate:
            return "\(prefix)\(Int(value.rounded())) bpm"
        case .strain:
            return "\(prefix)\(String(format: "%.1f", value))"
        case .sleep:
            return "\(prefix)\(sleepHours(abs(value)))"
        }
    }

    static func range(low: Double, high: Double, metric: AtriaMetricUnit) -> String {
        switch metric {
        case .recovery:
            return "\(Int(low.rounded()))-\(Int(high.rounded()))%"
        case .hrv:
            return "\(Int(low.rounded()))-\(Int(high.rounded())) ms"
        case .restingHeartRate:
            return "\(Int(low.rounded()))-\(Int(high.rounded())) bpm"
        case .strain:
            return "\(strain(low))-\(strain(high))"
        case .sleep:
            return "\(sleepHours(low))-\(sleepHours(high))"
        }
    }
}

enum AtriaMetricUnit {
    case recovery
    case hrv
    case restingHeartRate
    case strain
    case sleep
}

struct AtriaCalibratingLabel: View, Equatable {
    let day: Int
    /// Honest denominator + noun for the calibration countdown. Defaults keep
    /// recovery's real "Day X of 4" (a usable preliminary estimate lands ~day 4);
    /// the 14-night baselines (HRV/RHR) pass total: 14, unit: "Night" so the ring
    /// never reads complete while the metric is still learning (2026-07-08).
    var total: Int = 4
    var unit: String = "Day"
    var tint: Color = .orange

    private var clampedDay: Int {
        min(max(day, 0), total)
    }

    var body: some View {
        HStack(spacing: 7) {
            ZStack {
                Circle()
                    .stroke(tint.opacity(0.25), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: Double(clampedDay) / Double(max(total, 1)))
                    .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text("Calibrating")
                    .font(.caption.weight(.bold))
                Text("\(unit) \(clampedDay) of \(total)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(tint)
        .accessibilityLabel("Calibrating. \(unit) \(clampedDay) of \(total).")
    }
}

struct AtriaLoadingPanel: View, Equatable {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                ProgressView()
                    .controlSize(.small)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.quaternary)
                .frame(height: 58)
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.quaternary)
                    .frame(height: 38)
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.quaternary)
                    .frame(height: 38)
            }
        }
        .padding(18)
        .atriaCard(emphasis: .soft)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(subtitle.isEmpty ? title : "\(title). \(subtitle)")
    }
}

struct AtriaPanelSectionHeader: View, Equatable {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.title3.weight(.semibold))
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AtriaQuickTile: View, Equatable {
    let title: String
    let value: String
    let detail: String
    let system: String
    let tint: Color

    @Environment(\.colorScheme) private var colorScheme

    static func == (lhs: AtriaQuickTile, rhs: AtriaQuickTile) -> Bool {
        lhs.title == rhs.title
            && lhs.value == rhs.value
            && lhs.detail == rhs.detail
            && lhs.system == rhs.system
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: system)
                .font(.caption.weight(.semibold))
                .foregroundStyle(colorScheme == .dark ? tint.opacity(0.95) : tint)
            Text(value)
                .font(.headline.weight(.bold).monospacedDigit())
            Text(detail)
                .font(.caption2)
                .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.66) : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
        .padding(12)
        .atriaInsetCard(tint: tint)
    }
}

struct AtriaRecoveryMeter: View, Equatable {
    let estimate: Metrics.RecoveryEstimate

    private var tint: Color {
        guard let percent = estimate.percent else { return .orange }
        return Metrics.recoveryColor(percent)
    }

    private var fillFraction: CGFloat {
        guard let percent = estimate.percent else { return 0.16 }
        return CGFloat(min(max(Double(percent) / 100.0, 0), 1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Recovery", systemImage: "gauge.with.dots.needle.bottom.50percent")
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)

            Text(estimate.percent.map { AtriaMetricFormat.recovery(Double($0)) } ?? "Learning")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .monospacedDigit()

            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.08))
                .frame(height: 8)
                .overlay(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(tint.gradient)
                        .frame(width: max(18, 120 * fillFraction), height: 8)
                }

            Text(Self.confidenceText(for: estimate.confidence))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(estimate.confidence == .validated ? .green : .orange)

            Text(estimate.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .atriaInsetCard(tint: .green)
    }

    private static func confidenceText(for confidence: Metrics.RecoveryEstimate.Confidence) -> String {
        switch confidence {
        case .learning:
            return "Building"
        case .unverified:
            return "Still improving"
        case .personalBaseline:
            return "Personal baseline"
        case .validated:
            return "Checked"
        }
    }
}

struct AtriaStrainMeter: View, Equatable {
    let strain: Double
    let detail: String
    let confidence: String

    private var tint: Color {
        Metrics.strainColor(strain)
    }

    private var fillFraction: CGFloat {
        CGFloat(min(max(strain / 21.0, 0), 1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Day strain", systemImage: "flame.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)

            Text(AtriaMetricFormat.strain(strain))
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .monospacedDigit()

            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.08))
                .frame(height: 8)
                .overlay(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(tint.gradient)
                        .frame(width: max(18, 120 * fillFraction), height: 8)
                }

            Text(confidence)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(confidence == "local" ? .green : .orange)

            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .atriaInsetCard(tint: .orange)
    }
}

struct AtriaSummaryRow: View, Equatable {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 86, alignment: .leading)
            Text(value)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

struct AtriaStatusChip: View, Equatable {
    let text: String
    let systemImage: String
    let tint: Color

    @Environment(\.colorScheme) private var colorScheme

    static func == (lhs: AtriaStatusChip, rhs: AtriaStatusChip) -> Bool {
        lhs.text == rhs.text && lhs.systemImage == rhs.systemImage
    }

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(colorScheme == .dark ? tint.opacity(0.98) : tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .atriaChromeCapsule(tint: tint)
    }
}

enum AtriaMetricState: Equatable {
    case learning
    case personalBaseline
    case validated
    case noContact
    case conflict
    case local
    case estimate
    case research
    case live

    var tint: Color {
        switch self {
        case .learning:
            // NEUTRAL, not amber. Amber is this app's caution tier, and "has not
            // been scored yet" is not a caution -- it is the absence of a grade.
            // Wearing amber made a fresh night show two orange badges on the
            // journal card, reading as two warnings about data that simply did
            // not exist. Same rule the metric values follow: colour is earned by
            // a real reading, and an ungraded state renders neutral.
            //
            // `.conflict` and `.estimate` keep amber deliberately: a conflict IS
            // a caution, and an estimate is a real value carrying real
            // uncertainty. Neither is the same claim as "no data yet".
            return .secondary
        case .personalBaseline:
            return .blue
        case .validated, .live:
            return .green
        case .noContact:
            return .red
        case .conflict:
            return .orange
        case .local:
            return .purple
        case .estimate:
            return .orange
        case .research:
            return .teal
        }
    }

    var systemImage: String {
        switch self {
        case .learning:
            // Calm "building / filling up" glyph instead of a busy dashed ring.
            return "circle.bottomhalf.filled"
        case .personalBaseline:
            return "person.crop.circle.badge.checkmark"
        case .validated:
            return "checkmark.seal.fill"
        case .noContact:
            return "heart.slash.fill"
        case .conflict:
            return "exclamationmark.triangle.fill"
        case .local:
            return "iphone"
        case .estimate:
            return "function"
        case .research:
            return "waveform.badge.magnifyingglass"
        case .live:
            return "waveform.path.ecg"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .learning:
            return "Learning"
        case .personalBaseline:
            return "Personal baseline"
        case .validated:
            return "Checked"
        case .noContact:
            return "No signal"
        case .conflict:
            return "App conflict"
        case .local:
            return "Local"
        case .estimate:
            return "Estimate"
        case .research:
            return "Early"
        case .live:
            return "Live"
        }
    }
}

struct AtriaStateBadge: View, Equatable {
    let state: AtriaMetricState

    var body: some View {
        Image(systemName: state.systemImage)
            .font(.caption.weight(.bold))
            .foregroundStyle(state.tint)
            .frame(width: 28, height: 28)
            .background(AtriaIconTileBackground(cornerRadius: 9, tint: state.tint))
            .accessibilityLabel(state.accessibilityLabel)
    }
}

struct AtriaMetricTile: View, Equatable {
    static let gridSpacing: CGFloat = 12
    static let gridMinimumWidth: CGFloat = 142
    static let gridColumns = [GridItem(.adaptive(minimum: gridMinimumWidth), spacing: gridSpacing)]

    private static let compactHeight: CGFloat = 122
    private static let sparklineHeight: CGFloat = 132
    private static let footerHeight: CGFloat = 34

    let label: String
    let value: String
    var unit: String? = nil
    var state: AtriaMetricState? = nil
    var tint: Color = .blue
    var footnote: String? = nil
    var sparklineValues: [Int]? = nil
    var zone: AtriaMetricZone? = nil
    var targetMetric: AtriaTodayMetric? = nil
    var calibratingDay: Int? = nil
    var calibratingTotal: Int = 4
    var calibratingUnit: String = "Day"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingZoneInfo = false
    @State private var editingTargetMetric: AtriaTodayMetric?

    static func == (lhs: AtriaMetricTile, rhs: AtriaMetricTile) -> Bool {
        lhs.label == rhs.label
            && lhs.value == rhs.value
            && lhs.unit == rhs.unit
            && lhs.state == rhs.state
            && lhs.tint == rhs.tint
            && lhs.footnote == rhs.footnote
            && lhs.sparklineValues == rhs.sparklineValues
            && lhs.zone == rhs.zone
            && lhs.targetMetric == rhs.targetMetric
            && lhs.calibratingDay == rhs.calibratingDay
            && lhs.calibratingTotal == rhs.calibratingTotal
            && lhs.calibratingUnit == rhs.calibratingUnit
    }

    private var displayValue: String {
        if calibratingDay != nil { return "" }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.localizedCaseInsensitiveContains("learning")
            || trimmed.localizedCaseInsensitiveContains("prepar") {
            return ""
        }
        return trimmed.isEmpty ? "" : value
    }

    private var accessibilityText: String {
        var parts = [calibratingDay.map { "\(label) calibrating \(calibratingUnit.lowercased()) \(min(max($0, 0), calibratingTotal)) of \(calibratingTotal)" } ?? "\(label) \(displayValue)"]
        if let unit {
            parts[0] += " \(unit)"
        }
        if let state {
            parts.append(state.accessibilityLabel)
        }
        if let footnote,
           !footnote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(footnote)
        }
        if let zone, zone.showsWarning {
            parts.append(zone.level.label)
            parts.append(zone.targetSummary)
            parts.append("Tap info for guidance.")
        }
        if targetMetric != nil {
            parts.append("Long press to edit target.")
        }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Spacer(minLength: 0)
                if let zone, zone.showsWarning {
                    AtriaMetricZoneInfoButton(zone: zone) {
                        showingZoneInfo = true
                    }
                }
                if let state {
                    AtriaStateBadge(state: state)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if let calibratingDay {
                    AtriaCalibratingLabel(day: calibratingDay, total: calibratingTotal, unit: calibratingUnit, tint: tint)
                } else {
                    Text(displayValue)
                        .font(.system(size: 29, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(reduceMotion ? .identity : .numericText())
                        .animation(reduceMotion ? nil : .snappy(duration: AtriaDesignTokens.Motion.emphatic), value: displayValue)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                if calibratingDay == nil, let unit {
                    Text(unit)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }

            footer
        }
        .frame(maxWidth: .infinity,
               minHeight: tileHeight,
               maxHeight: tileHeight,
               alignment: .leading)
        .padding(12)
        .atriaInsetCard(tint: tint)
        .modifier(AtriaMetricTileTargetEditorModifier(targetMetric: targetMetric,
                                                      editingTargetMetric: $editingTargetMetric))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .sheet(isPresented: $showingZoneInfo) {
            if let zone {
                AtriaMetricZoneInfoSheet(zone: zone,
                                         onEditTarget: targetMetric.map { metric in
                                             { editingTargetMetric = metric }
                                         })
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
        .sheet(item: $editingTargetMetric) { metric in
            AtriaGlanceTargetEditorSheet(metric: metric)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var tileHeight: CGFloat {
        sparklineValues == nil ? Self.compactHeight : Self.sparklineHeight
    }

    @ViewBuilder
    private var footer: some View {
        if let sparklineValues {
            Sparkline(values: sparklineValues, tint: tint)
                .frame(height: Self.footerHeight)
        } else if let footnote,
                  !footnote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(footnote)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.78)
                .fixedSize(horizontal: false, vertical: true)
                .frame(height: Self.footerHeight, alignment: .topLeading)
        } else {
            Color.clear
                .frame(height: Self.footerHeight)
                .accessibilityHidden(true)
        }
    }
}

private struct AtriaMetricTileTargetEditorModifier: ViewModifier {
    let targetMetric: AtriaTodayMetric?
    @Binding var editingTargetMetric: AtriaTodayMetric?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let targetMetric {
            content
                .contextMenu {
                    Button {
                        editingTargetMetric = targetMetric
                    } label: {
                        Label("Edit target", systemImage: "target")
                    }
                }
                .accessibilityAction(named: Text("Edit target")) {
                    editingTargetMetric = targetMetric
                }
        } else {
            content
        }
    }
}

struct AtriaMetricZoneInfoButton: View, Equatable {
    let zone: AtriaMetricZone
    let action: () -> Void

    static func == (lhs: AtriaMetricZoneInfoButton, rhs: AtriaMetricZoneInfoButton) -> Bool {
        lhs.zone == rhs.zone
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let warningSystemImage = zone.warningSystemImage {
                    Image(systemName: warningSystemImage)
                        .font(.caption2.weight(.bold))
                        .accessibilityHidden(true)
                }
                Text("(i)")
                    .font(.caption2.weight(.black).monospaced())
                    .accessibilityHidden(true)
            }
            .foregroundStyle(zone.tint)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Target guidance for \(zone.title). \(zone.current)")
        .accessibilityHint("Opens target guidance and general wellness recommendations.")
    }
}

struct AtriaSectionDivider: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(colorScheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.10))
            .frame(height: 1)
    }
}

struct AtriaInlineQuickStat: View, Equatable {
    let label: String
    let value: String
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        .padding(10)
        .atriaInsetCard(tint: .white)
    }
}

struct AtriaProfileStepperTile: View {
    let title: String
    let value: String
    let decrement: () -> Void
    let increment: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title.weight(.bold).monospacedDigit())
            HStack(spacing: 10) {
                Button(action: decrement) {
                    Image(systemName: "minus")
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .atriaCardAction(prominent: false, tint: .secondary)
                .accessibilityLabel("Decrease \(title)")

                Button(action: increment) {
                    Image(systemName: "plus")
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .atriaCardAction(prominent: false, tint: .secondary)
                .accessibilityLabel("Increase \(title)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .atriaInsetCard(tint: .white)
    }
}

/// The design handoff's live-heart beat (`@keyframes atria-heart`): a quick
/// systole to 1.28x then straight back, followed by a long rest — one beat per
/// 1.1s. Deliberately a KEYFRAME animation, not `.symbolEffect(.pulse)` (which
/// fades opacity, reading as "signal strength" rather than a pulse) and not a
/// `repeatForever(autoreverses:)` ease, which is a symmetric sine with no rest
/// phase and so looks like breathing, not a heartbeat.
///
/// The rate is a fixed 1.1s on purpose and is NOT tied to the live BPM: the
/// number beside it already states the real rate honestly, and at 170bpm a
/// truthful 0.35s beat is frantic rather than legible.
struct AtriaPulsingHeart: View, Equatable {
    var font: Font = .headline.weight(.black)
    var tint: Color = .red

    /// One full cycle, matching the handoff's `atria-heart 1.1s`.
    private static let cycle: TimeInterval = 1.1
    private static let contract: TimeInterval = cycle * 0.15   // 0% -> 15%
    private static let release: TimeInterval = cycle * 0.15    // 15% -> 30%
    private static let rest: TimeInterval = cycle * 0.70       // 30% -> 100%

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func == (lhs: AtriaPulsingHeart, rhs: AtriaPulsingHeart) -> Bool {
        // Compare BOTH stored properties. Comparing tint alone would report two
        // different-sized hearts as equal and let SwiftUI skip a real font change.
        lhs.tint == rhs.tint && lhs.font == rhs.font
    }

    var body: some View {
        let icon = Image(systemName: "heart.fill")
            .font(font)
            .foregroundStyle(tint)

        if reduceMotion {
            icon
        } else {
            icon.keyframeAnimator(initialValue: 1.0, repeating: true) { view, scale in
                view.scaleEffect(scale)
            } keyframes: { _ in
                KeyframeTrack(\.self) {
                    CubicKeyframe(1.28, duration: Self.contract)
                    CubicKeyframe(1.0, duration: Self.release)
                    LinearKeyframe(1.0, duration: Self.rest)
                }
            }
        }
    }
}
