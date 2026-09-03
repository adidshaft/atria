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
    /// nil only when neither a payload nor a live probe could answer.
    let appGroupAvailable: Bool?

    /// Why there is no payload, in terms the reader can act on. The old copy
    /// told them to open the app once — advice that can only ever be read from
    /// inside the app, by someone who has already done exactly that
    /// (2026-09-03 render). nil once a payload exists.
    var missingPayloadDetail: String? {
        guard !hasSnapshot else { return nil }
        switch appGroupAvailable {
        case false:
            return "This build cannot reach the shared app group, so no payload can be written and the widgets stay unavailable."
        case true:
            return "The shared app group is reachable and nothing has been published yet. Atria publishes when today's numbers change; the widgets stay blank until that first delivery lands."
        case nil:
            return "No shared payload has been written, and the app group could not be checked from here. The widgets stay unavailable until a delivery succeeds."
        }
    }

    /// The snapshot answers for the payload that exists; a live probe answers
    /// for the surfaces themselves, which the app can check whether or not it
    /// has ever published. Reading only the snapshot reported three
    /// "Unknown"s on exactly the screen opened to find out (2026-09-03).
    init(snapshot: WidgetSnapshot?,
         layoutConfig: AtriaHomeLayoutConfig,
         live: WidgetSnapshotPublisher.Diagnostics? = nil) {
        let layout = layoutConfig.validated()
        hasSnapshot = snapshot != nil
        snapshotWrittenAt = snapshot?.createdAt
        schemaText = snapshot.map { String($0.schema) } ?? "--"
        appGroupAvailable = snapshot?.appGroupEnabled ?? live?.appGroupEnabled
        storageText = snapshot?.storage
            ?? live.map { $0.appGroupEnabled ? "Ready · nothing published yet" : "App group unavailable" }
            ?? "No shared payload"
        appGroupText = Self.availabilityText(appGroupAvailable)
        homeScreenTargetText = Self.availabilityText(
            snapshot?.widgetTargetPresent ?? live?.widgetTargetPresent
        )
        lockScreenTargetText = Self.availabilityText(
            snapshot?.complicationTargetPresent ?? live?.complicationTargetPresent
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
            layoutConfig: layoutConfig,
            live: WidgetSnapshotPublisher.diagnostics
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    AtriaWidgetDiagnosticHeader(
                        hasSnapshot: diagnostics.hasSnapshot,
                        missingPayloadDetail: diagnostics.missingPayloadDetail
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
    let missingPayloadDetail: String?

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

            Text(missingPayloadDetail
                 ?? "Atria can inspect delivery metadata here. Verify values and rings on the installed widgets, where WidgetKit applies their real freshness and expiry rules.")
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
