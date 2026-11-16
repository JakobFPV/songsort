import Foundation

/// The parts of Spotify's Web API that SongSort uses (endpoints as of the Feb 2026 changes).
/// `SpotifyClient` talks to Spotify; `InMemorySpotifyAPI` is a faithful fake for tests and the demo mode.
public protocol SpotifyAPI: Sendable {
    /// GET /me
    func currentUser() async throws -> SpotifyUser
    /// GET /me/tracks (newest first, max 50 per page)
    func savedTracks(offset: Int, limit: Int) async throws -> Page<Track>
    /// GET /me/playlists (max 50 per page)
    func myPlaylists(offset: Int, limit: Int) async throws -> Page<PlaylistSummary>
    /// GET /playlists/{id}/items, returning only item URIs (max 50 per page)
    func playlistItemURIs(playlistID: String, offset: Int, limit: Int) async throws -> Page<String>
    /// POST /me/playlists
    func createPlaylist(name: String, description: String, isPublic: Bool) async throws -> PlaylistSummary
    /// POST /playlists/{id}/items (max 100)
    func addToPlaylist(playlistID: String, uris: [String]) async throws
    /// DELETE /playlists/{id}/items (max 100; removes every copy of each URI)
    func removeFromPlaylist(playlistID: String, uris: [String]) async throws
    /// PUT /me/library (max 40)
    func saveToLibrary(uris: [String]) async throws
    /// DELETE /me/library (max 40)
    func removeFromLibrary(uris: [String]) async throws
    /// GET /me/library/contains (max 40)
    func libraryContains(uris: [String]) async throws -> [Bool]
}

public enum SpotifyLimits {
    public static let savedTracksPage = 50
    public static let playlistsPage = 50
    public static let playlistItemsPage = 50
    public static let playlistWrite = 100
    public static let libraryWrite = 40
    public static let libraryContains = 40
}
