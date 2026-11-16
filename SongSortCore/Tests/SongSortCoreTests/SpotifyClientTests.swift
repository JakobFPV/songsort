import Foundation
import Testing
@testable import SongSortCore

@Suite("Spotify Web API requests")
struct SpotifyClientTests {
    func client(_ transport: StubTransport, tokens: FixedTokens = FixedTokens(), sleeps: SleepRecorder = SleepRecorder()) -> SpotifyClient {
        SpotifyClient(transport: transport, tokens: tokens, maxWaitForRateLimit: 10, sleep: { await sleeps.record($0) })
    }

    // MARK: Request shapes (Feb 2026 endpoints)

    @Test func savedTracksRequestAndDecoding() async throws {
        let transport = StubTransport { _, _ in .init(json: Fixtures.savedTracksPage) }
        let page = try await client(transport).savedTracks(offset: 100, limit: 50)

        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/v1/me/tracks")
        #expect(request.queryItems == ["limit": "50", "offset": "100"])
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token-1")

        // The local file and the removed track are skipped but still count as raw entries.
        #expect(page.items.count == 1)
        #expect(page.rawCount == 3)
        #expect(page.total == 3)
        let track = try #require(page.items.first)
        #expect(track.id == "abc")
        #expect(track.uri == "spotify:track:abc")
        #expect(track.name == "Song A")
        #expect(track.artists == ["Artist One", "Artist Two"])
        #expect(track.album == "Album A")
        #expect(track.releaseYear == 1997)
        #expect(track.durationMs == 245_000)
        #expect(track.artworkURL?.absoluteString == "https://i.scdn.co/image/large")
    }

    @Test func playlistItemsReadBothItemAndDeprecatedTrack() async throws {
        let transport = StubTransport { _, _ in .init(json: Fixtures.playlistItemsPage) }
        let page = try await client(transport).playlistItemURIs(playlistID: "PL1", offset: 0, limit: 50)
        #expect(transport.requests.first?.url?.path == "/v1/playlists/PL1/items")
        #expect(page.items == ["spotify:track:new", "spotify:track:old", "spotify:episode:ep"])
    }

