import Foundation
import Observation

/// Sends the outbox to Spotify: resolves (finds or creates) the Rejected playlists, avoids duplicates,
/// batches writes, and backs off on network trouble, rate limits and expired logins.
@MainActor
@Observable
public final class SyncEngine {
    public enum Status: Equatable, Sendable {
        /// Nothing waiting.
        case idle
        /// Writes are held for the undo window and will go out shortly.
        case waiting
        case syncing
        /// Waiting for the connection to come back.
        case offline
        /// Rate-limited, over quota, or Spotify had a server error.
        case backingOff(until: Date, reason: SpotifyError)
        /// The login expired; nothing is sent until the user logs in again.
        case needsLogin
    }

    public private(set) var status: Status = .idle
    public private(set) var lastError: SpotifyError?

    public var unsentCount: Int { store.state.outbox.unsentCount }
    public var failedWrites: [PendingWrite] { store.state.outbox.failedWrites }

    @ObservationIgnored private let store: StateStore
    @ObservationIgnored private let api: SpotifyAPI
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var verifiedRejected: [String: String] = [:]
    @ObservationIgnored private var playlistContents: [String: Set<String>] = [:]
    @ObservationIgnored private var resumeAt: Date?
    @ObservationIgnored private var consecutiveFailures = 0
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var sleepTask: Task<Void, Never>?
    @ObservationIgnored private var pokeGeneration = 0

    public init(store: StateStore, api: SpotifyAPI, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.api = api
        self.now = now
        refreshIdleStatus()
    }

    // MARK: - Lifecycle

