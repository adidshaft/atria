import SwiftUI

struct AtriaBackdropLayer: View, Equatable {
    let isDark: Bool
    let reduceTransparency: Bool

    var body: some View {
        ZStack {
            if reduceTransparency {
                reducedTransparencyFill
            } else {
                LinearGradient(colors: gradientColors,
                               startPoint: .topLeading,
                               endPoint: .bottomTrailing)

                if isDark {
                    Rectangle()
                        .fill(
                            RadialGradient(colors: [accentOne, .clear],
                                           center: .topTrailing,
                                           startRadius: 18,
                                           endRadius: 210)
                        )

                    Rectangle()
                        .fill(
                            RadialGradient(colors: [accentTwo, .clear],
                                           center: .bottomLeading,
                                           startRadius: 22,
                                           endRadius: 220)
                        )

                    LinearGradient(colors: [
                        Color.white.opacity(0.025),
                        Color.clear,
                        Color.black.opacity(0.22)
                    ], startPoint: .top, endPoint: .bottom)
                } else {
                    RadialGradient(colors: [accentOne, accentOne.opacity(0.10), .clear],
                                   center: .center,
                                   startRadius: 12,
                                   endRadius: 180)
                        .frame(width: 240, height: 240)
                        .offset(x: 74, y: -78)
                }
            }
        }
    }

    private var reducedTransparencyFill: Color {
        isDark
            ? Color(red: 0.018, green: 0.023, blue: 0.032)
            : Color(red: 0.950, green: 0.960, blue: 0.990)
    }

    private var gradientColors: [Color] {
        if isDark {
            return [
                Color(red: 0.018, green: 0.023, blue: 0.032),
                Color(red: 0.024, green: 0.031, blue: 0.043),
                Color(red: 0.016, green: 0.021, blue: 0.030)
            ]
        }
        return [
            Color(red: 0.95, green: 0.96, blue: 0.99),
            Color(red: 0.90, green: 0.93, blue: 0.98),
            Color(red: 0.96, green: 0.95, blue: 0.93)
        ]
    }

    private var accentOne: Color {
        isDark ? Color.cyan.opacity(0.05) : Color.white.opacity(0.36)
    }

    private var accentTwo: Color {
        Color.blue.opacity(0.04)
    }
}

struct AtriaHeaderTitleBlock: View, Equatable {
    let headline: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Atria")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
            Text(headline)
                .font(.footnote)
                .foregroundStyle(.secondary.opacity(0.9))
                .lineLimit(2)
                .frame(maxWidth: 280, alignment: .leading)
        }
    }
}

struct AtriaConnectionGuideContext: Equatable {
    let hasEverConnected: Bool
    let attempts: Int
    let failures: Int
    let lastStatus: String
    let lastReason: String

    var isFirstHandoff: Bool {
        !hasEverConnected
    }

    var flowLabel: String {
        isFirstHandoff ? "First setup" : "Reconnect"
    }

    var progressLabel: String {
        if hasEverConnected {
            return "Reconnect is automatic now"
        }
        if attempts == 0 {
            return "Waiting to start first setup"
        }
        if failures == 0 {
            return "Automatic setup in progress"
        }
        return "Still trying automatically"
    }

    var progressDetail: String {
        if hasEverConnected {
            return "Atria keeps reconnecting in the background and saves what the strap makes available."
        }
        if attempts == 0 {
            return "Atria starts scanning when Bluetooth is available and keeps trying without requiring the screen to stay awake."
        }
        return "Attempt \(attempts) is the latest automatic pass. Keep the strap nearby; Atria will continue reconnecting."
    }

    var userStatusLabel: String {
        "\(lastStatus) • \(lastReason.replacingOccurrences(of: "_", with: " "))"
    }

    var actionSummary: String {
        if hasEverConnected {
            return "You can lock the phone after setup; Atria resumes from saved sessions and background reconnects."
        }
        return "After the first successful connection, Atria handles reconnects and saved-session recovery automatically."
    }
}

struct AtriaHomeObservers: View {
    @ObservedObject var statusStore: AtriaHomeModel.StatusStore
    @ObservedObject var snapshotStore: AtriaHomeModel.SnapshotStore
    let onStatusChange: (WhoopBLEManager.Status) -> Void
    let onDiagnosticsReady: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: statusStore.state.status) { _, status in
                onStatusChange(status)
            }
            .onChange(of: snapshotStore.diagnosticsReady) { _, ready in
                guard ready else { return }
                onDiagnosticsReady()
            }
    }
}

extension WhoopBLEManager.Status {
    var logToken: String {
        switch self {
        case .connecting:
            return "connecting"
        case .connected:
            return "connected"
        case .disconnected:
            return "disconnected"
        case .poweredOff:
            return "powered_off"
        case .scanning:
            return "scanning"
        }
    }
}
