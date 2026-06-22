import ActivityKit
import Foundation

struct AtriaLiveActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var heartRate: Int
        var strain: Double
        var batteryLevel: Int
        var sampleCount: Int
        var updatedAt: Date
    }

    var startedAt: Date
}
