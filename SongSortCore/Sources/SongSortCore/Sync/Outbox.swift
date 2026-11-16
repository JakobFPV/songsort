import Foundation

public enum WriteKind: String, Codable, Sendable {
    case addToPlaylist
    case removeFromPlaylist
    case saveToLibrary
    case removeFromLibrary

    /// How many URIs Spotify accepts in one call of this kind.
    public var batchLimit: Int {
        switch self {
        case .addToPlaylist, .removeFromPlaylist: SpotifyLimits.playlistWrite
        case .saveToLibrary, .removeFromLibrary: SpotifyLimits.libraryWrite
        }
    }
}

/// Which playlist a write targets. `.rejected` is resolved (found or created) only when the write is sent,
/// so rejecting works offline and an unused source never gets an empty Rejected playlist.
public enum PlaylistRef: Codable, Hashable, Sendable {
    case rejected(sourceKey: String)
    case id(String)
}

/// One change to Spotify for one song.
public struct WriteOp: Codable, Hashable, Sendable {
    public var kind: WriteKind
    public var playlist: PlaylistRef?
    public var uri: String

    public init(kind: WriteKind, playlist: PlaylistRef?, uri: String) {
        self.kind = kind
        self.playlist = playlist
        self.uri = uri
    }

    /// The write that reverses this one (used by undo).
    public var inverse: WriteOp {
        switch kind {
        case .addToPlaylist: WriteOp(kind: .removeFromPlaylist, playlist: playlist, uri: uri)
        case .removeFromPlaylist: WriteOp(kind: .addToPlaylist, playlist: playlist, uri: uri)
        case .saveToLibrary: WriteOp(kind: .removeFromLibrary, playlist: nil, uri: uri)
        case .removeFromLibrary: WriteOp(kind: .saveToLibrary, playlist: nil, uri: uri)
        }
    }
}

public struct PendingWrite: Codable, Identifiable, Sendable, Equatable {
    public enum State: Codable, Sendable, Equatable {
        /// Waiting to be sent (possibly still inside the hold window).
        case pending
        /// Part of the batch being sent right now.
        case inFlight
        /// Sent. `effective == false` means Spotify already had that state (e.g. the song was already in
        /// the Rejected playlist), so undo must not reverse it.
        case done(effective: Bool)
        /// Spotify refused it for a reason retrying won't fix. Blocks later writes for the same song.
        case failed(message: String)
    }

    public let id: UUID
    /// The swipe this write belongs to.
    public let decisionID: UUID
    public let op: WriteOp
    public let createdAt: Date
    public var eligibleAt: Date
    public var state: State
    /// The swipe was undone while this write was in flight: reverse it once it completes.
    public var compensateOnCompletion: Bool

    public init(id: UUID = UUID(), decisionID: UUID, op: WriteOp, createdAt: Date, eligibleAt: Date, state: State = .pending) {
        self.id = id
        self.decisionID = decisionID
        self.op = op
        self.createdAt = createdAt
        self.eligibleAt = eligibleAt
        self.state = state
        self.compensateOnCompletion = false
    }

    var isUnsent: Bool {
        switch state {
        case .pending, .inFlight, .failed: true
        case .done: false
        }
    }
}

/// A group of writes sent in one Spotify request.
public struct WriteBatch: Sendable, Equatable {
    public let kind: WriteKind
    public let playlist: PlaylistRef?
    public let writeIDs: [UUID]
    public let uris: [String]
}

/// The persistent queue of Spotify changes. Pure value type: the `SyncEngine` decides when to send,
/// this decides what to send and keeps the per-song order intact.
public struct Outbox: Codable, Sendable, Equatable {
    /// Writes wait this long before being sent, so a quick undo never has to touch Spotify
    /// (which keeps a song's original "date added" in Liked Songs).
    public static let defaultHold: TimeInterval = 10
    /// Completed writes are kept (for undo) up to this many.
    public static let completedHistoryLimit = 1_000

    public private(set) var writes: [PendingWrite] = []

    public init(writes: [PendingWrite] = []) {
        self.writes = writes
    }

    // MARK: - Queries

    /// Writes not yet applied to Spotify, including failed ones.
    public var unsentCount: Int { writes.count { $0.isUnsent } }
    public var failedWrites: [PendingWrite] {
        writes.filter { if case .failed = $0.state { true } else { false } }
    }
    public var hasPendingWork: Bool {
        writes.contains { $0.state == .pending || $0.state == .inFlight }
    }

    /// URIs that a pending write is about to take out of the given source (the song is effectively gone).
    public func urisPendingRemoval(from source: SortSource) -> Set<String> {
        let removal = source.removalOp(for: "")
        return Set(writes.lazy.filter { write in
            write.isUnsent && write.op.kind == removal.kind && write.op.playlist == removal.playlist
        }.map(\.op.uri))
    }

