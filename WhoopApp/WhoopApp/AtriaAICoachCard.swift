import SwiftUI

struct AtriaAICoachCard: View, Equatable {
    let context: AtriaCoachContext
    let settings: AtriaAICoachSettings
    let hasAPIKey: Bool
    let onSettingsChange: (AtriaAICoachSettings) -> Void
    let onSaveAPIKey: (String) -> Void
    let onDeleteAPIKey: () -> Void

    @State private var answer = AtriaCoachAnswer(title: "Coach off",
                                                 detail: "Enable local mode for an offline summary, or review bring-your-own-key cloud mode when a provider client is available.",
                                                 disclosure: "Off by default.",
                                                 networkPolicy: .none)
    @State private var apiKeyDraft = ""

    static func == (lhs: AtriaAICoachCard, rhs: AtriaAICoachCard) -> Bool {
        lhs.context == rhs.context
            && lhs.settings == rhs.settings
            && lhs.hasAPIKey == rhs.hasAPIKey
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
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
            }
            .padding(10)
            .atriaInsetCard(cornerRadius: 14, tint: .indigo)
        }
        .padding(14)
        .atriaRaisedCard(emphasis: .soft)
        .task(id: refreshID) {
            await refreshAnswer()
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
                Button("Save key") {
                    onSaveAPIKey(apiKeyDraft)
                    apiKeyDraft = ""
                }
                .buttonStyle(.glassProminent)
        .tint(.indigo)

                if hasAPIKey {
                    Button("Remove key") {
                        apiKeyDraft = ""
                        onDeleteAPIKey()
                    }
                    .buttonStyle(.glassProminent)
        .tint(.gray)
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
        "\(settings.mode.rawValue)-\(settings.cloudProvider.rawValue)-\(hasAPIKey)-\(context)"
    }

    @MainActor
    private func refreshAnswer() async {
        guard let provider = AtriaCoachProviderFactory.make(settings: settings, hasAPIKey: hasAPIKey) else {
            answer = AtriaCoachAnswer(title: "Coach off",
                                      detail: "Enable local mode for an offline summary, or keep cloud mode off until a reviewed provider client is available.",
                                      disclosure: "Off by default.",
                                      networkPolicy: .none)
            return
        }
        answer = await provider.answer(context: context)
    }
}
