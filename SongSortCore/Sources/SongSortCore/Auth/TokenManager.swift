import Foundation

public struct OAuthTokens: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var scope: String

    public init(accessToken: String, refreshToken: String, expiresAt: Date, scope: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
    }
}

/// Where tokens live between launches (the Keychain in the app, memory in tests).
public protocol TokenStore: Sendable {
    func loadTokens() -> OAuthTokens?
    func saveTokens(_ tokens: OAuthTokens)
    func deleteTokens()
}

public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: OAuthTokens?

    public init(tokens: OAuthTokens? = nil) {
        self.tokens = tokens
    }

    public func loadTokens() -> OAuthTokens? { lock.withLock { tokens } }
    public func saveTokens(_ tokens: OAuthTokens) { lock.withLock { self.tokens = tokens } }
    public func deleteTokens() { lock.withLock { tokens = nil } }
}

/// Owns the OAuth session: finishes the login, keeps the access token fresh, and refreshes
/// at most once at a time even when many requests need a token simultaneously.
public actor TokenManager: AccessTokenProvider {
    /// Refresh this long before the access token actually expires.
    static let refreshMargin: TimeInterval = 120

    private let configuration: AuthConfiguration
    private let store: TokenStore
    private let transport: HTTPTransport
    private let now: @Sendable () -> Date
    private var tokens: OAuthTokens?
    private var refreshTask: Task<OAuthTokens, Error>?
    private var sessionExpiredHandler: (@Sendable () -> Void)?

    public init(
        configuration: AuthConfiguration,
        store: TokenStore,
        transport: HTTPTransport = URLSessionTransport(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.store = store
        self.transport = transport
        self.now = now
        self.tokens = store.loadTokens()
    }

    public var isLoggedIn: Bool { tokens != nil }

    /// Called when Spotify rejects the refresh token, so the UI can ask for a new login.
    public func setSessionExpiredHandler(_ handler: @escaping @Sendable () -> Void) {
        sessionExpiredHandler = handler
    }

    /// Exchanges the code from the login redirect for tokens and stores them.
    public func completeLogin(callbackURL: URL, request: AuthorizationRequest) async throws {
        let code = try request.authorizationCode(from: callbackURL)
        let response: TokenResponseDTO
        do {
            response = try await tokenRequest([
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": configuration.redirectURI,
                "client_id": configuration.clientID,
                "code_verifier": request.verifier,
            ])
        } catch let failure as OAuthFailure {
            throw SpotifyError.loginFailed(failure.userMessage)
        }
        guard let refreshToken = response.refreshToken else {
            throw SpotifyError.loginFailed("Spotify didn't return a refresh token. Please try again.")
        }
        let tokens = OAuthTokens(
            accessToken: response.accessToken,
            refreshToken: refreshToken,
            expiresAt: now().addingTimeInterval(TimeInterval(response.expiresIn)),
            scope: response.scope ?? configuration.scopes.joined(separator: " ")
        )
        self.tokens = tokens
        store.saveTokens(tokens)
    }

    public func accessToken() async throws -> String {
        guard let tokens else { throw SpotifyError.loginRequired }
        if tokens.expiresAt.timeIntervalSince(now()) > Self.refreshMargin {
            return tokens.accessToken
        }
        return try await refresh().accessToken
    }

    public func refreshedAccessToken() async throws -> String {
        try await refresh().accessToken
    }

    public func logout() {
        refreshTask?.cancel()
        refreshTask = nil
        tokens = nil
        store.deleteTokens()
    }

    // MARK: - Refresh

    private func refresh() async throws -> OAuthTokens {
        if let refreshTask {
            return try await refreshTask.value
        }
        guard let current = tokens else { throw SpotifyError.loginRequired }
        let task = Task { try await self.performRefresh(current) }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func performRefresh(_ current: OAuthTokens) async throws -> OAuthTokens {
        do {
            let response = try await tokenRequest([
                "grant_type": "refresh_token",
                "refresh_token": current.refreshToken,
                "client_id": configuration.clientID,
            ])
            let updated = OAuthTokens(
                accessToken: response.accessToken,
                // Spotify may rotate the refresh token; keep the old one if it doesn't.
                refreshToken: response.refreshToken ?? current.refreshToken,
                expiresAt: now().addingTimeInterval(TimeInterval(response.expiresIn)),
                scope: response.scope ?? current.scope
            )
            tokens = updated
            store.saveTokens(updated)
            return updated
        } catch is OAuthFailure {
            // The refresh token was revoked or expired: the session is over.
            tokens = nil
            store.deleteTokens()
            sessionExpiredHandler?()
            throw SpotifyError.loginRequired
        }
    }

    // MARK: - Token endpoint

    struct OAuthFailure: Error {
        let code: String
        let description: String?

        var userMessage: String {
            switch code {
            case "invalid_client":
                "Spotify doesn't recognise this Client ID. Check Config/Local.xcconfig."
            case "invalid_grant":
                "Spotify rejected the login code. Check that the redirect URI in the dashboard is exactly songsort://callback."
            default:
                "Spotify login failed (\(description ?? code))."
            }
        }
    }

    private func tokenRequest(_ form: [String: String]) async throws -> TokenResponseDTO {
        var request = URLRequest(url: AuthConfiguration.tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode(form)

        let (data, response) = try await transport.send(request)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        switch response.statusCode {
        case 200..<300:
            do {
                return try decoder.decode(TokenResponseDTO.self, from: data)
            } catch {
                throw SpotifyError.invalidResponse("Couldn't read Spotify's login answer.")
            }
        case 400, 401:
            let body = try? decoder.decode(OAuthErrorDTO.self, from: data)
            throw OAuthFailure(code: body?.error ?? "invalid_request", description: body?.errorDescription)
        case 429:
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? 5
            throw SpotifyError.rateLimited(retryAfter: retryAfter)
        default:
            throw SpotifyError.server(status: response.statusCode)
        }
    }

    static func formEncode(_ form: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = form
            .sorted { $0.key < $1.key }
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
        return Data(body.utf8)
    }
}

struct TokenResponseDTO: Decodable {
    let accessToken: String
    let tokenType: String?
    let scope: String?
    let expiresIn: Int
    let refreshToken: String?
}

struct OAuthErrorDTO: Decodable {
    let error: String
    let errorDescription: String?
}