    /// The next writes that can go out together, or nil if nothing is due.
    ///
    /// Rules: writes for the same song are never reordered; a song with an unsent earlier write
    /// (pending, in flight or failed) blocks its later writes; one batch = one kind and one playlist,
    /// within Spotify's per-request limit, without duplicate URIs.
    public func nextBatch(now: Date) -> WriteBatch? {
        var blocked = Set<String>()
        var head: PendingWrite?
        var ids: [UUID] = []
        var uris: [String] = []
        var urisInBatch = Set<String>()

        for write in writes {
            switch write.state {
            case .done:
                continue
            case .inFlight, .failed:
                blocked.insert(write.op.uri)
            case .pending:
                let ready = write.eligibleAt <= now && !blocked.contains(write.op.uri)
                if let head {
                    let fits = ready
                        && write.op.kind == head.op.kind
                        && write.op.playlist == head.op.playlist
                        && ids.count < head.op.kind.batchLimit
                        && !urisInBatch.contains(write.op.uri)
                    if fits {
                        ids.append(write.id)
                        uris.append(write.op.uri)
                        urisInBatch.insert(write.op.uri)
                    } else {
                        blocked.insert(write.op.uri)
                    }
                } else if ready {
                    head = write
                    ids = [write.id]
                    uris = [write.op.uri]
                    urisInBatch = [write.op.uri]
                } else {
                    blocked.insert(write.op.uri)
                }
            }
        }
        guard let head else { return nil }
        return WriteBatch(kind: head.op.kind, playlist: head.op.playlist, writeIDs: ids, uris: uris)
    }

    /// When the earliest held write becomes due (nil if nothing is waiting on time).
    public func nextEligibleDate(after now: Date) -> Date? {
        writes.lazy.filter { $0.state == .pending && $0.eligibleAt > now }.map(\.eligibleAt).min()
    }

    // MARK: - Changes

    public mutating func enqueue(_ ops: [WriteOp], decisionID: UUID, now: Date, hold: TimeInterval) {
        for op in ops {
            writes.append(PendingWrite(decisionID: decisionID, op: op, createdAt: now, eligibleAt: now.addingTimeInterval(hold)))
        }
    }

    /// Reverses a swipe: unsent writes are dropped (Spotify never sees them); applied writes get an
    /// inverse write, in reverse order; in-flight writes are reversed when they complete.
    public mutating func undo(decisionID: UUID, now: Date) {
        var inverses: [WriteOp] = []
        writes.removeAll { write in
            guard write.decisionID == decisionID else { return false }
            switch write.state {
            case .pending, .failed:
                return true
            case .inFlight, .done:
                return false
            }
        }
        for index in writes.indices where writes[index].decisionID == decisionID {
            switch writes[index].state {
            case .inFlight:
                writes[index].compensateOnCompletion = true
            case .done(let effective):
                if effective { inverses.append(writes[index].op.inverse) }
            case .pending, .failed:
                break
            }
        }
        enqueue(inverses.reversed(), decisionID: UUID(), now: now, hold: 0)
    }

    /// Sends everything held right away (leaving the sorter, app going to the background).
    public mutating func makeAllEligible(now: Date) {
        for index in writes.indices where writes[index].state == .pending && writes[index].eligibleAt > now {
            writes[index].eligibleAt = now
        }
    }

    public mutating func markInFlight(_ ids: [UUID]) {
        update(ids) { $0.state = .inFlight }
    }

    /// Records the outcome of a sent batch. Writes whose swipe was undone in the meantime are reversed.
    public mutating func markDone(_ effects: [UUID: Bool], now: Date) {
        var compensations: [WriteOp] = []
        for index in writes.indices {
            guard let effective = effects[writes[index].id] else { continue }
            writes[index].state = .done(effective: effective)
            if writes[index].compensateOnCompletion {
                writes[index].compensateOnCompletion = false
                if effective { compensations.append(writes[index].op.inverse) }
            }
        }
        enqueue(compensations, decisionID: UUID(), now: now, hold: 0)
        pruneCompleted()
    }

    /// A transient failure: try again later. Writes of an undone swipe are simply dropped.
    public mutating func markPending(_ ids: [UUID]) {
        let idSet = Set(ids)
        writes.removeAll { idSet.contains($0.id) && $0.compensateOnCompletion }
        update(ids) { $0.state = .pending }
    }

    /// A permanent failure. Writes of an undone swipe are dropped instead.
    public mutating func markFailed(_ ids: [UUID], message: String) {
        let idSet = Set(ids)
        writes.removeAll { idSet.contains($0.id) && $0.compensateOnCompletion }
        update(ids) { $0.state = .failed(message: message) }
    }

    public mutating func retryFailed(now: Date) {
        for index in writes.indices {
            if case .failed = writes[index].state {
                writes[index].state = .pending
                writes[index].eligibleAt = now
            }
        }
    }

    /// After a crash, writes that were in flight are unknown; send them again (Spotify writes here
    /// are idempotent, and playlist adds are de-duplicated against the playlist's contents).
    public mutating func recoverAfterRelaunch() {
        for index in writes.indices where writes[index].state == .inFlight {
            writes[index].state = .pending
        }
    }

    private mutating func update(_ ids: [UUID], _ change: (inout PendingWrite) -> Void) {
        let idSet = Set(ids)
        for index in writes.indices where idSet.contains(writes[index].id) {
            change(&writes[index])
        }
    }

    private mutating func pruneCompleted() {
        let completed = writes.count { if case .done = $0.state { true } else { false } }
        var excess = completed - Self.completedHistoryLimit
        guard excess > 0 else { return }
        writes.removeAll { write in
            guard excess > 0, case .done = write.state else { return false }
            excess -= 1
            return true
        }
    }
}
