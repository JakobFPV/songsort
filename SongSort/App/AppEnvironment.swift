import Foundation
import SongSortCore

/// The app's services, wired either to real Spotify or (Debug builds) to the demo backend.
struct AppEnvironment {
    let isDemo: Bool
    let configuration: AuthConfiguration
    let tokens: TokenManager?
    let api: SpotifyAPI
    let store: StateStore
    let sync: SyncEngine
    let player: any MusicPlayer
    let network: NetworkMonitor
    /// Extra setup run once at launch (demo mode uses it to simulate failures).
    var prepare: (() async -> Void)?

    static func make() -> AppEnvironment {
        #if DEBUG
        let demo = DemoOptions.current
        if demo.isEnabled { return .demo(demo) }
        #endif
        return .live()
    }

    static func live() -> AppEnvironment {
        let clientID = Bundle.main.object(forInfoDictionaryKey: "SpotifyClientID") as? String ?? ""
        let configuration = AuthConfiguration(clientID: clientID)
        let tokens = TokenManager(configuration: configuration, store: KeychainTokenStore())
        let api = SpotifyClient(tokens: tokens)
        let store = StateStore(persistence: JSONFileStatePersistence(fileURL: stateFileURL(named: "state.json")))
        let sync = SyncEngine(store: store, api: api)
        let player = SpotifyRemotePlayer(configuration: configuration, accessToken: { try await tokens.accessToken() })
        return AppEnvironment(
            isDemo: false,
            configuration: configuration,
            tokens: tokens,
            api: api,
            store: store,
            sync: sync,
            player: player,
            network: NetworkMonitor()
        )
    }

    static func stateFileURL(named name: String) -> URL {
        (try? JSONFileStatePersistence.defaultFileURL(named: name))
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(name)
    }
}
