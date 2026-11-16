import CryptoKit
import Foundation

/// Authorization Code with PKCE (RFC 7636): no client secret ever ships in the app.
public enum PKCE {
    /// 64 random bytes, base64url-encoded: 86 characters, within the 43–128 the RFC allows.
    public static func makeVerifier() -> String {
        base64URL(randomBytes(64))
    }

    /// S256 challenge: base64url(SHA256(verifier)).
    public static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    public static func makeState() -> String {
        base64URL(randomBytes(16))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}

public struct AuthConfiguration: Sendable, Equatable {
    /// Must be added, exactly like this, to the app's Redirect URIs in the Spotify developer dashboard.
    public static let defaultRedirectURI = "songsort://callback"
    public static let callbackScheme = "songsort"

    /// Requested once for all three phases so a later phase never forces a new login.
    public static let defaultScopes = [
        "user-library-read",
        "user-library-modify",
        "playlist-read-private",
        "playlist-read-collaborative",
        "playlist-modify-private",
        "playlist-modify-public",
        "app-remote-control",
        "user-read-playback-state",
        "user-modify-playback-state",
        "user-top-read",
        "user-read-recently-played",
    ]

    public static let authorizeURL = URL(string: "https://accounts.spotify.com/authorize")!
    public static let tokenURL = URL(string: "https://accounts.spotify.com/api/token")!

    public let clientID: String
    public let redirectURI: String
    public let scopes: [String]

    public init(clientID: String, redirectURI: String = Self.defaultRedirectURI, scopes: [String] = Self.defaultScopes) {
        self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.redirectURI = redirectURI
        self.scopes = scopes
    }

    /// Spotify Client IDs are 32 hexadecimal characters.
    public var isConfigured: Bool {
        clientID.count == 32 && clientID.allSatisfy(\.isHexDigit)
    }
}

/// One login attempt: the URL to open, plus the secrets needed to finish it.
public struct AuthorizationRequest: Sendable, Equatable {
    public let url: URL
    public let verifier: String
    public let state: String

    public init(configuration: AuthConfiguration, verifier: String = PKCE.makeVerifier(), state: String = PKCE.makeState()) {
        var components = URLComponents(url: AuthConfiguration.authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: PKCE.challenge(for: verifier)),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: configuration.scopes.joined(separator: " ")),
        ]
        self.url = components.url!
        self.verifier = verifier
        self.state = state
    }

    /// Reads the authorization code from `songsort://callback?code=…&state=…`.
    public func authorizationCode(from callbackURL: URL) throws -> String {
        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        if let error = value("error") {
            if error == "access_denied" {
                throw SpotifyError.loginFailed("You didn't allow SongSort to use your Spotify account.")
            }
            throw SpotifyError.loginFailed("Spotify reported “\(error)”. Check the redirect URI and Client ID in the README.")
        }
        guard value("state") == state else {
            throw SpotifyError.loginFailed("The login answer didn't match this attempt. Please try again.")
        }
        guard let code = value("code"), !code.isEmpty else {
            throw SpotifyError.loginFailed("Spotify didn't send a login code. Please try again.")
        }
        return code
    }
}
