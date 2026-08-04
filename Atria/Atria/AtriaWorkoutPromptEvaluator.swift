import Foundation

enum AtriaWorkoutPromptEvaluator {
    // These values are elapsed seconds. The legacy names remain because the
    // presentation layer consumes them as an integer evidence duration.
    static let minimumSustainedSamples = 8 * 60
    static let minimumSustainedElevatedSamples = 5 * 60
    // 5 minutes continuous at +30, was 90s at +25 (2026-08-05 user
    // feedback): "even if the HR is slightly high for sometime, it detects
    // it" — a stair climb or a stress spike kept promoting the interruptive
    // "Review workout" prompt. Detection/candidate machinery is untouched;
    // only the prompt's READY bar rises to a real sustained effort. Tests
    // reference the constant, so they follow automatically.
    static let minimumContinuousElevatedSamples = 5 * 60
    static let minimumBPMOverRest = 30
    static let zoneLookbackSeconds: TimeInterval = 6 * 60
    static let zoneMinimumSamples = 4 * 60
    static let zoneMinimumContinuousSamples = 90
    static let zoneMinimumIndex = 3
    static let recentConfirmationSeconds: TimeInterval = 45
    static let recentConfirmationSamples = 30
    /// Match the persisted-session continuity contract. Real strap delivery is
    /// bursty: a CRC-valid accepted sample can arrive 5–15 seconds after the
    /// previous one without representing a physiological discontinuity. A gap
    /// above this limit still breaks the bout and contributes no elapsed
    /// evidence. Keeping one shared limit avoids rejecting a live episode that
    /// the exact same accepted samples prove after persistence.
    static let maximumPacketGap: TimeInterval = SavedSession.workoutContinuityGapLimit
    static let maximumSampleAge: TimeInterval = 5
    static let cooldown: TimeInterval = 45 * 60

    /// Strap-only quality evidence for a live workout prompt. These fields use
    /// the same audit counters as `SavedSession.workoutReadiness`; phone motion
    /// is deliberately not part of signal validity.
    struct SignalQuality: Equatable {
        let rawSamples: Int
        let acceptedSamples: Int
        let zeroSamples: Int
        let heldArtifacts: Int
        let droppedArtifacts: Int
        let acceptedGapCount: Int
        let maxAcceptedGap: TimeInterval
        let rrImpliedMedianBPM: Double?

        static let trustedContinuity = SignalQuality(rawSamples: 0,
                                                     acceptedSamples: 0,
                                                     zeroSamples: 0,
                                                     heldArtifacts: 0,
                                                     droppedArtifacts: 0,
                                                     acceptedGapCount: 0,
                                                     maxAcceptedGap: 0,
                                                     rrImpliedMedianBPM: nil)

        var contactCompromised: Bool {
            guard rawSamples > 0 else { return false }
            let artifactShare = Double(heldArtifacts + droppedArtifacts) / Double(rawSamples)
            let zeroShare = Double(zeroSamples) / Double(rawSamples)
            let acceptedShare = Double(acceptedSamples) / Double(rawSamples)
            if artifactShare >= 0.15 { return true }
            if zeroShare >= 0.25 { return true }
            // The audit stream can contain rejected packets that are neither a
            // zero nor a held/dropped optical artifact (for example malformed
            // or out-of-order transport values). A low accepted share is still
            // insufficient contact/continuity evidence and must fail closed.
            if acceptedShare < 0.70 { return true }
            return maxAcceptedGap > 120 && acceptedGapCount >= 3
        }

        var hasContinuityEvidence: Bool {
            // Continuity is proved by the timestamped accepted samples below,
            // where every hard gap breaks the current bout. Do not veto the
            // entire eight-minute window merely because it contains an older
            // gap: after reconnect, a new five-minute continuous effort must be
            // allowed to qualify. Repeated/large gaps and poor packet shares
            // still fail through `contactCompromised`.
            true
        }
    }

