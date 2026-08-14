import SwiftUI

/// Read-only delivery diagnostics for the widget pipeline.
///
/// This projection deliberately has no Recovery, strain, HRV, RHR, BPM, sleep,
/// step, ring-fill, zone, or freshness fields. WidgetKit owns presentation and
/// expiry of those values; duplicating that policy in the app created a second
/// renderer that could disagree with the installed widgets it claimed to prove.
struct AtriaWidgetProofDiagnostics: Equatable {
    let hasSnapshot: Bool
    let snapshotWrittenAt: Date?
    let schemaText: String
    let storageText: String
    let appGroupText: String
    let homeScreenTargetText: String
    let lockScreenTargetText: String
    let configuredOrderText: String
    let ringCenterText: String
    let legendStyleText: String

    init(snapshot: WidgetSnapshot?, layoutConfig: AtriaHomeLayoutConfig) {
        let layout = layoutConfig.validated()
        hasSnapshot = snapshot != nil
        snapshotWrittenAt = snapshot?.createdAt
        schemaText = snapshot.map { String($0.schema) } ?? "--"
        storageText = snapshot?.storage ?? "No shared payload"
        appGroupText = Self.availabilityText(snapshot?.appGroupEnabled)
        homeScreenTargetText = Self.availabilityText(
            snapshot?.widgetTargetPresent
        )
        lockScreenTargetText = Self.availabilityText(
            snapshot?.complicationTargetPresent
        )
        configuredOrderText = (
            snapshot?.layoutGlanceMetrics ?? layout.glanceMetrics
        ).joined(separator: " / ")
        ringCenterText = snapshot?.layoutRingCenterMetric
            ?? layout.ringCenterMetric.rawValue
        legendStyleText = snapshot?.layoutLegendStatStyle
            ?? layout.legendStatStyle.rawValue
    }

    private static func availabilityText(_ available: Bool?) -> String {
        switch available {
        case true: return "Available"
        case false: return "Unavailable"
        case nil: return "Unknown"
        }
    }
}

struct AtriaWidgetProofSheet: View {
    let snapshot: WidgetSnapshot?
    let layoutConfig: AtriaHomeLayoutConfig

    @Environment(\.dismiss) private var dismiss

    private var diagnostics: AtriaWidgetProofDiagnostics {
        AtriaWidgetProofDiagnostics(
            snapshot: snapshot,
            layoutConfig: layoutConfig
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    AtriaWidgetDiagnosticHeader(
                        hasSnapshot: diagnostics.hasSnapshot
                    )
                    AtriaWidgetDiagnosticScopeCard()
                    AtriaWidgetTargetDiagnosticsCard(
                        homeScreenTargetText:
                            diagnostics.homeScreenTargetText,
                        lockScreenTargetText:
                            diagnostics.lockScreenTargetText,
                        appGroupText: diagnostics.appGroupText
                    )
                    AtriaWidgetPayloadDiagnosticsCard(
                        diagnostics: diagnostics
                    )
                }
                .padding(18)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Widget diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        // Retain the established identifier for existing UI automation while
        // the visible surface is honestly renamed from proof to diagnostics.
        .accessibilityIdentifier("atria-widget-proof-sheet")
    }
}

private struct AtriaWidgetDiagnosticHeader: View {
    let hasSnapshot: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(
                hasSnapshot
                    ? "Shared widget payload found"
                    : "Shared widget payload missing",
                systemImage: hasSnapshot
                    ? "checkmark.seal.fill"
                    : "exclamationmark.triangle.fill"
            )
            .font(.headline.weight(.semibold))
            .foregroundStyle(hasSnapshot ? .green : .orange)

            Text(hasSnapshot
                 ? "Atria can inspect delivery metadata here. Verify values and rings on the installed widgets, where WidgetKit applies their real freshness and expiry rules."
                 : "Open Atria once to publish a shared payload. Widgets remain unavailable until that delivery succeeds.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }
}

private struct AtriaWidgetDiagnosticScopeCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Diagnostic scope", systemImage: "wrench.and.screwdriver")
                .font(.headline.weight(.semibold))

            diagnosticLine(
                symbol: "checkmark.circle.fill",
                tint: .green,
                text: "Checks shared-payload delivery and bundled widget targets."
            )
            diagnosticLine(
                symbol: "xmark.circle.fill",
                tint: .secondary,
                text: "Does not preview metric values, rings, freshness, or Live Activity rendering."
            )
        }
        .atriaWidgetDiagnosticCard()
    }

    private func diagnosticLine(
        symbol: String,
        tint: Color,
        text: String
    ) -> some View {
        Label {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(tint)
        }
    }
}

private struct AtriaWidgetTargetDiagnosticsCard: View {
    let homeScreenTargetText: String
    let lockScreenTargetText: String
    let appGroupText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("System surfaces", systemImage: "square.grid.2x2")
                .font(.headline.weight(.semibold))
            AtriaWidgetDiagnosticFactRow(
                title: "Home Screen target",
                value: homeScreenTargetText
            )
            AtriaWidgetDiagnosticFactRow(
                title: "Lock Screen target",
                value: lockScreenTargetText
            )
            AtriaWidgetDiagnosticFactRow(
                title: "Shared App Group",
                value: appGroupText
            )
        }
        .atriaWidgetDiagnosticCard()
    }
}

private struct AtriaWidgetPayloadDiagnosticsCard: View {
    let diagnostics: AtriaWidgetProofDiagnostics

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Payload metadata", systemImage: "shippingbox")
                .font(.headline.weight(.semibold))
            AtriaWidgetDiagnosticFactRow(
                title: "Last payload write",
                value: payloadWriteText
            )
            AtriaWidgetDiagnosticFactRow(
                title: "Schema",
                value: diagnostics.schemaText
            )
            AtriaWidgetDiagnosticFactRow(
                title: "Storage",
                value: diagnostics.storageText
            )
            AtriaWidgetDiagnosticFactRow(
                title: "Configured order",
                value: diagnostics.configuredOrderText
            )
            AtriaWidgetDiagnosticFactRow(
                title: "Ring center",
                value: diagnostics.ringCenterText
            )
            AtriaWidgetDiagnosticFactRow(
                title: "Legend style",
                value: diagnostics.legendStyleText
            )
        }
        .atriaWidgetDiagnosticCard()
    }

    private var payloadWriteText: String {
        diagnostics.snapshotWrittenAt?.formatted(
            date: .abbreviated,
            time: .shortened
        ) ?? "Not published"
    }
}

private struct AtriaWidgetDiagnosticFactRow: View {
    let title: String
    let value: String

    var body: some View {
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
}

private extension View {
    func atriaWidgetDiagnosticCard() -> some View {
        padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
    }
}
