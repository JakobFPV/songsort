import Foundation
import Testing
@testable import SongSortCore

@Suite("PKCE login")
struct PKCETests {
    let config = AuthConfiguration(clientID: "0123456789abcdef0123456789abcdef")

    @Test func challengeMatchesRFC7636Example() {
        #expect(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func verifierIsLongRandomAndURLSafe() {
        let verifier = PKCE.makeVerifier()
        #expect((43...128).contains(verifier.count))
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        #expect(verifier.unicodeScalars.allSatisfy(allowed.contains))
        #expect(PKCE.makeVerifier() != verifier)
    }

    @Test func authorizeURLCarriesEverythingSpotifyNeeds() throws {
        let request = AuthorizationRequest(configuration: config, verifier: "verifier", state: "state123")
        let components = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(components.host == "accounts.spotify.com")
        #expect(components.path == "/authorize")
        #expect(items["client_id"] == config.clientID)
        #expect(items["response_type"] == "code")
        #expect(items["redirect_uri"] == "songsort://callback")
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["code_challenge"] == PKCE.challenge(for: "verifier"))
        #expect(items["state"] == "state123")
        let scopes = Set((items["scope"] ?? "").split(separator: " ").map(String.init))
        #expect(scopes.isSuperset(of: ["user-library-read", "user-library-modify", "playlist-modify-private", "app-remote-control"]))
    }

    @Test func callbackParsing() throws {
        let request = AuthorizationRequest(configuration: config, verifier: "v", state: "abc")
        #expect(try request.authorizationCode(from: URL(string: "songsort://callback?code=XYZ&state=abc")!) == "XYZ")
        #expect(throws: SpotifyError.self) {
            try request.authorizationCode(from: URL(string: "songsort://callback?code=XYZ&state=other")!)
        }
        #expect(throws: SpotifyError.loginFailed("You didn't allow SongSort to use your Spotify account.")) {
            try request.authorizationCode(from: URL(string: "songsort://callback?error=access_denied&state=abc")!)
        }
    }

    @Test func clientIDValidation() {
        #expect(config.isConfigured)
        #expect(!AuthConfiguration(clientID: "").isConfigured)
        #expect(!AuthConfiguration(clientID: "YOUR_CLIENT_ID").isConfigured)
        #expect(AuthConfiguration(clientID: " 0123456789abcdef0123456789abcdef ").isConfigured)
    }
}

@Suite("Tokens")
struct TokenManagerTests {
    let config = AuthConfiguration(clientID: "0123456789abcdef0123456789abcdef")
    let clock = TestClock()

    func tokens(expiringIn seconds: TimeInterval) -> OAuthTokens {
        OAuthTokens(accessToken: "old-access", refreshToken: "refresh-1", expiresAt: clock.now.addingTimeInterval(seconds), scope: "a b")
    }