    @Test func removeFromLibraryUsesTheGenericLibraryEndpoint() async throws {
        let transport = StubTransport { _, _ in .init() }
        try await client(transport).removeFromLibrary(uris: ["spotify:track:a", "spotify:track:b"])
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == "/v1/me/library")
        #expect(request.queryItems["uris"] == "spotify:track:a,spotify:track:b")
    }

    @Test func saveToLibraryUsesPut() async throws {
        let transport = StubTransport { _, _ in .init() }
        try await client(transport).saveToLibrary(uris: ["spotify:track:a"])
        #expect(transport.requests.first?.httpMethod == "PUT")
        #expect(transport.requests.first?.url?.path == "/v1/me/library")
    }

    @Test func addToPlaylistSendsURIsInTheBody() async throws {
        let transport = StubTransport { _, _ in .init(status: 201, json: #"{"snapshot_id":"s"}"#) }
        try await client(transport).addToPlaylist(playlistID: "PL1", uris: ["spotify:track:a"])
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/v1/playlists/PL1/items")
        #expect(request.jsonBody?["uris"] as? [String] == ["spotify:track:a"])
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test func removeFromPlaylistSendsItemsInTheBody() async throws {
        let transport = StubTransport { _, _ in .init(json: #"{"snapshot_id":"s"}"#) }
        try await client(transport).removeFromPlaylist(playlistID: "PL1", uris: ["spotify:track:a"])
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == "/v1/playlists/PL1/items")
        let items = request.jsonBody?["items"] as? [[String: String]]
        #expect(items == [["uri": "spotify:track:a"]])
    }

    @Test func createPlaylistIsPrivateAndUsesMePlaylists() async throws {
        let transport = StubTransport { _, _ in .init(status: 201, json: Fixtures.createdPlaylist) }
        let playlist = try await client(transport).createPlaylist(name: "Rejected – Liked Songs", description: "d", isPublic: false)
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/v1/me/playlists")
        #expect(request.jsonBody?["name"] as? String == "Rejected – Liked Songs")
        #expect(request.jsonBody?["public"] as? Bool == false)
        #expect(playlist.id == "NEW1")
        #expect(playlist.ownerID == "me")
    }

    @Test func myPlaylistsReadsRenamedItemsCount() async throws {
        let transport = StubTransport { _, _ in .init(json: Fixtures.myPlaylistsPage) }
        let page = try await client(transport).myPlaylists(offset: 0, limit: 50)
        #expect(page.items.map(\.trackCount) == [12, 7])
        #expect(page.items.first?.isCollaborative == true)
    }

    @Test func libraryContainsReturnsBooleans() async throws {
        let transport = StubTransport { _, _ in .init(json: "[true,false]") }
        let result = try await client(transport).libraryContains(uris: ["spotify:playlist:a", "spotify:playlist:b"])
        #expect(result == [true, false])
        #expect(transport.requests.first?.url?.path == "/v1/me/library/contains")
    }

    @Test func tooManyURIsAreRefusedBeforeSending() async {
        let transport = StubTransport { _, _ in .init() }
        let uris = (1...41).map { "spotify:track:\($0)" }
        await #expect(throws: SpotifyError.self) { try await client(transport).removeFromLibrary(uris: uris) }
        #expect(transport.requests.isEmpty)
    }

    @Test func emptyWritesSendNothing() async throws {
        let transport = StubTransport { _, _ in .init() }
        try await client(transport).removeFromLibrary(uris: [])
        try await client(transport).addToPlaylist(playlistID: "x", uris: [])
        #expect(transport.requests.isEmpty)
    }

    // MARK: Errors

    @Test func expiredTokenIsRefreshedAndRetriedOnce() async throws {
        let transport = StubTransport { _, index in index == 0 ? .init(status: 401) : .init(json: #"{"id":"me","display_name":"Jo"}"#) }
        let tokens = FixedTokens()
        let user = try await client(transport, tokens: tokens).currentUser()
        #expect(user == SpotifyUser(id: "me", displayName: "Jo"))
        #expect(transport.requests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer token-1", "Bearer token-2"])
    }

    @Test func secondUnauthorizedMeansLoginRequired() async {
        let transport = StubTransport { _, _ in .init(status: 401) }
        await #expect(throws: SpotifyError.loginRequired) { try await client(transport).currentUser() }
        #expect(transport.requests.count == 2)
    }

    @Test func quotaExceededIsRecognised() async {
        let transport = StubTransport { _, _ in
            .init(status: 429, json: #"{"error":{"status":429,"message":"Too many requests","reason":"QUOTA_EXCEEDED"}}"#)
        }
        await #expect(throws: SpotifyError.quotaExceeded) { try await client(transport).currentUser() }
        #expect(transport.requests.count == 1)
    }

    @Test func shortRateLimitIsWaitedOut() async throws {
        let transport = StubTransport { _, index in
            index == 0 ? .init(status: 429, headers: ["Retry-After": "2"]) : .init(json: #"{"id":"me"}"#)
        }
        let sleeps = SleepRecorder()
        _ = try await client(transport, sleeps: sleeps).currentUser()
        #expect(await sleeps.values == [2])
    }

    @Test func longRateLimitIsHandedToTheCaller() async {
        let transport = StubTransport { _, _ in .init(status: 429, headers: ["Retry-After": "60"]) }
        await #expect(throws: SpotifyError.rateLimited(retryAfter: 60)) { try await client(transport).currentUser() }
    }

    @Test func forbiddenCarriesSpotifysMessage() async {
        let transport = StubTransport { _, _ in
            .init(status: 403, json: #"{"error":{"status":403,"message":"User not registered in the Developer Dashboard"}}"#)
        }
        await #expect(throws: SpotifyError.forbidden("Spotify: User not registered in the Developer Dashboard")) {
            try await client(transport).currentUser()
        }
    }

    @Test func serverErrorIsRetriedOnceThenReported() async {
        let transport = StubTransport { _, _ in .init(status: 502) }
        await #expect(throws: SpotifyError.server(status: 502)) { try await client(transport).currentUser() }
        #expect(transport.requests.count == 2)
    }

    @Test func noConnectionMapsToOffline() async {
        #expect(URLSessionTransport.map(URLError(.notConnectedToInternet)) == .offline)
        #expect(URLSessionTransport.map(URLError(.timedOut)) == .offline)
        #expect(URLSessionTransport.map(URLError(.cancelled)) == .cancelled)
    }

    @Test func releaseYearParsing() {
        #expect(Track.releaseYear(from: "1997-03-12") == 1997)
        #expect(Track.releaseYear(from: "1981-12") == 1981)
        #expect(Track.releaseYear(from: "2004") == 2004)
        #expect(Track.releaseYear(from: "0000") == nil)
        #expect(Track.releaseYear(from: nil) == nil)
    }

    @Test func durationFormatting() {
        #expect(DurationFormatter.string(fromMs: 245_000) == "4:05")
        #expect(DurationFormatter.string(fromMs: 59_999) == "0:59")
        #expect(DurationFormatter.string(fromMs: 3_725_000) == "1:02:05")
    }
}

actor SleepRecorder {
    private(set) var values: [TimeInterval] = []
    func record(_ seconds: TimeInterval) { values.append(seconds) }
}

enum Fixtures {
    static let savedTracksPage = """
    {"href":"https://api.spotify.com/v1/me/tracks?offset=100&limit=50","limit":50,"next":null,"offset":100,"previous":null,"total":3,
     "items":[
      {"added_at":"2024-05-01T10:00:00Z","track":{"id":"abc","uri":"spotify:track:abc","name":"Song A","type":"track","duration_ms":245000,"is_local":false,
        "artists":[{"id":"a1","name":"Artist One"},{"id":"a2","name":"Artist Two"}],
        "album":{"name":"Album A","release_date":"1997-03-12","release_date_precision":"day","images":[
          {"url":"https://i.scdn.co/image/small","width":64,"height":64},
          {"url":"https://i.scdn.co/image/large","width":640,"height":640},
          {"url":"https://i.scdn.co/image/mid","width":300,"height":300}]}}},
      {"added_at":"2024-05-01T10:00:00Z","track":{"id":null,"uri":"spotify:local:x","name":"Local","type":"track","duration_ms":1000,"is_local":true,"artists":[],"album":{"name":"","images":[]}}},
      {"added_at":"2024-05-01T10:00:00Z","track":null}
     ]}
    """

    static let playlistItemsPage = """
    {"href":"x","limit":50,"next":null,"offset":0,"previous":null,"total":3,
     "items":[
      {"added_at":"2024-05-01T10:00:00Z","is_local":false,"item":{"id":"new","uri":"spotify:track:new","name":"New","type":"track"}},
      {"added_at":"2024-05-01T10:00:00Z","is_local":false,"track":{"id":"old","uri":"spotify:track:old","name":"Old","type":"track"}},
      {"added_at":"2024-05-01T10:00:00Z","is_local":false,"item":{"id":"ep","uri":"spotify:episode:ep","name":"Episode","type":"episode"}}
     ]}
    """

    static let createdPlaylist = """
    {"collaborative":false,"description":"d","id":"NEW1","name":"Rejected – Liked Songs","owner":{"id":"me","display_name":"Me"},
     "public":false,"snapshot_id":"snap","items":{"href":"x","total":0},"type":"playlist","uri":"spotify:playlist:NEW1"}
    """

    static let myPlaylistsPage = """
    {"href":"x","limit":50,"next":null,"offset":0,"previous":null,"total":2,
     "items":[
      {"collaborative":true,"id":"P1","name":"Road Trip","owner":{"id":"me"},"snapshot_id":"a","items":{"href":"x","total":12}},
      {"collaborative":false,"id":"P2","name":"Old style","owner":{"id":"me"},"snapshot_id":"b","tracks":{"href":"x","total":7}}
     ]}
    """
}
