import SwiftUI

// Smart Wake screen (design source: Claude Design "Atria App UI.dc.html",
// section 6c, 2026-08-01 design-parity slice 1).
//
// The design draws a projected stepped hypnogram for the night ahead. Atria
// has no forward sleep-stage projection model — the wake decision runs on
// LIVE `AtriaWakeAlarmWindowSample` readings once the wearer is actually
// asleep (`AtriaWakeAlarmPlanner.decision`). Rather than invent a projection,
// this screen renders the real 30-minute smart window and the hard wake-by
// deadline on a plain time axis and says exactly what picks the wake minute.
// The design's "Likely wake at 7:14 AM" prediction chip is withheld for the
// same reason: it needs a real in-window decision from live samples, which
// cannot exist before sleep.

/// Pure axis/window math, unit-testable without SwiftUI.
enum AtriaSmartWakePresentation {
    /// Axis span before wake-by. 9h covers the need math's full 6–10h clamp
    /// midrange plus wind-down, mirroring the design's evening-to-wake sweep.
    static let axisSpanMinutes = 9 * 60

    struct Tick: Equatable {
        let fraction: Double
        let label: String
    }

    /// Whole clock hours inside the span (thinned so the row never crowds),
    /// plus the exact wake-by label pinned at the right edge.
    static func ticks(wakeByMinutes: Int) -> [Tick] {
        let start = wakeByMinutes - axisSpanMinutes
        var interior: [Tick] = []
        var minute = Int(ceil(Double(start) / 60.0)) * 60
        while minute < wakeByMinutes {
            let fraction = Double(minute - start) / Double(axisSpanMinutes)
            if fraction > 0.04, fraction < 0.88 {
                interior.append(Tick(fraction: fraction,
                                     label: clockLabel(minutesOfDay: minute)))
            }
            minute += 60
        }
        let stride = max(1, Int((Double(interior.count) / 4.0).rounded(.up)))
        var ticks: [Tick] = []
        for (index, tick) in interior.enumerated() where index % stride == 0 {
            ticks.append(tick)
        }
        ticks.append(Tick(fraction: 1, label: clockLabel(minutesOfDay: wakeByMinutes)))
        return ticks
    }

    /// "11p" on the hour, "7:30a" otherwise — the hypnogram's axis grammar.
    static func clockLabel(minutesOfDay: Int) -> String {
        let normalized = ((minutesOfDay % 1440) + 1440) % 1440
        let hour24 = normalized / 60
        let minute = normalized % 60
        let suffix = hour24 >= 12 ? "p" : "a"
        var hour12 = hour24 % 12
        if hour12 == 0 { hour12 = 12 }
        guard minute > 0 else { return "\(hour12)\(suffix)" }
        return "\(hour12):" + String(format: "%02d", minute) + suffix
    }

    /// The real smart window (`AtriaWakeAlarmPlanner.smartWindowDuration`,
    /// ending at wake-by) as fractions of the axis.
    static var windowFractions: (start: Double, end: Double) {
        let windowMinutes = AtriaWakeAlarmPlanner.smartWindowDuration / 60
        return (1 - windowMinutes / Double(axisSpanMinutes), 1)
    }

    static func subtitle(for mode: AtriaWakeAlarmPlan.Mode, displayTime: String) -> String {
        switch mode {
        case .smartWindow:
            // Honest descope (2026-08-04): the in-window early-wake evaluator
            // exists but needs live same-night stage readings the pipeline
            // does not produce yet — tonight this behaves as a hard alarm.
            return "Wake by \(displayTime) · smart early wake in development"
        case .exactTime:
            return "Ring at \(displayTime) sharp"
        case .sleepNeedMet:
            return "Wake once tonight's need is filled — \(displayTime) is the backstop"
        }
    }

    static func axisExplainer(for mode: AtriaWakeAlarmPlan.Mode, displayTime: String) -> String {
        switch mode {
        case .smartWindow:
            return "The hard \(displayTime) wake-by always fires. Picking a lighter minute inside this window needs live stage readings, which Atria doesn't produce during the night yet — until it does, this behaves as a standard alarm."
        case .exactTime:
            return "One alarm at \(displayTime) — no early window."
        case .sleepNeedMet:
            return "Fires as soon as slept time reaches tonight's need; the \(displayTime) wake-by is the hard fallback."
        }
    }

