import Foundation

/// Atria deliberately does NOT touch the user's music. This controller is inert:
/// no `MPMusicPlayerController`, no playback notifications, no now-playing polling.
///
/// Using `MPMusicPlayerController.systemMusicPlayer` (and `beginGenerating-
/// PlaybackNotifications`) can grab the audio route / now-playing focus and only
/// ever controls Apple Music — never the app the user is actually playing through
/// AirPods or a speaker. That is interference + battery drain a strap reader has
/// no business causing, so the whole feature is disabled. `hasNowPlayingInfo`
/// stays false, which hides every media control in the UI / Live Activity.
@MainActor
final class AtriaMediaController: ObservableObject {
    struct State: Equatable {
        var title: String = ""
        var artist: String = ""
        var isPlaying = false
        var hasNowPlayingInfo = false
        var commandRoute = "disabled"

        var accessibilitySummary: String { "" }
    }

    @Published private(set) var state = State()

    func setRefreshLoopActive(_ active: Bool) {}
    func refresh() {}
    func playPause() {}
    func stop() {}
    func nextTrack() {}
    func previousTrack() {}
}
