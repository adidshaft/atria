import Foundation

/// Pure wear/recoverability verdict for one historical-gap ledger window.
///
/// Answers the owner's question about a missing interval: was the strap off
/// the wrist (nothing to recover), on the charger, worn but not yet drained
/// (recoverable), or is the app/radio side to blame? Every rule needs positive
/// evidence; absent evidence yields `.indeterminate`, never a confident claim
/// (the no-sleep-cycle assessment honesty pattern — absent evidence is not
/// evidence).
enum AtriaGapWearClassification {
    /// Every input is explicit; `nil` means "not gathered", never "zero".
    struct Evidence: Equatable {
        /// Ledger window bounds. A `nil` end is a still-open window.
        var windowStart: Date
        var windowEnd: Date?

        /// SavedSession audit counters from sessions overlapping the window.
        /// Session HR overlapping a window is this repo's established
        /// worn-but-undrained proof; hrZero counters are zero-contact proof.
        var overlappingAcceptedHRSamples: Int?
        var overlappingZeroContactSamples: Int?

        /// Live `hasContact` observed at the instant the gap was opened.
        var hadContactAtOpen: Bool?

        /// Charging proven for time inside the window — must come from the
        /// bounded 2A19 rise proof or a 2A1B read, never `levelOnly`.
        var chargingProvenDuringWindow: Bool?

        /// Post-drain per-second `physiology_withheld(offWrist)` seconds that
        /// landed inside the window, and the window's expected missing seconds
        /// they are measured against.
        var postDrainOffWristSeconds: TimeInterval?
        var expectedMissingSeconds: TimeInterval?

        /// Oldest-first persist-before-ACK drain cursor. A window entirely at
        /// or behind it has already been served; WHOOP 4.0 cannot seek back.
        var drainCursorUnix: TimeInterval?
        /// "Start fresh" watermark. Windows entirely behind it were abandoned
        /// by explicit user choice and are never chased again.
        var abandonedThroughUnix: TimeInterval?
        /// The drain has terminally stalled (zero-progress slices / stale
        /// episode); no window is currently reachable.
        var terminallyStalled: Bool

        init(windowStart: Date,
             windowEnd: Date? = nil,
             overlappingAcceptedHRSamples: Int? = nil,
             overlappingZeroContactSamples: Int? = nil,
             hadContactAtOpen: Bool? = nil,
             chargingProvenDuringWindow: Bool? = nil,
             postDrainOffWristSeconds: TimeInterval? = nil,
             expectedMissingSeconds: TimeInterval? = nil,
             drainCursorUnix: TimeInterval? = nil,
             abandonedThroughUnix: TimeInterval? = nil,
             terminallyStalled: Bool = false) {
            self.windowStart = windowStart
            self.windowEnd = windowEnd
            self.overlappingAcceptedHRSamples = overlappingAcceptedHRSamples
            self.overlappingZeroContactSamples = overlappingZeroContactSamples
            self.hadContactAtOpen = hadContactAtOpen
            self.chargingProvenDuringWindow = chargingProvenDuringWindow
            self.postDrainOffWristSeconds = postDrainOffWristSeconds
            self.expectedMissingSeconds = expectedMissingSeconds
            self.drainCursorUnix = drainCursorUnix
            self.abandonedThroughUnix = abandonedThroughUnix
            self.terminallyStalled = terminallyStalled
        }
    }

    enum Verdict: Equatable {
        /// Worn during the window; the missing time exists on the strap.
        case wornUndrained(recoverable: Bool)
        /// The strap's own sensor reported no skin — nothing was recorded.
        case offWrist
        /// Proven on the charging pack — off the body, nothing recorded.
        case charging
        /// Worn at the moment the link dropped but no session rows overlap:
        /// the phone side (process or radio) was down, the strap kept banking.
        case appOrRadioDown(recoverable: Bool)
        /// No wear evidence, but recovery is provably impossible.
        case unrecoverable(reason: String)
        /// Missing evidence never produces a confident verdict.
        case indeterminate
    }

    static func classify(_ evidence: Evidence) -> Verdict {
        // Accepted session HR overlapping the window is the strongest wear
        // proof and outranks charging/zero counters that may also be present
        // across a long window (a fresh accepted pulse always wins).
        if let accepted = evidence.overlappingAcceptedHRSamples, accepted > 0 {
            return .wornUndrained(recoverable: isRecoverable(evidence))
        }
        // Charging outranks off-wrist: a charging strap is off the body by
        // definition, and "on the charger" is the more useful answer.
        if evidence.chargingProvenDuringWindow == true {
            return .charging
        }
        // A real zero-contact reading proves the strap was off wrist; so does
        // a gap opened while `hasContact` was a proven false.
        if let zero = evidence.overlappingZeroContactSamples, zero > 0 {
            return .offWrist
        }
        if evidence.hadContactAtOpen == false {
            return .offWrist
        }
        // Post-drain ground truth: the strap itself withheld physiology as
        // offWrist for at least half of the expected missing seconds.
        if let offSeconds = evidence.postDrainOffWristSeconds,
           let expected = evidence.expectedMissingSeconds,
           expected > 0,
           offSeconds >= expected / 2 {
            return .offWrist
        }
        // Contact at open with no overlapping session rows: the strap was on
        // the wrist when the phone lost it — the app or radio was down.
        if evidence.hadContactAtOpen == true {
            return .appOrRadioDown(recoverable: isRecoverable(evidence))
        }
        // No wear evidence at all. Only a provably dead recovery may still
        // speak; everything else fails closed.
        if let reason = provenUnrecoverableReason(evidence) {
            return .unrecoverable(reason: reason)
        }
        return .indeterminate
    }

