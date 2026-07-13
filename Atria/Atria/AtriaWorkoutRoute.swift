@preconcurrency import CoreLocation
import Foundation

struct AtriaWorkoutRoute: Codable, Identifiable, Equatable, Sendable {
    struct Point: Codable, Equatable, Sendable {
        let latitude: Double
        let longitude: Double
        let altitude: Double
        let timestamp: Date
        let horizontalAccuracy: Double
        var verticalAccuracy: Double? = nil
        var startsNewSegment: Bool? = nil

        var location: CLLocation {
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                       altitude: altitude,
                       horizontalAccuracy: horizontalAccuracy,
                       verticalAccuracy: verticalAccuracy ?? -1,
                       timestamp: timestamp)
        }
    }

    let id: String
    let workoutID: String
    let activityType: String
    let startedAt: Date
    let endedAt: Date
    var coverageStartedAt: Date? = nil
    let points: [Point]
    let distanceMeters: Double
    let elevationGainMeters: Double
    var pausedDuration: TimeInterval? = nil

    var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
    var movingDuration: TimeInterval {
        let coveredDuration = endedAt.timeIntervalSince(coverageStartedAt ?? startedAt)
        return max(0, coveredDuration - (pausedDuration ?? 0))
    }
    var averagePaceSecondsPerKilometer: TimeInterval? {
        guard distanceMeters >= 100 else { return nil }
        return movingDuration / (distanceMeters / 1_000)
    }
}

struct AtriaActiveWorkoutRouteCheckpoint: Codable, Equatable, Sendable {
    static let schema = 1

    let schema: Int
    let activityType: String
    let startedAt: Date
    let finalizedAt: Date?
    let points: [AtriaWorkoutRoute.Point]
    let distanceMeters: Double
    let elevationGainMeters: Double
    let pauseStartedAt: Date?
    let accumulatedPauseDuration: TimeInterval
    let updatedAt: Date
    var coverageStartedAt: Date? = nil
    /// Present only in the compact on-disk representation. Public callers and
    /// restored checkpoints continue to see the complete `points` array.
    var persistedPointCount: Int? = nil
    var journalByteCount: UInt64? = nil
}

