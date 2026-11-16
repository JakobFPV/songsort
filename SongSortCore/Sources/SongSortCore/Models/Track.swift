import Foundation

/// A song as SongSort needs it, built from Spotify's track object.
public struct Track: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let uri: String
    public let name: String
    public let artists: [String]
    public let album: String
    public let releaseYear: Int?
    public let durationMs: Int
    public let artworkURL: URL?

    public init(
        id: String,
        uri: String? = nil,
        name: String,
        artists: [String],
        album: String,
        releaseYear: Int?,
        durationMs: Int,
        artworkURL: URL? = nil
    ) {
        self.id = id
        self.uri = uri ?? Track.uri(forID: id)
        self.name = name
        self.artists = artists
        self.album = album
        self.releaseYear = releaseYear
        self.durationMs = durationMs
        self.artworkURL = artworkURL
    }

    /// "Artist A, Artist B"
    public var artistLine: String { artists.joined(separator: ", ") }

    /// Where playback starts: the middle of the song.
    public var middleMs: Int { max(0, durationMs / 2) }

    public static func uri(forID id: String) -> String { "spotify:track:\(id)" }

    /// The track ID inside a `spotify:track:<id>` URI, or nil for other URI types.
    public static func id(fromURI uri: String) -> String? {
        let prefix = "spotify:track:"
        guard uri.hasPrefix(prefix) else { return nil }
        let id = String(uri.dropFirst(prefix.count))
        return id.isEmpty ? nil : id
    }

    /// Spotify `release_date` is "1981", "1981-12" or "1981-12-01". Some very old catalog entries use "0000".
    public static func releaseYear(from releaseDate: String?) -> Int? {
        guard let releaseDate, releaseDate.count >= 4, let year = Int(releaseDate.prefix(4)), year > 0 else {
            return nil
        }
        return year
    }
}

/// Formats milliseconds as m:ss (or h:mm:ss for very long tracks).
public enum DurationFormatter {
    public static func string(fromMs ms: Int) -> String {
        let totalSeconds = max(0, ms) / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
