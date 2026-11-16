import Foundation

/// A faithful in-memory Spotify: same limits and semantics as the real endpoints SongSort uses.
/// Backs the automated tests and the Simulator demo mode.
public actor InMemorySpotifyAPI: SpotifyAPI {
    public struct Playlist: Sendable, Equatable {
        public var id: String
        public var name: String
        public var ownerID: String
        public var isCollaborative: Bool
        public var isFollowed: Bool
        public var uris: [String]
    }

    public enum Operation: Hashable, Sendable {
        case currentUser, savedTracks, myPlaylists, playlistItems, createPlaylist
        case addToPlaylist, removeFromPlaylist, saveToLibrary, removeFromLibrary, libraryContains
    }

    public enum Call: Equatable, Sendable {
        case currentUser
        case savedTracks(offset: Int, limit: Int)
        case myPlaylists(offset: Int)
        case playlistItems(playlistID: String, offset: Int)
        case createPlaylist(name: String, isPublic: Bool)
        case addToPlaylist(playlistID: String, uris: [String])
        case removeFromPlaylist(playlistID: String, uris: [String])
        case saveToLibrary(uris: [String])
        case removeFromLibrary(uris: [String])
        case libraryContains(uris: [String])

        public var isWrite: Bool {
            switch self {
            case .createPlaylist, .addToPlaylist, .removeFromPlaylist, .saveToLibrary, .removeFromLibrary: true
            default: false
            }
        }
    }

    public private(set) var user: SpotifyUser
    /// Liked Songs, newest first (Spotify's order).
    public private(set) var liked: [Track]
    /// "Your Library" playlists, most recent first.
    public private(set) var playlists: [Playlist]
    public private(set) var calls: [Call] = []

    private var catalog: [String: Track] = [:]
    private var failures: [Operation: [SpotifyError]] = [:]
    private var playlistCounter = 0
    private let latency: Duration?

    public init(
        user: SpotifyUser = SpotifyUser(id: "me", displayName: "Me"),
        liked: [Track] = [],
        playlists: [Playlist] = [],
        latency: Duration? = nil
    ) {
        self.user = user
        self.liked = liked
        self.playlists = playlists
        self.latency = latency
        for track in liked { catalog[track.uri] = track }
    }

    // MARK: - Test and demo controls

    public func failNext(_ operation: Operation, with error: SpotifyError, times: Int = 1) {
        failures[operation, default: []].append(contentsOf: Array(repeating: error, count: times))
    }

    @discardableResult
    public func addPlaylist(name: String, ownerID: String? = nil, uris: [String] = [], isCollaborative: Bool = false) -> String {
        playlistCounter += 1
        let id = "existing\(playlistCounter)"
        playlists.insert(
            Playlist(id: id, name: name, ownerID: ownerID ?? user.id, isCollaborative: isCollaborative, isFollowed: true, uris: uris),
            at: 0
        )
        return id
    }

    /// What "Delete playlist" does in Spotify: it disappears from your library.
    public func unfollowPlaylist(id: String) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].isFollowed = false
    }

    public func setLiked(_ tracks: [Track]) {
        liked = tracks
        for track in tracks { catalog[track.uri] = track }
    }

    public func clearCalls() { calls = [] }

    public func playlist(named name: String) -> Playlist? {
        playlists.first { $0.name == name && $0.isFollowed }
    }

    public func playlist(id: String) -> Playlist? {
        playlists.first { $0.id == id }
    }

    public func isLiked(_ uri: String) -> Bool {
        liked.contains { $0.uri == uri }
    }

    // MARK: - SpotifyAPI

    public func currentUser() async throws -> SpotifyUser {
        try await begin(.currentUser, .currentUser)
        return user
    }

    public func savedTracks(offset: Int, limit: Int) async throws -> Page<Track> {
        try await begin(.savedTracks, .savedTracks(offset: offset, limit: limit))
        try Self.check(limit, max: SpotifyLimits.savedTracksPage)
        return Self.page(of: liked, offset: offset, limit: limit)
    }

    public func myPlaylists(offset: Int, limit: Int) async throws -> Page<PlaylistSummary> {
        try await begin(.myPlaylists, .myPlaylists(offset: offset))
        try Self.check(limit, max: SpotifyLimits.playlistsPage)
        let summaries = playlists.filter(\.isFollowed).map {
            PlaylistSummary(id: $0.id, name: $0.name, ownerID: $0.ownerID, isCollaborative: $0.isCollaborative, trackCount: $0.uris.count, snapshotID: nil)
        }
        return Self.page(of: summaries, offset: offset, limit: limit)
    }

    public func playlistItemURIs(playlistID: String, offset: Int, limit: Int) async throws -> Page<String> {
        try await begin(.playlistItems, .playlistItems(playlistID: playlistID, offset: offset))
        try Self.check(limit, max: SpotifyLimits.playlistItemsPage)
        let playlist = try editablePlaylist(playlistID)
        return Self.page(of: playlist.uris, offset: offset, limit: limit)
    }

    public func createPlaylist(name: String, description: String, isPublic: Bool) async throws -> PlaylistSummary {
        try await begin(.createPlaylist, .createPlaylist(name: name, isPublic: isPublic))
        playlistCounter += 1
        let playlist = Playlist(id: "created\(playlistCounter)", name: name, ownerID: user.id, isCollaborative: false, isFollowed: true, uris: [])
        playlists.insert(playlist, at: 0)
        return PlaylistSummary(id: playlist.id, name: name, ownerID: user.id, isCollaborative: false, trackCount: 0, snapshotID: nil)
    }

    public func addToPlaylist(playlistID: String, uris: [String]) async throws {
        try await begin(.addToPlaylist, .addToPlaylist(playlistID: playlistID, uris: uris))
        try Self.check(uris.count, max: SpotifyLimits.playlistWrite)
        let index = try editablePlaylistIndex(playlistID)
        playlists[index].uris.append(contentsOf: uris)
    }

    public func removeFromPlaylist(playlistID: String, uris: [String]) async throws {
        try await begin(.removeFromPlaylist, .removeFromPlaylist(playlistID: playlistID, uris: uris))
        try Self.check(uris.count, max: SpotifyLimits.playlistWrite)
        let index = try editablePlaylistIndex(playlistID)
        let removing = Set(uris)
        playlists[index].uris.removeAll { removing.contains($0) }
    }

    public func saveToLibrary(uris: [String]) async throws {
        try await begin(.saveToLibrary, .saveToLibrary(uris: uris))
        try Self.check(uris.count, max: SpotifyLimits.libraryWrite)
        for uri in uris.reversed() where !isLiked(uri) {
            if let track = catalog[uri] {
                liked.insert(track, at: 0)
            }
        }
    }

    public func removeFromLibrary(uris: [String]) async throws {
        try await begin(.removeFromLibrary, .removeFromLibrary(uris: uris))
        try Self.check(uris.count, max: SpotifyLimits.libraryWrite)
        let removing = Set(uris)
        liked.removeAll { removing.contains($0.uri) }
    }

    public func libraryContains(uris: [String]) async throws -> [Bool] {
        try await begin(.libraryContains, .libraryContains(uris: uris))
        try Self.check(uris.count, max: SpotifyLimits.libraryContains)
        return uris.map { uri in
            if uri.hasPrefix("spotify:playlist:") {
                let id = String(uri.dropFirst("spotify:playlist:".count))
                return playlists.contains { $0.id == id && $0.isFollowed }
            }
            return isLiked(uri)
        }
    }

    // MARK: - Helpers

    private func begin(_ operation: Operation, _ call: Call) async throws {
        if let latency {
            try? await Task.sleep(for: latency)
        }
        calls.append(call)
        if var queued = failures[operation], !queued.isEmpty {
            let error = queued.removeFirst()
            failures[operation] = queued
            throw error
        }
    }

    private func editablePlaylistIndex(_ id: String) throws -> Int {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else {
            throw SpotifyError.notFound("Spotify: Playlist not found")
        }
        let playlist = playlists[index]
        guard playlist.ownerID == user.id || playlist.isCollaborative else {
            throw SpotifyError.forbidden("Spotify: You can't edit this playlist")
        }
        return index
    }

    private func editablePlaylist(_ id: String) throws -> Playlist {
        playlists[try editablePlaylistIndex(id)]
    }

    private static func check(_ count: Int, max: Int) throws {
        if count > max {
            throw SpotifyError.badRequest("Spotify: Too many ids requested (\(count) > \(max))")
        }
    }

    private static func page<T: Sendable>(of items: [T], offset: Int, limit: Int) -> Page<T> {
        let start = min(max(0, offset), items.count)
        let end = min(start + limit, items.count)
        return Page(items: Array(items[start..<end]), offset: offset, total: items.count)
    }
}
