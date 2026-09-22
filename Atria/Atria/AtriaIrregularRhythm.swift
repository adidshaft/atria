import Foundation
import SwiftUI

/// Honest AFib / irregular-rhythm education and a fail-closed pulse-timing check.
///
/// WHOOP 4 is optical PPG, not ECG. Atria never treats 1 Hz heart-rate samples
/// as a rhythm strip, never promotes a command echo into detection, and never
/// claims a diagnosis. High beat-to-beat variation can be healthy recovery
/// (respiratory sinus arrhythmia). The optional flag therefore requires a
/// dense, standard Heart Rate Measurement window whose successive differences
/// look random rather than regular or merely noisy.
enum AtriaIrregularRhythmCopy {
    static let title = "Irregular rhythm"
    static let cannotDiagnose = "Atria cannot diagnose AFib from this strap."
    static let notECG = "This strap measures pulse timing with light. That is not an ECG."
    static let talkToADoctor = "If you have questions about your heart rhythm, talk to a physician. Atria is not a medical device."
    static let watchLikeCaution = "Your pulse timing has shown irregular rhythm signs. This is not a diagnosis. If you have not already discussed heart rhythm with a physician, you should talk to your doctor."
    static let insufficient = "Not enough clean pulse timing to judge regularity."
    static let educationalDefinition = "Atrial fibrillation is an irregular heart rhythm diagnosed by a physician, usually with ECG. Optical pulse timing can sometimes look uneven for many reasons that are not AFib — breathing, motion, a loose strap, or healthy beat-to-beat variation."
}

enum AtriaIrregularRhythmNoteStore {
    static let physicianNoteKey = "atria.irregularRhythm.notedPhysicianAt"
    static let lastReadKey = "atria.irregularRhythm.lastReadAt"

    static func physicianNotedAt(defaults: UserDefaults = .standard) -> Date? {
        let value = defaults.double(forKey: physicianNoteKey)
        guard value > 0 else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    static func markPhysicianNoted(at date: Date = Date(),
                                   defaults: UserDefaults = .standard) {
        defaults.set(date.timeIntervalSince1970, forKey: physicianNoteKey)
    }

    static func clearPhysicianNote(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: physicianNoteKey)
    }

    static func markRead(at date: Date = Date(),
                         defaults: UserDefaults = .standard) {
        defaults.set(date.timeIntervalSince1970, forKey: lastReadKey)
    }

    static func lastReadAt(defaults: UserDefaults = .standard) -> Date? {
        let value = defaults.double(forKey: lastReadKey)
        guard value > 0 else { return nil }
        return Date(timeIntervalSince1970: value)
    }
}

enum AtriaIrregularRhythmAssessment {
    enum Outcome: Equatable {
        case insufficientEvidence
        case irregularRhythmSigns
    }

    struct Interval: Equatable, Sendable {
        let date: Date
        let milliseconds: Double
        let source: AtriaRRSourceProvenance?
    }

    struct Result: Equatable, Sendable {
        let outcome: Outcome
        let reason: String
        let largeSuccessiveDifferenceFraction: Double?
        let turningPointRatio: Double?

        var headline: String {
            switch outcome {
            case .insufficientEvidence:
                return AtriaCompactMetricPresentation.noValue
            case .irregularRhythmSigns:
                return "Signs"
            }
        }

        var detail: String {
            switch outcome {
            case .insufficientEvidence:
                return AtriaIrregularRhythmCopy.cannotDiagnose
            case .irregularRhythmSigns:
                return "Irregular signs · not a diagnosis"
            }
        }

        var caution: String {
            switch outcome {
            case .insufficientEvidence:
                return AtriaIrregularRhythmCopy.insufficient
            case .irregularRhythmSigns:
                return AtriaIrregularRhythmCopy.watchLikeCaution
            }
        }
    }

    static let minimumWindowSeconds: TimeInterval = 300
    static let maximumGapSeconds: TimeInterval = HRVSnapshot.maxReadyRRGapSeconds
    static let minimumQualifiedBeats = 150
    static let minimumSuccessiveDifferences = 120
    static let largeDifferenceFraction = 0.25
    static let maximumOutOfRangeFraction = 0.10
    static let minimumTurningPointRatio = 0.58
    static let maximumTurningPointRatio = 0.78
    static let restHeartRateRange = 45.0...100.0

    static func evaluate(
        samples: [AtriaBreathworkSession.RRSample],
        now: Date = Date()
    ) -> Result {
        evaluate(
            intervals: samples.map {
                Interval(date: $0.date, milliseconds: Double($0.ms), source: $0.source)
            },
            now: now
        )
    }

