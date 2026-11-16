import Foundation
import Testing
@testable import SongSortCore

@Suite("Queue order")
struct QueueBuilderTests {
    let tracks = makeTracks(6) // Spotify's order: t1 is the most recently liked

    @Test func sourceOrderKeepsSpotifysOrder() {
        let queue = QueueBuilder.build(tracks: tracks, sortedIDs: [], order: .sourceOrder, seed: 1)
        #expect(queue.map(\.id) == ["t1", "t2", "t3", "t4", "t5", "t6"])
    }

    @Test func reversedGivesOldestFirst() {
        let queue = QueueBuilder.build(tracks: tracks, sortedIDs: [], order: .reversed, seed: 1)
        #expect(queue.map(\.id) == ["t6", "t5", "t4", "t3", "t2", "t1"])
    }

    @Test func alreadySortedSongsAreSkipped() {
        let queue = QueueBuilder.build(tracks: tracks, sortedIDs: ["t1", "t4"], order: .sourceOrder, seed: 1)
        #expect(queue.map(\.id) == ["t2", "t3", "t5", "t6"])
    }

    @Test func songsAboutToBeRemovedAreSkipped() {
        let queue = QueueBuilder.build(
            tracks: tracks,
            sortedIDs: [],
            pendingRemovalURIs: ["spotify:track:t2"],
            order: .sourceOrder,
            seed: 1
        )
        #expect(!queue.map(\.id).contains("t2"))
        #expect(queue.count == 5)
    }

    @Test func duplicatesAppearOnce() {
        let withDuplicates = tracks + [makeTrack(2), makeTrack(3)]
        let queue = QueueBuilder.build(tracks: withDuplicates, sortedIDs: [], order: .sourceOrder, seed: 1)
        #expect(queue.map(\.id) == ["t1", "t2", "t3", "t4", "t5", "t6"])
    }

    @Test func emptyLibraryGivesEmptyQueue() {
        for order in QueueOrder.allCases {
            #expect(QueueBuilder.build(tracks: [], sortedIDs: [], order: order, seed: 7).isEmpty)
        }
    }

    @Test func everythingSortedGivesEmptyQueue() {
        let queue = QueueBuilder.build(tracks: tracks, sortedIDs: Set(tracks.map(\.id)), order: .sourceOrder, seed: 1)
        #expect(queue.isEmpty)
    }

    @Test func shuffleIsStableForTheSameSeed() {
        let many = makeTracks(50)
        let first = QueueBuilder.build(tracks: many, sortedIDs: [], order: .shuffled, seed: 42)
        let second = QueueBuilder.build(tracks: many.reversed(), sortedIDs: [], order: .shuffled, seed: 42)
        #expect(first.map(\.id) == second.map(\.id))
        #expect(Set(first.map(\.id)) == Set(many.map(\.id)))
        #expect(first.map(\.id) != many.map(\.id))
    }

    @Test func shuffleDiffersBetweenSeeds() {
        let many = makeTracks(50)
        let first = QueueBuilder.build(tracks: many, sortedIDs: [], order: .shuffled, seed: 1)
        let second = QueueBuilder.build(tracks: many, sortedIDs: [], order: .shuffled, seed: 2)
        #expect(first.map(\.id) != second.map(\.id))
    }

    @Test func shuffleKeepsRelativeOrderWhenSongsAreSorted() {
        // Resuming a shuffled run must not reshuffle the songs that are left.
        let many = makeTracks(30)
        let full = QueueBuilder.build(tracks: many, sortedIDs: [], order: .shuffled, seed: 9)
        let sorted = Set(full.prefix(10).map(\.id))
        let resumed = QueueBuilder.build(tracks: many, sortedIDs: sorted, order: .shuffled, seed: 9)
        #expect(resumed.map(\.id) == Array(full.dropFirst(10)).map(\.id))
    }
}

@Suite("Library loading")
struct LibraryLoaderTests {
    @Test func loadsAllPagesInOrder() async throws {
        let api = InMemorySpotifyAPI(liked: makeTracks(123))
        let progress = ProgressRecorder()
        let tracks = try await LibraryLoader.loadAll(
            fetchPage: { offset, limit in try await api.savedTracks(offset: offset, limit: limit) },
            progress: { loaded, total in await progress.record(loaded, total) }
        )
        #expect(tracks.map(\.id) == makeTracks(123).map(\.id))
        #expect(await api.calls.count == 3)
        let last = try #require(await progress.values.last)
        #expect(last.0 == 123 && last.1 == 123)
    }

    @Test func emptyLibraryNeedsOneRequest() async throws {
        let api = InMemorySpotifyAPI(liked: [])
        let tracks = try await LibraryLoader.loadAll(fetchPage: { try await api.savedTracks(offset: $0, limit: $1) })
        #expect(tracks.isEmpty)
        #expect(await api.calls == [.savedTracks(offset: 0, limit: 50)])
    }

    @Test func pagesThatShiftWhileLoadingDoNotDuplicateSongs() async throws {
        let all = makeTracks(60)
        // Page 2 overlaps page 1 by one song, as happens when a song is liked during loading.
        let tracks = try await LibraryLoader.loadAll(
            pageSize: 50,
            fetchPage: { offset, _ in
                offset == 0
                    ? Page(items: Array(all[0..<50]), offset: 0, total: 60)
                    : Page(items: Array(all[49..<60]), offset: offset, total: 60)
            }
        )
        #expect(tracks.map(\.id) == all.map(\.id))
    }

    @Test func errorsPropagate() async {
        let api = InMemorySpotifyAPI(liked: makeTracks(10))
        await api.failNext(.savedTracks, with: .offline)
        await #expect(throws: SpotifyError.offline) {
            _ = try await LibraryLoader.loadAll(fetchPage: { try await api.savedTracks(offset: $0, limit: $1) })
        }
    }
}

actor ProgressRecorder {
    private(set) var values: [(Int, Int)] = []
    func record(_ loaded: Int, _ total: Int) { values.append((loaded, total)) }
}

@Suite("Ledger")
struct SortLedgerTests {
    @Test func undoReachesBackOneHundredDecisions() {
        var ledger = SortLedger(shuffleSeed: 1)
        let date = Date()
        for number in 1...102 {
            ledger.append(DecisionRecord(track: makeTrack(number), decision: .keep, date: date))
        }
        #expect(ledger.sortedCount == 102)
        var undone = 0
        while ledger.popLastUndoable() != nil { undone += 1 }
        #expect(undone == 100)
        #expect(ledger.sortedCount == 2)
    }

    @Test func resetForgetsDecisionsButKeepsOrder() {
        var ledger = SortLedger(order: .reversed, shuffleSeed: 1)
        ledger.append(DecisionRecord(track: makeTrack(1), decision: .reject, date: Date()))
        ledger.lastKnownTotal = 10
        ledger.reset(now: Date())
        #expect(ledger.sortedCount == 0)
        #expect(ledger.lastKnownTotal == nil)
        #expect(ledger.order == .reversed)
    }
}
