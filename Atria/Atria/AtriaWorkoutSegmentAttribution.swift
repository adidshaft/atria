import SwiftUI

/// Per-segment attribution for a multi-activity workout (2026-08-30).
///
/// DERIVED, never stored: the confirmed record keeps exactly one zoneSeconds
/// schema and one scalar activityType (the dominant segment). Everything per
/// segment — bounds, moving duration, mean HR, zone seconds — is recomputed
/// here from the user-declared switch timeline plus the real recorded samples
/// in the real bounds, so it can never drift from the evidence.
enum AtriaWorkoutSegmentAttribution {

    struct Slice: Equatable, Identifiable {
        let activityType: String
        let start: Date
        let end: Date
        /// Wall span minus pause exclusions inside this slice's bounds.
        let movingDuration: TimeInterval
        /// Mean of the non-excluded samples inside the bounds. Nil when the
        /// slice holds no samples — rendered as unavailable, never invented.
        let meanHR: Int?
        /// Derived zone seconds for this slice's non-excluded samples. Nil
        /// when no zone time accrued.
        let zoneSeconds: [String: TimeInterval]?

        var id: Date { start }

        var resolvedActivityType: AtriaWorkoutActivityType {
            AtriaWorkoutActivityType(rawValue: activityType) ?? .other
        }
    }

    /// Splits the session window at each declared switch and attributes the
    /// samples between consecutive boundaries. Segment timestamps are clamped
    /// into [sessionStart, sessionEnd]; samples inside excluded (pause)
    /// intervals never contribute to a slice's HR or zones, mirroring
    /// `AtriaStrengthLog.samplesExcludingIntervals`.
    nonisolated static func derive(segments: [WorkoutSegment],
                                   sessionStart: Date,
                                   sessionEnd: Date,
                                   samples: [HRSample],
                                   excludedIntervals: [ExcludedInterval],
                                   maxHR: Int,
                                   restingHR: Int?) -> [Slice] {
        guard sessionEnd > sessionStart, !segments.isEmpty else { return [] }
        let ordered = segments.sorted { $0.startedAt < $1.startedAt }
        let activeSamples = AtriaStrengthLog.samplesExcludingIntervals(
            samples.sorted { $0.t < $1.t },
            excludedIntervals: excludedIntervals
        )
        var slices: [Slice] = []
        for (index, segment) in ordered.enumerated() {
            let start = min(max(segment.startedAt, sessionStart), sessionEnd)
            let end = index + 1 < ordered.count
                ? min(max(ordered[index + 1].startedAt, start), sessionEnd)
                : sessionEnd
            guard end > start else { continue }
            let sliceSamples = activeSamples.filter { $0.t >= start && $0.t <= end }
            let meanHR: Int? = sliceSamples.isEmpty
                ? nil
                : Int((Double(sliceSamples.reduce(0) { $0 + $1.bpm })
                        / Double(sliceSamples.count)).rounded())
            let zoneSummary = AtriaAnalytics.Strain.maxHeartRateZoneSeconds(
                sliceSamples.map { (t: $0.t.timeIntervalSince(start), bpm: $0.bpm) },
                maxHR: maxHR,
                restingHR: restingHR
            )
            slices.append(Slice(
                activityType: segment.activityType,
                start: start,
                end: end,
                movingDuration: WorkoutSegment.movingDuration(
                    start: start,
                    end: end,
                    excludedIntervals: excludedIntervals
                ),
                meanHR: meanHR,
                zoneSeconds: zoneSummary.isEmpty ? nil : zoneSummary.storage
            ))
        }
        return slices
    }

    /// `SavedSession`/`UserConfirmedWorkout` predate strict concurrency; the
    /// detail sheet takes a value/COW snapshot on the main actor and hands the
    /// worker only immutable reads — the same confinement idiom as the sheet's
    /// `HeartRateTraceSourceSnapshot`.
    struct SourceSnapshot: @unchecked Sendable {
        let workout: UserConfirmedWorkout
        let sessions: [SavedSession]
        let fallbackRestingHR: Int?
        let fallbackMaxHR: Int

        var hasSwitchTimeline: Bool { (workout.segments?.count ?? 0) >= 2 }

        func derive() -> [Slice] {
            AtriaWorkoutSegmentAttribution.derive(workout: workout,
                                                  sessions: sessions,
                                                  fallbackRestingHR: fallbackRestingHR,
                                                  fallbackMaxHR: fallbackMaxHR)
        }
    }

    /// Detail-sheet convenience: flattens the overlapping saved sessions into
    /// window samples first (the same absolute-time projection the sheet's HR
    /// trace uses), then attributes them per declared segment.
    nonisolated static func derive(workout: UserConfirmedWorkout,
                                   sessions: [SavedSession],
                                   fallbackRestingHR: Int?,
                                   fallbackMaxHR: Int) -> [Slice] {
        guard let segments = workout.segments, segments.count >= 2 else { return [] }
        var samples: [HRSample] = []
        for session in sessions where session.end > workout.start && session.start < workout.end {
            for point in session.points {
                let time = session.start.addingTimeInterval(max(0, point.t))
                guard time >= workout.start, time <= workout.end, point.bpm > 0 else { continue }
                samples.append(HRSample(t: time, bpm: point.bpm))
            }
        }
        // GAP-03 grammar: a workout that froze its HRR boundaries derives
        // per-segment zones from those same values; only a legacy record with
        // no freeze falls back to the caller's current-profile values.
        return derive(segments: segments,
                      sessionStart: workout.start,
                      sessionEnd: workout.end,
                      samples: samples,
                      excludedIntervals: workout.excludedIntervals ?? [],
                      maxHR: workout.zoneBoundaries?.maxHR ?? fallbackMaxHR,
                      restingHR: workout.zoneBoundaries?.restingHR ?? fallbackRestingHR)
    }
}

/// Compact per-segment strip for the workout detail sheet: one line per
/// declared segment (type · duration · avg HR). Rendered only when the user
/// actually switched (2+ segments); single-type workouts show nothing new.
struct AtriaWorkoutSegmentStripCard: View {
    let slices: [AtriaWorkoutSegmentAttribution.Slice]

    var body: some View {
        if slices.count >= 2 {
            VStack(alignment: .leading, spacing: 8) {
                Label("Activities", systemImage: "arrow.triangle.swap")
                    .font(.subheadline.weight(.bold))
                ForEach(slices) { slice in
                    HStack(spacing: 8) {
                        Image(systemName: slice.resolvedActivityType.icon)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        Text(slice.resolvedActivityType == .other
                             ? "Workout" : slice.activityType)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(Self.durationText(slice.movingDuration))
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(slice.meanHR.map { "\($0) bpm" } ?? "-- bpm")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 58, alignment: .trailing)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            // Existing workout-surface tint; the strip introduces no new hue.
            .atriaInsetCard(tint: .mint)
        }
    }

    static func durationText(_ duration: TimeInterval) -> String {
        let minutes = Int((duration / 60).rounded())
        if minutes >= 60 {
            return "\(minutes / 60)h \(minutes % 60)m"
        }
        return "\(minutes)m"
    }
}
