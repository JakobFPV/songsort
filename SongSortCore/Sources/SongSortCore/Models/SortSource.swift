import Foundation

/// Something the user sorts: Liked Songs (Phase 1) or one of their playlists (Phase 2).
public enum SortSource: Codable, Hashable, Sendable {
    case likedSongs
    case playlist(id: String, name: String)

    /// Stable storage key. Renaming a playlist does not change it.
    public var key: String {
        switch self {
        case .likedSongs: "liked"
        case .playlist(let id, _): "playlist:\(id)"
        }
    }

    public var displayName: String {
        switch self {
        case .likedSongs: "Liked Songs"
        case .playlist(_, let name): name
        }
    }

    /// The write that takes a rejected song out of this source.
    public func removalOp(for uri: String) -> WriteOp {
        switch self {
        case .likedSongs:
            WriteOp(kind: .removeFromLibrary, playlist: nil, uri: uri)
        case .playlist(let id, _):
            WriteOp(kind: .removeFromPlaylist, playlist: .id(id), uri: uri)
        }
    }

    /// The writes for rejecting a song: first into the Rejected playlist, then out of the source.
    /// The order matters: if the first write fails, the second never runs, so a song can't get lost.
    public func rejectOps(for track: Track) -> [WriteOp] {
        [
            WriteOp(kind: .addToPlaylist, playlist: .rejected(sourceKey: key), uri: track.uri),
            removalOp(for: track.uri),
        ]
    }
}

public struct SpotifyUser: Codable, Sendable, Equatable {
    public let id: String
    public let displayName: String?

    public init(id: String, displayName: String?) {
        self.id = id
        self.displayName = displayName
    }

    public var name: String {
        if let displayName, !displayName.isEmpty { return displayName }
        return id
    }
}

public struct PlaylistSummary: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let ownerID: String
    public let isCollaborative: Bool
    public let trackCount: Int
    public let snapshotID: String?

    public init(id: String, name: String, ownerID: String, isCollaborative: Bool, trackCount: Int, snapshotID: String?) {
        self.id = id
        self.name = name
        self.ownerID = ownerID
        self.isCollaborative = isCollaborative
        self.trackCount = trackCount
        self.snapshotID = snapshotID
    }
}

/// One page of a Spotify paging object.
public struct Page<Item: Sendable>: Sendable {
    public let items: [Item]
    /// Number of raw entries on this page, including ones we skipped (local files, episodes, removed tracks).
    public let rawCount: Int
    public let offset: Int
    public let total: Int

    public init(items: [Item], rawCount: Int? = nil, offset: Int, total: Int) {
        self.items = items
        self.rawCount = rawCount ?? items.count
        self.offset = offset
        self.total = total
    }

    public var hasMore: Bool { offset + rawCount < total && rawCount > 0 }
}
