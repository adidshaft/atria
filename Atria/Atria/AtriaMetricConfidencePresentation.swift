import Foundation
import SwiftUI

/// ONE deterministic presentation model for every compact metric card.
///
/// Before this existed, each surface hand-assembled its own value + confidence
/// prose, so the same physiological state could read three different ways and
/// the caveat was rendered at the same prominence as the datum
/// ("Limited confidence · HRV unavailable" beside a ring already showing a real
/// score). That reads as a broken product even though both statements are true.
///
/// The rules encoded here, in priority order:
///
///  1. If a valid numeric metric exists, it is ALWAYS the value.
///  2. A value is never replaced by "Learning"/"Unavailable"/a warning phrase.
///  3. `noValue` ("--") appears ONLY when the metric genuinely cannot be
///     computed -- not when it is merely uncertain.
///  4. Confidence and provenance leave the value line entirely and become a
///     short fixed-vocabulary marker, so a card can never grow a second line.
///
/// Everything here is pure and takes primitives, so the presentation contract
/// is unit-testable without building a view or a store.
enum AtriaMetricConfidenceLevel: String, Equatable, CaseIterable {
    case high
    case moderate
    case limited
    case provisional

    /// What a status line shows when there is no more specific marker to give.
    /// Short by contract -- the raw confidence names ("personal baseline") are
    /// long enough to wrap a compact card and were part of why cards ended up
    /// at different heights.
    var shortLabel: String {
        switch self {
        case .high: return "checked"
        case .moderate: return "baseline"
        case .limited: return "limited"
        case .provisional: return "provisional"
        }
    }

    /// Status colour for how far this number can be TRUSTED -- a separate axis
    /// from how good the number is.
    ///
    /// Deliberately green/amber only. Red is reserved for a genuinely poor
    /// measured value (a red recovery zone), and reusing it for data confidence
    /// would read as "your recovery is bad" when it actually means "we are less
    /// sure of it". Those are different claims and must not share a colour.
    var statusTint: Color {
        switch self {
        case .high, .moderate: return AtriaMetricZoneLevel.green.tint
        case .limited, .provisional: return AtriaMetricZoneLevel.yellow.tint
        }
    }
}

struct AtriaCompactMetricPresentation: Equatable {
    /// The one token meaning "this metric cannot be computed". Deliberately the
    /// same glyph pair already accepted by the app-wide pending checks
    /// (`AtriaTodayGlanceItem.isPendingValue`), so swapping a producer from
    /// "Learning" to this cannot silently break pending detection downstream.
    static let noValue = "--"

    /// Numeric (or `noValue`). Never prose, never a warning.
    let value: String
    /// Short fixed-vocabulary marker, or nil when confidence is high enough that
    /// saying anything would be noise. Every case is <= 14 characters so the
    /// reserved status line cannot wrap and change a card's height.
    let marker: String?
    let level: AtriaMetricConfidenceLevel
    /// True when the real value is a floor, not a point estimate -- sparse wear
    /// integrates real but under-representative load. Callers render this as a
    /// "≥" prefix; it is never silently rounded away.
    let isLowerBound: Bool

    var hasValue: Bool { value != Self.noValue }

    /// THE canonical "this value line is not a real reading" check.
    ///
    /// Three separate versions of this had drifted apart --
    /// `AtriaTodayGlanceItem.isPendingValue` and `pendingShareValue` accepted
    /// "--", while `metricIsPending` recognised only "learning"/"prepar"/empty.
    /// That divergence was latent until a producer moved off the word
    /// "Learning": the two-glyph token would have been read as a REAL value by
    /// the third check, presenting "--" as a genuine measurement. Every caller
    /// now delegates here so the set cannot drift again.
    ///
    /// Deliberately the union of the old behaviours -- exact tokens plus the
    /// substring matches the widest version used -- so no string that was
    /// previously treated as pending stops being pending. Applied only to value
    /// lines, which are short numerals or status words, so substring matching
    /// cannot swallow legitimate prose.
    static func isPendingValue(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if trimmed == noValue || trimmed == "\u{2014}" { return true }
        let lowered = trimmed.lowercased()
        return lowered.contains("learning")
            || lowered.contains("prepar")
            || lowered.contains("building")
    }