    @Test func loginExchangesTheCodeAndStoresTokens() async throws {
        let transport = StubTransport { _, _ in
            .init(json: #"{"access_token":"A1","token_type":"Bearer","scope":"user-library-read","expires_in":3600,"refresh_token":"R1"}"#)
        }
        let store = InMemoryTokenStore()
        let clock = self.clock
        let manager = TokenManager(configuration: config, store: store, transport: transport, now: { clock.now })
        let request = AuthorizationRequest(configuration: config, verifier: "the-verifier", state: "s")

        try await manager.completeLogin(callbackURL: URL(string: "songsort://callback?code=C0DE&state=s")!, request: request)

        let sent = try #require(transport.requests.first)
        #expect(sent.url == AuthConfiguration.tokenURL)
        #expect(sent.httpMethod == "POST")
        #expect(sent.formBody == [
            "grant_type": "authorization_code",
            "code": "C0DE",
            "redirect_uri": "songsort://callback",
            "client_id": config.clientID,
            "code_verifier": "the-verifier",
        ])
        #expect(store.loadTokens()?.accessToken == "A1")
        #expect(store.loadTokens()?.refreshToken == "R1")
        #expect(store.loadTokens()?.expiresAt == clock.now.addingTimeInterval(3600))
        #expect(await manager.isLoggedIn)
        #expect(try await manager.accessToken() == "A1")
    }

    @Test func freshTokenIsUsedWithoutNetwork() async throws {
        let transport = StubTransport { _, _ in .init(status: 500) }
        let clock = self.clock
        let manager = TokenManager(configuration: config, store: InMemoryTokenStore(tokens: tokens(expiringIn: 3000)), transport: transport, now: { clock.now })
        #expect(try await manager.accessToken() == "old-access")
        #expect(transport.requests.isEmpty)
    }

    @Test func expiringTokenIsRefreshedOnceForConcurrentCallers() async throws {
        let transport = StubTransport { _, _ in
            .init(json: #"{"access_token":"new-access","token_type":"Bearer","expires_in":3600}"#)
        }
        let store = InMemoryTokenStore(tokens: tokens(expiringIn: 30))
        let clock = self.clock
        let manager = TokenManager(configuration: config, store: store, transport: transport, now: { clock.now })

        let results = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<5 { group.addTask { try await manager.accessToken() } }
            return try await group.reduce(into: [String]()) { $0.append($1) }
        }

        #expect(results == Array(repeating: "new-access", count: 5))
        #expect(transport.requests.count == 1)
        #expect(transport.requests[0].formBody["grant_type"] == "refresh_token")
        #expect(transport.requests[0].formBody["refresh_token"] == "refresh-1")
        // Spotify didn't send a new refresh token, so the old one is kept.
        #expect(store.loadTokens()?.refreshToken == "refresh-1")
    }

    @Test func rotatedRefreshTokenIsSaved() async throws {
        let transport = StubTransport { _, _ in
            .init(json: #"{"access_token":"new-access","token_type":"Bearer","expires_in":3600,"refresh_token":"refresh-2"}"#)
        }
        let store = InMemoryTokenStore(tokens: tokens(expiringIn: 0))
        let clock = self.clock
        let manager = TokenManager(configuration: config, store: store, transport: transport, now: { clock.now })
        _ = try await manager.accessToken()
        #expect(store.loadTokens()?.refreshToken == "refresh-2")
    }

    @Test func revokedRefreshTokenEndsTheSession() async throws {
        let transport = StubTransport { _, _ in
            .init(status: 400, json: #"{"error":"invalid_grant","error_description":"Refresh token revoked"}"#)
        }
        let store = InMemoryTokenStore(tokens: tokens(expiringIn: 0))
        let expired = Flag()
        let clock = self.clock
        let manager = TokenManager(configuration: config, store: store, transport: transport, now: { clock.now })
        await manager.setSessionExpiredHandler { expired.set() }

        await #expect(throws: SpotifyError.loginRequired) { try await manager.accessToken() }
        #expect(store.loadTokens() == nil)
        #expect(!(await manager.isLoggedIn))
        #expect(expired.isSet)
    }

    @Test func offlineRefreshKeepsTheSession() async throws {
        let transport = StubTransport { _, _ in throw SpotifyError.offline }
        let store = InMemoryTokenStore(tokens: tokens(expiringIn: 0))
        let clock = self.clock
        let manager = TokenManager(configuration: config, store: store, transport: transport, now: { clock.now })
        await #expect(throws: SpotifyError.offline) { try await manager.accessToken() }
        #expect(store.loadTokens() != nil)
        #expect(await manager.isLoggedIn)
    }

    @Test func logoutDeletesTokens() async {
        let store = InMemoryTokenStore(tokens: tokens(expiringIn: 3000))
        let manager = TokenManager(configuration: config, store: store, transport: StubTransport { _, _ in .init() })
        await manager.logout()
        #expect(store.loadTokens() == nil)
        await #expect(throws: SpotifyError.loginRequired) { try await manager.accessToken() }
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
