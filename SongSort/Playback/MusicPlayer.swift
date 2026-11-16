import Foundation
import SongSortCore

enum PlayerConnection: Equatable {
    /// Not needed yet (no sorter open), or disconnected on purpose.
    case idle
    case connecting
    case connected
    /// Spotify isn't running, or the connection dropped. "Start playback" opens Spotify for a moment.
    case needsStart
    case notInstalled
    case failed(String)
}

/// What Spotify is playing, as last reported; the position is extrapolated between reports.
struct PlaybackState: Equatable {
    var trackURI: String
    var durationMs: Int
    var positionMs: Int
    var isPaused: Bool
    var updatedAt: Date

    func position(at date: Date) -> Int {
        guard !isPaused else { return positionMs }
        let elapsed = Int(date.timeIntervalSince(updatedAt) * 1000)
        return min(durationMs, max(0, positionMs + elapsed))
    }
}

/// Plays songs through the Spotify app (App Remote) or, in demo mode, a simulation.
protocol MusicPlayer: AnyObject {
    var connection: PlayerConnection { get }
    var state: PlaybackState? { get }
    /// A problem with the current song, e.g. "Spotify didn't start this song".
    var problem: String? { get }

    /// The sorter appeared: connect if Spotify is running.
    func activate()
    /// The sorter closed: pause and stop following the queue.
    func deactivate()
    func play(_ track: Track, from positionMs: Int)
    func pause()
    func togglePause()
    func seek(to positionMs: Int)
    /// Opens Spotify briefly to wake it up and authorize playback, then returns to SongSort.
    func startSpotify(playing track: Track?)
    /// Handles the redirect back from the Spotify app. Returns false if the URL isn't for the player.
    func handle(url: URL) -> Bool
    func appDidBecomeActive()
    func appDidEnterBackground()
}

enum SpotifyLinks {
    /// Spotify's App Store page (used when the app isn't installed).
    static let appStore = URL(string: "https://apps.apple.com/app/id324684580")!

    static func track(_ track: Track) -> URL? {
        URL(string: "https://open.spotify.com/track/\(track.id)")
    }
}
