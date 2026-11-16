import Foundation

/// Every failure the app can get from Spotify, already classified so callers can decide
/// whether to retry, wait, ask for a new login, or show the error.
public enum SpotifyError: Error, Equatable, Sendable {
    /// The Spotify Client ID is missing from Config/Local.xcconfig.
    case notConfigured
    /// No stored login, or Spotify rejected the refresh token.
    case loginRequired
    /// The Spotify login page reported an error or the user cancelled.
    case loginFailed(String)
    /// No internet connection or the request timed out.
    case offline
    /// HTTP 429 from the normal rate limiter.
    case rateLimited(retryAfter: TimeInterval)
    /// HTTP 429 with reason QUOTA_EXCEEDED (Development Mode quota of the developer account).
    case quotaExceeded
    /// HTTP 403, e.g. account not allowlisted, owner's Premium lapsed, or playlist not editable.
    case forbidden(String)
    case notFound(String)
    case badRequest(String)
    case server(status: Int)
    case invalidResponse(String)
    case cancelled

    /// Worth retrying automatically later without the user doing anything.
    public var isTransient: Bool {
        switch self {
        case .offline, .rateLimited, .quotaExceeded, .server, .cancelled: true
        default: false
        }
    }

    public var title: String {
        switch self {
        case .notConfigured: "Spotify Client ID missing"
        case .loginRequired: "Your Spotify login expired"
        case .loginFailed: "Spotify login didn't finish"
        case .offline: "You're offline"
        case .rateLimited: "Spotify asked SongSort to slow down"
        case .quotaExceeded: "Spotify's limit for your developer account was reached"
        case .forbidden: "Spotify refused the request"
        case .notFound: "Not found on Spotify"
        case .badRequest: "Spotify rejected the request"
        case .server: "Spotify is having problems"
        case .invalidResponse: "Unexpected answer from Spotify"
        case .cancelled: "Cancelled"
        }
    }

    public var message: String {
        switch self {
        case .notConfigured:
            "Add your Client ID to Config/Local.xcconfig and rebuild. The README explains how."
        case .loginRequired:
            "Log in again to keep syncing. Your swipes are saved on this phone."
        case .loginFailed(let reason):
            reason
        case .offline:
            "Check your connection. Swipes are saved and sync when you're back online."
        case .rateLimited(let retryAfter):
            "Retrying in \(Int(retryAfter.rounded(.up))) s. Nothing is lost."
        case .quotaExceeded:
            "Development-mode apps have a usage quota. Changes are saved and will sync later."
        case .forbidden(let reason), .notFound(let reason), .badRequest(let reason), .invalidResponse(let reason):
            reason
        case .server(let status):
            "Spotify returned error \(status). SongSort will retry."
        case .cancelled:
            "The request was cancelled."
        }
    }
}
