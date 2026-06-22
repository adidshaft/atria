import Foundation
import MediaPlayer

@MainActor
final class AtriaMediaController: ObservableObject {
    struct State: Equatable {
        var title: String = "Media"
        var artist: String = "System player"
        var isPlaying = false
        var hasNowPlayingInfo = false
        var commandRoute = "system_music_player"

        var accessibilitySummary: String {
            hasNowPlayingInfo ? "\(title), \(artist)" : "System media controls"
        }
    }

    @Published private(set) var state = State()

    private let player = MPMusicPlayerController.systemMusicPlayer
    private var refreshTask: Task<Void, Never>?

    init() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleNowPlayingItemChanged),
                                               name: .MPMusicPlayerControllerNowPlayingItemDidChange,
                                               object: player)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handlePlaybackStateChanged),
                                               name: .MPMusicPlayerControllerPlaybackStateDidChange,
                                               object: player)
        player.beginGeneratingPlaybackNotifications()
        refresh()
        startRefreshLoop()
    }

    deinit {
        refreshTask?.cancel()
        NotificationCenter.default.removeObserver(self)
        player.endGeneratingPlaybackNotifications()
    }

    func refresh() {
        let item = player.nowPlayingItem
        let nowPlaying = MPNowPlayingInfoCenter.default().nowPlayingInfo
        let title = nowPlaying?[MPMediaItemPropertyTitle] as? String ?? item?.title
        let artist = nowPlaying?[MPMediaItemPropertyArtist] as? String ?? item?.artist
        let playbackRate = nowPlaying?[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber

        state = State(title: title?.nonEmptyMediaText ?? "Media",
                      artist: artist?.nonEmptyMediaText ?? "System player",
                      isPlaying: playbackRate.map { $0.doubleValue > 0 } ?? (player.playbackState == .playing),
                      hasNowPlayingInfo: title != nil || artist != nil,
                      commandRoute: "system_music_player")
    }

    func playPause() {
        if state.isPlaying {
            player.pause()
            WHOOPDebugLog("WHOOPDBG media_control command=pause route=%@ now_playing=%d local_only=1",
                  state.commandRoute,
                  state.hasNowPlayingInfo ? 1 : 0)
        } else {
            player.play()
            WHOOPDebugLog("WHOOPDBG media_control command=play route=%@ now_playing=%d local_only=1",
                  state.commandRoute,
                  state.hasNowPlayingInfo ? 1 : 0)
        }
        refresh()
    }

    func stop() {
        player.stop()
        WHOOPDebugLog("WHOOPDBG media_control command=stop route=%@ now_playing=%d local_only=1",
              state.commandRoute,
              state.hasNowPlayingInfo ? 1 : 0)
        refresh()
    }

    func nextTrack() {
        player.skipToNextItem()
        WHOOPDebugLog("WHOOPDBG media_control command=next route=%@ now_playing=%d local_only=1",
              state.commandRoute,
              state.hasNowPlayingInfo ? 1 : 0)
        refresh()
    }

    func previousTrack() {
        player.skipToPreviousItem()
        WHOOPDebugLog("WHOOPDBG media_control command=previous route=%@ now_playing=%d local_only=1",
              state.commandRoute,
              state.hasNowPlayingInfo ? 1 : 0)
        refresh()
    }

    @objc private func handleNowPlayingItemChanged() {
        refresh()
    }

    @objc private func handlePlaybackStateChanged() {
        refresh()
    }

    private func startRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                self?.refresh()
            }
        }
    }
}

private extension String {
    var nonEmptyMediaText: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
