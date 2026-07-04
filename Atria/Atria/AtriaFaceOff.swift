import SwiftUI
import UIKit

/// Recovery Face-Off: a stateless friend comparison. The sender's last-7-day
/// recovery/strain/sleep summary is compressed into the link itself
/// (JSON -> zlib -> base64url, ~200-400 bytes), so no server, no account, and
/// no backend ever sees the data — it lives only in the link the user sends.
struct AtriaFaceOffPayload: Codable, Equatable, Identifiable {
    struct DayStat: Codable, Equatable {
        /// Days before `endEpochDay` (0 = most recent).
        let o: Int
        /// Recovery percent 1-99, nil while learning.
        let r: Int?
        /// Strain 0-21, tenths.
        let s: Double?
        /// Sleep hours, tenths.
        let z: Double?
    }

    static let currentVersion = 1
    static let maxNameLength = 24

    let v: Int
    let name: String
    /// Days since 1970 UTC of the newest stat, so both sides agree on alignment.
    let endEpochDay: Int
    let days: [DayStat]

    var id: String { "\(name)-\(endEpochDay)-\(days.count)" }

    var averageRecovery: Int? {
        let values = days.compactMap(\.r)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / values.count
    }

    var averageStrain: Double? {
        let values = days.compactMap(\.s)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    var averageSleepHours: Double? {
        let values = days.compactMap(\.z)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}

enum AtriaFaceOff {
    static let deepLinkToken = "compare"
    static let queryItemName = "d"

    /// Build the sender payload from saved daily metrics (last 7 days).
    static func makePayload(name: String, history: [SavedDailyMetric], now: Date = Date()) -> AtriaFaceOffPayload? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let recent = history
            .filter { calendar.startOfDay(for: $0.day) <= today }
            .sorted { $0.day > $1.day }
            .prefix(7)
        guard !recent.isEmpty, let newest = recent.first else { return nil }
        let endDay = epochDay(newest.day)
        var stats: [AtriaFaceOffPayload.DayStat] = []
        for metric in recent {
            let offset: Int = max(0, endDay - epochDay(metric.day))
            let strainTenths: Double? = metric.strain.map { ($0 * 10).rounded() / 10 }
            let sleepHoursTenths: Double? = metric.sleepDuration.map { duration in
                ((duration / 3600) * 10).rounded() / 10
            }
            stats.append(AtriaFaceOffPayload.DayStat(o: offset,
                                                     r: metric.recoveryPercent,
                                                     s: strainTenths,
                                                     z: sleepHoursTenths))
        }
        guard stats.contains(where: { $0.r != nil || $0.s != nil || $0.z != nil }) else { return nil }
        let cleanName = String(name.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(AtriaFaceOffPayload.maxNameLength))
        return AtriaFaceOffPayload(v: AtriaFaceOffPayload.currentVersion,
                                   name: cleanName.isEmpty ? "A friend" : cleanName,
                                   endEpochDay: endDay,
                                   days: stats)
    }

    static func url(for payload: AtriaFaceOffPayload) -> URL? {
        guard let encoded = encode(payload) else { return nil }
        var components = URLComponents()
        components.scheme = "atria"
        components.host = deepLinkToken
        components.queryItems = [URLQueryItem(name: queryItemName, value: encoded)]
        return components.url
    }

    static func payload(from url: URL) -> AtriaFaceOffPayload? {
        guard url.scheme?.lowercased() == "atria" else { return nil }
        let pieces = ([url.host].compactMap { $0 } + url.pathComponents.filter { $0 != "/" })
            .map { $0.lowercased() }
        guard pieces.contains(deepLinkToken) else { return nil }
        guard let encoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == queryItemName })?.value else { return nil }
        return decode(encoded)
    }

    static func encode(_ payload: AtriaFaceOffPayload) -> String? {
        guard let json = try? JSONEncoder().encode(payload),
              let compressed = try? (json as NSData).compressed(using: .zlib) as Data else { return nil }
        return compressed.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ encoded: String) -> AtriaFaceOffPayload? {
        var base64 = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard base64.utf8.count <= 4096,
              let compressed = Data(base64Encoded: base64),
              let json = try? (compressed as NSData).decompressed(using: .zlib) as Data,
              json.count <= 16_384,
              let raw = try? JSONDecoder().decode(AtriaFaceOffPayload.self, from: json) else { return nil }
        return sanitized(raw)
    }

    /// Defensive clamps against crafted links: version check, bounded counts,
    /// bounded values. A payload is data the user tapped, never trusted input.
    private static func sanitized(_ raw: AtriaFaceOffPayload) -> AtriaFaceOffPayload? {
        guard raw.v == AtriaFaceOffPayload.currentVersion,
              (1...14).contains(raw.days.count) else { return nil }
        let name = String(raw.name.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(AtriaFaceOffPayload.maxNameLength))
        let days = raw.days.prefix(14).map { day in
            AtriaFaceOffPayload.DayStat(o: min(max(day.o, 0), 30),
                                        r: day.r.map { min(max($0, 1), 99) },
                                        s: day.s.map { min(max($0, 0), 21) },
                                        z: day.z.map { min(max($0, 0), 16) })
        }
        return AtriaFaceOffPayload(v: raw.v,
                                   name: name.isEmpty ? "A friend" : name,
                                   endEpochDay: min(max(raw.endEpochDay, 0), 40_000),
                                   days: Array(days))
    }

    private static func epochDay(_ date: Date) -> Int {
        Int(date.timeIntervalSince1970 / 86_400)
    }
}