    /// Starts the background loop that sends due writes.
    public func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let generation = self.pokeGeneration
                let wake = await self.runOnce()
                if self.pokeGeneration != generation { continue }
                await self.sleep(until: wake)
            }
        }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
        sleepTask?.cancel()
    }

    /// New writes were queued or something changed: re-check now.
    public func poke() {
        pokeGeneration &+= 1
        sleepTask?.cancel()
        if status != .syncing { refreshIdleStatus() }
    }

    /// Sends held writes right away (leaving the sorter, app going to the background).
    public func flushNow() {
        store.update { $0.outbox.makeAllEligible(now: now()) }
        poke()
    }

    /// Flushes and waits (up to `timeout`) until nothing is pending or syncing is blocked.
    public func flushAndWait(timeout: TimeInterval) async {
        flushNow()
        let deadline = now().addingTimeInterval(timeout)
        while store.state.outbox.hasPendingWork, now() < deadline {
            switch status {
            case .offline, .needsLogin, .backingOff:
                return
            case .idle, .waiting, .syncing:
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    public func networkBecameAvailable() {
        if status == .offline {
            resumeAt = nil
            consecutiveFailures = 0
        }
        poke()
    }

    public func loginRestored() {
        if status == .needsLogin {
            status = .idle
        }
        resumeAt = nil
        poke()
    }

    public func retryFailed() {
        store.update { $0.outbox.retryFailed(now: now()) }
        poke()
    }

    /// Forget per-session knowledge (after logout).
    public func resetCaches() {
        verifiedRejected = [:]
        playlistContents = [:]
    }

    // MARK: - Sending

    /// Sends every write that is due. Returns when to look again (nil = only when poked).
    @discardableResult
    public func runOnce() async -> Date? {
        guard !isRunning else { return nil }
        isRunning = true
        defer { isRunning = false }

        if status == .needsLogin { return nil }
        if let resumeAt, resumeAt > now() { return resumeAt }
        resumeAt = nil

        while let batch = store.state.outbox.nextBatch(now: now()) {
            status = .syncing
            store.update { $0.outbox.markInFlight(batch.writeIDs) }
            do {
                let effects = try await execute(batch)
                store.update { $0.outbox.markDone(effects, now: now()) }
                consecutiveFailures = 0
                lastError = nil
            } catch {
                let spotifyError = (error as? SpotifyError) ?? .invalidResponse(error.localizedDescription)
                switch handleFailure(spotifyError, batch: batch) {
                case .continueWithNextBatch:
                    continue
                case .stop(let wake):
                    return wake
                }
            }
        }
        refreshIdleStatus()
        return store.state.outbox.nextEligibleDate(after: now())
    }

    private enum FailureAction {
        case continueWithNextBatch
        case stop(wake: Date?)
    }

    private func handleFailure(_ error: SpotifyError, batch: WriteBatch) -> FailureAction {
        lastError = error
        switch error {
        case .loginRequired, .notConfigured:
            store.update { $0.outbox.markPending(batch.writeIDs) }
            status = .needsLogin
            return .stop(wake: nil)
        case .offline, .cancelled:
            store.update { $0.outbox.markPending(batch.writeIDs) }
            consecutiveFailures += 1
            let wake = now().addingTimeInterval(backoffDelay())
            resumeAt = wake
            status = .offline
            return .stop(wake: wake)
        case .rateLimited(let retryAfter):
            store.update { $0.outbox.markPending(batch.writeIDs) }
            let wake = now().addingTimeInterval(max(1, retryAfter))
            resumeAt = wake
            status = .backingOff(until: wake, reason: error)
            return .stop(wake: wake)
        case .quotaExceeded:
            store.update { $0.outbox.markPending(batch.writeIDs) }
            let wake = now().addingTimeInterval(15 * 60)
            resumeAt = wake
            status = .backingOff(until: wake, reason: error)
            return .stop(wake: wake)
        case .server:
            store.update { $0.outbox.markPending(batch.writeIDs) }
            consecutiveFailures += 1
            let wake = now().addingTimeInterval(backoffDelay())
            resumeAt = wake
            status = .backingOff(until: wake, reason: error)
            return .stop(wake: wake)
        case .forbidden(let message), .notFound(let message), .badRequest(let message),
             .invalidResponse(let message), .loginFailed(let message):
            // Retrying won't help. Park these writes (they block later writes for the same songs,
            // so a song is never removed from its source unless it reached the Rejected playlist).
            store.update { $0.outbox.markFailed(batch.writeIDs, message: message) }
            return .continueWithNextBatch
        }
    }

    private func backoffDelay() -> TimeInterval {
        let steps: [TimeInterval] = [5, 15, 30, 60, 120]
        return steps[min(max(consecutiveFailures - 1, 0), steps.count - 1)]
    }

    private func refreshIdleStatus() {
        guard status != .needsLogin else { return }
        if case .backingOff(let until, _) = status, until > now() { return }
        if status == .offline, let resumeAt, resumeAt > now() { return }
        status = store.state.outbox.hasPendingWork ? .waiting : .idle
    }

    private func sleep(until date: Date?) async {
        let seconds = date.map { max(0, $0.timeIntervalSince(now())) } ?? 3_600
        let task = Task { _ = try? await Task.sleep(for: .seconds(seconds)) }
        sleepTask = task
        await task.value
        sleepTask = nil
    }

    // MARK: - Executing a batch

    /// Performs one batch. Returns, per write, whether it changed anything in Spotify.
    private func execute(_ batch: WriteBatch) async throws -> [UUID: Bool] {
        var effects: [UUID: Bool] = [:]
        switch batch.kind {
        case .addToPlaylist:
            guard let ref = batch.playlist, let playlistID = try await resolve(ref, createIfMissing: true) else {
                throw SpotifyError.badRequest("No playlist to add to.")
            }
            let existing = try await contents(of: playlistID)
            var toAdd: [String] = []
            for (id, uri) in zip(batch.writeIDs, batch.uris) {
                if existing.contains(uri) {
                    effects[id] = false
                } else {
                    effects[id] = true
                    toAdd.append(uri)
                }
            }
            if !toAdd.isEmpty {
                try await api.addToPlaylist(playlistID: playlistID, uris: toAdd)
                playlistContents[playlistID, default: []].formUnion(toAdd)
            }

        case .removeFromPlaylist:
            guard let ref = batch.playlist else { throw SpotifyError.badRequest("No playlist to remove from.") }
            guard let playlistID = try await resolve(ref, createIfMissing: false) else {
                // The Rejected playlist is gone, so there's nothing to take the song out of.
                for id in batch.writeIDs { effects[id] = false }
                return effects
            }
            try await api.removeFromPlaylist(playlistID: playlistID, uris: batch.uris)
            playlistContents[playlistID]?.subtract(batch.uris)
            for id in batch.writeIDs { effects[id] = true }

        case .saveToLibrary:
            try await api.saveToLibrary(uris: batch.uris)
            for id in batch.writeIDs { effects[id] = true }

        case .removeFromLibrary:
            try await api.removeFromLibrary(uris: batch.uris)
            for id in batch.writeIDs { effects[id] = true }
        }
        return effects
    }

    private func resolve(_ ref: PlaylistRef, createIfMissing: Bool) async throws -> String? {
        switch ref {
        case .id(let id):
            return id
        case .rejected(let sourceKey):
            return try await resolveRejectedPlaylist(sourceKey: sourceKey, createIfMissing: createIfMissing)
        }
    }

    /// Finds the "Rejected – <source>" playlist: the remembered one if you still have it in your library,
    /// else an owned playlist with exactly that name, else (when adding) a new private one.
    func resolveRejectedPlaylist(sourceKey: String, createIfMissing: Bool) async throws -> String? {
        if let id = verifiedRejected[sourceKey] { return id }

        if let stored = store.state.rejectedPlaylistIDs[sourceKey] {
            let stillThere = try await api.libraryContains(uris: ["spotify:playlist:\(stored)"]).first ?? false
            if stillThere {
                verifiedRejected[sourceKey] = stored
                return stored
            }
            playlistContents[stored] = nil
        }

        let sourceName = store.state.sourceNames[sourceKey]
            ?? (sourceKey == SortSource.likedSongs.key ? SortSource.likedSongs.displayName : "Playlist")
        let name = RejectedPlaylistNaming.name(forSourceNamed: sourceName)
        if let existing = try await findOwnedPlaylist(named: name) {
            remember(existing.id, for: sourceKey)
            return existing.id
        }
        guard createIfMissing else { return nil }

        let created = try await api.createPlaylist(
            name: name,
            description: RejectedPlaylistNaming.description(forSourceNamed: sourceName),
            isPublic: false
        )
        playlistContents[created.id] = []
        remember(created.id, for: sourceKey)
        return created.id
    }

    private func remember(_ playlistID: String, for sourceKey: String) {
        verifiedRejected[sourceKey] = playlistID
        store.update { $0.rejectedPlaylistIDs[sourceKey] = playlistID }
    }

    private func findOwnedPlaylist(named name: String) async throws -> PlaylistSummary? {
        let ownerID = try await currentUserID()
        var offset = 0
        while true {
            let page = try await api.myPlaylists(offset: offset, limit: SpotifyLimits.playlistsPage)
            if let match = page.items.first(where: { $0.name == name && $0.ownerID == ownerID }) {
                return match
            }
            guard page.hasMore else { return nil }
            offset += page.rawCount
        }
    }

    private func currentUserID() async throws -> String {
        if let id = store.state.user?.id { return id }
        let user = try await api.currentUser()
        store.update { $0.user = user }
        return user.id
    }

    /// The URIs in a playlist, loaded once per app session and kept up to date as we change it.
    private func contents(of playlistID: String) async throws -> Set<String> {
        if let cached = playlistContents[playlistID] { return cached }
        var uris = Set<String>()
        var offset = 0
        while true {
            let page = try await api.playlistItemURIs(playlistID: playlistID, offset: offset, limit: SpotifyLimits.playlistItemsPage)
            uris.formUnion(page.items)
            guard page.hasMore else { break }
            offset += page.rawCount
        }
        playlistContents[playlistID] = uris
        return uris
    }
}
