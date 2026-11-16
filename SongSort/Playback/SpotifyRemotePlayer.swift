import Foundation
import Observation
import SongSortCore
import SpotifyiOS
import UIKit

/// Plays songs in the Spotify app on this iPhone through the iOS SDK's App Remote (Premium: on-demand).
///
/// App Remote has no "play from position", so every card is `play(uri)` followed immediately by
/// `seek(middle)`. Player-state events from Spotify keep `state` honest.
@Observable
final class SpotifyRemotePlayer: MusicPlayer {
    private(set) var connection: PlayerConnection = .idle
    private(set) var state: PlaybackState?
    private(set) var problem: String?

    @ObservationIgnored private let appRemote: SPTAppRemote
    @ObservationIgnored private let callbacks = RemoteCallbacks()
    @ObservationIgnored private let accessToken: () async throws -> String
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var wanted: (track: Track, positionMs: Int)?
    @ObservationIgnored private var playGeneration = 0
    @ObservationIgnored private var lastPlayRequest = Date.distantPast
    @ObservationIgnored private var pendingSeek: (uri: String, positionMs: Int, at: Date)?
    @ObservationIgnored private var confirmed: RemoteSnapshot?
    @ObservationIgnored private var userPaused = false
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var awaitingSpotifyCallback = false

    init(configuration: AuthConfiguration, accessToken: @escaping () async throws -> String) {
        let redirect = URL(string: configuration.redirectURI) ?? URL(string: AuthConfiguration.defaultRedirectURI)!
        let sdkConfiguration = SPTConfiguration(clientID: configuration.clientID, redirectURL: redirect)
        appRemote = SPTAppRemote(configuration: sdkConfiguration, logLevel: .error)
        self.accessToken = accessToken
        appRemote.delegate = callbacks
        callbacks.onConnect = { [weak self] in self?.didConnect() }
        callbacks.onConnectionFailure = { [weak self] message in self?.didFailToConnect(message) }
        callbacks.onDisconnect = { [weak self] message in self?.didDisconnect(message) }
        callbacks.onPlayerState = { [weak self] snapshot in self?.apply(snapshot) }
    }

    private var isSpotifyInstalled: Bool {
        UIApplication.shared.canOpenURL(URL(string: "spotify:")!)
    }

    // MARK: - Connection

    func activate() {
        isActive = true
        guard isSpotifyInstalled else {
            connection = .notInstalled
            return
        }
        if appRemote.isConnected {
            connection = .connected
        } else {
            connect()
        }
    }

    func deactivate() {
        isActive = false
        wanted = nil
        problem = nil
        watchdog?.cancel()
        pause()
    }

    private func connect() {
        guard connection != .connecting, !appRemote.isConnected else { return }
        connection = .connecting
        Task {
            do {
                appRemote.connectionParameters.accessToken = try await accessToken()
            } catch SpotifyError.loginRequired {
                connection = .failed("Log in to Spotify again to play songs.")
                return
            } catch {
                // Offline: try with the token we already have.
            }
            appRemote.connect()
        }
    }

    func startSpotify(playing track: Track?) {
        guard isSpotifyInstalled else {
            connection = .notInstalled
            return
        }
        if let track { wanted = (track, track.middleMs) }
        connection = .connecting
        awaitingSpotifyCallback = true
        appRemote.authorizeAndPlayURI(track?.uri ?? "", asRadio: false, additionalScopes: nil) { @Sendable [weak self] success in
            guard !success else { return }
            Task { @MainActor in
                self?.awaitingSpotifyCallback = false
                self?.connection = .notInstalled
            }
        }
    }

    func handle(url: URL) -> Bool {
        guard let parameters = appRemote.authorizationParameters(from: url) else { return false }
        awaitingSpotifyCallback = false
        if let token = parameters[SPTAppRemoteAccessTokenKey] {
            appRemote.connectionParameters.accessToken = token
            connection = .connecting
            appRemote.connect()
        } else if let message = parameters[SPTAppRemoteErrorDescriptionKey] {
            connection = .failed("Spotify didn't connect: \(message)")
        } else {
            connection = .needsStart
        }
        return true
    }

    func appDidBecomeActive() {
        guard isActive, isSpotifyInstalled, !appRemote.isConnected else { return }
        if awaitingSpotifyCallback {
            // Normally the redirect from Spotify connects us; fall back if it never comes.
            Task {
                try? await Task.sleep(for: .seconds(2))
                guard awaitingSpotifyCallback, !appRemote.isConnected else { return }
                awaitingSpotifyCallback = false
                connection = .idle
                connect()
            }
        } else {
            connection = .idle
            connect()
        }
    }

    func appDidEnterBackground() {
        // Spotify recommends dropping the connection while in the background; music keeps playing.
        if appRemote.isConnected {
            appRemote.disconnect()
        }
    }

    private func didConnect() {
        connection = .connected
        appRemote.playerAPI?.delegate = callbacks
        appRemote.playerAPI?.subscribe(toPlayerState: { @Sendable _, _ in })
        if isActive, let wanted {
            play(wanted.track, from: wanted.positionMs)
        }
    }

    private func didFailToConnect(_ message: String?) {
        guard !appRemote.isConnected else { return }
        connection = isSpotifyInstalled ? .needsStart : .notInstalled
    }

    private func didDisconnect(_ message: String?) {
        // A nil message means we disconnected on purpose (app went to the background).
        connection = message == nil ? .idle : (isActive ? .needsStart : .idle)
    }

    // MARK: - Playback

