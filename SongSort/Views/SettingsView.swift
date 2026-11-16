import SongSortCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var confirmLogout = false
    @State private var confirmStartOver = false

    var body: some View {
        Form {
            Section("Spotify account") {
                LabeledContent("Logged in as", value: app.user?.name ?? "–")
                if app.isDemo {
                    Text("Demo mode: a made-up library, and nothing is sent to Spotify.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Log out", role: .destructive) { confirmLogout = true }
                }
            }

            Section {
                Picker("Order", selection: orderBinding) {
                    ForEach(QueueOrder.allCases, id: \.self) { order in
                        Text(order.label).tag(order)
                    }
                }
                Button("Start over…", role: .destructive) { confirmStartOver = true }
            } header: {
                Text("Liked Songs")
            } footer: {
                Text("Newest first is Spotify's order. Shuffle stays the same until you choose it again. Start over forgets which songs you've sorted; songs already in “Rejected – Liked Songs” stay there.")
            }

            Section {
                SyncStatusRow()
                if !app.env.sync.failedWrites.isEmpty {
                    Button("Retry failed changes") { app.env.sync.retryFailed() }
                }
                if app.env.sync.unsentCount > 0 {
                    Button("Send waiting changes now") { app.env.sync.flushNow() }
                }
            } header: {
                Text("Sync")
            } footer: {
                Text("Changes reach Spotify about 10 seconds after a swipe, so an undo in that window never touches Spotify.")
            }

            Section("How it works") {
                Text("Keep leaves a song where it is. Reject adds it to the private playlist “Rejected – Liked Songs” and then removes it from Liked Songs. Undo reverses both.")
                Text("Spotify can't restore a song's original “date added”. If you undo a reject after it was sent, the song returns to the top of Liked Songs.")
                    .foregroundStyle(.secondary)
            }
            .font(.footnote)

            Section {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Log out of Spotify?", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("Log out", role: .destructive) { Task { await app.logOut() } }
        } message: {
            Text("Your sorting progress stays on this phone.")
        }
        .confirmationDialog("Start over with Liked Songs?", isPresented: $confirmStartOver, titleVisibility: .visible) {
            Button("Start over", role: .destructive) {
                app.env.store.update { $0.ledgers[SortSource.likedSongs.key]?.reset(now: Date()) }
            }
        } message: {
            Text("SongSort forgets which songs you've already sorted.")
        }
    }

    private var orderBinding: Binding<QueueOrder> {
        Binding(
            get: { app.env.store.state.ledger(for: .likedSongs)?.order ?? .sourceOrder },
            set: { order in
                app.env.store.update { state in
                    var ledger = state.ledgers[SortSource.likedSongs.key] ?? SortLedger()
                    ledger.order = order
                    if order == .shuffled { ledger.shuffleSeed = .random(in: .min ... .max) }
                    state.ledgers[SortSource.likedSongs.key] = ledger
                }
            }
        )
    }
}
