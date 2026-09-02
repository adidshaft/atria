import SwiftUI

// Live set-logging surface (design source: Claude Design "Atria App
// UI.dc.html", section 7a, 2026-08-01 design-parity slice 2): rest ring with
// the real per-exercise target, the SET/WEIGHT/REPS/RPE table with its done
// and PR status column, and the amber steppers.
//
// Everything reads the workout's real `LoggedSet` array and the persisted
// per-exercise rest override. A PR badge only appears when the set actually
// beats the saved `StrengthPersonalRecords`, RPE renders "--" until the wearer
// enters one, and the heart-rate line under the ring shows the live strap
// reading or says there isn't one.

enum AtriaStrengthSetTablePresentation {
    struct Row: Identifiable, Equatable {
        let id: UUID
        let number: Int
        let weightText: String
        let repsText: String
        let rpeText: String
        let isPersonalRecord: Bool
        let isEditing: Bool
    }

    /// Sets of one exercise inside the current workout, numbered in the order
    /// they were logged.
    static func rows(sets: [LoggedSet],
                     exercise: String,
                     records: StrengthPersonalRecords,
                     editingSetID: UUID?) -> [Row] {
        let key = AtriaStrengthLog.normalized(exercise)
        var rows: [Row] = []
        // Records accumulate set by set so a PR badge means "beat everything
        // saved before this set", not "beats the workout's own final best".
        var running = records
        for set in sets where AtriaStrengthLog.normalized(set.exercise) == key {
            let isRecord = AtriaStrengthLog.isPR(set, against: running)
            running.accept(set)
            rows.append(Row(id: set.id,
                            number: rows.count + 1,
                            weightText: weightCell(set.weightKg),
                            repsText: set.reps.map(String.init) ?? "--",
                            rpeText: rpeText(set.rpe),
                            isPersonalRecord: isRecord,
                            isEditing: set.id == editingSetID))
        }
        return rows
    }

    static func weightCell(_ weightKg: Double?) -> String {
        guard let weightKg else { return "--" }
        let rounded = (weightKg * 10).rounded() / 10
        if abs(rounded - rounded.rounded()) < 0.05 {
            return "\(Int(rounded.rounded()))"
        }
        return String(format: "%.1f", rounded)
    }

    static func rpeText(_ rpe: Double?) -> String {
        guard let rpe else { return "--" }
        let rounded = (rpe * 2).rounded() / 2
        if abs(rounded - rounded.rounded()) < 0.05 {
            return "\(Int(rounded.rounded()))"
        }
        return String(format: "%.1f", rounded)
    }

    /// mm:ss remaining on the rest timer.
    static func restRemainingText(now: Date, end: Date) -> String {
        let remaining = max(0, Int(end.timeIntervalSince(now).rounded()))
        return String(format: "%d:%02d", remaining / 60, remaining % 60)
    }

    /// 1 at the start of the rest, 0 when it elapses.
    static func restFraction(now: Date, end: Date, target: TimeInterval) -> Double {
        guard target > 0 else { return 0 }
        let remaining = max(0, end.timeIntervalSince(now))
        return min(max(remaining / target, 0), 1)
    }
}

/// The rest ring, its target copy, and the two rest controls. Driven by the
/// workout's real rest deadline; when no rest is running it states the target
/// instead of animating a countdown that isn't happening.
struct AtriaStrengthRestPanel: View {
    let exercise: String
    let restEndsAt: Date?
    let targetSeconds: TimeInterval
    let onSubtract15: () -> Void
    let onSkip: () -> Void
    let heartRateLine: String

