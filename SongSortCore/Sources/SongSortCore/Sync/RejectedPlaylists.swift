import Foundation

/// Naming rules for the "Rejected – …" playlists.
public enum RejectedPlaylistNaming {
    /// "Rejected", space, en dash (U+2013), space.
    public static let prefix = "Rejected \u{2013} "
    /// Spotify doesn't document a maximum; 100 characters keeps names readable everywhere.
    public static let maxLength = 100

    public static func name(forSourceNamed sourceName: String) -> String {
        let trimmed = sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let full = prefix + (trimmed.isEmpty ? "Untitled playlist" : trimmed)
        guard full.count > maxLength else { return full }
        return String(full.prefix(maxLength - 1)) + "…"
    }

    public static func description(forSourceNamed sourceName: String) -> String {
        let trimmed = sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Songs you rejected in SongSort from \(trimmed.isEmpty ? "a playlist" : trimmed). Nothing was deleted; add them back any time."
    }

    public static func isRejectedPlaylistName(_ name: String) -> Bool {
        name.hasPrefix(prefix)
    }
}
