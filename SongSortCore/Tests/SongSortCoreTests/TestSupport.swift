import Foundation
@testable import SongSortCore

func makeTrack(_ number: Int, durationMs: Int = 200_000) -> Track {
    Track(
        id: "t\(number)",
        name: "Song \(number)",
        artists: ["Artist \(number)"],
        album: "Album \(number)",
        releaseYear: 1990 + number % 30,
        durationMs: durationMs
    )
}

func makeTracks(_ count: Int) -> [Track] {
    count == 0 ? [] : (1...count).map { makeTrack($0) }
}

/// A clock the tests move forward by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)

    var now: Date { lock.withLock { current } }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

/// App wiring with an in-memory Spotify, an in-memory "disk" and a manual clock.
@MainActor
final class Harness {
    let clock: TestClock
    let api: InMemorySpotifyAPI
    let persistence: InMemoryStatePersistence
    let store: StateStore
    let sync: SyncEngine

    init(
        liked: [Track] = [],
        api: InMemorySpotifyAPI? = nil,
        persistence: InMemoryStatePersistence = InMemoryStatePersistence(),
        clock: TestClock = TestClock()
    ) {
        self.clock = clock
        self.api = api ?? InMemorySpotifyAPI(liked: liked)
        self.persistence = persistence
        self.store = StateStore(persistence: persistence)
        self.sync = SyncEngine(store: store, api: self.api, now: { clock.now })
    }

    func session(_ source: SortSource = .likedSongs) -> SortSession {
        let clock = self.clock
        return SortSession(source: source, api: api, store: store, sync: sync, now: { clock.now })
    }

    /// Quit and relaunch: everything in memory is gone except what was saved, and Spotify itself.
    func relaunch() async -> Harness {
        await store.flush()
        return Harness(api: api, persistence: InMemoryStatePersistence(initial: persistence.savedState), clock: clock)
    }

    /// Lets the hold window pass and sends everything due.
    func syncAll() async {
        clock.advance(by: Outbox.defaultHold + 1)
        await sync.runOnce()
    }

    var rejectedPlaylistName: String { RejectedPlaylistNaming.name(forSourceNamed: "Liked Songs") }

    func rejectedPlaylist() async -> InMemorySpotifyAPI.Playlist? {
        await api.playlist(named: rejectedPlaylistName)
    }

    func likedIDs() async -> [String] {
        await api.liked.map(\.id)
    }

    func writeCalls() async -> [InMemorySpotifyAPI.Call] {
        await api.calls.filter(\.isWrite)
    }
}

/// An HTTP stub that records requests and answers from a closure.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    struct Reply {
        var status = 200
        var json = "{}"
        var headers: [String: String] = [:]
    }

    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private let handler: @Sendable (URLRequest, Int) throws -> Reply

    init(_ handler: @escaping @Sendable (URLRequest, Int) throws -> Reply) {
        self.handler = handler
    }

    var requests: [URLRequest] { lock.withLock { recorded } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let index = lock.withLock {
            recorded.append(request)
            return recorded.count - 1
        }
        let reply = try handler(request, index)
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        return (Data(reply.json.utf8), response)
    }
}

actor FixedTokens: AccessTokenProvider {
    private(set) var refreshes = 0

    func accessToken() async throws -> String { "token-\(refreshes + 1)" }

    func refreshedAccessToken() async throws -> String {
        refreshes += 1
        return "token-\(refreshes + 1)"
    }
}

extension URLRequest {
    var queryItems: [String: String] {
        let items = URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    var jsonBody: [String: Any]? {
        httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    var formBody: [String: String] {
        guard let body = httpBody, let string = String(data: body, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for pair in string.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            result[parts[0]] = parts[1].removingPercentEncoding
        }
        return result
    }
}