    /// The value exactly as it should appear, lower-bound prefix included.
    var displayValue: String {
        guard hasValue, isLowerBound else { return value }
        return value.hasPrefix("≥") ? value : "≥ \(value)"
    }
}

// MARK: - Expanded detail

/// The provenance behind a compact card, for the surface a tap opens.
///
/// Every field is optional and every optional means "not measured at this
/// scope" -- never zero, never a guess. Day-level gap count and gap duration
/// are deliberately absent: those are measured per detected window
/// (`WorkoutReviewCandidate`, detection readiness), and no day-level aggregate
/// exists. Rendering "0 gaps" from their absence would be fabrication, so the
/// detail surface says the measurement is not available at this scope instead.
struct AtriaMetricProvenance: Equatable {
    /// The value exactly as the compact card shows it, lower-bound prefix and all.
    let displayValue: String
    let level: AtriaMetricConfidenceLevel
    let isLowerBound: Bool
    /// Whether HRV contributed to the score, or nil where the metric has no
    /// HRV input at all.
    let usesHRV: Bool?
    /// Accepted strap coverage over the elapsed day, 0...1. Nil before the day
    /// is long enough to judge.
    let hrCoverageFraction: Double?
    /// When the underlying data was last updated, and where it came from.
    let sourceLabel: String
    let observedAt: Date?
    /// The metric's own graded status -- the green/amber/red zone its value
    /// falls in. Nil where the value has NO real grade, which keeps the
    /// documented honesty guard: painting a colour around an ungraded number
    /// asserts a standing the app has not earned. Neutral is the honest render
    /// for nil, never green.
    var valueStatusTint: Color? = nil

    var coverageText: String? {
        guard let hrCoverageFraction else { return nil }
        return "HR coverage \(Int((hrCoverageFraction * 100).rounded()))%"
    }

    /// Why confidence is reduced, stated concretely rather than as an adjective.
    /// Nil when confidence is high and there is nothing to explain.
    var reducedConfidenceReason: String? {
        if isLowerBound {
            return "Strap wear covered only part of the day, so accumulated load is a floor, not a total."
        }
        if usesHRV == false {
            return "HRV was not available for this score, so it was computed from resting heart rate alone."
        }
        switch level {
        case .high: return nil
        case .moderate: return "Scored against your own baseline, which is still narrowing as more nights arrive."
        case .limited: return "Some inputs were missing or outside their trusted range."
        case .provisional: return "Max heart rate is age-estimated rather than measured, so the scale is approximate."
        }
    }

    /// What would actually raise confidence. Nil when nothing is needed.
    var improvementHint: String? {
        if isLowerBound { return "Wear the strap for more of the day." }
        if usesHRV == false { return "Record a night of sleep with the strap on so HRV can contribute." }
        switch level {
        case .high: return nil
        case .moderate: return "Keep recording nights -- the baseline tightens as it fills."
        case .limited: return "Keep the strap connected so fewer inputs drop out."
        case .provisional: return "Record a maximal effort so max heart rate is measured rather than estimated."
        }
    }
}

// MARK: - Recovery

