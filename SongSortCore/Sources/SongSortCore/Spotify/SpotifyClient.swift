import Foundation

/// Supplies OAuth access tokens. `TokenManager` is the real one.
public protocol AccessTokenProvider: Sendable {
    /// A token that is valid for at least a little while (refreshing first if needed).
    func accessToken() async throws -> String
    /// A brand-new token, used after Spotify answered 401.
    func refreshedAccessToken() async throws -> String
}

/// Spotify Web API client: builds requests, attaches the token, maps every failure to `SpotifyError`.
public final class SpotifyClient: SpotifyAPI {
    public static let baseURL = URL(string: "https://api.spotify.com/v1/")!

    private let transport: HTTPTransport
    private let tokens: AccessTokenProvider
    private let maxWaitForRateLimit: TimeInterval
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    /// - Parameters:
    ///   - maxWaitForRateLimit: a 429 with a `Retry-After` up to this long is waited out and retried here;
    ///     longer waits are handed to the caller as `.rateLimited` (the sync engine then backs off).
    public init(
        transport: HTTPTransport = URLSessionTransport(),
        tokens: AccessTokenProvider,
        maxWaitForRateLimit: TimeInterval = 10,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.transport = transport
        self.tokens = tokens
        self.maxWaitForRateLimit = maxWaitForRateLimit
        self.sleep = sleep
    }

    // MARK: - Endpoints

    public func currentUser() async throws -> SpotifyUser {
        let dto = try decode(UserDTO.self, from: await perform(Endpoint(method: "GET", path: "me")))
        return SpotifyUser(id: dto.id, displayName: dto.displayName)
    }

    public func savedTracks(offset: Int, limit: Int) async throws -> Page<Track> {
        let data = try await perform(Endpoint(method: "GET", path: "me/tracks", query: Self.paging(offset, limit)))
        let dto = try decode(PagingDTO<SavedTrackDTO>.self, from: data)
        return Page(
            items: dto.items.compactMap { $0.track?.makeTrack() },
            rawCount: dto.items.count,
            offset: dto.offset ?? offset,
            total: dto.total
        )
    }

    public func myPlaylists(offset: Int, limit: Int) async throws -> Page<PlaylistSummary> {
        let data = try await perform(Endpoint(method: "GET", path: "me/playlists", query: Self.paging(offset, limit)))
        let dto = try decode(PagingDTO<PlaylistDTO>.self, from: data)
        return Page(items: dto.items.map { $0.makeSummary() }, offset: dto.offset ?? offset, total: dto.total)
    }

    public func playlistItemURIs(playlistID: String, offset: Int, limit: Int) async throws -> Page<String> {
        let query = Self.paging(offset, limit) + [URLQueryItem(name: "additional_types", value: "track,episode")]
        let data = try await perform(Endpoint(method: "GET", path: "playlists/\(playlistID)/items", query: query))
        let dto = try decode(PagingDTO<PlaylistItemDTO>.self, from: data)
        return Page(
            items: dto.items.compactMap { $0.content?.uri },
            rawCount: dto.items.count,
            offset: dto.offset ?? offset,
            total: dto.total
        )
    }

    public func createPlaylist(name: String, description: String, isPublic: Bool) async throws -> PlaylistSummary {
        let body = try Self.encode(CreatePlaylistBody(name: name, description: description, public: isPublic))
        let data = try await perform(Endpoint(method: "POST", path: "me/playlists", body: body))
        return try decode(PlaylistDTO.self, from: data).makeSummary()
    }

    public func addToPlaylist(playlistID: String, uris: [String]) async throws {
        guard !uris.isEmpty else { return }
        try Self.check(uris.count, max: SpotifyLimits.playlistWrite)
        let body = try Self.encode(AddItemsBody(uris: uris))
        _ = try await perform(Endpoint(method: "POST", path: "playlists/\(playlistID)/items", body: body))
    }

    public func removeFromPlaylist(playlistID: String, uris: [String]) async throws {
        guard !uris.isEmpty else { return }
        try Self.check(uris.count, max: SpotifyLimits.playlistWrite)
        let body = try Self.encode(RemoveItemsBody(items: uris.map { .init(uri: $0) }))
        _ = try await perform(Endpoint(method: "DELETE", path: "playlists/\(playlistID)/items", body: body))
    }

    public func saveToLibrary(uris: [String]) async throws {
        guard !uris.isEmpty else { return }
        try Self.check(uris.count, max: SpotifyLimits.libraryWrite)
        _ = try await perform(Endpoint(method: "PUT", path: "me/library", query: [Self.urisItem(uris)]))
    }

