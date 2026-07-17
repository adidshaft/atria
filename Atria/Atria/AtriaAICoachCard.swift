import SwiftUI

struct AtriaAICoachCard: View, Equatable {
    let context: AtriaCoachContext
    let preparedPayload: AtriaCoachPayload?
    let settings: AtriaAICoachSettings
    let hasAPIKey: Bool

    @State private var answer = AtriaCoachAnswer(title: "Preparing your summary",
                                                 detail: "Using your latest Atria data.",
                                                 disclosure: "",
                                                 networkPolicy: .none)
    @State private var payload: AtriaCoachPayload?
    @State private var fabricationFlags: [String] = []
    @State private var showsPayloadAudit = false

    static func == (lhs: AtriaAICoachCard, rhs: AtriaAICoachCard) -> Bool {
        lhs.context == rhs.context
            && lhs.preparedPayload == rhs.preparedPayload
            && lhs.settings == rhs.settings
            && lhs.hasAPIKey == rhs.hasAPIKey
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "brain.head.profile")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.indigo)
                    .frame(width: 38, height: 38)
                    .background(AtriaIconTileBackground(cornerRadius: 12, tint: .indigo))

                Text("Coach")
                    .font(.subheadline.weight(.semibold))

                Spacer(minLength: 8)

                Text(modeLabel)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.indigo)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.indigo.opacity(0.12), in: Capsule())
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(displayTitle)
                    .font(.footnote.weight(.semibold))
                Text(displayDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    if let payload {
                        Button {
                            showsPayloadAudit = true
                        } label: {
                            Label("Sources", systemImage: "checkmark.shield")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.indigo)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(payload.receiptSummary)
                        .accessibilityHint("Opens the exact Atria data used for this answer.")
                    }
                    if !fabricationFlags.isEmpty {
                        Label("Check figures", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Metrics.electricYellow)
                    }
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

    private var modeLabel: String {
        switch settings.mode {
        case .off: return "Off"
        case .local: return "On-device"
        case .cloud: return settings.cloudProvider.title
        }
    }

    private var displayTitle: String {
        answer.networkPolicy == .cloudDisabled ? "Cloud coach isn't available yet" : answer.title
    }

    private var displayDetail: String {
        answer.networkPolicy == .cloudDisabled
            ? "Switch to On-device in Settings for private summaries now."
            : answer.detail
    }

    private var refreshID: String {
        "\(settings.mode.rawValue)-\(settings.cloudProvider.rawValue)-\(hasAPIKey)-\(context)-\(preparedPayload?.now ?? "legacy")-\(preparedPayload?.last7.count ?? 0)"
    }

    @MainActor
    private func refreshAnswer() async {
        guard let provider = AtriaCoachProviderFactory.make(settings: settings, hasAPIKey: hasAPIKey) else {
            answer = AtriaCoachAnswer(title: "Coach off",
                                      detail: "Turn it on in Settings when you want summaries.",
                                      disclosure: "",
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