/// Side-by-side you-vs-friend comparison, with the reciprocity loop: the
/// receiver can send their own week back with one tap.
struct AtriaFaceOffView: View {
    let friend: AtriaFaceOffPayload
    let mine: AtriaFaceOffPayload?
    @Environment(\.dismiss) private var dismiss
    @State private var storyImage: UIImage?

    private var replyURL: URL? {
        mine.flatMap(AtriaFaceOff.url(for:))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Text("Recovery Face-Off")
                        .font(.title3.weight(.bold))

                    HStack(alignment: .top, spacing: 12) {
                        column(title: mine == nil ? "You" : "You",
                               payload: mine,
                               tint: .cyan)
                        column(title: friend.name,
                               payload: friend,
                               tint: .orange)
                    }

                    if let winner = weeklyWinnerText {
                        Text(winner)
                            .font(.subheadline.weight(.semibold))
                            .multilineTextAlignment(.center)
                    }

                    Text("This comparison came from the link itself — no account, no server, nothing shared beyond what your friend chose to send.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    if let replyURL {
                        ShareLink(item: replyURL) {
                            Label("Send yours back", systemImage: "arrow.uturn.left.circle.fill")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    if let storyImage {
                        ShareLink(item: Image(uiImage: storyImage),
                                  preview: SharePreview("Recovery Face-Off", image: Image(uiImage: storyImage))) {
                            Label("Share as story", systemImage: "camera.filters")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(20)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                storyImage = renderStoryImage()
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// Story-format (9:16) render of the head-to-head card — the Instagram
    /// surface of the challenge loop.
    @MainActor
    private func renderStoryImage() -> UIImage? {
        let content = VStack(spacing: 24) {
            Spacer(minLength: 0)
            Text("Recovery Face-Off")
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
            HStack(alignment: .top, spacing: 14) {
                column(title: "You", payload: mine, tint: .cyan)
                column(title: friend.name, payload: friend, tint: .orange)
            }
            if let winner = weeklyWinnerText {
                Text(winner)
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
            }
            Text("Atria · your data stays yours")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.55))
            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(width: 360, height: 640)
        .background(
            LinearGradient(colors: [Color(red: 0.05, green: 0.07, blue: 0.14),
                                    Color(red: 0.02, green: 0.03, blue: 0.07)],
                           startPoint: .top,
                           endPoint: .bottom)
        )
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 3
        return renderer.uiImage
    }

    private var weeklyWinnerText: String? {
        guard let mineAvg = mine?.averageRecovery, let friendAvg = friend.averageRecovery else { return nil }
        if mineAvg == friendAvg { return "Dead heat: \(mineAvg)% average recovery each." }
        let lead = abs(mineAvg - friendAvg)
        return mineAvg > friendAvg
            ? "You lead by \(lead)% average recovery this week."
            : "\(friend.name) leads by \(lead)% average recovery this week."
    }

    private func column(title: String, payload: AtriaFaceOffPayload?, tint: Color) -> some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let payload {
                AtriaMetricRing(label: "Recovery",
                                value: payload.averageRecovery.map { "\($0)%" } ?? "--",
                                fraction: payload.averageRecovery.map { Double($0) / 100 },
                                tint: tint,
                                size: 96)

                statRow(label: "Strain",
                        value: payload.averageStrain.map { String(format: "%.1f", $0) } ?? "--")
                statRow(label: "Sleep",
                        value: payload.averageSleepHours.map { String(format: "%.1f h", $0) } ?? "--")
                statRow(label: "Days", value: "\(payload.days.count)")
            } else {
                Text("Your week is still learning — wear the strap and check back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(14)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func statRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
    }
}
