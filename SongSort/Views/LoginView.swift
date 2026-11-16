import AuthenticationServices
import SongSortCore
import SwiftUI

struct LoginView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            AppMark()
            VStack(spacing: 8) {
                Text("SongSort")
                    .font(.largeTitle.bold())
                Text("Swipe through your Spotify library.\nRight to keep, left to reject.")
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            if !app.isConfigured {
                MessageCard(
                    icon: "key.slash",
                    tint: .orange,
                    title: SpotifyError.notConfigured.title,
                    message: "Copy Config/Local.example.xcconfig to Config/Local.xcconfig, add your Client ID, and rebuild. The README walks you through it."
                )
            }
            if let error = app.loginError {
                MessageCard(icon: "exclamationmark.triangle.fill", tint: .red, title: "Login didn't work", message: error)
            }

            Button {
                Task { await app.logIn(using: authenticate) }
            } label: {
                Group {
                    if app.isLoggingIn {
                        ProgressView()
                    } else {
                        Text("Log in with Spotify")
                    }
                }
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!app.isConfigured || app.isLoggingIn)

            Text("Needs Spotify Premium and the Spotify app on this iPhone.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
    }

    private func authenticate(_ url: URL) async throws -> URL {
        try await webAuthenticationSession.authenticate(
            using: url,
            callbackURLScheme: AuthConfiguration.callbackScheme,
            preferredBrowserSession: .shared
        )
    }
}

/// Two stacked cards with a heart, echoing the app icon.
struct AppMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white.opacity(0.45))
                .frame(width: 70, height: 92)
                .rotationEffect(.degrees(-12))
                .offset(x: -14)
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white)
                .frame(width: 70, height: 92)
                .rotationEffect(.degrees(8))
                .offset(x: 10)
                .overlay {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(Color(red: 0.95, green: 0.33, blue: 0.42))
                        .rotationEffect(.degrees(8))
                        .offset(x: 10)
                }
        }
        .frame(width: 140, height: 140)
        .background(
            LinearGradient(
                colors: [Color(red: 0.20, green: 0.11, blue: 0.47), Color(red: 0.98, green: 0.42, blue: 0.40)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 32, style: .continuous)
        )
        .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
        .accessibilityHidden(true)
    }
}

struct MessageCard: View {
    let icon: String
    let tint: Color
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
