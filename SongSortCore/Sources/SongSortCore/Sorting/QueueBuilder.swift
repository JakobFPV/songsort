import Foundation

/// Builds the list of songs still to sort.
public enum QueueBuilder {
    /// - Parameters:
    ///   - tracks: the source's songs in Spotify's order (may contain duplicates for playlists).
    ///   - sortedIDs: songs already decided in this run; they never come back.
    ///   - pendingRemovalURIs: songs a not-yet-sent reject is about to remove from the source.
    public static func build(
        tracks: [Track],
        sortedIDs: Set<String>,
        pendingRemovalURIs: Set<String> = [],
        order: QueueOrder,
        seed: UInt64
    ) -> [Track] {
        var seen = Set<String>()
        var remaining: [Track] = []
        remaining.reserveCapacity(tracks.count)
        for track in tracks where !seen.contains(track.id) {
            seen.insert(track.id)
            if sortedIDs.contains(track.id) || pendingRemovalURIs.contains(track.uri) { continue }
            remaining.append(track)
        }

        switch order {
        case .sourceOrder:
            return remaining
        case .reversed:
            return remaining.reversed()
        case .shuffled:
            return remaining
                .map { (key: shuffleKey(for: $0.id, seed: seed), track: $0) }
                .sorted { $0.key != $1.key ? $0.key < $1.key : $0.track.id < $1.track.id }
                .map(\.track)
        }
    }

    /// A per-song random key that only depends on the seed and the song, so the shuffled order
    /// stays the same across launches even when songs are added or removed.
    static func shuffleKey(for id: String, seed: UInt64) -> UInt64 {
        // FNV-1a over the seed and the ID, then a SplitMix64 finalizer to spread the bits.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01b3
        withUnsafeBytes(of: seed.littleEndian) { bytes in
            for byte in bytes {
                hash ^= UInt64(byte)
                hash = hash &* prime
            }
        }
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        hash ^= hash >> 30
        hash = hash &* 0xbf58_476d_1ce4_e5b9
        hash ^= hash >> 27
        hash = hash &* 0x94d0_49bb_1331_11eb
        hash ^= hash >> 31
        return hash
    }
}

/// Loads every page of a source, a few pages at a time, and returns the songs in Spotify's order.
public enum LibraryLoader {
    public static func loadAll(
        pageSize: Int = SpotifyLimits.savedTracksPage,
        maxConcurrentRequests: Int = 4,
        fetchPage: @escaping @Sendable (_ offset: Int, _ limit: Int) async throws -> Page<Track>,
        progress: @escaping @Sendable (_ loaded: Int, _ total: Int) async -> Void = { _, _ in }
    ) async throws -> [Track] {
        let first = try await fetchPage(0, pageSize)
        await progress(min(first.rawCount, first.total), first.total)
        guard first.hasMore else { return dedupe(first.items) }

        let offsets = Array(stride(from: first.offset + first.rawCount, to: first.total, by: pageSize))
        var pages: [Int: [Track]] = [first.offset: first.items]
        var loaded = first.rawCount

        try await withThrowingTaskGroup(of: (Int, Page<Track>).self) { group in
            var nextIndex = 0
            func addNext() {
                guard nextIndex < offsets.count else { return }
                let offset = offsets[nextIndex]
                nextIndex += 1
                group.addTask { (offset, try await fetchPage(offset, pageSize)) }
            }
            for _ in 0..<max(1, maxConcurrentRequests) { addNext() }
            while let (offset, page) = try await group.next() {
                pages[offset] = page.items
                loaded += page.rawCount
                await progress(min(loaded, first.total), first.total)
                addNext()
            }
        }

        let ordered = pages.keys.sorted().flatMap { pages[$0] ?? [] }
        return dedupe(ordered)
    }

    /// The library can change while it loads, which shifts pages; keep the first copy of each song.
    static func dedupe(_ tracks: [Track]) -> [Track] {
        var seen = Set<String>()
        return tracks.filter { seen.insert($0.id).inserted }
    }
}
