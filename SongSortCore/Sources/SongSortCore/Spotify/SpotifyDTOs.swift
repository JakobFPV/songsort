import Foundation

// Wire formats of the Web API (decoded with .convertFromSnakeCase).
// Everything is optional where Spotify has removed or may omit fields (Feb 2026 changes).

struct PagingDTO<Item: Decodable>: Decodable {
    let items: [Item]
    let total: Int
    let offset: Int?
    let next: String?
}

struct SavedTrackDTO: Decodable {
    let addedAt: String?
    let track: TrackDTO?
}

/// Playlist entries carry the track in `item` since Feb 2026; `track` is the deprecated name.
struct PlaylistItemDTO: Decodable {
    let isLocal: Bool?
    let item: TrackDTO?
    let track: TrackDTO?

    var content: TrackDTO? { item ?? track }
}

struct TrackDTO: Decodable {
    let id: String?
    let uri: String?
    let name: String?
    let type: String?
    let durationMs: Int?
    let isLocal: Bool?
    let artists: [ArtistRefDTO]?
    let album: AlbumDTO?

    /// nil for local files, podcast episodes and removed tracks, which SongSort skips.
    func makeTrack() -> Track? {
        guard let id, !id.isEmpty, isLocal != true, type == nil || type == "track" else { return nil }
        return Track(
            id: id,
            uri: uri ?? Track.uri(forID: id),
            name: name ?? "Unknown song",
            artists: (artists ?? []).compactMap(\.name).filter { !$0.isEmpty },
            album: album?.name ?? "",
            releaseYear: Track.releaseYear(from: album?.releaseDate),
            durationMs: durationMs ?? 0,
            artworkURL: album?.bestImageURL
        )
    }
}

struct ArtistRefDTO: Decodable {
    let id: String?
    let name: String?
}

struct AlbumDTO: Decodable {
    let name: String?
    let releaseDate: String?
    let images: [ImageDTO]?

    /// Spotify lists album images widest first (640, 300, 64). Use the widest for the card.
    var bestImageURL: URL? {
        let sorted = (images ?? []).sorted { ($0.width ?? 0) > ($1.width ?? 0) }
        return sorted.first.flatMap { URL(string: $0.url) }
    }
}

struct ImageDTO: Decodable {
    let url: String
    let width: Int?
    let height: Int?
}

struct UserDTO: Decodable {
    let id: String
    let displayName: String?
}

struct PlaylistDTO: Decodable {
    struct Owner: Decodable {
        let id: String
    }

    /// `{ "href": …, "total": … }` in lists; a full paging object on GET /playlists/{id}. Both have `total`.
    struct Count: Decodable {
        let total: Int?
    }

    let id: String
    let name: String
    let owner: Owner
    let collaborative: Bool?
    let snapshotId: String?
    let items: Count?
    let tracks: Count?

    func makeSummary() -> PlaylistSummary {
        PlaylistSummary(
            id: id,
            name: name,
            ownerID: owner.id,
            isCollaborative: collaborative ?? false,
            trackCount: items?.total ?? tracks?.total ?? 0,
            snapshotID: snapshotId
        )
    }
}

struct ErrorEnvelopeDTO: Decodable {
    struct Body: Decodable {
        let status: Int?
        let message: String?
        let reason: String?
    }

    let error: Body
}

// Request bodies

struct CreatePlaylistBody: Encodable {
    let name: String
    let description: String
    let `public`: Bool
}

struct AddItemsBody: Encodable {
    let uris: [String]
}

struct RemoveItemsBody: Encodable {
    struct Item: Encodable {
        let uri: String
    }

    let items: [Item]
}
