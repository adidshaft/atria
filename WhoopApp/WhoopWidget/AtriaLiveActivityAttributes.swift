import ActivityKit
import Foundation

struct AtriaLiveActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var heartRate: Int
        var strain: Double
        var batteryLevel: Int
        var sampleCount: Int
        var mediaTitle: String
        var mediaArtist: String
        var mediaIsPlaying: Bool
        var mediaHasNowPlayingInfo: Bool
        var updatedAt: Date
    }

    var startedAt: Date
}