    /// Recoverable = not proven unrecoverable. Unknown cursor/watermark keeps
    /// the window recoverable so missing bookkeeping never abandons real data.
    static func isRecoverable(_ evidence: Evidence) -> Bool {
        provenUnrecoverableReason(evidence) == nil
    }

    /// The only three conditions that prove a window cannot be refilled.
    /// A window straddling the cursor still has an unserved tail and stays
    /// recoverable; an open window has no right edge and is never behind.
    static func provenUnrecoverableReason(_ evidence: Evidence) -> String? {
        if evidence.terminallyStalled { return "terminal_stall" }
        guard let end = evidence.windowEnd else { return nil }
        let endUnix = end.timeIntervalSince1970
        guard endUnix.isFinite else { return nil }
        if let abandoned = evidence.abandonedThroughUnix,
           abandoned.isFinite, abandoned > 0, endUnix <= abandoned {
            return "behind_abandoned_watermark"
        }
        if let cursor = evidence.drainCursorUnix,
           cursor.isFinite, cursor > 0, endUnix <= cursor {
            return "behind_drain_cursor"
        }
        return nil
    }

    // MARK: - Gap-open suppression evidence

    /// How close a zero-contact reading must sit to each edge of a missing
    /// interval before the whole interval may be attributed to off-wrist.
    /// Wide enough for contact-stability delay after re-wear and for the
    /// first zero to land after removal; tiny against multi-hour phantom
    /// windows, so anything ambiguous fails closed and the window opens.
    static let offWristEdgeProofSlack: TimeInterval = 180

    /// True only when a zero-contact run brackets the interval: it began
    /// within `edgeSlack` of the interval start AND the newest zero reading
    /// sits within `edgeSlack` of the interval end. A lone zero deep inside
    /// the interval proves off-wrist only at that instant — the wearer may
    /// have re-worn the strap while the link was down, and that worn time IS
    /// recoverable, so a partial proof never suppresses the window.
    static func offWristProvenAcross(
        intervalStartUnix: TimeInterval,
        intervalEndUnix: TimeInterval,
        zeroContactRunStartUnix: TimeInterval?,
        lastZeroContactUnix: TimeInterval?,
        edgeSlack: TimeInterval = offWristEdgeProofSlack
    ) -> Bool {
        guard intervalStartUnix.isFinite,
              intervalEndUnix.isFinite,
              intervalEndUnix > intervalStartUnix,
              let runStart = zeroContactRunStartUnix, runStart.isFinite,
              let lastZero = lastZeroContactUnix, lastZero.isFinite,
              lastZero >= runStart else { return false }
        // A run left over from an earlier outage carries no proof for this
        // interval: at least one zero must have been observed inside it.
        guard lastZero > intervalStartUnix else { return false }
        return runStart <= intervalStartUnix + edgeSlack
            && lastZero >= intervalEndUnix - edgeSlack
    }

    // MARK: - Durable off-wrist exclusion tally

    /// Spans that were proven off-wrist at gap-open time and therefore never
    /// became ledger windows. Kept so the backlog line can say how much time
    /// was excluded as off-wrist instead of silently vanishing it.
    enum OffWristExclusion {
        struct Span: Codable, Equatable {
            let startUnix: TimeInterval
            let endUnix: TimeInterval
        }

        static let defaultsKey = "atria.offlineSync.offWristExcludedSpans.v1"
        /// The exclusion is context for the current backlog line, not an
        /// archive; two days comfortably outlives any live backlog episode.
        static let retention: TimeInterval = 48 * 60 * 60
        static let maximumSpans = 32

        @discardableResult
        static func recordExcludedSpan(startUnix: TimeInterval,
                                       endUnix: TimeInterval,
                                       now: Date = Date(),
                                       defaults: UserDefaults = .standard) -> Bool {
            guard startUnix.isFinite, endUnix.isFinite,
                  endUnix > startUnix,
                  // Beyond the ledger's own recoverable horizon a span is
                  // malformed input, not evidence.
                  endUnix - startUnix <= 13 * 24 * 60 * 60 else { return false }
            var spans = load(defaults: defaults)
            spans.append(Span(startUnix: startUnix, endUnix: endUnix))
            spans = retained(spans, now: now)
            guard let data = try? JSONEncoder().encode(spans) else { return false }
            defaults.set(data, forKey: defaultsKey)
            return true
        }

        /// Union of retained spans (overlaps counted once) in seconds.
        static func excludedSeconds(now: Date = Date(),
                                    defaults: UserDefaults = .standard) -> TimeInterval {
            let spans = retained(load(defaults: defaults), now: now)
                .sorted { $0.startUnix < $1.startUnix }
            guard var currentStart = spans.first?.startUnix else { return 0 }
            var currentEnd = spans[0].endUnix
            var total: TimeInterval = 0
            for span in spans.dropFirst() {
                if span.startUnix > currentEnd {
                    total += currentEnd - currentStart
                    currentStart = span.startUnix
                    currentEnd = span.endUnix
                } else if span.endUnix > currentEnd {
                    currentEnd = span.endUnix
                }
            }
            return total + (currentEnd - currentStart)
        }

        private static func load(defaults: UserDefaults) -> [Span] {
            guard let data = defaults.data(forKey: defaultsKey),
                  let spans = try? JSONDecoder().decode([Span].self, from: data) else {
                // Corrupt tally decodes to empty context, never to a crash or
                // an invented exclusion claim.
                return []
            }
            return spans
        }

        private static func retained(_ spans: [Span], now: Date) -> [Span] {
            let floorUnix = now.timeIntervalSince1970 - retention
            var kept = spans.filter { $0.endUnix >= floorUnix }
            if kept.count > maximumSpans {
                kept = Array(kept.suffix(maximumSpans))
            }
            return kept
        }
    }
}
