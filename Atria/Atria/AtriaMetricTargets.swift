import SwiftUI

enum AtriaMetricZoneLevel: String, Equatable, Codable {
    case green
    case yellow
    case red

    var tint: Color {
        switch self {
        case .green: return .green
        case .yellow: return .orange
        case .red: return .red
        }
    }

    var warningSystemImage: String? {
        switch self {
        case .green: return nil
        case .yellow: return "exclamationmark.circle"
        case .red: return "exclamationmark.triangle.fill"
        }
    }

    var label: String {
        switch self {
        case .green: return "In target"
        case .yellow: return "Watch"
        case .red: return "Low"
        }
    }
}

struct AtriaMetricTarget: Equatable, Codable {
    enum Direction: String, Equatable, Codable {
        case higherIsBetter
        case lowerIsBetter
        case targetBand
    }

    enum Source: String, Equatable, Codable {
        case researchDefault
        case personalBaseline
        case userEdited
    }

    let metricID: String
    let direction: Direction
    let greenLower: Double
    let yellowLower: Double
    let source: Source

    static let recoveryRecommended = AtriaMetricTarget(metricID: "recovery",
                                                       direction: .higherIsBetter,
                                                       greenLower: 67,
                                                       yellowLower: 34,
                                                       source: .researchDefault)

    static func recovery(greenLower: Double, yellowLower: Double) -> AtriaMetricTarget {
        let clampedYellow = min(max(yellowLower, 1), 99)
        let clampedGreen = min(max(greenLower, clampedYellow + 1), 100)
        let isDefault = Int(clampedGreen.rounded()) == 67 && Int(clampedYellow.rounded()) == 34
        return AtriaMetricTarget(metricID: "recovery",
                                 direction: .higherIsBetter,
                                 greenLower: clampedGreen,
                                 yellowLower: clampedYellow,
                                 source: isDefault ? .researchDefault : .userEdited)
    }

    var summaryText: String {
        "Green >= \(Int(greenLower.rounded()))%, yellow \(Int(yellowLower.rounded()))-\(Int(greenLower.rounded()) - 1)%, red < \(Int(yellowLower.rounded()))%"
    }
}

struct AtriaMetricZone: Equatable {
    let level: AtriaMetricZoneLevel
    let title: String
    let current: String
    let targetSummary: String
    let recommendation: String
    let disclaimer: String

    var tint: Color { level.tint }
    var warningSystemImage: String? { level.warningSystemImage }
    var showsWarning: Bool { warningSystemImage != nil }

    static let nonMedicalDisclaimer = "General wellness guidance only, not medical advice."
}

extension Metrics {
    static func recoveryZone(_ pct: Int?, target: AtriaMetricTarget = .recoveryRecommended) -> AtriaMetricZone? {
        guard let pct else { return nil }
        let level: AtriaMetricZoneLevel
        if Double(pct) >= target.greenLower {
            level = .green
        } else if Double(pct) >= target.yellowLower {
            level = .yellow
        } else {
            level = .red
        }

        let recommendation: String
        switch level {
        case .green:
            recommendation = "Recovery is inside your target zone. Match training load to how you feel."
        case .yellow:
            recommendation = "Low recovery -- keep today light, hydrate, and get to bed earlier."
        case .red:
            recommendation = "Very low recovery -- prioritize rest, hydration, and an easy day."
        }

        return AtriaMetricZone(level: level,
                               title: "Recovery target",
                               current: "\(pct)% recovery is \(level.label.lowercased()).",
                               targetSummary: target.summaryText,
                               recommendation: recommendation,
                               disclaimer: AtriaMetricZone.nonMedicalDisclaimer)
    }
}

struct AtriaMetricZoneInfoSheet: View {
    let zone: AtriaMetricZone

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: zone.warningSystemImage ?? "checkmark.circle.fill")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(zone.tint)
                        .frame(width: 42, height: 42)
                        .background(AtriaIconTileBackground(cornerRadius: 14, tint: zone.tint))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(zone.title)
                            .font(.headline.weight(.semibold))
                        Text(zone.current)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Target zone")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(zone.targetSummary)
                        .font(.body.weight(.semibold))
                }
                .padding(14)
                .atriaInsetCard(tint: zone.tint)

                VStack(alignment: .leading, spacing: 8) {
                    Text("What to do")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(zone.recommendation)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .atriaInsetCard(tint: zone.tint)

                Text(zone.disclaimer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle("Metric info")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
