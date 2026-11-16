import AuthenticationServices
import SongSortCore
import SwiftUI

/// The one most important problem right now: login expired, offline, rate-limited, or failed writes.
struct StatusBanner: View {
    @Environment(AppModel.self) private var app
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    private struct Content {
        let icon: String
        let tint: Color
        let title: String
        let message: String?
        var actionTitle: String?
        var action: (() -> Void)?
    }

    var body: some View {
        if let content {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: content.icon)
                    .font(.title3)
                    .foregroundStyle(content.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(content.title)
                        .font(.subheadline.weight(.semibold))
                    if let message = content.message {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if let title = content.actionTitle, let action = content.action {
                    Button(title, action: action)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .padding(12)
            .background(content.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var content: Content? {
        let sync = app.env.sync
        let unsent = sync.unsentCount

        if app.needsLogin {
            return Content(
                icon: "person.crop.circle.badge.exclamationmark",
                tint: .orange,
                title: SpotifyError.loginRequired.title,
                message: unsent > 0 ? "\(Self.changes(unsent)) waiting. Log in again to send them." : "Log in again to keep sorting.",
                actionTitle: "Log in",
                action: { Task { await app.logIn(using: authenticate) } }
            )
        }
        if !app.env.network.isOnline || sync.status == .offline {
            return Content(
                icon: "wifi.slash",
                tint: .orange,
                title: "You're offline",
                message: unsent > 0
                    ? "\(Self.changes(unsent)) will sync when you're back online."
                    : "Swipes are saved and sync when you're back online."
            )
        }
        if case .backingOff(let until, let reason) = sync.status {
            return Content(
                icon: "hourglass",
                tint: .orange,
                title: reason.title,
                message: "\(Self.changes(unsent)) waiting. Retrying at \(until.formatted(date: .omitted, time: .shortened))."
            )
        }
        let failed = sync.failedWrites
        if let first = failed.first, case .failed(let message) = first.state {
            return Content(
                icon: "exclamationmark.triangle.fill",
                tint: .red,
                title: "\(Self.changes(failed.count)) couldn't be saved to Spotify",
                message: message,
                actionTitle: "Retry",
                action: { sync.retryFailed() }
            )
        }
        if let saveError = app.env.store.lastSaveError {
            return Content(icon: "externaldrive.badge.exclamationmark", tint: .red, title: "Couldn't save progress", message: saveError)
        }
        return nil
    }

    static func changes(_ count: Int) -> String {
        count == 1 ? "1 change" : "\(count) changes"
    }

    private func authenticate(_ url: URL) async throws -> URL {
        try await webAuthenticationSession.authenticate(
            using: url,
            callbackURLScheme: AuthConfiguration.callbackScheme,
            preferredBrowserSession: .shared
        )
    }
}

extension QueueOrder {
    var label: String {
        switch self {
        case .sourceOrder: "Newest first"
        case .reversed: "Oldest first"
        case .shuffled: "Shuffle"
        }
    }
}
