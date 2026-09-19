import Foundation

/// Start Set / ingest IMU / Stop & log set. The live workout view owns one
/// instance for presentation; `live` is the in-process window BLE feeds.
/// Samples are stored only while a set is open — this is not all-day motion.
final class AtriaStrengthSetWindow: @unchecked Sendable {
    static let live = AtriaStrengthSetWindow()

    struct Draft: Equatable, Sendable {
        var exercise: String
        var weightKg: Double?
        var reps: Int?
        var rpe: Double?
    }

    struct Labels: Equatable, Sendable {
        var exercise: String
        var weightKg: Double?
        var reps: Int?
        var rpe: Double?
        var effectiveLoadKg: Double?
        var supersetGroupID: String? = nil
        var supersetOrder: Int? = nil
        var supersetTransitionSeconds: TimeInterval? = nil
    }

    private let lock = NSLock()
    private var startedAt: Date?
    private var storedDraft: Draft?
    private var buffer: [LoggedSetIMUSample] = []

    /// Bound so a forgotten open set cannot grow without limit. Oldest samples
    /// are dropped first; Start/Stop timestamps are unaffected.
    static let maximumBufferedSamples = 250_000

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return startedAt != nil
    }

    var openedAt: Date? {
        lock.lock()
        defer { lock.unlock() }
        return startedAt
    }

    var draft: Draft? {
        lock.lock()
        defer { lock.unlock() }
        return storedDraft
    }

    @discardableResult
    func start(at now: Date, draft: Draft) -> Date {
        lock.lock()
        startedAt = now
        storedDraft = draft
        buffer.removeAll(keepingCapacity: true)
        lock.unlock()
        return now
    }

    func updateDraft(_ draft: Draft) {
        lock.lock()
        defer { lock.unlock() }
        guard startedAt != nil else { return }
        storedDraft = draft
    }

    /// Draft shown when the wearer opens the labels sheet.
    /// An open set keeps the pending Stop-time labels. Priming from the last
    /// logged set is only for starting the next set, not for editing an
    /// in-progress one.
    static func draftForOpeningLabels(
        setWindowIsOpen: Bool,
        current: Draft,
        lastLoggedForExercise: LoggedSet?
    ) -> Draft {
        guard !setWindowIsOpen else { return current }
        guard let last = lastLoggedForExercise else {
            if AtriaStrengthLog.isEstimatedBodyweightExercise(current.exercise) {
                return Draft(exercise: current.exercise,
                             weightKg: 0,
                             reps: current.reps,
                             rpe: current.rpe)
            }
            return current
        }
        return Draft(exercise: current.exercise,
                     weightKg: last.weightKg ?? current.weightKg,
                     reps: last.reps ?? current.reps,
                     rpe: current.rpe)
    }

    func ingest(_ samples: [LoggedSetIMUSample]) {
        lock.lock()
        defer { lock.unlock() }
        guard let startedAt else { return }
        for sample in samples where sample.t >= startedAt {
            buffer.append(sample)
        }
        if buffer.count > Self.maximumBufferedSamples {
            buffer.removeFirst(buffer.count - Self.maximumBufferedSamples)
        }
    }

    /// Closes the window into a logged set. `t` is the stop/log instant so
    /// rest, supersets, and PRs keep their existing meaning. Returns nil when
    /// no set is open or `now` is not strictly after start.
    func stop(at now: Date, labels: Labels) -> LoggedSet? {
        lock.lock()
        defer { lock.unlock() }
        guard let start = startedAt, start < now else { return nil }
        let bound = buffer.filter { $0.t >= start && $0.t <= now }
        startedAt = nil
        storedDraft = nil
        buffer.removeAll(keepingCapacity: true)
        return LoggedSet(exercise: labels.exercise,
                         weightKg: labels.weightKg,
                         reps: labels.reps,
                         rpe: labels.rpe,
                         t: now,
                         effectiveLoadKg: labels.effectiveLoadKg,
                         supersetGroupID: labels.supersetGroupID,
                         supersetOrder: labels.supersetOrder,
                         supersetTransitionSeconds: labels.supersetTransitionSeconds,
                         startedAt: start,
                         endedAt: now,
                         imuSamples: bound)
    }

    func stopUsingDraft(at now: Date, bodyMassKg: Double?) -> LoggedSet? {
        lock.lock()
        let draft = storedDraft
        lock.unlock()
        guard let draft else { return stop(at: now, labels: Labels(exercise: "",
                                                                   weightKg: nil,
                                                                   reps: nil,
                                                                   rpe: nil,
                                                                   effectiveLoadKg: nil)) }
        let effective = AtriaStrengthLog.effectiveLoadKg(
            exercise: draft.exercise,
            externalWeightKg: draft.weightKg,
            bodyMassKg: bodyMassKg
        )?.loadKg
        return stop(at: now,
                    labels: Labels(exercise: draft.exercise,
                                   weightKg: draft.weightKg,
                                   reps: draft.reps,
                                   rpe: draft.rpe,
                                   effectiveLoadKg: effective))
    }

    func cancel() {
        lock.lock()
        startedAt = nil
        storedDraft = nil
        buffer.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    /// R10 frames are one second of 100 Hz acceleration. `receivedAt` is the
    /// wall-clock arrival of the complete frame (last sample).
    static func samples(fromR10 frame: AtriaR10MotionFrame,
                        receivedAt: Date) -> [LoggedSetIMUSample] {
        let count = frame.acceleration.count
        guard count > 0 else { return [] }
        let dt = 1.0 / Double(AtriaR10MotionDecoder.sampleCount)
        return frame.acceleration.enumerated().map { index, vector in
            LoggedSetIMUSample(
                t: receivedAt.addingTimeInterval(Double(index - (count - 1)) * dt),
                ax: vector.x,
                ay: vector.y,
                az: vector.z
            )
        }
    }

    /// 0x33 decoder frames have no intra-frame clock. Every sample is stamped
    /// at frame receipt so Start/Stop filtering stays on one clock.
    static func samples(fromDecoded decoded: AtriaIMUDecoder.DecodeResult,
                        receivedAt: Date) -> [LoggedSetIMUSample] {
        decoded.samples.map { sample in
            LoggedSetIMUSample(t: receivedAt, ax: sample.xG, ay: sample.yG, az: sample.zG)
        }
    }

    static func ingestLiveR10(frame: AtriaR10MotionFrame, receivedAt: Date) {
        guard live.isOpen else { return }
        live.ingest(samples(fromR10: frame, receivedAt: receivedAt))
    }

    static func ingestLiveDecoded(_ decoded: AtriaIMUDecoder.DecodeResult, receivedAt: Date) {
        guard live.isOpen else { return }
        live.ingest(samples(fromDecoded: decoded, receivedAt: receivedAt))
    }
}
