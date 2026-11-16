import Foundation

public enum Decision: String, Codable, Sendable {
    case keep
    case reject
}

public struct DecisionRecord: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let trackID: String
    public let decision: Decision
    public let date: Date
    /// Full song details for recent decisions, so undo can bring the card back even after a relaunch.
    /// Dropped for older records to keep the saved file small.
    public var track: Track?

    public init(id: UUID = UUID(), track: Track, decision: Decision, date: Date) {
        self.id = id
        self.trackID = track.id
        self.decision = decision
        self.date = date
        self.track = track
    }
}

public enum QueueOrder: String, Codable, Sendable, CaseIterable {
    /// Spotify's order (Liked Songs: newest first).
    case sourceOrder
    /// Reverse of Spotify's order (Liked Songs: oldest first).
    case reversed
    /// Random, but stable across launches (seeded).
    case shuffled
}

/// Everything SongSort remembers about sorting one source: the decisions of the current run
/// (cleared by "Start over"), the chosen order, and the last known size for the Home screen.
public struct SortLedger: Codable, Sendable, Equatable {
    /// How many decisions back undo can go.
    public static let undoDepth = 100

    public private(set) var records: [DecisionRecord] = []
    public var order: QueueOrder = .sourceOrder
    public var shuffleSeed: UInt64
    /// Total of the run (sorted + still to sort) when last seen, for the Home screen.
    public var lastKnownTotal: Int?
    public var updatedAt: Date?

    public init(order: QueueOrder = .sourceOrder, shuffleSeed: UInt64 = .random(in: .min ... .max)) {
        self.order = order
        self.shuffleSeed = shuffleSeed
    }

    public var sortedCount: Int { records.count }
    public var sortedIDs: Set<String> { Set(records.map(\.trackID)) }
    public var keptCount: Int { records.count { $0.decision == .keep } }
    public var rejectedCount: Int { records.count { $0.decision == .reject } }
    public var lastUndoable: DecisionRecord? {
        guard let last = records.last, last.track != nil else { return nil }
        return last
    }

    public func contains(trackID: String) -> Bool {
        records.contains { $0.trackID == trackID }
    }

    public mutating func append(_ record: DecisionRecord) {
        records.append(record)
        updatedAt = record.date
        let cutoff = records.count - Self.undoDepth - 1
        if cutoff >= 0 {
            records[cutoff].track = nil
        }
    }

    /// Removes and returns the most recent decision if it can be undone.
    public mutating func popLastUndoable() -> DecisionRecord? {
        guard lastUndoable != nil else { return nil }
        return records.removeLast()
    }

    /// "Start over": forget the run, keep the order preference, reshuffle.
    public mutating func reset(now: Date) {
        records = []
        lastKnownTotal = nil
        shuffleSeed = .random(in: .min ... .max)
        updatedAt = now
    }
}
