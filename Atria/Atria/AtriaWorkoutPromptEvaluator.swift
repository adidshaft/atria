import Foundation

enum AtriaWorkoutPromptEvaluator {
    // These values are elapsed seconds. The legacy names remain because the
    // presentation layer consumes them as an integer evidence duration.
    static let minimumSustainedSamples = 8 * 60
    static let minimumSustainedElevatedSamples = 5 * 60
    static let minimumContinuousElevatedSamples = 90
    static let minimumBPMOverRest = 25
    static let zoneLookbackSeconds: TimeInterval = 6 * 60
    static let zoneMinimumSamples = 4 * 60
    static let zoneMinimumContinuousSamples = 90
    static let zoneMinimumIndex = 3
    static let recentConfirmationSeconds: TimeInterval = 45
    static let recentConfirmationSamples = 30
    static let maximumPacketGap: TimeInterval = 5
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
            if artifactShare >= 0.15 { return true }
            if zeroShare >= 0.25 { return true }
            return maxAcceptedGap > 120 && acceptedGapCount >= 3
        }

        var hasContinuityEvidence: Bool {
            rrImpliedMedianBPM != nil || (acceptedGapCount == 0 && maxAcceptedGap <= 15)
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

        for index in timed.indices {
            let sample = timed[index]
            let naturalEnd = index + 1 < timed.endIndex ? timed[index + 1].t : now
            let intervalEnd = min(min(naturalEnd,
                                      sample.t.addingTimeInterval(maximumPacketGap)),
                                  now)
            let gapToPrevious = index > timed.startIndex
                ? sample.t.timeIntervalSince(timed[index - 1].t)
                : 0
            if gapToPrevious > maximumPacketGap {
                elevated.breakBout()
                zone.breakBout()
            }

            let isElevated = sample.t >= sustainedStart
                && sample.bpm - restingHeartRate >= minimumBPMOverRest
            if isElevated {
                let start = max(sample.t, sustainedStart)
                elevated.add(intervalStart: start,
                             intervalEnd: max(start, intervalEnd),
                             recentStart: recentStart)
            } else {
                elevated.breakBout()
            }

            let zoneIndex = Metrics.heartRateZone(bpm: sample.bpm,
                                                  rest: restingHeartRate,
                                                  max: maxHeartRate)?.index ?? 0
            let isInZone = sample.t >= zoneStart && zoneIndex >= zoneMinimumIndex
            if isInZone {
                let start = max(sample.t, zoneStart)
                zone.add(intervalStart: start,
                         intervalEnd: max(start, intervalEnd),
                         recentStart: recentStart)
            } else {
                zone.breakBout()
            }
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
        let sustainedPath = trustworthySignal
            && elevatedSeconds >= minimumSustainedElevatedSamples
            && longestElevatedSeconds >= minimumContinuousElevatedSamples
            && recentElevatedSeconds >= recentConfirmationSamples
            && currentElevated
        let zonePath = trustworthySignal
            && zoneSeconds >= zoneMinimumSamples
            && longestZoneSeconds >= zoneMinimumContinuousSamples
            && recentZoneSeconds >= recentConfirmationSamples

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