    public func removeFromLibrary(uris: [String]) async throws {
        guard !uris.isEmpty else { return }
        try Self.check(uris.count, max: SpotifyLimits.libraryWrite)
        _ = try await perform(Endpoint(method: "DELETE", path: "me/library", query: [Self.urisItem(uris)]))
    }

    public func libraryContains(uris: [String]) async throws -> [Bool] {
        guard !uris.isEmpty else { return [] }
        try Self.check(uris.count, max: SpotifyLimits.libraryContains)
        let data = try await perform(Endpoint(method: "GET", path: "me/library/contains", query: [Self.urisItem(uris)]))
        return try decode([Bool].self, from: data)
    }

    // MARK: - Plumbing

    struct Endpoint {
        var method: String
        var path: String
        var query: [URLQueryItem] = []
        var body: Data? = nil
    }

    func makeRequest(_ endpoint: Endpoint, token: String) throws -> URLRequest {
        guard var components = URLComponents(
            url: Self.baseURL.appendingPathComponent(endpoint.path),
            resolvingAgainstBaseURL: false
        ) else {
            throw SpotifyError.badRequest("Couldn't build the request URL.")
        }
        if !endpoint.query.isEmpty {
            components.queryItems = endpoint.query
        }
        guard let url = components.url else { throw SpotifyError.badRequest("Couldn't build the request URL.") }
        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body = endpoint.body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    func perform(_ endpoint: Endpoint) async throws -> Data {
        var token = try await tokens.accessToken()
        var didRefresh = false
        var rateLimitRetries = 0
        var serverRetries = 0

        while true {
            let (data, response) = try await transport.send(makeRequest(endpoint, token: token))
            let status = response.statusCode
            switch status {
            case 200..<300:
                return data
            case 401:
                // Expired or revoked access token: refresh once, then give up and ask for a new login.
                guard !didRefresh else { throw SpotifyError.loginRequired }
                didRefresh = true
                token = try await tokens.refreshedAccessToken()
            case 429:
                let info = Self.errorBody(data)
                if info?.reason == "QUOTA_EXCEEDED" {
                    throw SpotifyError.quotaExceeded
                }
                let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? 5
                guard retryAfter <= maxWaitForRateLimit, rateLimitRetries < 2 else {
                    throw SpotifyError.rateLimited(retryAfter: retryAfter)
                }
                rateLimitRetries += 1
                try await pause(retryAfter)
            case 500...:
                guard serverRetries < 1 else { throw SpotifyError.server(status: status) }
                serverRetries += 1
                try await pause(1)
            default:
                throw Self.clientError(status: status, data: data)
            }
        }
    }

    private func pause(_ seconds: TimeInterval) async throws {
        do {
            try await sleep(seconds)
        } catch {
            throw SpotifyError.cancelled
        }
    }

    static func clientError(status: Int, data: Data) -> SpotifyError {
        let message = errorBody(data)?.message
        switch status {
        case 403:
            return .forbidden(message.map { "Spotify: \($0)" } ?? "Spotify returned 403 Forbidden.")
        case 404:
            return .notFound(message.map { "Spotify: \($0)" } ?? "Spotify couldn't find that item.")
        case 400..<500:
            return .badRequest(message.map { "Spotify: \($0)" } ?? "Spotify returned error \(status).")
        default:
            return .invalidResponse("Spotify returned an unexpected status \(status).")
        }
    }

    static func errorBody(_ data: Data) -> ErrorEnvelopeDTO.Body? {
        try? makeDecoder().decode(ErrorEnvelopeDTO.self, from: data).error
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try Self.makeDecoder().decode(T.self, from: data)
        } catch {
            throw SpotifyError.invalidResponse("Couldn't read Spotify's answer (\(T.self)).")
        }
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            throw SpotifyError.badRequest("Couldn't encode the request.")
        }
    }

    static func paging(_ offset: Int, _ limit: Int) -> [URLQueryItem] {
        [URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "offset", value: String(offset))]
    }

    static func urisItem(_ uris: [String]) -> URLQueryItem {
        URLQueryItem(name: "uris", value: uris.joined(separator: ","))
    }

    static func check(_ count: Int, max: Int) throws {
        if count > max {
            throw SpotifyError.badRequest("Too many items in one request (\(count), Spotify allows \(max)).")
        }
    }
}
