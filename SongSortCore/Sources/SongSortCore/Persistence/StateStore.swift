import Foundation
import Observation

/// Everything SongSort keeps on the phone, saved as one file so the sort ledger and the queue of
/// Spotify changes can never disagree after a crash.
public struct PersistedState: Codable, Sendable, Equatable {
    public var version = 1
    public var user: SpotifyUser?
    /// Sorting progress per source (key: `SortSource.key`).
    public var ledgers: [String: SortLedger] = [:]
    /// Spotify changes not yet sent (plus recent completed ones, for undo).
    public var outbox = Outbox()
    /// Source key → ID of its "Rejected – …" playlist.
    public var rejectedPlaylistIDs: [String: String] = [:]
    /// Source key → display name, used to name a new Rejected playlist.
    public var sourceNames: [String: String] = [:]

    public init() {}

    public func ledger(for source: SortSource) -> SortLedger? {
        ledgers[source.key]
    }
}

public protocol StatePersistence: Sendable {
    func load() -> PersistedState?
    func save(_ state: PersistedState) async throws
}

/// Writes the state as JSON, atomically, off the main thread.
public struct JSONFileStatePersistence: StatePersistence {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `Application Support/SongSort/<name>`
    public static func defaultFileURL(named name: String = "state.json") throws -> URL {
        let directory = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("SongSort", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }

    public func load() -> PersistedState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(PersistedState.self, from: data)
    }

    @concurrent
    public func save(_ state: PersistedState) async throws {
        let data = try JSONEncoder().encode(state)
        try data.write(to: fileURL, options: [.atomic])
    }
}

/// For tests and previews: keeps the "saved" copy in memory.
public final class InMemoryStatePersistence: StatePersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: PersistedState?
    private var saves = 0

    public init(initial: PersistedState? = nil) {
        stored = initial
    }

    public func load() -> PersistedState? { lock.withLock { stored } }

    public func save(_ state: PersistedState) async throws {
        lock.withLock {
            stored = state
            saves += 1
        }
    }

    public var saveCount: Int { lock.withLock { saves } }
    public var savedState: PersistedState? { lock.withLock { stored } }
}

/// The single in-memory owner of `PersistedState`. Every change is saved in the background,
/// coalescing rapid changes into one write.
@MainActor
@Observable
public final class StateStore {
    public private(set) var state: PersistedState
    public private(set) var lastSaveError: String?

    @ObservationIgnored private let persistence: StatePersistence
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var needsSave = false

    public init(persistence: StatePersistence) {
        self.persistence = persistence
        var loaded = persistence.load() ?? PersistedState()
        loaded.outbox.recoverAfterRelaunch()
        self.state = loaded
    }

    public func update(_ change: (inout PersistedState) -> Void) {
        change(&state)
        scheduleSave()
    }

    /// Waits until everything changed so far is on disk.
    public func flush() async {
        while let task = saveTask {
            await task.value
        }
    }

    private func scheduleSave() {
        needsSave = true
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            while let self, self.needsSave {
                self.needsSave = false
                let snapshot = self.state
                do {
                    try await self.persistence.save(snapshot)
                    self.lastSaveError = nil
                } catch {
                    self.lastSaveError = "Couldn't save progress on this phone: \(error.localizedDescription)"
                }
            }
            self?.saveTask = nil
        }
    }
}
