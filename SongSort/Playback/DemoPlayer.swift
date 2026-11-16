#if DEBUG
import Foundation
import Observation
import SongSortCore

/// Simulated playback for the Simulator demo mode (the Spotify app can't run in the Simulator).
@Observable
final class DemoPlayer: MusicPlayer {
    enum StartState: String {
        case connected
        case needsStart
        case notInstalled
    }

    private(set) var connection: PlayerConnection = .idle
    private(set) var state: PlaybackState?
    private(set) var problem: String?

    @ObservationIgnored private let startState: StartState
    @ObservationIgnored private var started = false
    @ObservationIgnored private var isActive = false

    init(startState: StartState) {
        self.startState = startState
    }

    func activate() {
        isActive = true
        switch startState {
        case .notInstalled:
            connection = .notInstalled
        case .needsStart where !started:
            connection = .needsStart
        default:
            connection = .connected
        }
    }

    func deactivate() {
        isActive = false
        pause()
    }

    func play(_ track: Track, from positionMs: Int) {
        guard isActive, connection == .connected else { return }
        problem = nil
        state = PlaybackState(trackURI: track.uri, durationMs: track.durationMs, positionMs: positionMs, isPaused: false, updatedAt: Date())
    }

    func pause() {
        guard let state, !state.isPaused else { return }
        self.state = PlaybackState(trackURI: state.trackURI, durationMs: state.durationMs, positionMs: state.position(at: Date()), isPaused: true, updatedAt: Date())
    }

    func togglePause() {
        guard let state else { return }
        let now = Date()
        self.state = PlaybackState(trackURI: state.trackURI, durationMs: state.durationMs, positionMs: state.position(at: now), isPaused: !state.isPaused, updatedAt: now)
    }

    func seek(to positionMs: Int) {
        guard let state else { return }
        self.state = PlaybackState(trackURI: state.trackURI, durationMs: state.durationMs, positionMs: positionMs, isPaused: state.isPaused, updatedAt: Date())
    }

    func startSpotify(playing track: Track?) {
        guard startState != .notInstalled else { return }
        started = true
        connection = .connected
        if let track { play(track, from: track.middleMs) }
    }

    func handle(url: URL) -> Bool { false }
    func appDidBecomeActive() {}
    func appDidEnterBackground() {}
}
#endif
