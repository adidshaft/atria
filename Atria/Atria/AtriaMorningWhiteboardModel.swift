import SwiftUI

/// Assessment P0.4 (2026-08-14): the morning whiteboard model — measured
/// numbers lead the day. Pure, unit-testable without SwiftUI; every band
/// comes from the SAME displayed baseline authority
/// (AtriaBaselineTargetSnapshot), the sleep row reads only the frozen need,
/// and nothing here recomputes.
///
/// 2026-08-28: the Today-screen whiteboard CARD retired in the owner's
/// stack audit (its rows duplicated the rings and glance tiles), but the
/// model stays load-bearing: WidgetSnapshot serializes its rows and tones
/// across the app→extension boundary for the widget face.
struct AtriaTodayMorningWhiteboardModel: Equatable {
    enum Tone: Equatable { case supportive, caution, strained, neutral }

    struct Row: Equatable, Identifiable {
        let id: String
        let systemImage: String
        let valuePhrase: String
        let sentence: String
        let tone: Tone
        let route: AtriaMetricDetailKind
        /// VoiceOver copy when the visible sentence is a shortened form
        /// (declutter R22): "calibrating" must survive in the spoken label
        /// even though the row shows only the progress count.
        var accessibilitySentence: String? = nil
    }

    let rows: [Row]

    static func make(hrvMS: Int?,
                     restingHR: Int?,
                     baseline: AtriaBaselineTargetSnapshot,
                     sleepDurationText: String?,
                     nightConfirmed: Bool?,
                     needHours: Double?,
                     yesterdayTRIMP: Double?,
                     yesterdayStrain: Double?,
                     yesterdayStrainIsPartial: Bool) -> AtriaTodayMorningWhiteboardModel {
        var rows: [Row] = []

        // HRV vs the 14–30 night personal band.
        let hrvSentence: String
        let hrvTone: Tone
        var hrvAccessibilitySentence: String? = nil
        // §13.3 (2026-08-14): z comes from the shared band authority so the
        // coach sentence and this row can never disagree.
        if let z = baseline.hrvBandZ(hrvMS: hrvMS),
           let mean = baseline.hrvLnMean,
           let sd = baseline.hrvLnSD {
            let lower = Int(exp(mean - sd).rounded())
            let upper = Int(exp(mean + sd).rounded())
            hrvSentence = "typical \(lower)–\(upper) ms"
            hrvTone = z >= -1 ? .supportive : (z >= -2 ? .caution : .strained)
        } else {
            hrvSentence = "\(min(baseline.hrvSampleCount, 14)) of 14 nights"
            hrvAccessibilitySentence = "calibrating · " + hrvSentence
            hrvTone = .neutral
        }
        rows.append(Row(id: "hrv",
                        systemImage: "waveform.path.ecg",
                        valuePhrase: hrvMS.map { "HRV \($0) ms" } ?? "HRV —",
                        sentence: hrvSentence,
                        tone: hrvTone,
                        route: .hrv,
                        accessibilitySentence: hrvAccessibilitySentence))

        // RHR vs the personal band (lower is supportive).
        let rhrSentence: String
        let rhrTone: Tone
        var rhrAccessibilitySentence: String? = nil
        if let z = baseline.restingBandZ(restingHR: restingHR),
           let mean = baseline.restingMean,
           let sd = baseline.restingSD {
            rhrSentence = "typical \(Int((mean - sd).rounded()))–\(Int((mean + sd).rounded())) bpm"
            rhrTone = z <= 1 ? .supportive : (z <= 2 ? .caution : .strained)
        } else {
            rhrSentence = "\(min(baseline.restingSampleCount, 14)) of 14 days"
            rhrAccessibilitySentence = "calibrating · " + rhrSentence
            rhrTone = .neutral
        }
        rows.append(Row(id: "rhr",
                        systemImage: "heart",
                        valuePhrase: restingHR.map { "RHR \($0) bpm" } ?? "RHR —",
                        sentence: rhrSentence,
                        tone: rhrTone,
                        route: .restingHeartRate,
                        accessibilitySentence: rhrAccessibilitySentence))

        // Sleep hours vs THAT night's frozen need — never a recomputation.
        let sleepSentence: String
        var sleepAccessibilitySentence: String? = nil
        if let needHours {
            sleepSentence = "of \(AtriaMetricFormat.sleepHours(needHours)) need"
        } else if nightConfirmed == true {
            // Declutter R22: the legacy-night reason is RELOCATED to the
            // spoken label (the sleep detail sheet the row routes to lives in
            // AtriaOverviewSections, outside this pass's files), not deleted.
            sleepSentence = "need unavailable"
            sleepAccessibilitySentence = "need unavailable for this legacy night"
        } else {
            sleepSentence = "awaiting tonight's sleep"
        }
        rows.append(Row(id: "sleep",
                        systemImage: "moon.zzz",
                        valuePhrase: sleepDurationText.map { "Slept \($0)" } ?? "Sleep —",
                        sentence: sleepSentence,
                        tone: .neutral,
                        route: .sleep,
                        accessibilitySentence: sleepAccessibilitySentence))

        // Assessment §13.2 (2026-08-14): yesterday leads with the persisted
        // TRIMP truth (P1.7 rollup field); the 0–21 display score stays as a
        // parenthetical skin, "TRIMP 188 (15.0)". Legacy rows without stored
        // TRIMP keep the display score alone — TRIMP is never reconstructed
        // by inverting the display curve.
        let yesterdayHasTRIMP = yesterdayTRIMP.map { $0.isFinite && $0 > 0 } ?? false
        let yesterdayValue: String
        if let yesterdayTRIMP, yesterdayHasTRIMP {
            yesterdayValue = yesterdayStrain.map {
                String(format: "TRIMP %.0f (%.1f)", yesterdayTRIMP, $0)
            } ?? String(format: "TRIMP %.0f", yesterdayTRIMP)
        } else {
            yesterdayValue = yesterdayStrain.map { String(format: "Strain %.1f", $0) } ?? "Strain —"
        }
        rows.append(Row(id: "yesterday",
                        systemImage: "flame",
                        valuePhrase: yesterdayValue,
                        sentence: (yesterdayStrain == nil && !yesterdayHasTRIMP)
                            ? "no strain recorded yesterday"
                            : (yesterdayStrainIsPartial ? "yesterday · partial coverage" : "yesterday"),
                        tone: .neutral,
                        route: .strain))
        return AtriaTodayMorningWhiteboardModel(rows: rows)
    }
}
