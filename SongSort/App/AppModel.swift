import AuthenticationServices
import SongSortCore
import SwiftUI

/// App-wide state: which screen is showing, login and logout, and lifecycle events.
@Observable
final class AppModel {
    enum Route: Equatable {
        case launching
        case loggedOut
        case home
    }

    private(set) var route: Route = .launching
    private(set) var isLoggingIn = false
    private(set) var sessionExpired = false
    var loginError: String?

    let env: AppEnvironment
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init(environment: AppEnvironment) {
        env = environment
    }

    var isDemo: Bool { env.isDemo }
    var isConfigured: Bool { env.isDemo || env.configuration.isConfigured }
    var user: SpotifyUser? { env.store.state.user }
    /// The Spotify session ended: show "Log in again" (progress and pending changes are kept).
    var needsLogin: Bool { sessionExpired || env.sync.status == .needsLogin }

    // MARK: - Launch

    func start() async {
        env.network.onChange = { [weak self] online in
            if online { self?.env.sync.networkBecameAvailable() }
        }
        env.network.start()
        await env.prepare?()
        if let tokens = env.tokens {
            await tokens.setSessionExpiredHandler { [weak self] in
                Task { @MainActor in self?.sessionExpired = true }
            }
        }
        env.sync.start()

        if env.isDemo {
            route = .home
            return
        }
        guard env.configuration.isConfigured, let tokens = env.tokens, await tokens.isLoggedIn else {
            route = .loggedOut
            return
        }
        route = .home
        await refreshUser()
    }

    private func refreshUser() async {
        do {
            let user = try await env.api.currentUser()
            env.store.update { $0.user = user }
        } catch SpotifyError.loginRequired {
            sessionExpired = true
        } catch {
            // Offline or Spotify trouble: keep showing the cached name.
        }
    }

    // MARK: - Login

    /// Runs the PKCE login. `authenticate` shows Spotify's consent page and returns the redirect URL.
    func logIn(using authenticate: (URL) async throws -> URL) async {
        guard let tokens = env.tokens else { return }
        guard env.configuration.isConfigured else {
            loginError = SpotifyError.notConfigured.message
            return
        }
        isLoggingIn = true
        loginError = nil
        defer { isLoggingIn = false }

        let request = AuthorizationRequest(configuration: env.configuration)
        do {
            let callbackURL = try await authenticate(request.url)
            try await tokens.completeLogin(callbackURL: callbackURL, request: request)
            sessionExpired = false
            route = .home
            env.sync.loginRestored()
            await refreshUser()
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // Closed the login sheet: nothing to report.
        } catch let error as SpotifyError {
            loginError = error.message
        } catch {
            loginError = "Couldn't open Spotify's login page: \(error.localizedDescription)"
        }
    }

    func logOut() async {
        await env.tokens?.logout()
        env.player.deactivate()
        env.sync.resetCaches()
        env.store.update { $0.user = nil }
        sessionExpired = false
        route = .loggedOut
    }

    // MARK: - System events

    func handleOpenURL(_ url: URL) {
        _ = env.player.handle(url: url)
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            env.player.appDidBecomeActive()
            env.sync.poke()
        case .background:
            env.player.appDidEnterBackground()
            saveBeforeSuspension()
        default:
            break
        }
    }

    /// Gives pending Spotify changes and the progress file a chance to finish before iOS suspends the app.
    private func saveBeforeSuspension() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Save SongSort changes") { [weak self] in
            self?.endBackgroundTask()
        }
        Task {
            await env.sync.flushAndWait(timeout: 20)
            await env.store.flush()
            endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
