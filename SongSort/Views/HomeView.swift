import SongSortCore
import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @State private var sorter: SorterRoute?
    @State private var confirmStartOver = false

    private struct SorterRoute: Identifiable {
        let id = UUID()
        let session: SortSession
    }

    private var ledger: SortLedger? { app.env.store.state.ledger(for: .likedSongs) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button(action: openSorter) {
                        LikedSongsRow(ledger: ledger)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            confirmStartOver = true
                        } label: {
                            Label("Start over…", systemImage: "arrow.counterclockwise")
                        }
                    }
                } header: {
                    Text("Sort")
                } footer: {
                    Text("Rejected songs move to the private playlist “\(RejectedPlaylistNaming.name(forSourceNamed: "Liked Songs"))”. Nothing is deleted.")
                }

                Section {
                    ComingSoonRow(title: "Sort a playlist", icon: "music.note.list", caption: "Coming in Phase 2")
                    ComingSoonRow(title: "Discover", icon: "sparkles", caption: "Phase 3: choose an option in PLAN.md first")
                } header: {
                    Text("Next")
                }

                Section {
                    SyncStatusRow()
                } header: {
                    Text("Spotify")
                }
            }
            .navigationTitle("SongSort")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .safeAreaInset(edge: .top) {
                StatusBanner()
            }
            .safeAreaInset(edge: .bottom) {
                primaryButton
            }
            .animation(.default, value: app.needsLogin)
        }
        .fullScreenCover(item: $sorter) { route in
            SorterView(session: route.session, player: app.env.player, sync: app.env.sync)
        }
        .confirmationDialog("Start over with Liked Songs?", isPresented: $confirmStartOver, titleVisibility: .visible) {
            Button("Start over", role: .destructive) {
                app.env.store.update { $0.ledgers[SortSource.likedSongs.key]?.reset(now: Date()) }
            }
        } message: {
            Text("SongSort forgets which songs you've already sorted. Songs already in “Rejected – Liked Songs” stay there.")
        }
    }

    /// Big, thumb-reachable button at the bottom.
    private var primaryButton: some View {
        Button(action: openSorter) {
            Text(primaryTitle)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 54)
        }
        .buttonStyle(.borderedProminent)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var primaryTitle: String {
        guard let ledger, ledger.sortedCount > 0 else { return "Start sorting Liked Songs" }
        if let total = ledger.lastKnownTotal {
            return ledger.sortedCount >= total ? "Review Liked Songs" : "Resume · \(ledger.sortedCount + 1) / \(total)"
        }
        return "Resume sorting"
    }

    private func openSorter() {
        let session = SortSession(source: .likedSongs, api: app.env.api, store: app.env.store, sync: app.env.sync)
        sorter = SorterRoute(session: session)
    }
}

private struct LikedSongsRow: View {
    let ledger: SortLedger?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "heart.fill")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(
                    LinearGradient(colors: [.indigo, .pink], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
            VStack(alignment: .leading, spacing: 5) {
                Text("Liked Songs")
                    .font(.headline)
                Text(progressText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let fraction {
                    ProgressView(value: fraction)
                        .tint(.pink)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the sorter")
    }

    private var progressText: String {
        let sorted = ledger?.sortedCount ?? 0
        let rejected = ledger?.rejectedCount ?? 0
        guard let total = ledger?.lastKnownTotal else {
            return sorted > 0 ? "\(sorted) sorted" : "Not started yet"
        }
        if sorted == 0 { return "\(total) songs · not started" }
        if sorted >= total { return "All \(total) sorted · \(rejected) rejected" }
        return "\(sorted) of \(total) sorted · \(rejected) rejected"
    }

    private var fraction: Double? {
        guard let ledger, let total = ledger.lastKnownTotal, total > 0, ledger.sortedCount > 0 else { return nil }
        return min(1, Double(ledger.sortedCount) / Double(total))
    }
}

private struct ComingSoonRow: View {
    let title: String
    let icon: String
    let caption: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 54, height: 40)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.secondary)
                Text(caption).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct SyncStatusRow: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let sync = app.env.sync
        HStack(spacing: 12) {
            Image(systemName: icon(sync))
                .foregroundStyle(tint(sync))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title(sync))
                if let user = app.user {
                    Text(app.isDemo ? "Demo mode: nothing is sent to Spotify" : "Logged in as \(user.name)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func title(_ sync: SyncEngine) -> String {
        let unsent = sync.unsentCount
        switch sync.status {
        case .syncing:
            return "Saving changes to Spotify…"
        case .needsLogin:
            return "\(StatusBanner.changes(unsent)) waiting for login"
        case .offline:
            return "\(StatusBanner.changes(unsent)) waiting for a connection"
        case .backingOff:
            return "\(StatusBanner.changes(unsent)) waiting (Spotify asked to slow down)"
        case .idle, .waiting:
            if !sync.failedWrites.isEmpty { return "\(StatusBanner.changes(sync.failedWrites.count)) failed" }
            return unsent == 0 ? "All changes saved to Spotify" : "\(StatusBanner.changes(unsent)) about to be sent"
        }
    }

    private func icon(_ sync: SyncEngine) -> String {
        if !sync.failedWrites.isEmpty { return "exclamationmark.triangle.fill" }
        switch sync.status {
        case .idle: return sync.unsentCount == 0 ? "checkmark.circle.fill" : "clock"
        case .waiting, .syncing: return "arrow.triangle.2.circlepath"
        case .offline: return "wifi.slash"
        case .backingOff: return "hourglass"
        case .needsLogin: return "person.crop.circle.badge.exclamationmark"
        }
    }

    private func tint(_ sync: SyncEngine) -> Color {
        if !sync.failedWrites.isEmpty { return .red }
        switch sync.status {
        case .idle where sync.unsentCount == 0: return .green
        case .idle, .waiting, .syncing: return .blue
        case .offline, .backingOff, .needsLogin: return .orange
        }
    }
}