    struct Result: Equatable {
        let shouldPrompt: Bool
        let sustainedPath: Bool
        let zonePath: Bool
        /// Covered elapsed seconds, not packet counts.
        let elevatedSamples: Int
        let zoneSamples: Int
        let longestElevatedBout: Int
        let longestZoneBout: Int
        let recentElevatedSamples: Int
        let recentZoneSamples: Int
    }

    private struct TimedEvidence {
        var total: TimeInterval = 0
        var longestBout: TimeInterval = 0
        var currentBout: TimeInterval = 0
        var recent: TimeInterval = 0

        mutating func add(intervalStart: Date,
                          intervalEnd: Date,
                          recentStart: Date) {
            let duration = max(0, intervalEnd.timeIntervalSince(intervalStart))
            total += duration
            currentBout += duration
            longestBout = max(longestBout, currentBout)

            let overlapStart = max(intervalStart, recentStart)
            recent += max(0, intervalEnd.timeIntervalSince(overlapStart))
        }

        mutating func breakBout() {
            currentBout = 0
        }
    }

    static func evaluate(samples: [HRSample],
                         currentHeartRate: Int,
                         restingHeartRate: Int,
                         maxHeartRate: Int,
                         hasContact: Bool = true,
                         signalQuality: SignalQuality = .trustedContinuity,
                         now: Date = Date()) -> Result {
        let sustainedStart = now.addingTimeInterval(-TimeInterval(minimumSustainedSamples))
        let zoneStart = now.addingTimeInterval(-zoneLookbackSeconds)
        let earliestCutoff = min(sustainedStart, zoneStart)
        let recentStart = now.addingTimeInterval(-recentConfirmationSeconds)

        // Sessions are normally ordered. Binary search keeps this hot-path work
        // proportional to the live window rather than an all-day session. Any
        // duplicate or backwards timestamps in that suffix are rejected below.
        var low = 0
        var high = samples.count
        while low < high {
            let middle = low + (high - low) / 2
            if samples[middle].t < earliestCutoff {
                low = middle + 1
            } else {
                high = middle
            }
        }

        var timed: [HRSample] = []
        timed.reserveCapacity(min(samples.count - low, minimumSustainedSamples + 32))
        var lastAcceptedDate: Date?
        for sample in samples[low...] {
            // Future packets cannot prove present effort. Repeated/backwards
            // timestamps have zero trustworthy elapsed time and are ignored.
            guard sample.t >= earliestCutoff, sample.t <= now else { continue }
            if let lastAcceptedDate, sample.t <= lastAcceptedDate { continue }
            timed.append(sample)
            lastAcceptedDate = sample.t
        }

        guard let freshest = timed.last,
              now.timeIntervalSince(freshest.t) >= 0,
              now.timeIntervalSince(freshest.t) <= maximumSampleAge else {
            return emptyResult
        }

        var elevated = TimedEvidence()
        var zone = TimedEvidence()

        func addEvidence(for sample: HRSample,
                         intervalStart: Date,
                         intervalEnd: Date) {
            let isElevated = sample.bpm - restingHeartRate >= minimumBPMOverRest
            if isElevated {
                let start = max(intervalStart, sustainedStart)
                elevated.add(intervalStart: start,
                             intervalEnd: max(start, intervalEnd),
                             recentStart: recentStart)
            } else {
                elevated.breakBout()
            }

            let zoneIndex = Metrics.heartRateZone(bpm: sample.bpm,
                                                  rest: restingHeartRate,
                                                  max: maxHeartRate)?.index ?? 0
            if zoneIndex >= zoneMinimumIndex {
                let start = max(intervalStart, zoneStart)
                zone.add(intervalStart: start,
                         intervalEnd: max(start, intervalEnd),
                         recentStart: recentStart)
            } else {
                zone.breakBout()
            }
        }

        // Persisted readiness associates elapsed evidence with the sample
        // arriving after an interval. Mirror that contract live so a missing
        // interval or reconnect-like jump contributes no duration and its first
        // sample cannot seed a bout that disappears after review.
        if timed.count > 1 {
            for index in timed.index(after: timed.startIndex)..<timed.endIndex {
                let previous = timed[timed.index(before: index)]
                let sample = timed[index]
                let gap = sample.t.timeIntervalSince(previous.t)
                let unverifiedReconnectBlip = gap > SavedSession.workoutMicroGapReseedCadence
                    && abs(sample.bpm - previous.bpm) >= SavedSession.workoutMicroGapReseedJumpBPM
                guard gap <= maximumPacketGap, !unverifiedReconnectBlip else {
                    elevated.breakBout()
                    zone.breakBout()
                    continue
                }
                addEvidence(for: sample,
                            intervalStart: previous.t,
                            intervalEnd: sample.t)
            }
        }
        if freshest.t < now {
            addEvidence(for: freshest,
                        intervalStart: freshest.t,
                        intervalEnd: now)
        }

        let elevatedSeconds = wholeSeconds(elevated.total)
        let zoneSeconds = wholeSeconds(zone.total)
        let longestElevatedSeconds = wholeSeconds(elevated.longestBout)
        let longestZoneSeconds = wholeSeconds(zone.longestBout)
        let recentElevatedSeconds = wholeSeconds(elevated.recent)
        let recentZoneSeconds = wholeSeconds(zone.recent)
        let averageBPM = timed.isEmpty
            ? Double(currentHeartRate)
            : Double(timed.reduce(0) { $0 + $1.bpm }) / Double(timed.count)
        let rrDisagreement = signalQuality.rrImpliedMedianBPM.map {
            abs($0 - averageBPM) > 20
        } ?? false
        let trustworthySignal = hasContact
            && !signalQuality.contactCompromised
            && !rrDisagreement
            && signalQuality.hasContinuityEvidence
        let currentElevated = currentHeartRate - restingHeartRate >= minimumBPMOverRest
        let currentZoneIndex = Metrics.heartRateZone(bpm: currentHeartRate,
                                                     rest: restingHeartRate,
                                                     max: maxHeartRate)?.index ?? 0
        let sustainedPath = trustworthySignal
            && elevatedSeconds >= minimumSustainedElevatedSamples
            && longestElevatedSeconds >= minimumSustainedElevatedSamples
            && recentElevatedSeconds >= recentConfirmationSamples
            && currentElevated
        let zonePath = trustworthySignal
            && zoneSeconds >= zoneMinimumSamples
            && longestZoneSeconds >= zoneMinimumSamples
            && recentZoneSeconds >= recentConfirmationSamples
            && currentZoneIndex >= zoneMinimumIndex

        return Result(shouldPrompt: sustainedPath || zonePath,
                      sustainedPath: sustainedPath,
                      zonePath: zonePath,
                      elevatedSamples: elevatedSeconds,
                      zoneSamples: zoneSeconds,
                      longestElevatedBout: longestElevatedSeconds,
                      longestZoneBout: longestZoneSeconds,
                      recentElevatedSamples: recentElevatedSeconds,
                      recentZoneSamples: recentZoneSeconds)
    }

    private static var emptyResult: Result {
        Result(shouldPrompt: false,
               sustainedPath: false,
               zonePath: false,
               elevatedSamples: 0,
               zoneSamples: 0,
               longestElevatedBout: 0,
               longestZoneBout: 0,
               recentElevatedSamples: 0,
               recentZoneSamples: 0)
    }

    private static func wholeSeconds(_ duration: TimeInterval) -> Int {
        Int(duration.rounded(.down))
    }

    static func isInCooldown(dismissedUntil: Date?, now: Date = Date()) -> Bool {
        guard let dismissedUntil else { return false }
        return dismissedUntil > now
    }
}
