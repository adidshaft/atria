import SwiftUI

struct AtriaAICoachCard: View, Equatable {
    let context: AtriaCoachContext
    let preparedPayload: AtriaCoachPayload?
    let settings: AtriaAICoachSettings
    let hasAPIKey: Bool
    let onSettingsChange: (AtriaAICoachSettings) -> Void
    let onSaveAPIKey: (String) -> Void
    let onDeleteAPIKey: () -> Void

    @State private var answer = AtriaCoachAnswer(title: "Coach off",
                                                 detail: "Enable local mode for an offline summary, or review bring-your-own-key cloud mode when a provider client is available.",
                                                 disclosure: "Off by default.",
                                                 networkPolicy: .none)
    @State private var payload: AtriaCoachPayload?
    @State private var fabricationFlags: [String] = []
    @State private var apiKeyDraft = ""
    @State private var showsPayloadAudit = false

    static func == (lhs: AtriaAICoachCard, rhs: AtriaAICoachCard) -> Bool {
        lhs.context == rhs.context
            && lhs.preparedPayload == rhs.preparedPayload
            && lhs.settings == rhs.settings
            && lhs.hasAPIKey == rhs.hasAPIKey
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "brain.head.profile")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.indigo)
                    .frame(width: 38, height: 38)
                    .background(AtriaIconTileBackground(cornerRadius: 12, tint: .indigo))

                VStack(alignment: .leading, spacing: 3) {
                    Text("AI coach")
                        .font(.subheadline.weight(.semibold))
                    Text(settings.mode == .off ? "Off by default" : answer.disclosure)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Picker("Coach mode", selection: modeBinding) {
                ForEach(AtriaAICoachSettings.Mode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if settings.mode == .cloud {
                cloudControls
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(answer.title)
                    .font(.footnote.weight(.semibold))
                Text(answer.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let payload {
                    Button {
                        showsPayloadAudit = true
                    } label: {
                        Text(payload.receiptSummary)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.indigo)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the exact data sent to the coach.")
                }
                if !fabricationFlags.isEmpty {
                    Text("⚠ Contains figures not from your data")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.yellow)
                }
            }
            .padding(10)
            .atriaInsetCard(cornerRadius: 14, tint: .indigo)
        }
        .padding(14)
        .atriaCard(emphasis: .soft)
        .task(id: refreshID) {
            await refreshAnswer()
        }
        .sheet(isPresented: $showsPayloadAudit) {
            if let payload {
                AtriaCoachPayloadAuditSheet(payload: payload)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private var cloudControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Provider", selection: providerBinding) {
                ForEach(AtriaAICoachSettings.CloudProvider.allCases, id: \.self) { provider in
                    Text(provider.title).tag(provider)
                }
            }
            .pickerStyle(.segmented)

            SecureField(hasAPIKey ? "API key saved" : "Paste API key", text: $apiKeyDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .privacySensitive()
                .font(.caption)
                .padding(10)
                .atriaInsetCard(cornerRadius: 14, tint: .indigo)

            HStack(spacing: 8) {
                Button {
                    onSaveAPIKey(apiKeyDraft)
                    apiKeyDraft = ""
                } label: {
                    Text("Save key")
                        .frame(maxWidth: .infinity)
                }
                .atriaCardAction(tint: .indigo)

                if hasAPIKey {
                    Button {
                        apiKeyDraft = ""
                        onDeleteAPIKey()
                    } label: {
                        Text("Remove key")
                            .frame(maxWidth: .infinity)
                    }
                    .atriaCardAction(prominent: false, tint: .gray)
                }
            }

            Text("Cloud mode is opt-in. This build stores your key locally and does not send metrics until a reviewed \(settings.cloudProvider.title) client is enabled.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var modeBinding: Binding<AtriaAICoachSettings.Mode> {
        Binding(
            get: { settings.mode },
            set: { mode in
                var next = settings
                next.mode = mode
                onSettingsChange(next)
            }
        )
    }

    private var providerBinding: Binding<AtriaAICoachSettings.CloudProvider> {
        Binding(
            get: { settings.cloudProvider },
            set: { provider in
                var next = settings
                next.cloudProvider = provider
                onSettingsChange(next)
            }
        )
    }

    private var refreshID: String {
        "\(settings.mode.rawValue)-\(settings.cloudProvider.rawValue)-\(hasAPIKey)-\(context)-\(preparedPayload?.now ?? "legacy")-\(preparedPayload?.last7.count ?? 0)"
    }

    @MainActor
    private func refreshAnswer() async {
        guard let provider = AtriaCoachProviderFactory.make(settings: settings, hasAPIKey: hasAPIKey) else {
            answer = AtriaCoachAnswer(title: "Coach off",
                                      detail: "Enable local mode for an offline summary, or keep cloud mode off until a reviewed provider client is available.",
                                      disclosure: "Off by default.",
                                      networkPolicy: .none)
            payload = nil
            fabricationFlags = []
            return
        }
        let sentPayload = preparedPayload ?? AtriaCoachPayload.legacy(context: context)
        payload = sentPayload
        #if DEBUG
        if Self.debugShowsPayloadAuditFixture(arguments: ProcessInfo.processInfo.arguments) {
            showsPayloadAudit = true
        }
        if Self.debugShowsFlaggedReplyFixture(arguments: ProcessInfo.processInfo.arguments) {
            answer = AtriaCoachAnswer(title: "Check this reply",
                                      detail: "Your RHR was 49 bpm.",
                                      disclosure: "\(sentPayload.receiptSummary). Debug fixture plants an invented number.",
                                      networkPolicy: .offlineOnly)
            fabricationFlags = AtriaCoachPayload.fabricationFlags(response: "\(answer.title) \(answer.detail)",
                                                                  payload: sentPayload)
            return
        }
        #endif
        answer = await provider.answer(payload: sentPayload, context: context)
        fabricationFlags = AtriaCoachPayload.fabricationFlags(response: "\(answer.title) \(answer.detail)",
                                                              payload: sentPayload)
    }

    #if DEBUG
    private static func debugShowsFlaggedReplyFixture(arguments: [String]) -> Bool {
        guard let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture") else { return false }
        let valueIndex = arguments.index(after: fixtureIndex)
        return arguments.indices.contains(valueIndex)
            && arguments[valueIndex] == "ai-coach-flagged"
    }

    private static func debugShowsPayloadAuditFixture(arguments: [String]) -> Bool {
        guard let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture") else { return false }
        let valueIndex = arguments.index(after: fixtureIndex)
        return arguments.indices.contains(valueIndex)
            && arguments[valueIndex] == "ai-coach-audit"
    }
    #endif
}

private struct AtriaCoachPayloadAuditSheet: View {
    let payload: AtriaCoachPayload
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Sent context") {
                    ForEach(Array(payload.auditLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.body.monospacedDigit())
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Coach context")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
