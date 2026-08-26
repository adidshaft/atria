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

    static func respiratory(_ value: Double?) -> String {
        guard let value else { return "--" }
        // "/min" is the canonical respiratory unit label (2026-08-05 audit:
        // "rpm" is nonstandard — colloquially revolutions per minute). The
        // space keeps the hero split (AtriaMetricHeroValueText) styling the
        // unit as the smaller secondary token, same as "54 ms" / "58 bpm".
        return String(format: "%.1f /min", value)
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
        case .respiratory:
            return respiratory(value)
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
            let sleepPrefix = value > 0 ? "+" : (value < 0 ? "\u{2212}" : "")
            return "\(sleepPrefix)\(sleepHours(abs(value)))"
        case .respiratory:
            return "\(prefix)\(String(format: "%.1f", value)) /min"
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
        case .respiratory:
            return String(format: "%.1f-%.1f /min", low, high)
        }
    }
}

enum AtriaMetricUnit {
    case recovery
    case hrv
    case restingHeartRate
    case strain
    case sleep
    case respiratory
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
            // Routine absence (strap off wrist / out of range) is not an
            // alarm — red implied something was wrong with the DATA. Same
            // colour-is-earned rule as `.learning` above (2026-08-04).
            return .secondary
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

/// Honest event-window visual for manual entry sheets (sleep, nap, workout):
/// draws ONLY the user-entered start→end span on an hour-ticked time track with
/// a duration readout. It never implies stage/zone data — it's a pure function
/// of the two times the user picked — so it stays within Atria's honesty rules
/// (no fabricated sensor detail). Updates live as the pickers move.
struct AtriaEventWindowTimeline: View, Equatable {
    let title: String
    let start: Date
    let end: Date
    let tint: Color
    var timeZoneIdentifier: String? = nil

    private var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }

    private var spanStart: Date {
        start.addingTimeInterval(-max(30 * 60, duration * 0.2))
    }

    private var spanEnd: Date {
        end.addingTimeInterval(max(30 * 60, duration * 0.2))
    }

    private func fraction(_ date: Date) -> CGFloat {
        let total = spanEnd.timeIntervalSince(spanStart)
        guard total > 0 else { return 0 }
        return CGFloat(min(1, max(0, date.timeIntervalSince(spanStart) / total)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer(minLength: 8)
                Text(Self.durationText(duration))
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(tint)
            }

            GeometryReader { geo in
                let w = geo.size.width
                let trackH: CGFloat = 34
                let x0 = fraction(start) * w
                let x1 = fraction(end) * w
                let capW = max(6, x1 - x0)

                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                        .frame(width: w, height: trackH)

                    hourTicks(width: w, height: trackH)

                    Capsule(style: .continuous)
                        .fill(LinearGradient(colors: [tint.opacity(0.92), tint.opacity(0.55)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: capW, height: trackH)
                        .offset(x: x0)
                }
                .frame(width: w, height: trackH)
            }
            .frame(height: 34)

            HStack {
                Text(Self.timeText(start, timeZoneIdentifier: timeZoneIdentifier))
                Spacer(minLength: 0)
                Text(Self.timeText(end, timeZoneIdentifier: timeZoneIdentifier))
            }
            .font(.system(size: 10, weight: .semibold).monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) from \(Self.timeText(start, timeZoneIdentifier: timeZoneIdentifier)) to \(Self.timeText(end, timeZoneIdentifier: timeZoneIdentifier)), duration \(Self.durationText(duration))")
    }

    private func hourTicks(width: CGFloat, height: CGFloat) -> some View {
        Canvas { context, size in
            let total = spanEnd.timeIntervalSince(spanStart)
            guard total > 0 else { return }
            var calendar = Calendar.current
            if let timeZoneIdentifier, let timeZone = TimeZone(identifier: timeZoneIdentifier) {
                calendar.timeZone = timeZone
            }
            // Keep decorations inside the rounded track.
            context.clip(to: Path(roundedRect: CGRect(origin: .zero, size: size),
                                  cornerRadius: 9, style: .continuous))

            // Day/night context bands: shade the hours the window spans that
            // fall in typical night (21:00-06:00) so a sleep/nap window visibly
            // sits in the dark hours. Pure clock derivation from the entered
            // times -- no sensor claim, no stage data.
            func isNight(_ date: Date) -> Bool {
                let hour = calendar.component(.hour, from: date)
                return hour >= 21 || hour < 6
            }
            let comps = calendar.dateComponents([.year, .month, .day, .hour], from: spanStart)
            if var cell = calendar.date(from: comps) {
                while cell < spanEnd {
                    let cellEnd = cell.addingTimeInterval(3600)
                    let x0 = CGFloat(max(0, cell.timeIntervalSince(spanStart)) / total) * size.width
                    let x1 = CGFloat(min(total, cellEnd.timeIntervalSince(spanStart)) / total) * size.width
                    if isNight(cell), x1 > x0 {
                        context.fill(Path(CGRect(x: x0, y: 0, width: x1 - x0, height: size.height)),
                                     with: .color(Color.indigo.opacity(0.09)))
                    }
                    cell = cellEnd
                }
            }

            // Hour tick hairlines.
            guard var tick = calendar.date(from: comps) else { return }
            if tick < spanStart { tick = tick.addingTimeInterval(3600) }
            while tick < spanEnd {
                let x = CGFloat(tick.timeIntervalSince(spanStart) / total) * size.width
                var path = Path()
                path.move(to: CGPoint(x: x, y: 4))
                path.addLine(to: CGPoint(x: x, y: size.height - 4))
                context.stroke(path,
                               with: .color(Color.primary.opacity(0.08)),
                               style: StrokeStyle(lineWidth: 1))
                tick = tick.addingTimeInterval(3600)
            }
        }
        .frame(width: width, height: height)
        .allowsHitTesting(false)
    }

    private static func durationText(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "--" }
        let minutes = Int((seconds / 60).rounded())
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours > 0 { return "\(hours)h \(remainder)m" }
        return "\(remainder)m"
    }

    private static func timeText(_ date: Date, timeZoneIdentifier: String?) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        if let timeZoneIdentifier, let timeZone = TimeZone(identifier: timeZoneIdentifier) {
            style.timeZone = timeZone
        }
        return date.formatted(style)
    }
}

/// Apple-Stocks-style plain-text selector (design direction 2026-08-05): a
/// spacious row of text items with a single subtle capsule that slides under
/// the selected one. Replaces congested `.pickerStyle(.segmented)` controls --
/// no heavy pill-in-pill container, generous tap targets, clearer selected
/// state, more breathing room.
struct AtriaTextSelector<Item: Hashable>: View {
    let items: [Item]
    let title: (Item) -> String
    @Binding var selection: Item

    @Namespace private var highlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items, id: \.self) { item in
                let isSelected = item == selection
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.28)) {
                        selection = item
                    }
                } label: {
                    Text(title(item))
                        .font(.subheadline.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                        .contentShape(Capsule())
                        .background {
                            if isSelected {
                                Capsule(style: .continuous)
                                    .fill(Color.primary.opacity(0.07))
                                    .matchedGeometryEffect(id: "atria.selector.highlight", in: highlight)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title(item))
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .accessibilityElement(children: .contain)
    }
}
