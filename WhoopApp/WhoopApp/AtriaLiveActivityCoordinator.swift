import ActivityKit
import Foundation

@MainActor
final class AtriaLiveActivityCoordinator {
    struct Snapshot: Equatable {
        var isRecording: Bool
        var heartRate: Int
        var strain: Double
        var batteryLevel: Int
        var sampleCount: Int
    }

    private var activity: Activity<AtriaLiveActivityAttributes>?
    private var startedAt: Date?
    private var lastSnapshot: Snapshot?

    func update(_ snapshot: Snapshot) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            lastSnapshot = snapshot
            return
        }

        if snapshot.isRecording {
            if activity == nil {
                start(with: snapshot)
            } else if snapshot != lastSnapshot {
                Task { await updateActivity(with: snapshot) }
            }
        } else if activity != nil {
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
            WHOOPDebugLog("WHOOPDBG live_activity status=started bpm=%d strain=%.1f samples=%d local_only=1",
                          snapshot.heartRate,
                          snapshot.strain,
                          snapshot.sampleCount)
        } catch {
            WHOOPDebugLog("WHOOPDBG live_activity status=start_failed error=%@ local_only=1",
                          String(describing: error))
        }
    }

    private func updateActivity(with snapshot: Snapshot) async {
        guard let activity else { return }
        await activity.update(ActivityContent(state: contentState(from: snapshot),
                                              staleDate: Date().addingTimeInterval(90)))
    }

    private func endActivity(with snapshot: Snapshot) async {
        guard let activity else { return }
        await activity.end(ActivityContent(state: contentState(from: snapshot),
                                           staleDate: nil),
                           dismissalPolicy: .after(Date().addingTimeInterval(30)))
        self.activity = nil
        startedAt = nil
        WHOOPDebugLog("WHOOPDBG live_activity status=ended bpm=%d strain=%.1f samples=%d local_only=1",
                      snapshot.heartRate,
                      snapshot.strain,
                      snapshot.sampleCount)
    }

    private func contentState(from snapshot: Snapshot) -> AtriaLiveActivityAttributes.ContentState {
        AtriaLiveActivityAttributes.ContentState(heartRate: snapshot.heartRate,
                                                 strain: snapshot.strain,
                                                 batteryLevel: snapshot.batteryLevel,
                                                 sampleCount: snapshot.sampleCount,
                                                 updatedAt: Date())
    }
}