enum AtriaActiveWorkoutRouteCheckpointStore {
    private static var defaultURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root
            .appendingPathComponent("Atria", isDirectory: true)
            .appendingPathComponent("active-workout-route.json")
    }

    static func save(_ checkpoint: AtriaActiveWorkoutRouteCheckpoint,
                     to url: URL? = nil) throws {
        let destination = url ?? defaultURL
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let fullCheckpoint = replacingPoints(in: checkpoint,
                                             with: checkpoint.points,
                                             persistedPointCount: nil,
                                             journalByteCount: nil)
        try JSONEncoder.atriaRoute.encode(fullCheckpoint).write(to: destination, options: .atomic)
        // A full legacy-compatible checkpoint is self-contained. Removing the
        // journal after the atomic metadata swap is crash-safe because readers
        // ignore it when `persistedPointCount` is absent.
        try? FileManager.default.removeItem(at: journalURL(for: destination))
    }

    /// Appends only newly accepted fixes, then atomically commits lightweight
    /// route metadata. The caller serializes writes and supplies the point count
    /// represented by the preceding queued write. A mismatch fails closed so a
    /// caller can repair with one full reset instead of silently losing points.
    @discardableResult
    static func saveIncremental(_ checkpoint: AtriaActiveWorkoutRouteCheckpoint,
                                appendedPoints: [AtriaWorkoutRoute.Point],
                                expectedPersistedPointCount: Int,
                                resetJournal: Bool,
                                to url: URL? = nil) throws -> Int {
        let destination = url ?? defaultURL
        let journal = journalURL(for: destination)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        let priorMetadata = loadMetadata(from: destination)
        let priorCount = priorMetadata?.persistedPointCount ?? 0
        let priorByteCount = priorMetadata?.journalByteCount ?? 0
        guard resetJournal || priorCount == expectedPersistedPointCount else {
            throw CocoaError(.fileReadCorruptFile,
                             userInfo: [NSLocalizedDescriptionKey:
                                "Route journal expected \(expectedPersistedPointCount) points but contains \(priorCount)."])
        }

        if !FileManager.default.fileExists(atPath: journal.path) {
            _ = FileManager.default.createFile(atPath: journal.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: journal)
        defer { try? handle.close() }
        let committedBytes: UInt64 = resetJournal ? 0 : priorByteCount
        try handle.truncate(atOffset: committedBytes)
        try handle.seek(toOffset: committedBytes)

        let encoder = JSONEncoder.atriaRoute
        var appendedByteCount: UInt64 = 0
        for point in appendedPoints {
            var row = try encoder.encode(point)
            row.append(0x0A)
            try handle.write(contentsOf: row)
            appendedByteCount += UInt64(row.count)
        }
        try handle.synchronize()

        let totalPointCount = (resetJournal ? 0 : expectedPersistedPointCount) + appendedPoints.count
        let metadata = replacingPoints(in: checkpoint,
                                       with: [],
                                       persistedPointCount: totalPointCount,
                                       journalByteCount: committedBytes + appendedByteCount)
        try JSONEncoder.atriaRoute.encode(metadata).write(to: destination, options: .atomic)
        return totalPointCount
    }

    static func load(from url: URL? = nil) -> AtriaActiveWorkoutRouteCheckpoint? {
        let source = url ?? defaultURL
        guard let checkpoint = loadMetadata(from: source),
              checkpoint.schema == AtriaActiveWorkoutRouteCheckpoint.schema else { return nil }
        guard let expectedPointCount = checkpoint.persistedPointCount else {
            return checkpoint
        }
        guard expectedPointCount >= 0,
              let journalData = try? Data(contentsOf: journalURL(for: source)) else { return nil }
        let rows = journalData.split(separator: 0x0A, omittingEmptySubsequences: true)
        guard rows.count >= expectedPointCount else { return nil }
        let decoder = JSONDecoder.atriaRoute
        var points: [AtriaWorkoutRoute.Point] = []
        points.reserveCapacity(expectedPointCount)
        for row in rows.prefix(expectedPointCount) {
            guard let point = try? decoder.decode(AtriaWorkoutRoute.Point.self, from: Data(row)) else {
                return nil
            }
            points.append(point)
        }
        return replacingPoints(in: checkpoint,
                               with: points,
                               persistedPointCount: nil,
                               journalByteCount: nil)
    }

    static func clear(at url: URL? = nil) {
        let destination = url ?? defaultURL
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.removeItem(at: journalURL(for: destination))
    }

    private static func loadMetadata(from url: URL) -> AtriaActiveWorkoutRouteCheckpoint? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.atriaRoute.decode(AtriaActiveWorkoutRouteCheckpoint.self, from: data)
    }

    private static func journalURL(for metadataURL: URL) -> URL {
        metadataURL.deletingPathExtension().appendingPathExtension("points.ndjson")
    }

    private static func replacingPoints(
        in checkpoint: AtriaActiveWorkoutRouteCheckpoint,
        with points: [AtriaWorkoutRoute.Point],
        persistedPointCount: Int?,
        journalByteCount: UInt64?
    ) -> AtriaActiveWorkoutRouteCheckpoint {
        AtriaActiveWorkoutRouteCheckpoint(
            schema: checkpoint.schema,
            activityType: checkpoint.activityType,
            startedAt: checkpoint.startedAt,
            finalizedAt: checkpoint.finalizedAt,
            points: points,
            distanceMeters: checkpoint.distanceMeters,
            elevationGainMeters: checkpoint.elevationGainMeters,
            pauseStartedAt: checkpoint.pauseStartedAt,
            accumulatedPauseDuration: checkpoint.accumulatedPauseDuration,
            updatedAt: checkpoint.updatedAt,
            coverageStartedAt: checkpoint.coverageStartedAt,
            persistedPointCount: persistedPointCount,
            journalByteCount: journalByteCount
        )
    }
}

@MainActor
final class AtriaWorkoutRouteRecorder: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    struct Snapshot {
        var isRecording = false
        var isPaused = false
        var authorizationStatus: CLAuthorizationStatus = .notDetermined
        /// Bounded geometry intended only for the live map. Complete route fixes
        /// remain private in `points` for recovery and export fidelity.
        var previewCoordinates: [CLLocationCoordinate2D] = []
        var pointCount = 0
        var distanceMeters: Double = 0
        var elevationGainMeters: Double = 0
        var lastError: String?