    static func evaluate(intervals: [Interval], now: Date = Date()) -> Result {
        let windowStart = now.addingTimeInterval(-minimumWindowSeconds)
        let window = intervals.filter { $0.date >= windowStart && $0.date <= now }
            .sorted { $0.date < $1.date }
        guard window.count >= 2 else {
            return insufficient("window")
        }

        var priorDate: Date?
        for sample in window {
            if let priorDate, sample.date < priorDate {
                return insufficient("order")
            }
            priorDate = sample.date
            guard sample.source == .standardHeartRateMeasurement2A37 else {
                return insufficient("provenance")
            }
        }

        var qualified: [Interval] = []
        var outOfRange = 0
        var previous: Interval?
        var maxGap: TimeInterval = 0
        for sample in window {
            if let previous {
                let gap = sample.date.timeIntervalSince(previous.date)
                if gap > maxGap { maxGap = gap }
            }
            if (300...2_000).contains(sample.milliseconds), sample.milliseconds.isFinite {
                qualified.append(sample)
            } else {
                outOfRange += 1
            }
            previous = sample
        }

        guard maxGap <= maximumGapSeconds else {
            return insufficient("gap")
        }
        guard qualified.count >= minimumQualifiedBeats else {
            return insufficient("beats")
        }
        let coverage = (qualified.last?.date.timeIntervalSince(qualified.first?.date ?? now) ?? 0)
            + ((qualified.first?.milliseconds ?? 0) / 1_000)
        guard coverage >= minimumWindowSeconds - 10 else {
            return insufficient("coverage")
        }

        let outOfRangeFraction = Double(outOfRange) / Double(window.count)
        guard outOfRangeFraction < maximumOutOfRangeFraction else {
            return insufficient("noise")
        }

        let meanMS = qualified.map(\.milliseconds).reduce(0, +) / Double(qualified.count)
        let impliedHR = 60_000 / meanMS
        guard restHeartRateRange.contains(impliedHR) else {
            return insufficient("rate")
        }

        var largeDifferences = 0
        var differenceCount = 0
        var values: [Double] = []
        values.reserveCapacity(qualified.count)
        var previousQualified: Interval?
        for sample in qualified {
            values.append(sample.milliseconds)
            guard let prior = previousQualified else {
                previousQualified = sample
                continue
            }
            let gap = sample.date.timeIntervalSince(prior.date)
            if gap <= 0 || gap > maximumGapSeconds {
                previousQualified = sample
                continue
            }
            differenceCount += 1
            let relative = abs(sample.milliseconds - prior.milliseconds) / prior.milliseconds
            if relative > 0.20 {
                largeDifferences += 1
            }
            previousQualified = sample
        }
        guard differenceCount >= minimumSuccessiveDifferences else {
            return insufficient("differences")
        }

        let largeFraction = Double(largeDifferences) / Double(differenceCount)
        guard let turningPointRatio = turningPointRatio(values),
              (minimumTurningPointRatio...maximumTurningPointRatio).contains(turningPointRatio) else {
            return Result(outcome: .insufficientEvidence,
                          reason: "pattern",
                          largeSuccessiveDifferenceFraction: largeFraction,
                          turningPointRatio: turningPointRatio(values))
        }
        guard largeFraction >= largeDifferenceFraction else {
            return Result(outcome: .insufficientEvidence,
                          reason: "regular",
                          largeSuccessiveDifferenceFraction: largeFraction,
                          turningPointRatio: turningPointRatio)
        }

        return Result(outcome: .irregularRhythmSigns,
                      reason: "irregular_successive_differences",
                      largeSuccessiveDifferenceFraction: largeFraction,
                      turningPointRatio: turningPointRatio)
    }

    static func turningPointRatio(_ values: [Double]) -> Double? {
        guard values.count >= 8 else { return nil }
        var turns = 0
        let interior = values.count - 2
        guard interior > 0 else { return nil }
        for index in 1..<(values.count - 1) {
            let left = values[index] - values[index - 1]
            let right = values[index + 1] - values[index]
            if left * right < 0 {
                turns += 1
            }
        }
        return Double(turns) / Double(interior)
    }

    private static func insufficient(_ reason: String) -> Result {
        Result(outcome: .insufficientEvidence,
               reason: reason,
               largeSuccessiveDifferenceFraction: nil,
               turningPointRatio: nil)
    }
}

struct AtriaIrregularRhythmNoteCard: View {
    @State private var physicianNotedAt: Date?
    @State private var lastReadAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: AtriaDesignTokens.Spacing.sm) {
            Text("YOUR NOTES")
                .font(.caption2.weight(.bold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Text(noteSummary)
                .font(.footnote)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Button(physicianNotedAt == nil
                   ? "Log that I talked with a physician"
                   : "Clear physician note") {
                if physicianNotedAt == nil {
                    AtriaIrregularRhythmNoteStore.markPhysicianNoted()
                } else {
                    AtriaIrregularRhythmNoteStore.clearPhysicianNote()
                }
                refresh()
            }
            .font(.footnote.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AtriaDesignTokens.Spacing.lg)
        .atriaCard(cornerRadius: AtriaDesignTokens.Radius.tile, emphasis: .soft)
        .onAppear {
            AtriaIrregularRhythmNoteStore.markRead()
            refresh()
        }
    }

    private var noteSummary: String {
        let read = lastReadAt.map {
            "Last opened \($0.formatted(date: .abbreviated, time: .omitted))."
        } ?? "You have not opened this note before."
        if let physicianNotedAt {
            return "\(read) You logged a physician conversation on \(physicianNotedAt.formatted(date: .abbreviated, time: .omitted))."
        }
        return "\(read) This stays on this iPhone. It is a reminder, not a medical record."
    }

    private func refresh() {
        physicianNotedAt = AtriaIrregularRhythmNoteStore.physicianNotedAt()
        lastReadAt = AtriaIrregularRhythmNoteStore.lastReadAt()
    }
}
