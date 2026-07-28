import Foundation

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

    /// The value exactly as it should appear, lower-bound prefix included.
    var displayValue: String {
        guard hasValue, isLowerBound else { return value }
        return value.hasPrefix("≥") ? value : "≥ \(value)"
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
    /// looks stale), then the missing input, then the bare level. At high
    /// confidence there is nothing worth saying.
    private static func recoveryMarker(level: AtriaMetricConfidenceLevel,
                                       usesHRV: Bool,
                                       isFromPreviousSleep: Bool) -> String? {
        if isFromPreviousSleep { return "prev. sleep" }
        if !usesHRV { return "HRV pending" }
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
