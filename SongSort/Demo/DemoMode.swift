#if DEBUG
import Foundation
import SongSortCore

/// Demo mode for the Simulator, enabled with launch arguments (Debug builds only):
///
///     -SongSortDemo YES               fake library + simulated player, no Spotify account needed
///     -SongSortDemoReset YES          start from scratch (forget demo progress)
///     -SongSortDemoLibrary empty      an empty Liked Songs (also: small = 3 songs)
///     -SongSortDemoPlayer needsStart  Spotify "not running" (also: notInstalled, connected)
///     -SongSortDemoOffline YES        every Spotify call fails as offline (writes = only changes fail)
///     -SongSortDemoWriteError login   saving changes fails: login expired (also: quota, forbidden)
struct DemoOptions {
    var isEnabled: Bool
    var reset: Bool
    var library: String?
    var player: DemoPlayer.StartState
    /// nil, "writes" (loading works, saving changes fails) or anything else (everything fails).
    var offline: String?
    var writeError: SpotifyError?

    var tracks: [Track] {
        switch library {
        case "empty": []
        case "small": Array(DemoLibrary.tracks.prefix(3))
        default: DemoLibrary.tracks
        }
    }

    static var current: DemoOptions {
        let defaults = UserDefaults.standard
        return DemoOptions(
            isEnabled: defaults.bool(forKey: "SongSortDemo"),
            reset: defaults.bool(forKey: "SongSortDemoReset"),
            library: defaults.string(forKey: "SongSortDemoLibrary"),
            player: defaults.string(forKey: "SongSortDemoPlayer").flatMap(DemoPlayer.StartState.init(rawValue:)) ?? .connected,
            offline: defaults.string(forKey: "SongSortDemoOffline"),
            writeError: defaults.string(forKey: "SongSortDemoWriteError").map { kind in
                switch kind {
                case "login": .loginRequired
                case "quota": .quotaExceeded
                default: .forbidden("Spotify: You cannot add items to this playlist.")
                }
            }
        )
    }
}

extension AppEnvironment {
    static func demo(_ options: DemoOptions) -> AppEnvironment {
        let fileURL = stateFileURL(named: "demo-state.json")
        if options.reset {
            try? FileManager.default.removeItem(at: fileURL)
        }
        let api = InMemorySpotifyAPI(
            user: SpotifyUser(id: "demo", displayName: "Demo listener"),
            liked: options.tracks,
            latency: .milliseconds(150)
        )
        let store = StateStore(persistence: JSONFileStatePersistence(fileURL: fileURL))
        store.update { $0.user = SpotifyUser(id: "demo", displayName: "Demo listener") }
        var environment = AppEnvironment(
            isDemo: true,
            configuration: AuthConfiguration(clientID: ""),
            tokens: nil,
            api: api,
            store: store,
            sync: SyncEngine(store: store, api: api),
            player: DemoPlayer(startState: options.player),
            network: NetworkMonitor()
        )
        let offline = options.offline
        let writeError = options.writeError
        if offline != nil || writeError != nil {
            environment.prepare = {
                if let offline {
                    var operations: [InMemorySpotifyAPI.Operation] = [
                        .currentUser, .myPlaylists, .playlistItems, .createPlaylist,
                        .addToPlaylist, .removeFromPlaylist, .saveToLibrary, .removeFromLibrary, .libraryContains,
                    ]
                    if offline != "writes" { operations.append(.savedTracks) }
                    for operation in operations {
                        await api.failNext(operation, with: .offline, times: 10_000)
                    }
                }
                if let writeError {
                    await api.failNext(.addToPlaylist, with: writeError, times: 10_000)
                }
            }
        }
        return environment
    }
}

/// Fictional songs for the demo.
enum DemoLibrary {
    static let tracks: [Track] = [
        ("Paper Lanterns", ["Marlow Rivers"], "Night Market", 2019, 214),
        ("Coastline Static", ["Velvet Static"], "Low Tide Radio", 2016, 248),
        ("Juniper Smoke", ["Juniper & the Echoes"], "Field Notes", 2021, 197),
        ("Tokyo After Rain", ["Kito Sato", "Lumen Drive"], "Neon Shrine", 2018, 263),
        ("Gold in the Gutter", ["Odessa Lane"], "Small Victories", 2012, 231),
        ("The Long Way Home", ["Northbound Choir"], "Winter Roads", 2009, 302),
        ("Satellite Hearts", ["Lumen Drive"], "Orbit", 2022, 189),
        ("Brass & Bones", ["The Night Bureau"], "Case Files", 2014, 276),
        ("Fern Hollow", ["Ada Moreau"], "Green Rooms", 2020, 221),
        ("Lighthouse Keeper", ["Sable Coast"], "Salt", 2011, 244),
        ("Midnight Arcade", ["Static Bloom"], "Pixel Hearts", 2023, 203),
        ("Silver Thread", ["Paloma Ruiz"], "Tejidos", 2017, 238),
        ("Run the Red Lights", ["The Night Bureau", "Odessa Lane"], "Case Files", 2014, 199),
        ("Hollow Moon", ["Marlow Rivers"], "Night Market", 2019, 257),
        ("Postcards from Lisbon", ["Ada Moreau"], "Green Rooms", 2020, 212),
        ("Thunder in July", ["Northbound Choir"], "Summer Roads", 2013, 285),
        ("Concrete Garden", ["Velvet Static"], "Low Tide Radio", 2016, 226),
        ("Echo Park", ["Juniper & the Echoes"], "Field Notes", 2021, 240),
        ("Glass Elevator", ["Static Bloom"], "Pixel Hearts", 2023, 178),
        ("Slow Dancer", ["Sable Coast"], "Salt", 2011, 333),
        ("River of Names", ["Paloma Ruiz"], "Tejidos", 2017, 266),
        ("Afterglow Avenue", ["Kito Sato"], "Neon Shrine", 2018, 209),
        ("Weathervane", ["Odessa Lane"], "Small Victories", 2012, 247),
        ("Copper Sky", ["Lumen Drive"], "Orbit", 2022, 224),
        ("Telephone Wire", ["Marlow Rivers"], "Early Hours", 1998, 252),
        ("Blue Motel", ["The Night Bureau"], "Vacancy", 2006, 291),
        ("Sundial", ["Ada Moreau"], "Hours", 2024, 186),
        ("Driftwood Choir", ["Northbound Choir", "Sable Coast"], "Winter Roads", 2009, 318),
        ("Static on the Radio", ["Velvet Static"], "First Transmission", 2003, 233),
        ("Lemon Trees", ["Paloma Ruiz"], "Jardines", 2010, 205),
        ("Vapor Trails", ["Static Bloom"], "Afterimage", 2025, 196),
        ("Last Train to Nowhere", ["Juniper & the Echoes"], "Stations", 1994, 274),
        ("Velvet Underpass", ["Kito Sato"], "Underpass", 2015, 239),
        ("Wildflower Season", ["Odessa Lane"], "Bloom", 1987, 228),
        ("Neon Cathedral", ["Lumen Drive"], "Orbit", 2022, 301),
        ("Morning Ferry", ["Sable Coast"], "Harbour Lights", 1979, 262),
    ].enumerated().map { index, song in
        Track(
            id: String(format: "demo%02d", index + 1),
            name: song.0,
            artists: song.1,
            album: song.2,
            releaseYear: song.3,
            durationMs: song.4 * 1000
        )
    }
}
#endif