    private var targetText: String {
        let total = Int(targetSeconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    var body: some View {
        HStack(spacing: AtriaDesignTokens.Spacing.lg) {
            ring
            VStack(alignment: .leading, spacing: AtriaDesignTokens.Spacing.sm) {
                Text("Target \(targetText) between working sets.")
                    .font(.caption.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(heartRateLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if restEndsAt != nil {
                    HStack(spacing: AtriaDesignTokens.Spacing.sm) {
                        restChip(title: "\u{2212}15s", action: onSubtract15)
                        restChip(title: "Skip", action: onSkip)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(AtriaDesignTokens.Spacing.md)
        .atriaInsetCard(cornerRadius: AtriaDesignTokens.Radius.tile, tint: AtriaStrengthPalette.amber)
    }

    @ViewBuilder
    private var ring: some View {
        if let restEndsAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                AtriaStrengthRestRing(
                    fraction: AtriaStrengthSetTablePresentation.restFraction(now: context.date,
                                                                            end: restEndsAt,
                                                                            target: targetSeconds),
                    centerText: AtriaStrengthSetTablePresentation.restRemainingText(now: context.date,
                                                                                    end: restEndsAt),
                    caption: "REST"
                )
            }
            .accessibilityLabel("Rest timer running for \(exercise)")
        } else {
            AtriaStrengthRestRing(fraction: 0, centerText: targetText, caption: "TARGET")
                .accessibilityLabel("Rest target \(targetText)")
        }
    }

    private func restChip(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.bold).monospacedDigit())
                .padding(.horizontal, 12)
                .frame(minHeight: 38)
                .background(.primary.opacity(0.08), in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct AtriaStrengthRestRing: View {
    let fraction: Double
    let centerText: String
    let caption: String

    var body: some View {
        ZStack {
            Circle()
                .stroke(AtriaStrengthPalette.amber.opacity(0.16), lineWidth: 9)
            // No rest running means no arc at all — not a hairline that reads
            // like a timer about to start.
            if fraction > 0.001 {
                Circle()
                    .trim(from: 0, to: min(fraction, 1))
                    .stroke(AtriaStrengthPalette.amber,
                            style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 1) {
                Text(centerText)
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(caption)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 96, height: 96)
        .accessibilityElement(children: .ignore)
    }
}

/// Live heart-rate line for the rest panel. Its own leaf so a 1 Hz strap
/// publication redraws one caption instead of the whole logging sheet.
struct AtriaStrengthRestHeartRateHost: View {
    @ObservedObject var pulseStore: AtriaHomeModel.PulseLiveStore
    let exercise: String
    let restEndsAt: Date?
    let targetSeconds: TimeInterval
    let onSubtract15: () -> Void
    let onSkip: () -> Void

    var body: some View {
        AtriaStrengthRestPanel(exercise: exercise,
                               restEndsAt: restEndsAt,
                               targetSeconds: targetSeconds,
                               onSubtract15: onSubtract15,
                               onSkip: onSkip,
                               heartRateLine: heartRateLine)
    }

    private var heartRateLine: String {
        let heartRate = pulseStore.state.heartRate
        guard heartRate > 0 else { return "No live heart rate from the strap right now." }
        return "Heart rate \(heartRate) bpm now."
    }
}

/// SET / WEIGHT / REPS / RPE table with the design's status column. The
/// pending row shows what the steppers will log next — it is input, not a
/// recorded set, and is drawn in the amber active style.
struct AtriaStrengthSetTable: View {
    let rows: [AtriaStrengthSetTablePresentation.Row]
    let pendingWeightText: String
    let pendingRepsText: String
    let pendingRPEText: String

    private let columns: [GridItem] = [
        GridItem(.fixed(28), spacing: 6, alignment: .leading),
        GridItem(.flexible(), spacing: 6, alignment: .leading),
        GridItem(.flexible(), spacing: 6, alignment: .leading),
        GridItem(.fixed(52), spacing: 6, alignment: .leading),
        GridItem(.fixed(30), spacing: 0, alignment: .trailing)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 0) {
            headerCell("SET")
            headerCell("WEIGHT")
            headerCell("REPS")
            headerCell("RPE")
            headerCell("")

            ForEach(rows) { row in
                cell("\(row.number)", emphasized: false)
                weightCell(row)
                cell(row.repsText, emphasized: true)
                cell(row.rpeText, emphasized: false)
                status(row)
            }

            cell("\(rows.count + 1)", emphasized: false)
            pendingWeightCell
            cell(pendingRepsText, emphasized: true)
            cell(pendingRPEText, emphasized: false)
            Text("\u{2013}")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .trailing)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Logged sets table. \(rows.count) sets logged.")
    }

    private func headerCell(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.bold))
            .kerning(0.6)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
    }

    private func cell(_ text: String, emphasized: Bool) -> some View {
        Text(text)
            .font(.system(size: 14, weight: emphasized ? .bold : .semibold))
            .monospacedDigit()
            .foregroundStyle(text == "--" ? Color.secondary : Color.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(.primary.opacity(0.08))
                    .frame(height: 0.5)
            }
    }

    private func weightCell(_ row: AtriaStrengthSetTablePresentation.Row) -> some View {
        HStack(spacing: 0) {
            Text(row.weightText)
                .font(.system(size: 14, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(row.isEditing ? AtriaStrengthPalette.amberTint : .primary)
                .padding(.horizontal, row.isEditing ? 8 : 0)
                .padding(.vertical, row.isEditing ? 3 : 0)
                .background(row.isEditing ? AtriaStrengthPalette.amber.opacity(0.2) : .clear,
                            in: Capsule(style: .continuous))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.primary.opacity(0.08))
                .frame(height: 0.5)
        }
    }

    private var pendingWeightCell: some View {
        HStack(spacing: 0) {
            Text(pendingWeightText)
                .font(.system(size: 14, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(AtriaStrengthPalette.amberTint)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(AtriaStrengthPalette.amber.opacity(0.2), in: Capsule(style: .continuous))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.primary.opacity(0.08))
                .frame(height: 0.5)
        }
    }

    private func status(_ row: AtriaStrengthSetTablePresentation.Row) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            if row.isPersonalRecord {
                Text("PR")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(AtriaStrengthPalette.amberTint)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(AtriaStrengthPalette.amber.opacity(0.2),
                                in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(AtriaStrengthPalette.done)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .trailing)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.primary.opacity(0.08))
                .frame(height: 0.5)
        }
    }
}

/// Design stepper: 34pt minus, the value with its unit, 34pt amber plus.
struct AtriaStrengthStepper: View {
    let title: String
    let value: String
    let unit: String?
    let decrement: () -> Void
    let increment: () -> Void

    var body: some View {
        HStack(spacing: AtriaDesignTokens.Spacing.md) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)

            Button(action: decrement) {
                Image(systemName: "minus")
                    .font(.subheadline.weight(.black))
                    .frame(width: 44, height: 44)
                    .background(.primary.opacity(0.1), in: Circle())
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Decrease \(title)")

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 17, weight: .bold))
                    .monospacedDigit()
                if let unit {
                    Text(unit)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)

            Button(action: increment) {
                Image(systemName: "plus")
                    .font(.subheadline.weight(.black))
                    .frame(width: 44, height: 44)
                    .background(AtriaStrengthPalette.amber.opacity(0.2), in: Circle())
                    .foregroundStyle(AtriaStrengthPalette.amberTint)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Increase \(title)")
        }
        .padding(.horizontal, AtriaDesignTokens.Spacing.md)
        .padding(.vertical, 6)
        .background(.primary.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.inset, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityValue("\(value) \(unit ?? "")")
    }
}

/// "Back Squat · set 4" with the live pill from the design header.
struct AtriaStrengthLoggingHeader: View {
    let exercise: String
    let setNumber: Int
    let isRecording: Bool

    var body: some View {
        HStack(alignment: .center, spacing: AtriaDesignTokens.Spacing.sm) {
            VStack(alignment: .leading, spacing: 1) {
                Text(exercise)
                    .font(.headline.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("Set \(setNumber) this workout")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if isRecording {
                HStack(spacing: 5) {
                    Circle()
                        .fill(AtriaStrengthPalette.amber)
                        .frame(width: 6, height: 6)
                        .shadow(color: AtriaStrengthPalette.amber.opacity(0.8), radius: 4)
                    Text("Live")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(AtriaStrengthPalette.amberTint)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(AtriaStrengthPalette.amber.opacity(0.18), in: Capsule(style: .continuous))
                .overlay(Capsule(style: .continuous)
                    .strokeBorder(AtriaStrengthPalette.amber.opacity(0.4), lineWidth: 1))
            }
        }
    }
}