        var latestCoordinate: CLLocationCoordinate2D? {
            previewCoordinates.last
        }
    }

    struct Draft: Equatable, Sendable {
        let activityType: AtriaWorkoutActivityType
        let startedAt: Date
        let endedAt: Date
        let coverageStartedAt: Date?
        let points: [AtriaWorkoutRoute.Point]
        let distanceMeters: Double
        let elevationGainMeters: Double
        let pausedDuration: TimeInterval
    }

    @Published private(set) var snapshot = Snapshot()

    private let manager = CLLocationManager()
    private var activeType: AtriaWorkoutActivityType?
    private var startedAt: Date?
    private var points: [AtriaWorkoutRoute.Point] = []
    private var previewCoordinates: [CLLocationCoordinate2D] = []
    private var distanceMeters: Double = 0
    private var elevationGainMeters: Double = 0
    private var lastPublishedAt: Date?
    private var pauseStartedAt: Date?
    private var accumulatedPauseDuration: TimeInterval = 0
    private var lastCheckpointAt: Date?
    private var coverageStartedAt: Date?
    private var needsNewRouteSegment = true
    private var lastEnqueuedCheckpointPointCount = 0
    private var checkpointNeedsFullRewrite = true
    private var checkpointRestoreTask: Task<Void, Never>?
    nonisolated static let maximumLivePreviewPointCount = 512
    private static let checkpointInterval: TimeInterval = 15
    private nonisolated static let checkpointQueue = DispatchQueue(
        label: "com.adidshaft.atria.workout-route-checkpoint",
        qos: .utility
    )

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = 3
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        snapshot.authorizationStatus = manager.authorizationStatus
    }

    func start(activityType: AtriaWorkoutActivityType, startedAt: Date) {
        guard activityType.supportsRouteRecording else {
            stopUpdatingLocation()
            return
        }
        activeType = activityType
        self.startedAt = startedAt
        checkpointRestoreTask?.cancel()
        checkpointRestoreTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let checkpoint = await Self.loadDurableCheckpoint()
            guard !Task.isCancelled,
                  self.activeType == activityType,
                  self.startedAt == startedAt else { return }
            self.restoreActiveCheckpointIfMatching(checkpoint,
                                                   activityType: activityType,
                                                   startedAt: startedAt)
            self.checkpointRestoreTask = nil
            self.beginLocationAccessIfAvailable()
        }
        snapshot.authorizationStatus = manager.authorizationStatus
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            // Start after the durable route has been loaded so a location fix
            // cannot race the restore and make the older route look non-empty.
            break
        case .denied, .restricted:
            snapshot.lastError = "Location access is off. Enable it in Settings to record a route."
        @unknown default:
            snapshot.lastError = "Location access is unavailable."
        }
    }

    func stop(at endedAt: Date = Date()) -> Draft? {
        checkpointRestoreTask?.cancel()
        checkpointRestoreTask = nil
        settlePause(at: endedAt)
        stopUpdatingLocation()
        guard let activeType, let startedAt, points.count >= 2 else {
            discardDurableCheckpoint()
            reset()
            return nil
        }
        let draft = Draft(activityType: activeType,
                          startedAt: startedAt,
                          endedAt: endedAt,
                          coverageStartedAt: coverageStartedAt,
                          points: points,
                          distanceMeters: distanceMeters,
                          elevationGainMeters: elevationGainMeters,
                          pausedDuration: accumulatedPauseDuration)
        // The Draft above is an immutable in-memory handoff. Queue the final
        // durable checkpoint without blocking the workout-dismiss animation;
        // the pending workout intent remains the crash-recovery authority until
        // the confirmed route file and session store both finish.
        persistCheckpoint(at: endedAt, finalizedAt: endedAt, synchronously: false)
        reset()
        return draft
    }

    func cancel() {
        checkpointRestoreTask?.cancel()
        checkpointRestoreTask = nil
        stopUpdatingLocation()
        discardDurableCheckpoint()
        reset()
    }

    func flushCheckpoint(reason: String,
                         completion: (@MainActor @Sendable () -> Void)? = nil) {
        guard activeType != nil, startedAt != nil else {
            completion?()
            return
        }
        persistCheckpoint(at: Date(),
                          finalizedAt: nil,
                          synchronously: false,
                          force: true,
                          completion: completion)
        AtriaDebugLog("ATRIADBG workout_route_checkpoint status=queued reason=%@ points=%d",
                      reason,
                      points.count)
    }

    func discardDurableCheckpoint() {
        Self.checkpointQueue.sync {
            AtriaActiveWorkoutRouteCheckpointStore.clear()
        }
    }

    func finalizedDraft(startedAt: Date,
                        activityType: AtriaWorkoutActivityType,
                        endedAt: Date) async -> Draft? {
        guard let checkpoint = await Self.loadDurableCheckpoint() else { return nil }
        return Self.recoveredDraft(from: checkpoint,
                                   startedAt: startedAt,
                                   activityType: activityType,
                                   endedAt: endedAt)
    }

    /// Rebuilds a route after the workout's ended intent is already durable.
    /// The process can be suspended after that intent is saved but before
    /// `stop(at:)` marks the route checkpoint finalized. In that crash window,
    /// the pending intent's end is authoritative and the still-active matching
    /// checkpoint must not be discarded with the user's exact route.
    nonisolated static func recoveredDraft(
        from checkpoint: AtriaActiveWorkoutRouteCheckpoint,
        startedAt: Date,
        activityType: AtriaWorkoutActivityType,
        endedAt: Date
    ) -> Draft? {
        guard abs(checkpoint.startedAt.timeIntervalSince(startedAt)) <= 2,
              checkpoint.activityType == activityType.rawValue,
              checkpoint.points.count >= 2 else { return nil }
        let finalEnd = checkpoint.finalizedAt ?? endedAt
        guard finalEnd > checkpoint.startedAt else { return nil }
        let openPauseDuration = checkpoint.pauseStartedAt.map {
            max(0, finalEnd.timeIntervalSince(max($0, checkpoint.startedAt)))
        } ?? 0
        return Draft(activityType: activityType,
                     startedAt: checkpoint.startedAt,
                     endedAt: finalEnd,
                     coverageStartedAt: checkpoint.coverageStartedAt ?? checkpoint.points.first?.timestamp,
                     points: checkpoint.points,
                     distanceMeters: checkpoint.distanceMeters,
                     elevationGainMeters: checkpoint.elevationGainMeters,
                     pausedDuration: checkpoint.accumulatedPauseDuration + openPauseDuration)
    }

    func pause(at now: Date = Date()) {
        guard activeType != nil, pauseStartedAt == nil else { return }
        pauseStartedAt = now
        needsNewRouteSegment = true
        manager.stopUpdatingLocation()
        snapshot.isRecording = false
        snapshot.isPaused = true
        persistCheckpoint(at: now, finalizedAt: nil, synchronously: false, force: true)
    }

    func resume(at now: Date = Date()) {
        guard pauseStartedAt != nil else { return }
        settlePause(at: now)
        needsNewRouteSegment = true
        snapshot.isPaused = false
        beginUpdatesIfNeeded()
        persistCheckpoint(at: now, finalizedAt: nil, synchronously: false, force: true)
    }

    func movingDuration(at now: Date = Date()) -> TimeInterval {
        guard let startedAt else { return 0 }
        let livePause = pauseStartedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0
        return max(0, now.timeIntervalSince(startedAt) - accumulatedPauseDuration - livePause)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        snapshot.authorizationStatus = manager.authorizationStatus
        if manager.authorizationStatus == .authorizedAlways
            || manager.authorizationStatus == .authorizedWhenInUse {
            guard checkpointRestoreTask == nil else { return }
            beginLocationAccessIfAvailable()
        } else if manager.authorizationStatus == .denied
                    || manager.authorizationStatus == .restricted {
            snapshot.lastError = "Location access is off. Enable it in Settings to record a route."
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard snapshot.isRecording, !snapshot.isPaused, let startedAt else { return }
        let now = Date()
        for location in locations {
            // Core Location may batch valid fixes while the app is locked or in
            // another app. Judge them against the workout window, not delivery
            // time; the old 15-second wall-clock gate discarded those batches
            // and produced straight-line gaps in otherwise valid routes.
            guard Self.shouldAcceptRouteLocation(
                horizontalAccuracy: location.horizontalAccuracy,
                timestamp: location.timestamp,
                workoutStartedAt: startedAt,
                deliveredAt: now
            ) else { continue }
            let startsNewSegment = points.isEmpty || needsNewRouteSegment
            if let previousPoint = points.last, !startsNewSegment {
                let previous = previousPoint.location
                let delta = location.distance(from: previous)
                let seconds = location.timestamp.timeIntervalSince(previous.timestamp)
                guard Self.shouldAccumulateRouteDelta(distance: delta,
                                                      seconds: seconds,
                                                      previousAccuracy: previous.horizontalAccuracy,
                                                      currentAccuracy: location.horizontalAccuracy,
                                                      activityType: activeType) else { continue }
                distanceMeters += delta
                let altitudeGain = location.altitude - previous.altitude
                let previousVerticalAccuracy = previousPoint.verticalAccuracy ?? -1
                let altitudeNoiseFloor = max(1,
                                             max(previousVerticalAccuracy,
                                                 location.verticalAccuracy) * 0.5)
                if previousVerticalAccuracy >= 0,
                   previousVerticalAccuracy <= 10,
                   location.verticalAccuracy >= 0,
                   location.verticalAccuracy <= 10,
                   altitudeGain >= altitudeNoiseFloor,
                   altitudeGain < 15 {
                    elevationGainMeters += altitudeGain
                }
            }
            if coverageStartedAt == nil { coverageStartedAt = location.timestamp }
            points.append(AtriaWorkoutRoute.Point(latitude: location.coordinate.latitude,
                                                  longitude: location.coordinate.longitude,
                                                  altitude: location.altitude,
                                                  timestamp: location.timestamp,
                                                  horizontalAccuracy: location.horizontalAccuracy,
                                                  verticalAccuracy: location.verticalAccuracy,
                                                  startsNewSegment: startsNewSegment))
            previewCoordinates = Self.previewCoordinates(
                byAppending: location.coordinate,
                to: previewCoordinates
            )
            needsNewRouteSegment = false
        }
        guard lastPublishedAt.map({ now.timeIntervalSince($0) >= 1 }) ?? true else { return }
        lastPublishedAt = now
        publishSnapshot()
        persistCheckpoint(at: now, finalizedAt: nil, synchronously: false)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard (error as? CLError)?.code != .locationUnknown else { return }
        snapshot.lastError = error.localizedDescription
    }

    private func beginUpdatesIfNeeded() {
        guard activeType != nil, pauseStartedAt == nil, !snapshot.isRecording else { return }
        snapshot.lastError = nil
        snapshot.isRecording = true
        manager.startUpdatingLocation()
    }

    nonisolated static func shouldAcceptRouteLocation(
        horizontalAccuracy: CLLocationAccuracy,
        timestamp: Date,
        workoutStartedAt: Date,
        deliveredAt: Date
    ) -> Bool {
        horizontalAccuracy >= 0
            && horizontalAccuracy <= 35
            && timestamp >= workoutStartedAt.addingTimeInterval(-5)
            && timestamp <= deliveredAt.addingTimeInterval(5)
    }

    nonisolated static func shouldAccumulateRouteDelta(distance: CLLocationDistance,
                                                       seconds: TimeInterval,
                                                       previousAccuracy: CLLocationAccuracy,
                                                       currentAccuracy: CLLocationAccuracy,
                                                       activityType: AtriaWorkoutActivityType?) -> Bool {
        guard seconds > 0,
              previousAccuracy >= 0,
              currentAccuracy >= 0 else { return false }
        let uncertaintyFloor = max(2, min(12, max(previousAccuracy, currentAccuracy) * 0.35))
        guard distance >= uncertaintyFloor else { return false }
        let maximumSpeed: CLLocationSpeed
        switch activityType {
        case .walking, .hiking: maximumSpeed = 6
        case .running: maximumSpeed = 12
        case .cycling: maximumSpeed = 25
        default: maximumSpeed = 12
        }
        return distance / seconds <= maximumSpeed
    }

    nonisolated static func shouldRequestTemporaryFullAccuracy(
        authorizationStatus: CLAuthorizationStatus,
        accuracyAuthorization: CLAccuracyAuthorization
    ) -> Bool {
        (authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse)
            && accuracyAuthorization == .reducedAccuracy
    }

    /// Incrementally bounds live map geometry. Compaction touches at most
    /// `limit + 1` coordinates and always keeps both route endpoints; it never
    /// traverses or mutates the full-fidelity route array.
    nonisolated static func previewCoordinates(
        byAppending coordinate: CLLocationCoordinate2D,
        to existing: [CLLocationCoordinate2D],
        limit: Int = maximumLivePreviewPointCount
    ) -> [CLLocationCoordinate2D] {
        guard limit >= 2 else { return [coordinate] }
        var result = existing
        result.append(coordinate)
        guard result.count > limit else { return result }
        var compacted: [CLLocationCoordinate2D] = []
        compacted.reserveCapacity((result.count / 2) + 2)
        compacted.append(result[0])
        var index = 2
        while index < result.count - 1 {
            compacted.append(result[index])
            index += 2
        }
        compacted.append(result[result.count - 1])
        return compacted
    }

    nonisolated static func boundedPreviewCoordinates(
        from points: [AtriaWorkoutRoute.Point],
        limit: Int = maximumLivePreviewPointCount
    ) -> [CLLocationCoordinate2D] {
        points.reduce(into: [CLLocationCoordinate2D]()) { preview, point in
            preview = previewCoordinates(
                byAppending: CLLocationCoordinate2D(latitude: point.latitude,
                                                     longitude: point.longitude),
                to: preview,
                limit: limit
            )
        }
    }

    private func requestTemporaryFullAccuracyIfNeeded() {
        guard Self.shouldRequestTemporaryFullAccuracy(
            authorizationStatus: manager.authorizationStatus,
            accuracyAuthorization: manager.accuracyAuthorization
        ) else { return }
        manager.requestTemporaryFullAccuracyAuthorization(
            withPurposeKey: "AtriaWorkoutRoute"
        ) { [weak self] error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                // Approximate fixes are still useful and continue recording;
                // surface the limitation without failing or stopping a workout.
                self?.snapshot.lastError = "Precise Location is off, so this route may be less accurate. \(error.localizedDescription)"
            }
        }
    }

    private func stopUpdatingLocation() {
        manager.stopUpdatingLocation()
        snapshot.isRecording = false
        snapshot.isPaused = false
    }

    private func settlePause(at now: Date) {
        guard let pauseStartedAt else { return }
        accumulatedPauseDuration += max(0, now.timeIntervalSince(pauseStartedAt))
        self.pauseStartedAt = nil
    }

    private func publishSnapshot() {
        snapshot.previewCoordinates = previewCoordinates
        snapshot.pointCount = points.count
        snapshot.distanceMeters = distanceMeters
        snapshot.elevationGainMeters = elevationGainMeters
    }

    private nonisolated static func loadDurableCheckpoint() async -> AtriaActiveWorkoutRouteCheckpoint? {
        await withCheckedContinuation { continuation in
            checkpointQueue.async {
                continuation.resume(returning: AtriaActiveWorkoutRouteCheckpointStore.load())
            }
        }
    }

    private func beginLocationAccessIfAvailable() {
        guard manager.authorizationStatus == .authorizedAlways
                || manager.authorizationStatus == .authorizedWhenInUse else { return }
        requestTemporaryFullAccuracyIfNeeded()
        beginUpdatesIfNeeded()
    }

    private func restoreActiveCheckpointIfMatching(_ checkpoint: AtriaActiveWorkoutRouteCheckpoint?,
                                                   activityType: AtriaWorkoutActivityType,
                                                   startedAt: Date) {
        guard points.isEmpty,
              let checkpoint,
              checkpoint.finalizedAt == nil,
              abs(checkpoint.startedAt.timeIntervalSince(startedAt)) <= 2,
              checkpoint.activityType == activityType.rawValue else { return }
        points = checkpoint.points
        previewCoordinates = Self.boundedPreviewCoordinates(from: checkpoint.points)
        distanceMeters = checkpoint.distanceMeters
        elevationGainMeters = checkpoint.elevationGainMeters
        pauseStartedAt = checkpoint.pauseStartedAt
        accumulatedPauseDuration = checkpoint.accumulatedPauseDuration
        coverageStartedAt = checkpoint.coverageStartedAt ?? checkpoint.points.first?.timestamp
        needsNewRouteSegment = checkpoint.pauseStartedAt != nil
        lastCheckpointAt = checkpoint.updatedAt
        // `load()` intentionally hides whether this came from a legacy inline
        // checkpoint or the point journal. Rebase once on the next durability
        // write so both formats resume safely without assuming journal state.
        lastEnqueuedCheckpointPointCount = 0
        checkpointNeedsFullRewrite = true
        publishSnapshot()
        snapshot.isPaused = checkpoint.pauseStartedAt != nil
        AtriaDebugLog("ATRIADBG workout_route_checkpoint status=restored points=%d distance_m=%.1f",
                      points.count,
                      distanceMeters)
    }

    private func persistCheckpoint(at now: Date,
                                   finalizedAt: Date?,
                                   synchronously: Bool,
                                   force: Bool = false,
                                   completion: (@MainActor @Sendable () -> Void)? = nil) {
        guard let activeType, let startedAt else { return }
        guard force || finalizedAt != nil
                || lastCheckpointAt.map({ now.timeIntervalSince($0) >= Self.checkpointInterval }) != false else {
            return
        }
        lastCheckpointAt = now
        let resetJournal = finalizedAt != nil
            || checkpointNeedsFullRewrite
            || lastEnqueuedCheckpointPointCount > points.count
        let expectedPointCount = resetJournal ? 0 : lastEnqueuedCheckpointPointCount
        let appendedPoints = resetJournal
            ? points
            : Array(points.dropFirst(expectedPointCount))
        lastEnqueuedCheckpointPointCount = points.count
        checkpointNeedsFullRewrite = false
        let checkpoint = AtriaActiveWorkoutRouteCheckpoint(
            schema: AtriaActiveWorkoutRouteCheckpoint.schema,
            activityType: activeType.rawValue,
            startedAt: startedAt,
            finalizedAt: finalizedAt,
            points: [],
            distanceMeters: distanceMeters,
            elevationGainMeters: elevationGainMeters,
            pauseStartedAt: pauseStartedAt,
            accumulatedPauseDuration: accumulatedPauseDuration,
            updatedAt: now,
            coverageStartedAt: coverageStartedAt
        )
        let write: @Sendable () -> Void = { [weak self] in
            defer {
                if let completion {
                    Task { @MainActor in completion() }
                }
            }
            do {
                try AtriaActiveWorkoutRouteCheckpointStore.saveIncremental(
                    checkpoint,
                    appendedPoints: appendedPoints,
                    expectedPersistedPointCount: expectedPointCount,
                    resetJournal: resetJournal
                )
            } catch {
                AtriaDebugLog("ATRIADBG workout_route_checkpoint status=save_failed error=%@",
                              String(describing: error))
                Task { @MainActor [weak self] in
                    self?.checkpointNeedsFullRewrite = true
                }
            }
        }
        if synchronously {
            Self.checkpointQueue.sync(execute: write)
        } else {
            Self.checkpointQueue.async(execute: write)
        }
    }

    private func reset() {
        activeType = nil
        startedAt = nil
        points = []
        previewCoordinates = []
        distanceMeters = 0
        elevationGainMeters = 0
        lastPublishedAt = nil
        pauseStartedAt = nil
        accumulatedPauseDuration = 0
        lastCheckpointAt = nil
        coverageStartedAt = nil
        needsNewRouteSegment = true
        lastEnqueuedCheckpointPointCount = 0
        checkpointNeedsFullRewrite = true
        snapshot = Snapshot(authorizationStatus: manager.authorizationStatus)
    }
}