    func play(_ track: Track, from positionMs: Int) {
        wanted = (track, positionMs)
        problem = nil
        userPaused = false
        guard isActive else { return }
        guard appRemote.isConnected, let player = appRemote.playerAPI else {
            if connection == .idle { connect() }
            return
        }
        playGeneration += 1
        let generation = playGeneration
        lastPlayRequest = Date()
        pendingSeek = (track.uri, positionMs, Date())
        // Show the expected state right away; Spotify's events confirm or correct it.
        state = PlaybackState(trackURI: track.uri, durationMs: track.durationMs, positionMs: positionMs, isPaused: false, updatedAt: Date())
        player.play(track.uri, callback: { @Sendable [weak self] _, error in
            let message = error?.localizedDescription
            Task { @MainActor in self?.didRequestPlay(generation: generation, positionMs: positionMs, error: message) }
        })
        startWatchdog(trackURI: track.uri, generation: generation)
    }

    private func didRequestPlay(generation: Int, positionMs: Int, error: String?) {
        guard generation == playGeneration else { return }
        if let error {
            problem = "Spotify couldn't play this song (\(error))."
            return
        }
        appRemote.playerAPI?.seek(toPosition: positionMs, callback: nil)
    }

    func pause() {
        guard appRemote.isConnected, let state, !state.isPaused else { return }
        appRemote.playerAPI?.pause(nil)
        self.state = PlaybackState(trackURI: state.trackURI, durationMs: state.durationMs, positionMs: state.position(at: Date()), isPaused: true, updatedAt: Date())
    }

    func togglePause() {
        guard appRemote.isConnected, let player = appRemote.playerAPI else {
            if connection == .idle { connect() }
            return
        }
        if let wanted, state?.trackURI != wanted.track.uri {
            play(wanted.track, from: wanted.positionMs)
            return
        }
        guard let state else { return }
        let now = Date()
        if state.isPaused {
            player.resume(nil)
            userPaused = false
            problem = nil
        } else {
            player.pause(nil)
            userPaused = true
        }
        self.state = PlaybackState(trackURI: state.trackURI, durationMs: state.durationMs, positionMs: state.position(at: now), isPaused: !state.isPaused, updatedAt: now)
    }

    func seek(to positionMs: Int) {
        guard appRemote.isConnected, let player = appRemote.playerAPI else { return }
        if let wanted, state?.trackURI != wanted.track.uri {
            play(wanted.track, from: positionMs)
            return
        }
        guard let state else { return }
        player.seek(toPosition: positionMs, callback: nil)
        pendingSeek = (state.trackURI, positionMs, Date())
        self.state = PlaybackState(trackURI: state.trackURI, durationMs: state.durationMs, positionMs: positionMs, isPaused: state.isPaused, updatedAt: Date())
    }

    private func apply(_ snapshot: RemoteSnapshot) {
        confirmed = snapshot
        // Ignore the event Spotify sends between "play" and our "seek to the middle".
        if let pendingSeek, snapshot.uri == pendingSeek.uri, Date().timeIntervalSince(pendingSeek.at) < 2,
           abs(snapshot.positionMs - pendingSeek.positionMs) > 3_000 {
            return
        }
        pendingSeek = nil
        state = PlaybackState(
            trackURI: snapshot.uri,
            durationMs: snapshot.durationMs,
            positionMs: snapshot.positionMs,
            isPaused: snapshot.isPaused,
            updatedAt: Date()
        )
        guard isActive, let wanted else { return }
        if snapshot.uri == wanted.track.uri {
            if !snapshot.isPaused { problem = nil }
        } else if !snapshot.isPaused, Date().timeIntervalSince(lastPlayRequest) > 3 {
            // The song ended and Spotify moved on to something else: stop instead of playing a stranger.
            appRemote.playerAPI?.pause(nil)
            problem = "The song ended. Tap ↺ to hear it again."
        }
    }

    private func startWatchdog(trackURI: String, generation: Int) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled, generation == self.playGeneration, !self.userPaused else { return }
            if self.confirmed?.uri != trackURI || self.confirmed?.isPaused == true {
                self.problem = "Spotify didn't start this song. Tap ▶ to try again."
            }
        }
    }
}

/// Values copied out of SPTAppRemotePlayerState so they can cross to the main actor.
struct RemoteSnapshot: Sendable {
    let uri: String
    let durationMs: Int
    let positionMs: Int
    let isPaused: Bool
}

/// Receives the SDK's delegate calls (on any thread) and forwards them to the main actor.
final class RemoteCallbacks: NSObject, SPTAppRemoteDelegate, SPTAppRemotePlayerStateDelegate {
    var onConnect: (() -> Void)?
    var onConnectionFailure: ((String?) -> Void)?
    var onDisconnect: ((String?) -> Void)?
    var onPlayerState: ((RemoteSnapshot) -> Void)?

    nonisolated func appRemoteDidEstablishConnection(_ appRemote: SPTAppRemote) {
        Task { @MainActor in self.onConnect?() }
    }

    nonisolated func appRemote(_ appRemote: SPTAppRemote, didFailConnectionAttemptWithError error: (any Error)?) {
        let message = error?.localizedDescription ?? "Couldn't connect to Spotify."
        Task { @MainActor in self.onConnectionFailure?(message) }
    }

    nonisolated func appRemote(_ appRemote: SPTAppRemote, didDisconnectWithError error: (any Error)?) {
        let message = error?.localizedDescription
        Task { @MainActor in self.onDisconnect?(message) }
    }

    nonisolated func playerStateDidChange(_ playerState: any SPTAppRemotePlayerState) {
        let snapshot = RemoteSnapshot(
            uri: playerState.track.uri,
            durationMs: Int(playerState.track.duration),
            positionMs: playerState.playbackPosition,
            isPaused: playerState.isPaused
        )
        Task { @MainActor in self.onPlayerState?(snapshot) }
    }
}
