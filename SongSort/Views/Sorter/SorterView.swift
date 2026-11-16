import AuthenticationServices
import SongSortCore
import SwiftUI

struct SorterView: View {
    @State private var model: SorterModel
    @State private var confirmStartOver = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @Environment(AppModel.self) private var app

    init(session: SortSession, player: any MusicPlayer, sync: SyncEngine) {
        _model = State(initialValue: SorterModel(session: session, player: player, sync: sync))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            StatusBanner()
            content
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .task { await model.appear() }
        .onDisappear { model.disappear() }
        .sensoryFeedback(.impact(weight: .medium), trigger: model.decisionCount)
        .sensoryFeedback(.selection, trigger: model.undoCount)
        .overlay(alignment: .top) { toast }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.toast)
        .confirmationDialog("Start over with \(model.session.source.displayName)?", isPresented: $confirmStartOver, titleVisibility: .visible) {
            Button("Start over", role: .destructive) {
                Task { await model.startOver() }
            }
        } message: {
            Text("SongSort forgets which songs you've already sorted here. Songs already in “\(RejectedPlaylistNaming.name(forSourceNamed: model.session.source.displayName))” stay there.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Close")

            Spacer()

            VStack(spacing: 1) {
                Text(model.session.source.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(counterText)
                    .font(.headline.monospacedDigit())
                    .contentTransition(.numericText())
                    .animation(.snappy, value: counterText)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(model.session.source.displayName), song \(counterText.replacingOccurrences(of: " / ", with: " of "))")

            Spacer()

            Menu {
                Picker("Order", selection: orderBinding) {
                    ForEach(QueueOrder.allCases, id: \.self) { order in
                        Text(order.label).tag(order)
                    }
                }
                if let track = model.session.current, let url = SpotifyLinks.track(track) {
                    Button {
                        openURL(url)
                    } label: {
                        Label("Open in Spotify", systemImage: "arrow.up.right.square")
                    }
                }
                Button(role: .destructive) {
                    confirmStartOver = true
                } label: {
                    Label("Start over…", systemImage: "arrow.counterclockwise")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("More")
        }
        .padding(.horizontal, 8)
    }

    private var counterText: String {
        switch model.session.phase {
        case .idle, .loading, .failed: "–"
        case .sorting, .empty, .finished: model.session.counterText
        }
    }

    private var orderBinding: Binding<QueueOrder> {
        Binding(get: { model.session.order }, set: { model.setOrder($0) })
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch model.session.phase {
        case .idle, .loading:
            loading
        case .failed(let error):
            failure(error)
        case .empty:
            message(
                icon: "music.note",
                title: "Nothing to sort",
                text: "Your \(model.session.source.displayName) is empty. Like some songs in Spotify, then come back."
            )
        case .finished:
            finished
        case .sorting:
            VStack(spacing: 14) {
                CardStackView(model: model)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                PlaybackControlsView(model: model)
                    .padding(.horizontal, 24)
                DecisionBar(model: model)
                    .padding(.bottom, 10)
            }
        }
    }

    private var loading: some View {
        VStack(spacing: 14) {
            Spacer()
            if case .loading(let loaded, let total) = model.session.phase, total > 0 {
                ProgressView(value: Double(loaded), total: Double(total))
                    .frame(maxWidth: 240)
                Text("Loading \(model.session.source.displayName)… \(loaded) of \(total)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                ProgressView()
                Text("Loading \(model.session.source.displayName)…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func failure(_ error: SpotifyError) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: error == .offline ? "wifi.slash" : "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text(error.title)
                .font(.title3.bold())
                .multilineTextAlignment(.center)
            Text(error == .offline ? "Couldn't load your songs. Check your connection and try again." : error.message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if error == .loginRequired {
                Button("Log in again") {
                    Task {
                        await app.logIn(using: authenticate)
                        if !app.needsLogin { await model.reload() }
                    }
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Try again") { Task { await model.reload() } }
                    .buttonStyle(.borderedProminent)
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }

    private func message(icon: String, title: String, text: String) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text(title).font(.title2.bold())
            Text(text)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }

    private var finished: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("All \(model.session.total) songs sorted")
                .font(.title2.bold())
            Text("Rejected songs are in the playlist “\(RejectedPlaylistNaming.name(forSourceNamed: model.session.source.displayName))” in Spotify.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            VStack(spacing: 10) {
                if model.session.canUndo {
                    Button {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { model.undo() }
                    } label: {
                        Label("Undo last swipe", systemImage: "arrow.uturn.backward")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                }
                Button(role: .destructive) {
                    confirmStartOver = true
                } label: {
                    Text("Start over…").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                Button {
                    dismiss()
                } label: {
                    Text("Done").frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
    }

    @ViewBuilder
    private var toast: some View {
        if let toast = model.toast {
            Text(toast.text)
                .font(.footnote.weight(.medium))
                .lineLimit(2)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 60)
                .padding(.horizontal, 24)
                .transition(.move(edge: .top).combined(with: .opacity))
                .id(toast.id)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    private func authenticate(_ url: URL) async throws -> URL {
        try await webAuthenticationSession.authenticate(
            using: url,
            callbackURLScheme: AuthConfiguration.callbackScheme,
            preferredBrowserSession: .shared
        )
    }
}
