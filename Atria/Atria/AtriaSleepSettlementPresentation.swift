import Foundation
import SwiftUI

/// What the app tells you about last night while it is still working it out.
///
/// Waking up produced silence. The cause is not that nothing is happening --
/// `sleepCandidateIsSettledForClosedAutoConfirmation` deliberately withholds
/// auto-confirmation for 30 minutes past the wake boundary, and the foreground
/// re-evaluation path is independently throttled to the same interval. So there
/// is a real window in which a night has been detected and is being settled,
/// and nothing on screen said so. "No notification" was being read as "no sleep
/// detected" when those are different states.
///
/// This models the four states explicitly so the app can say which one it is in.
/// It is pure and takes primitives, so the state machine is unit-testable
/// without a store, a view, or a clock.
///
/// Honesty rule: `.saved` is reachable ONLY from a persisted confirmed sleep.
/// No other input may promote a night to saved, because that would claim
/// confirmation before the production gates passed.
///
/// Declutter R4 (2026-08-20): Today renders the settlement row only for the
/// actionable states (`processing`/`reviewReady`). The terminal `.saved` title
/// + freshness stamp are RELOCATED to the ring hero's accessibility summary
/// (see `accessibilitySummary` in AtriaTodayScreen), and `waitingForData` is
/// carried by the sleep chip's "Awaiting current sleep" detail — all four
/// states stay modeled here so nothing about the truth changed, only where
/// each state is said.
enum AtriaSleepSettlementState: Equatable {
    /// Wake boundary crossed, inside the settlement window. Detected, not yet
    /// eligible for auto-confirmation.
    case processing(since: Date)
    /// Settled past the window but still unconfirmed -- waiting on the user, not
    /// on the app.
    case reviewReady(since: Date)
    /// A confirmed sleep is persisted. Only this state may say "saved".
    case saved(at: Date)
    /// No candidate and not enough accepted strap data to make one. Distinct
    /// from "no sleep detected": the app has not been given enough to judge.
    case waitingForData

    var title: String {
        switch self {
        case .processing: return "Sleep ended · processing"
        case .reviewReady: return "Sleep detected · review ready"
        // A confirmed window proves its timing was saved. It does not prove
        // that motion, HR, staging, or overnight-load evidence is available,
        // so avoid wording that can be read as "analysis is complete."
        case .saved: return "Sleep window saved"
        // "Subject · state" like its siblings — the subject-less version
        // never said WHAT was waiting (2026-08-04 review, rank 8). Still
        // deliberately not "no sleep detected": only "not enough to judge".
        case .waitingForData: return "Last night · not enough strap data yet"
        }
    }

    /// The instant this state became true, for the freshness stamp. Nil for
    /// `waitingForData`, which has no event behind it -- and an absent stamp is
    /// honest where a fabricated "just now" would not be.
    var since: Date? {
        switch self {
        case .processing(let date), .reviewReady(let date), .saved(let date):
            return date
        case .waitingForData:
            return nil
        }
    }

    /// True while the app itself still owes work. Drives whether the row should
    /// keep refreshing on foreground and on newly accepted heart rate.
    var isSettling: Bool {
        if case .processing = self { return true }
        return false
    }

    /// Status colour for where last night stands, on the same calibrated
    /// three-band scale the metric zones use.
    ///
    /// Green only for `saved`, because that is the only state backed by a
    /// persisted confirmation -- the same honesty rule that keeps an ungraded
    /// metric neutral. Amber for `reviewReady`, which is genuinely waiting on
    /// the user and is the one state that wants attention. Nil for `processing`
    /// and `waitingForData`: the app is working or has nothing to judge, and
    /// neither is a status the user needs to act on. Nil renders neutral.
    var statusTint: Color? {
        switch self {
        case .saved: return AtriaMetricZoneLevel.green.tint
        case .reviewReady: return AtriaMetricZoneLevel.yellow.tint
        case .processing, .waitingForData: return nil
        }
    }
}

struct AtriaSleepSettlementPresentation {
    /// Mirrors `SessionStore.sleepCandidateIsSettledForClosedAutoConfirmation`'s
    /// default. Declared here so the UI's notion of "still settling" cannot
    /// silently disagree with the gate that actually withholds confirmation.
    static let settlementDelay: TimeInterval = 30 * 60

    /// Resolution order is deliberate: a persisted confirmation wins over any
    /// candidate, because the candidate that produced it is usually still in the
    /// snapshot and would otherwise re-report the night as unsettled.
    ///
    /// There is deliberately no "no sleep detected" state. The four states here
    /// are the ones the product defines, and with no candidate the app cannot
    /// honestly distinguish "you did not sleep" from "not enough accepted strap
    /// data to tell" -- so it says the latter, which is the claim it can support.
    /// Separating those two would need a real data-sufficiency signal joined to
    /// sleep state, which does not exist yet (see the Problem 2 diagnosis).
    static func state(confirmedSleepEnd: Date?,
                      confirmedSleepSavedAt: Date?,
                      candidateEnd: Date?,
                      now: Date,
                      settlementDelay: TimeInterval = settlementDelay) -> AtriaSleepSettlementState {
        if let confirmedSleepEnd {
            // Saved wins, and it is stamped with when it was saved rather than
            // when the night ended -- the stamp answers "how fresh is what I am
            // looking at", not "when did I wake".
            return .saved(at: confirmedSleepSavedAt ?? confirmedSleepEnd)
        }

        if let candidateEnd {
            let elapsed = now.timeIntervalSince(candidateEnd)
            // A candidate whose end is in the future (clock skew, or a night
            // still in progress) is treated as settling rather than as review
            // ready: it cannot be past a window it has not entered.
            if elapsed < settlementDelay {
                return .processing(since: candidateEnd)
            }
            return .reviewReady(since: candidateEnd)
        }

        return .waitingForData
    }

    /// Compact freshness stamp, e.g. "2m ago". Nil when the state has no event
    /// behind it. Short by the same contract as the metric markers so a status
    /// row cannot wrap.
    static func freshnessText(for state: AtriaSleepSettlementState,
                              now: Date) -> String? {
        guard let since = state.since else { return nil }
        let elapsed = now.timeIntervalSince(since)
        guard elapsed >= 0 else { return "just now" }
        let minutes = Int(elapsed / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }
}
