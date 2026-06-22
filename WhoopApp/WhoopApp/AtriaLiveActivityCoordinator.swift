import ActivityKit
import Foundation

@MainActor
final class AtriaLiveActivityCoordinator {
    struct Snapshot: Equatable {
        var isRecording: Bool
        var heartRate: Int
        var strain: Double
        var batteryLevel: Int
        var readingCount: Int
        var mediaTitle: String
        var mediaArtist: String
        var mediaIsPlaying: Bool
        var mediaHasNowPlayingInfo: Bool
    }

    private var activity: Activity<AtriaLiveActivityAttributes>?
    private var startedAt: Date?
    private var lastSnapshot: Snapshot?
    private var lastActivitySnapshot: Snapshot?
    private var lastActivityUpdateAt: Date?
    private var pendingActivityUpdateTask: Task<Void, Never>?
    private let minimumActivityUpdateInterval: TimeInterval = 15

    func update(_ snapshot: Snapshot) {
        let now = Date()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            lastSnapshot = snapshot
            return
        }

        if snapshot.isRecording {
            if activity == nil {
                start(with: snapshot)
            } else if snapshot != lastSnapshot {
                enqueueActivityUpdate(snapshot, now: now)
            }
        } else if activity != nil {
            pendingActivityUpdateTask?.cancel()
            pendingActivityUpdateTask = nil
            Task { await endActivity(with: snapshot) }
        }
        lastSnapshot = snapshot
    }

    private func start(with snapshot: Snapshot) {
        let startDate = startedAt ?? Date()
        startedAt = startDate
        let attributes = AtriaLiveActivityAttributes(startedAt: startDate)
        let state = contentState(from: snapshot)

        do {
            activity = try Activity.request(attributes: attributes,
                                            content: ActivityContent(state: state,
                                                                     staleDate: Date().addingTimeInterval(90)),
                                            pushType: nil)
            WHOOPDebugLog("WHOOPDBG live_activity status=started bpm=%d strain=%.1f readings=%d media_now_playing=%d local_only=1",
                          snapshot.heartRate,
                          snapshot.strain,
                          snapshot.readingCount,
                          snapshot.mediaHasNowPlayingInfo ? 1 : 0)
        } catch {
            WHOOPDebugLog("WHOOPDBG live_activity status=start_failed error=%@ local_only=1",
                          String(describing: error))
        }
        lastActivitySnapshot = snapshot
        lastActivityUpdateAt = Date()
    }

    private func updateActivity(with snapshot: Snapshot) async {
        guard let activity else { return }
        await activity.update(ActivityContent(state: contentState(from: snapshot),
                                              staleDate: Date().addingTimeInterval(90)))
        lastActivitySnapshot = snapshot
        lastActivityUpdateAt = Date()
    }

    private func endActivity(with snapshot: Snapshot) async {
        guard let activity else { return }
        await activity.end(ActivityContent(state: contentState(from: snapshot),
                                           staleDate: nil),
                           dismissalPolicy: .after(Date().addingTimeInterval(30)))
        self.activity = nil
        startedAt = nil
        lastActivitySnapshot = nil
        lastActivityUpdateAt = nil
        pendingActivityUpdateTask?.cancel()
        pendingActivityUpdateTask = nil
        WHOOPDebugLog("WHOOPDBG live_activity status=ended bpm=%d strain=%.1f readings=%d media_now_playing=%d local_only=1",
                      snapshot.heartRate,
                      snapshot.strain,
                      snapshot.readingCount,
                      snapshot.mediaHasNowPlayingInfo ? 1 : 0)
    }

    private func contentState(from snapshot: Snapshot) -> AtriaLiveActivityAttributes.ContentState {
        AtriaLiveActivityAttributes.ContentState(heartRate: snapshot.heartRate,
                                                 strain: snapshot.strain,
                                                 batteryLevel: snapshot.batteryLevel,
                                                 readingCount: snapshot.readingCount,
                                                 mediaTitle: snapshot.mediaTitle,
                                                 mediaArtist: snapshot.mediaArtist,
                                                 mediaIsPlaying: snapshot.mediaIsPlaying,
                                                 mediaHasNowPlayingInfo: snapshot.mediaHasNowPlayingInfo,
                                                 updatedAt: Date())
    }

    private func enqueueActivityUpdate(_ snapshot: Snapshot, now: Date) {
        if shouldSendActivityUpdateImmediately(snapshot, now: now) {
            pendingActivityUpdateTask?.cancel()
            pendingActivityUpdateTask = nil
            Task { await updateActivity(with: snapshot) }
            return
        }

        guard pendingActivityUpdateTask == nil else { return }
        let delay = nextActivityUpdateDelay(now: now)
        pendingActivityUpdateTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            pendingActivityUpdateTask = nil
            guard let latest = lastSnapshot, latest.isRecording else { return }
            await updateActivity(with: latest)
        }
    }

    private func shouldSendActivityUpdateImmediately(_ snapshot: Snapshot, now: Date) -> Bool {
        guard let lastActivitySnapshot, let lastActivityUpdateAt else { return true }

        if snapshot.mediaTitle != lastActivitySnapshot.mediaTitle
            || snapshot.mediaArtist != lastActivitySnapshot.mediaArtist
            || snapshot.mediaIsPlaying != lastActivitySnapshot.mediaIsPlaying
            || snapshot.mediaHasNowPlayingInfo != lastActivitySnapshot.mediaHasNowPlayingInfo
            || snapshot.batteryLevel != lastActivitySnapshot.batteryLevel {
            return true
        }

        return now.timeIntervalSince(lastActivityUpdateAt) >= minimumActivityUpdateInterval
    }

    private func nextActivityUpdateDelay(now: Date) -> UInt64 {
        guard let lastActivityUpdateAt else { return 0 }
        let remaining = max(0, minimumActivityUpdateInterval - now.timeIntervalSince(lastActivityUpdateAt))
        return UInt64(remaining * 1_000_000_000)
    }
}
