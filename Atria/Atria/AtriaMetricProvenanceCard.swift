import SwiftUI

/// Everything the compact card could not say, as a standalone view.
///
/// Extracted from `AtriaMetricDetailSheet`, where it lived as three private
/// methods. Two reasons: a self-contained card does not belong as private
/// methods on a sheet inside a 30k-line file, and while private it could not be
/// rendered in isolation -- which mattered, because it sits below the fold in a
/// sheet the simulator cannot scroll, so it had shipped without ever being seen.
/// As its own internal view it can be rendered straight to an image in a test.
///
/// Rows appear only when the underlying measurement exists. An absent row means
/// "not measured at this scope", which is why nothing here renders a zero as a
/// stand-in.
struct AtriaMetricProvenanceCard: View {
    let provenance: AtriaMetricProvenance

    var body: some View {
        VStack(alignment: .leading, spacing: AtriaDesignTokens.Spacing.md) {
            Text("Data quality")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 0) {
                // Two status axes, deliberately kept apart. The value carries the
                // metric's own graded zone (green/amber/red) and stays NEUTRAL
                // when it has no real grade -- colouring an ungraded number would
                // assert a standing the app has not earned. Confidence carries
                // how far the number can be trusted, which is green/amber only.
                row("Value", provenance.displayValue, tint: provenance.valueStatusTint)
                row("Confidence", provenance.level.displayName,
                    tint: provenance.level.statusTint)
                if let fraction = provenance.hrCoverageFraction {
                    row("HR coverage", "\(Int((fraction * 100).rounded()))%")
                }
                if let usesHRV = provenance.usesHRV {
                    row("HRV", usesHRV ? "Contributed" : "Not available")
                }
                if provenance.isLowerBound {
                    row("Reading", "Lower bound")
                }
                row("Source", provenance.sourceLabel)
                if let observedAt = provenance.observedAt {
                    // Time alone is ambiguous the moment a score is carried over
                    // from a previous night -- a bare "07:12" reads as this
                    // morning. Same-day stays time-only; anything older names
                    // its day.
                    let isToday = Calendar.current.isDateInToday(observedAt)
                    row("Updated",
                        isToday
                        ? observedAt.formatted(date: .omitted, time: .shortened)
                        : observedAt.formatted(date: .abbreviated, time: .shortened))
                }
            }

            if let reason = provenance.reducedConfidenceReason {
                note(title: "Limitation", body: reason)
            }
            if let hint = provenance.improvementHint {
                note(title: "Next step", body: hint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AtriaDesignTokens.Spacing.lg)
        .atriaCard(cornerRadius: AtriaDesignTokens.Radius.card, emphasis: .soft)
    }

    /// `tint` nil means this row has no graded status, and renders neutral.
    private func row(_ label: String, _ value: String, tint: Color? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AtriaDesignTokens.Spacing.md) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: AtriaDesignTokens.Spacing.sm)
            if let tint {
                // The dot carries the status without depending on colour alone
                // being legible against the value text, and keeps the row height
                // fixed whether or not a status exists.
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
            }
            Text(value)
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(tint ?? .primary)
                .multilineTextAlignment(.trailing)
        }
        .frame(minHeight: 32)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }

    private func note(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: AtriaDesignTokens.Spacing.xs) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(body)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