enum AtriaWorkoutRouteStore {
    private static let persistenceQueue = DispatchQueue(
        label: "com.adidshaft.atria.workout-route-store",
        qos: .utility
    )

    private static var directoryURL: URL {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent("atria-workout-routes", isDirectory: true)
    }

    static func save(_ draft: AtriaWorkoutRouteRecorder.Draft, workoutID: String) -> AtriaWorkoutRoute? {
        let route = AtriaWorkoutRoute(id: workoutID,
                                      workoutID: workoutID,
                                      activityType: draft.activityType.rawValue,
                                      startedAt: draft.startedAt,
                                      endedAt: draft.endedAt,
                                      coverageStartedAt: draft.coverageStartedAt,
                                      points: draft.points,
                                      distanceMeters: draft.distanceMeters,
                                      elevationGainMeters: draft.elevationGainMeters,
                                      pausedDuration: draft.pausedDuration)
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let data = try JSONEncoder.atriaRoute.encode(route)
            try data.write(to: fileURL(workoutID: workoutID), options: .atomic)
            return route
        } catch {
            AtriaDebugLog("ATRIADBG workout_route status=save_failed workout_id=%@ error=%@",
                          workoutID,
                          String(describing: error))
            return nil
        }
    }

    static func saveAsync(_ draft: AtriaWorkoutRouteRecorder.Draft,
                          workoutID: String,
                          completion: @escaping @MainActor @Sendable (AtriaWorkoutRoute?) -> Void) {
        persistenceQueue.async {
            let route = save(draft, workoutID: workoutID)
            Task { @MainActor in completion(route) }
        }
    }

    static func load(workoutID: String) -> AtriaWorkoutRoute? {
        guard let data = try? Data(contentsOf: fileURL(workoutID: workoutID)) else { return nil }
        return try? JSONDecoder.atriaRoute.decode(AtriaWorkoutRoute.self, from: data)
    }

    static func reassociate(from oldWorkoutID: String, to newWorkoutID: String) {
        guard oldWorkoutID != newWorkoutID,
              let old = load(workoutID: oldWorkoutID) else { return }
        let updated = AtriaWorkoutRoute(id: newWorkoutID,
                                        workoutID: newWorkoutID,
                                        activityType: old.activityType,
                                        startedAt: old.startedAt,
                                        endedAt: old.endedAt,
                                        coverageStartedAt: old.coverageStartedAt,
                                        points: old.points,
                                        distanceMeters: old.distanceMeters,
                                        elevationGainMeters: old.elevationGainMeters,
                                        pausedDuration: old.pausedDuration)
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try JSONEncoder.atriaRoute.encode(updated).write(to: fileURL(workoutID: newWorkoutID), options: .atomic)
            try? FileManager.default.removeItem(at: fileURL(workoutID: oldWorkoutID))
        } catch {
            AtriaDebugLog("ATRIADBG workout_route status=reassociate_failed old_id=%@ new_id=%@ error=%@",
                          oldWorkoutID,
                          newWorkoutID,
                          String(describing: error))
        }
    }

    /// Keeps a saved route consistent with an atomic Activity edit. Points are
    /// clipped to the new window, metrics are recomputed, and changing to an
    /// indoor/non-route type removes precise location rather than leaving stale
    /// coordinates attached to the workout.
    static func reconcile(from oldWorkoutID: String,
                          to newWorkoutID: String,
                          activityType: AtriaWorkoutActivityType,
                          start: Date,
                          end: Date) {
        guard activityType.supportsRouteRecording else {
            delete(workoutID: oldWorkoutID)
            if newWorkoutID != oldWorkoutID { delete(workoutID: newWorkoutID) }
            return
        }
        guard let old = load(workoutID: oldWorkoutID) ?? load(workoutID: newWorkoutID) else { return }
        let source = old.points.filter { $0.timestamp >= start && $0.timestamp <= end }
        guard source.count >= 2 else {
            delete(workoutID: oldWorkoutID)
            if newWorkoutID != oldWorkoutID { delete(workoutID: newWorkoutID) }
            return
        }

        var clipped: [AtriaWorkoutRoute.Point] = []
        var distance = 0.0
        var elevation = 0.0
        for point in source {
            let beginsSegment = clipped.isEmpty || point.startsNewSegment == true
            let normalized = AtriaWorkoutRoute.Point(
                latitude: point.latitude,
                longitude: point.longitude,
                altitude: point.altitude,
                timestamp: point.timestamp,
                horizontalAccuracy: point.horizontalAccuracy,
                verticalAccuracy: point.verticalAccuracy,
                startsNewSegment: beginsSegment
            )
            if let previous = clipped.last, !beginsSegment {
                let delta = point.location.distance(from: previous.location)
                let seconds = point.timestamp.timeIntervalSince(previous.timestamp)
                if AtriaWorkoutRouteRecorder.shouldAccumulateRouteDelta(
                    distance: delta,
                    seconds: seconds,
                    previousAccuracy: previous.horizontalAccuracy,
                    currentAccuracy: point.horizontalAccuracy,
                    activityType: activityType
                ) {
                    distance += delta
                    let previousVA = previous.verticalAccuracy ?? -1
                    let currentVA = point.verticalAccuracy ?? -1
                    let gain = point.altitude - previous.altitude
                    let noiseFloor = max(1, max(previousVA, currentVA) * 0.5)
                    if previousVA >= 0, previousVA <= 10,
                       currentVA >= 0, currentVA <= 10,
                       gain >= noiseFloor, gain < 15 {
                        elevation += gain
                    }
                }
            }
            clipped.append(normalized)
        }
        let updated = AtriaWorkoutRoute(id: newWorkoutID,
                                        workoutID: newWorkoutID,
                                        activityType: activityType.rawValue,
                                        startedAt: start,
                                        endedAt: end,
                                        coverageStartedAt: clipped.first?.timestamp,
                                        points: clipped,
                                        distanceMeters: distance,
                                        elevationGainMeters: elevation,
                                        pausedDuration: min(old.pausedDuration ?? 0,
                                                            max(0, end.timeIntervalSince(start))))
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try JSONEncoder.atriaRoute.encode(updated)
                .write(to: fileURL(workoutID: newWorkoutID), options: .atomic)
            if oldWorkoutID != newWorkoutID {
                try? FileManager.default.removeItem(at: fileURL(workoutID: oldWorkoutID))
            }
        } catch {
            AtriaDebugLog("ATRIADBG workout_route status=reconcile_failed old_id=%@ new_id=%@ error=%@",
                          oldWorkoutID,
                          newWorkoutID,
                          String(describing: error))
        }
    }

    static func delete(workoutID: String) {
        try? FileManager.default.removeItem(at: fileURL(workoutID: workoutID))
    }

    static func gpxURL(for route: AtriaWorkoutRoute) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Atria-\(safeComponent(route.workoutID)).gpx")
        let timestampFormatter = ISO8601DateFormatter()
        var segments: [[AtriaWorkoutRoute.Point]] = []
        for point in route.points {
            if segments.isEmpty || point.startsNewSegment == true {
                segments.append([])
            }
            segments[segments.count - 1].append(point)
        }
        let points = segments.map { segment in
            let rows = segment.map { point in
                "<trkpt lat=\"\(point.latitude)\" lon=\"\(point.longitude)\"><ele>\(point.altitude)</ele><time>\(timestampFormatter.string(from: point.timestamp))</time></trkpt>"
            }.joined(separator: "\n")
            return "<trkseg>\n\(rows)\n</trkseg>"
        }.joined(separator: "\n")
        let gpxNamespace = "http" + "://www.topografix.com/GPX/1/1"
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Atria" xmlns="\(gpxNamespace)">
        <trk><name>\(route.activityType)</name>
        \(points)
        </trk>
        </gpx>
        """
        do {
            try Data(xml.utf8).write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private static func fileURL(workoutID: String) -> URL {
        directoryURL.appendingPathComponent("\(safeComponent(workoutID)).json")
    }

    private static func safeComponent(_ value: String) -> String {
        value.map { character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "_"
        }.reduce(into: "") { $0.append($1) }
    }
}

private extension JSONEncoder {
    static var atriaRoute: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var atriaRoute: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
