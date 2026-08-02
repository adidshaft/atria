import Foundation

/// Manages sleep candidate validation, auto-confirmation gates, and late-sleep surfacing.
enum SleepSettlementManager {

    /// Determines whether a sleep candidate should automatically enter the confirmed store.
    static func shouldAutoConfirm(_ candidate: SleepCandidate) -> Bool {
        // Low-confidence / HR-only review candidates must remain review candidates
        guard candidate.source != .sleepReviewHROnly else { return false }
        guard candidate.confidence != .low else { return false }
        guard candidate.motionValidated else { return false }
        guard !candidate.reason.contains("user confirmation required") else { return false }
        return true
    }

    /// Evaluates whether a later strap session should be surfaced as a separate nap/resumed-sleep review.
    static func shouldSurfaceAsLateReview(_ candidate: SleepCandidate, after mainSleepEnd: Date) -> Bool {
        guard candidate.start > mainSleepEnd else { return false }
        // Do not bridge roughly six-hour gaps or fabricate continuous sleep
        let gapSeconds = candidate.start.timeIntervalSince(mainSleepEnd)
        guard gapSeconds < 6 * 3600 else { return false }
        return candidate.hasAcceptedHRSamples
    }
}

struct SleepCandidate {
    let source: SleepSource
    let confidence: Confidence
    let motionSource: String
    let motionValidated: Bool
    let start: Date
    let end: Date
    let reason: String
    let hasAcceptedHRSamples: Bool
}

enum SleepSource: String, Codable {
    case strapMotionHR
    case sleepReviewHROnly
    case strapHRDense
    case manual
}

enum Confidence: String, Codable {
    case high
    case low
}
