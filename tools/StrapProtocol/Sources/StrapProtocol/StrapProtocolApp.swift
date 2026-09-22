import SwiftUI

@main
struct StrapProtocolApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 980, minHeight: 640)
        }
        .defaultSize(width: 1100, height: 720)
    }
}

struct ContentView: View {
    @StateObject private var link = StrapLink()

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            controlColumn
                .frame(width: 280)
            Divider()
            logColumn
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var controlColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(link.deviceName)
                    .font(.title3.weight(.semibold))
                Text(link.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(link.notifiesReady ? "Writes unlocked" : "Writes locked until notifies on")
                    .font(.caption2)
                    .foregroundStyle(link.notifiesReady ? .green : .orange)
                HStack(spacing: 8) {
                    Button(link.connected ? "Disconnect" : "Connect") {
                        link.connected ? link.disconnect() : link.connect()
                    }
                    .keyboardShortcut(.defaultAction)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Heart rate")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(link.heartRate.map(String.init) ?? "—")
                        .font(.system(size: 56, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("\(link.heartRateCount) samples")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    count("Compact 0x33", link.compactCount)
                    count("Backfill 0x34", link.backfillCount)
                    count("Leftover 2B", link.leftoverCount)
                    count("Proprietary HR", link.proprietaryHRCount)
                    if let battery = link.battery {
                        count("Battery", battery)
                    }
                }
                .font(.callout.monospacedDigit())

                Text(link.lastReply)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)

                commandGroup("Handshake") {
                    Button("Run init") { link.runInit() }
                    Button("Start history") { link.startHistory() }
                    Button("Abort history") { link.abortHistory() }
                    Button("Link check") { link.linkValid() }
                    Button("Strap battery") { link.readStrapBattery() }
                }
                commandGroup("Motion") {
                    Button("Compact on") { link.enableCompact() }
                    Button("Compact off") { link.disableCompact() }
                    Button("R10 on") { link.enableLeftover() }
                    Button("R10 off") { link.disableLeftover() }
                }
                commandGroup("Heart") {
                    Button("Strap HR on") { link.enableProprietaryHR() }
                    Button("Strap HR off") { link.disableProprietaryHR() }
                }
                Text("Standard heart rate stays on. Compact on is 6A. R10 on is 3F and turns itself off after leftover frames. 9A is not in this app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var logColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Packets")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(link.lines.reversed()) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(line.time)
                                .foregroundStyle(.secondary)
                                .frame(width: 92, alignment: .leading)
                            Text(line.kind)
                                .frame(width: 120, alignment: .leading)
                            Text(line.detail)
                                .textSelection(.enabled)
                        }
                        .font(.system(size: 12, design: .monospaced))
                    }
                }
                .padding(12)
            }
        }
    }

    private func count(_ label: String, _ value: Int) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text("\(value)")
        }
    }

    private func commandGroup(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}
