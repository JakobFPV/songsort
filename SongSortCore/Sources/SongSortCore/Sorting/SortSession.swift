import Foundation
import Observation

/// One sorting run over one source: loads the songs, keeps the queue, records keep/reject,
/// queues the Spotify changes, and undoes.
@MainActor
@Observable
public final class SortSession {
    public enum Phase: Equatable, Sendable {
        case idle
        case loading(loaded: Int, total: Int)
        case sorting
        /// The source has no songs at all.
        case empty
        /// Every song in the source has been sorted.
        case finished
        case failed(SpotifyError)
    }

    public let source: SortSource
    public private(set) var phase: Phase = .idle
    /// Songs still to sort; the first one is on screen.
    public private(set) var queue: [Track] = []

    @ObservationIgnored private let api: SpotifyAPI
    @ObservationIgnored private let store: StateStore
    @ObservationIgnored private let sync: SyncEngine?
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let hold: TimeInterval
    @ObservationIgnored private var sourceTracks: [Track] = []

    public init(
        source: SortSource,
        api: SpotifyAPI,
        store: StateStore,
        sync: SyncEngine?,
        hold: TimeInterval = Outbox.defaultHold,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.source = source
        self.api = api
        self.store = store
        self.sync = sync
        self.hold = hold
        self.now = now
        if store.state.ledgers[source.key] == nil {
            store.update { $0.ledgers[source.key] = SortLedger() }
        }
    }

    // MARK: - Derived state

    public var ledger: SortLedger { store.state.ledgers[source.key] ?? SortLedger(shuffleSeed: 0) }
    public var current: Track? { queue.first }
    /// The songs after the current one (for the card stack and prefetching cover art).
    public var upcoming: [Track] { Array(queue.dropFirst().prefix(3)) }
    public var sortedCount: Int { ledger.sortedCount }
    /// Songs in this run: already sorted plus still to sort.
    public var total: Int { sortedCount + queue.count }
    /// Number of the song on screen (or the total when everything is sorted).
    public var position: Int { queue.isEmpty ? sortedCount : sortedCount + 1 }
    /// "37 / 412"
    public var counterText: String { "\(position) / \(total)" }
    public var canUndo: Bool { ledger.lastUndoable != nil }
    public var order: QueueOrder { ledger.order }

    // MARK: - Loading

    public func load() async {
        phase = .loading(loaded: 0, total: 0)
        store.update { $0.sourceNames[source.key] = source.displayName }
        do {
            let fetch = try pageFetcher()
            sourceTracks = try await LibraryLoader.loadAll(
                fetchPage: fetch,
                progress: { [weak self] loaded, total in
                    await self?.updateLoadingProgress(loaded: loaded, total: total)
                }
            )
            rebuildQueue()
        } catch let error as SpotifyError {
            phase = .failed(error)
        } catch {
            phase = .failed(.invalidResponse(error.localizedDescription))
        }
    }

    private func pageFetcher() throws -> @Sendable (Int, Int) async throws -> Page<Track> {
        switch source {
        case .likedSongs:
            let api = self.api
            return { offset, limit in try await api.savedTracks(offset: offset, limit: limit) }
        case .playlist:
            throw SpotifyError.badRequest("Sorting a playlist arrives in Phase 2.")
        }
    }

    private func updateLoadingProgress(loaded: Int, total: Int) {
        if case .loading = phase {
            phase = .loading(loaded: loaded, total: total)
        }
    }

    private func rebuildQueue() {
        let ledger = self.ledger
        queue = QueueBuilder.build(
            tracks: sourceTracks,
            sortedIDs: ledger.sortedIDs,
            pendingRemovalURIs: store.state.outbox.urisPendingRemoval(from: source),
            order: ledger.order,
            seed: ledger.shuffleSeed
        )
        refreshPhase()
        rememberTotal()
    }

    private func refreshPhase() {
        if queue.isEmpty {
            phase = sortedCount == 0 ? .empty : .finished
        } else {
            phase = .sorting
        }
    }

    private func rememberTotal() {
        let total = self.total
        let key = source.key
        if store.state.ledgers[key]?.lastKnownTotal != total {
            store.update { $0.ledgers[key]?.lastKnownTotal = total }
        }
    }

    // MARK: - Decisions

    @discardableResult
    public func keep() -> DecisionRecord? { decide(.keep) }

    @discardableResult
    public func reject() -> DecisionRecord? { decide(.reject) }

    private func decide(_ decision: Decision) -> DecisionRecord? {
        guard phase == .sorting, let track = queue.first else { return nil }
        let date = now()
        let record = DecisionRecord(track: track, decision: decision, date: date)
        let ops = decision == .reject ? source.rejectOps(for: track) : []
        let key = source.key
        let hold = self.hold
        queue.removeFirst()
        let newTotal = sortedCount + 1 + queue.count

        // Ledger and outbox change in one update, so they are saved together.
        store.update { state in
            state.ledgers[key, default: SortLedger()].append(record)
            state.ledgers[key]?.lastKnownTotal = newTotal
            if !ops.isEmpty {
                state.outbox.enqueue(ops, decisionID: record.id, now: date, hold: hold)
            }
        }
        refreshPhase()
        if !ops.isEmpty { sync?.poke() }
        return record
    }

    /// Brings back the most recent decision of this source and reverses its Spotify changes.
    @discardableResult
    public func undo() -> DecisionRecord? {
        guard let record = ledger.lastUndoable, let track = record.track else { return nil }
        let date = now()
        let key = source.key
        store.update { state in
            _ = state.ledgers[key]?.popLastUndoable()
            if record.decision == .reject {
                state.outbox.undo(decisionID: record.id, now: date)
            }
        }
        queue.removeAll { $0.id == track.id }
        queue.insert(track, at: 0)
        if !sourceTracks.contains(where: { $0.id == track.id }) {
            sourceTracks.insert(track, at: 0)
        }
        phase = .sorting
        rememberTotal()
        if record.decision == .reject { sync?.poke() }
        return record
    }

    // MARK: - Run management

    /// Forgets which songs were sorted in this source and reloads it from Spotify.
    public func startOver() async {
        let date = now()
        store.update { $0.ledgers[source.key]?.reset(now: date) }
        await load()
    }

    public func setOrder(_ order: QueueOrder) {
        let key = source.key
        store.update { state in
            state.ledgers[key]?.order = order
            if order == .shuffled {
                state.ledgers[key]?.shuffleSeed = .random(in: .min ... .max)
            }
        }
        switch phase {
        case .sorting, .finished, .empty:
            rebuildQueue()
        case .idle, .loading, .failed:
            break
        }
    }
}
