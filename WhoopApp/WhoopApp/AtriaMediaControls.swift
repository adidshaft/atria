import Foundation
import MediaPlayer

@MainActor
final class AtriaMediaController: ObservableObject {
    struct State: Equatable {
        var title: String = "Media"
        var artist: String = "System player"
        var playbackState: MPMusicPlaybackState = .stopped
        var hasNowPlayingInfo = false

        var isPlaying: Bool { playbackState == .playing }
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
        let title = item?.title ?? nowPlaying?[MPMediaItemPropertyTitle] as? String
        let artist = item?.artist ?? nowPlaying?[MPMediaItemPropertyArtist] as? String

        state = State(title: title?.nonEmptyMediaText ?? "Media",
                      artist: artist?.nonEmptyMediaText ?? "System player",
                      playbackState: player.playbackState,
                      hasNowPlayingInfo: title != nil || artist != nil)
    }

    func playPause() {
        if state.isPlaying {
            player.pause()
            WHOOPDebugLog("WHOOPDBG media_control command=pause source=system_music_player local_only=1")
        } else {
            player.play()
            WHOOPDebugLog("WHOOPDBG media_control command=play source=system_music_player local_only=1")
        }
        refresh()
    }

    func stop() {
        player.stop()
        WHOOPDebugLog("WHOOPDBG media_control command=stop source=system_music_player local_only=1")
        refresh()
    }

    func nextTrack() {
        player.skipToNextItem()
        WHOOPDebugLog("WHOOPDBG media_control command=next source=system_music_player local_only=1")
        refresh()
    }

    func previousTrack() {
        player.skipToPreviousItem()
        WHOOPDebugLog("WHOOPDBG media_control command=previous source=system_music_player local_only=1")
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
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                await self?.refresh()
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