extension AtriaCompactMetricPresentation {
    /// Recovery is computable exactly when the estimator produced a percent.
    /// Every other input only downgrades confidence -- none of them may take the
    /// number away.
    static func recovery(percent: Int?,
                         confidence: Metrics.RecoveryEstimate.Confidence,
                         usesHRV: Bool,
                         isProvisional: Bool,
                         isFromPreviousSleep: Bool) -> Self {
        guard let percent else {
            // No score at all. This is the ONLY branch allowed to drop the value,
            // and the marker names what is actually missing rather than saying
            // "learning", which told the user nothing actionable.
            return Self(value: noValue,
                        marker: usesHRV ? "no sleep yet" : "HRV pending",
                        level: .limited,
                        isLowerBound: false)
        }

        let level = confidenceLevel(confidence, isProvisional: isProvisional)
        return Self(value: "\(percent)%",
                    marker: recoveryMarker(level: level,
                                           usesHRV: usesHRV,
                                           isFromPreviousSleep: isFromPreviousSleep),
                    level: level,
                    isLowerBound: false)
    }

    static func confidenceLevel(_ confidence: Metrics.RecoveryEstimate.Confidence,
                                isProvisional: Bool) -> AtriaMetricConfidenceLevel {
        if isProvisional { return .provisional }
        switch confidence {
        case .validated: return .high
        case .personalBaseline: return .moderate
        case .unverified: return .limited
        case .learning: return .provisional
        }
    }

    /// Marker priority: carry-over first (it explains a number that otherwise
    /// looks stale), then the score's actual input provenance, then the bare
    /// level. At high confidence there is nothing worth saying.
    private static func recoveryMarker(level: AtriaMetricConfidenceLevel,
                                       usesHRV: Bool,
                                       isFromPreviousSleep: Bool) -> String? {
        if isFromPreviousSleep { return "prev. sleep" }
        // A numeric score with `usesHRV == false` is already computed from RHR.
        // Calling it "HRV pending" makes a real, settled RHR-only estimate look
        // like an unfinished job and hides which evidence actually produced it.
        if !usesHRV { return "RHR-only" }
        switch level {
        case .high: return nil
        case .moderate: return nil
        case .limited: return "limited"
        case .provisional: return "provisional"
        }
    }
}

// MARK: - Strain

extension AtriaCompactMetricPresentation {
    /// Mirrors the token vocabulary emitted by
    /// `AtriaHomeView.HeroSnapshot.strainConfidence(...)`. Parsing is kept in one
    /// place, and named, so the presentation contract cannot drift from the
    /// producer the way the scattered `localizedCaseInsensitiveContains` checks
    /// did.
    struct StrainEvidence: Equatable {
        /// TRIMP is a Banister integration over heart-rate reserve. Without
        /// resting-HR evidence, load evidence, or a max HR above rest, HRR is
        /// undefined -- so there is genuinely no number, and `noValue` is
        /// correct rather than a hidden value.
        let isComputable: Bool
        /// Real but under-representative wear: the value is a floor.
        let isPartial: Bool
        /// Max HR came from an age formula rather than a measured effort.
        let isAgeEstimatedMaxHR: Bool

        static func parse(confidence: String) -> Self {
            let lowered = confidence.lowercased()
            return Self(isComputable: !lowered.contains("learning")
                            && !lowered.contains("standby"),
                        isPartial: lowered.contains("partial"),
                        isAgeEstimatedMaxHR: lowered.contains("age-estimated"))
        }
    }

    static func strain(strain: Double, confidence: String) -> Self {
        let evidence = StrainEvidence.parse(confidence: confidence)
        guard evidence.isComputable else {
            return Self(value: noValue,
                        marker: "HR pending",
                        level: .limited,
                        isLowerBound: false)
        }

        let numeric = String(format: "%.1f", strain)
        if evidence.isPartial {
            // A floor is still a real measurement, so it keeps the number and
            // says so plainly instead of being downgraded to a placeholder.
            return Self(value: numeric,
                        marker: "lower bound",
                        level: .limited,
                        isLowerBound: true)
        }
        if evidence.isAgeEstimatedMaxHR {
            return Self(value: numeric,
                        marker: "provisional",
                        level: .provisional,
                        isLowerBound: false)
        }
        return Self(value: numeric, marker: nil, level: .high, isLowerBound: false)
    }
}