    static func icon(for mode: AtriaWakeAlarmPlan.Mode) -> String {
        switch mode {
        case .smartWindow: return "sunrise.fill"
        case .exactTime: return "clock.fill"
        case .sleepNeedMet: return "moon.zzz.fill"
        }
    }

    /// Design row order (6c): Smart window leads, then Exact time, then
    /// Sleep-need met. Presentation-only — the model enum stays untouched.
    static let modeRowOrder: [AtriaWakeAlarmPlan.Mode] = [.smartWindow, .exactTime, .sleepNeedMet]
}

private struct AtriaVerticalLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: 0))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.height))
        return path
    }
}

/// The Smart Wake sheet: window axis, alarm-mode radios, wake-by editor, and
/// the arm control — all reading and writing the real `AtriaWakeAlarmStore`
/// defaults and scheduling through the real `AtriaWakeAlarmScheduler`.
struct AtriaSmartWakeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AtriaDefault(AtriaWakeAlarmStore.enabledKey) private var wakeAlarmEnabled: Bool = false
    @AtriaDefault(AtriaWakeAlarmStore.modeKey) private var wakeAlarmMode: String = AtriaWakeAlarmPlan.Mode.smartWindow.rawValue
    @AtriaDefault(AtriaWakeAlarmStore.wakeByMinutesKey) private var wakeByMinutes: Int = AtriaWakeAlarmPlan.defaultPlan.wakeByMinutes
    @State private var alarmStatusText: String?

    /// The design's smart-window cyan (#64D2FF) — same hue the hypnogram
    /// uses for REM.
    private static let cyan = Color(red: 0.392, green: 0.824, blue: 1.0)

    private var plan: AtriaWakeAlarmPlan {
        AtriaWakeAlarmPlan(mode: AtriaWakeAlarmPlan.Mode(rawValue: wakeAlarmMode) ?? .smartWindow,
                           wakeByHour: wakeByMinutes / 60,
                           wakeByMinute: wakeByMinutes % 60)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AtriaDesignTokens.Spacing.lg) {
                    windowCard
                    modeCard
                    wakeByCard
                    armButton
                    Text(alarmStatusText ?? "Phone alarm uses AlarmKit. The hard wake-by remains the fallback in every mode.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(AtriaDesignTokens.Spacing.lg)
            }
            .navigationTitle("Smart wake")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Window axis

    private var windowCard: some View {
        let ticks = AtriaSmartWakePresentation.ticks(wakeByMinutes: wakeByMinutes)
        let window = AtriaSmartWakePresentation.windowFractions
        let mode = plan.mode
        return VStack(alignment: .leading, spacing: AtriaDesignTokens.Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("Tonight's window")
                    .atriaEyebrow()
                Spacer(minLength: 0)
                Text("wake by \(plan.displayTime)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                    if mode == .smartWindow {
                        // The real 30-minute window: tinted band, dashed
                        // opening edge, solid deadline edge.
                        Rectangle()
                            .fill(Self.cyan.opacity(0.16))
                            .frame(width: proxy.size.width * (window.end - window.start))
                            .offset(x: proxy.size.width * window.start)
                        AtriaVerticalLine()
                            .stroke(Self.cyan.opacity(0.6),
                                    style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .frame(width: 1)
                            .offset(x: proxy.size.width * window.start)
                    }
                    AtriaVerticalLine()
                        .stroke(Self.cyan, style: StrokeStyle(lineWidth: 1.5))
                        .frame(width: 1.5)
                        .offset(x: proxy.size.width - 1.5)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .frame(height: 44)

            GeometryReader { proxy in
                ForEach(Array(ticks.enumerated()), id: \.offset) { _, tick in
                    Text(tick.label)
                        .font(.caption2.weight(.medium).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                        .position(x: min(max(proxy.size.width * tick.fraction, 12),
                                         proxy.size.width - 16),
                                  y: proxy.size.height / 2)
                }
            }
            .frame(height: 12)
            .accessibilityHidden(true)

            Text(AtriaSmartWakePresentation.axisExplainer(for: mode, displayTime: plan.displayTime))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .atriaInsetCard(tint: .cyan)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tonight's window. \(AtriaSmartWakePresentation.axisExplainer(for: mode, displayTime: plan.displayTime))")
    }

    // MARK: - Mode radios

    private var modeCard: some View {
        VStack(alignment: .leading, spacing: AtriaDesignTokens.Spacing.sm) {
            Text("Alarm mode")
                .atriaEyebrow()
            ForEach(AtriaSmartWakePresentation.modeRowOrder, id: \.rawValue) { mode in
                modeRow(mode)
            }
        }
        .padding(14)
        .atriaInsetCard(tint: .cyan)
    }

    private func modeRow(_ mode: AtriaWakeAlarmPlan.Mode) -> some View {
        let selected = wakeAlarmMode == mode.rawValue
        return Button {
            wakeAlarmMode = mode.rawValue
            AtriaWakeAlarmStore.save(plan)
            if wakeAlarmEnabled { scheduleWakeAlarm() }
        } label: {
            HStack(spacing: AtriaDesignTokens.Spacing.md) {
                Image(systemName: AtriaSmartWakePresentation.icon(for: mode))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Self.cyan)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(AtriaSmartWakePresentation.subtitle(for: mode, displayTime: plan.displayTime))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(selected ? Self.cyan : Color.secondary.opacity(0.5))
            }
            .padding(AtriaDesignTokens.Spacing.md)
            .background(selected ? Self.cyan.opacity(0.12) : Color.primary.opacity(0.03),
                        in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous)
                    .stroke(Self.cyan.opacity(selected ? 0.45 : 0), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(mode.title). \(AtriaSmartWakePresentation.subtitle(for: mode, displayTime: plan.displayTime)).\(selected ? " Selected." : "")")
    }

    // MARK: - Wake-by editor

    private var wakeByCard: some View {
        VStack(alignment: .leading, spacing: AtriaDesignTokens.Spacing.sm) {
            Text("Wake-by")
                .atriaEyebrow()
            Stepper(value: $wakeByMinutes, in: 0...(23 * 60 + 59), step: 5) {
                Text("Wake by \(plan.displayTime)")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
            .onChange(of: wakeByMinutes) { _, _ in
                AtriaWakeAlarmStore.save(plan)
                if wakeAlarmEnabled { scheduleWakeAlarm() }
            }
        }
        .padding(14)
        .atriaInsetCard(tint: .cyan)
    }

    // MARK: - Arm

    private var armButton: some View {
        Button {
            wakeAlarmEnabled.toggle()
            if wakeAlarmEnabled {
                scheduleWakeAlarm()
            } else {
                AtriaWakeAlarmScheduler.cancelLast()
                alarmStatusText = "Alarm off"
            }
        } label: {
            Label(wakeAlarmEnabled
                  ? "Alarm armed \u{00b7} turn off"
                  : (plan.mode == .smartWindow ? "Arm smart alarm" : "Arm alarm"),
                  systemImage: wakeAlarmEnabled ? "checkmark.circle.fill" : "alarm.fill")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .atriaCardAction(tint: .cyan)
    }

    private func scheduleWakeAlarm() {
        let plan = plan
        AtriaWakeAlarmStore.save(plan)
        Task {
            let result = await AtriaWakeAlarmScheduler.scheduleHardAlarm(plan: plan)
            await MainActor.run {
                switch result {
                case .scheduled(_, let fireDate):
                    alarmStatusText = "AlarmKit set \(fireDate.formatted(date: .omitted, time: .shortened))"
                    AtriaDebugLog("ATRIADBG wake_alarm_smart_sheet status=scheduled mode=%@ wake_by=%@ fire=%@",
                                  plan.mode.rawValue,
                                  plan.displayTime,
                                  fireDate.formatted(date: .numeric, time: .shortened))
                case .denied:
                    wakeAlarmEnabled = false
                    alarmStatusText = "Alarm permission needed"
                case .unavailable(let reason):
                    wakeAlarmEnabled = false
                    alarmStatusText = "Alarm unavailable"
                    AtriaDebugLog("ATRIADBG wake_alarm_smart_sheet status=unavailable reason=%@",
                                  reason)
                }
            }
        }
    }
}
