import Foundation
import Testing
@testable import SongSortCore

@MainActor
@Suite("Sorting Liked Songs")
struct SortSessionTests {
    // MARK: Loading and the counter

    @Test func emptyLibraryShowsNothingToSortAndTouchesNothing() async {
        let harness = Harness(liked: [])
        let session = harness.session()
        await session.load()

        #expect(session.phase == .empty)
        #expect(session.counterText == "0 / 0")
        #expect(session.keep() == nil)
        #expect(session.reject() == nil)
        await harness.syncAll()
        #expect(await harness.writeCalls().isEmpty)
        #expect(await harness.rejectedPlaylist() == nil)
    }

    @Test func counterShowsCurrentSongAndTotal() async {
        let harness = Harness(liked: makeTracks(412))
        let session = harness.session()
        await session.load()

        #expect(session.phase == .sorting)
        #expect(session.counterText == "1 / 412")
        for _ in 0..<36 { session.keep() }
        #expect(session.counterText == "37 / 412")
        session.reject()
        // A rejected song still counts toward the total.
        #expect(session.counterText == "38 / 412")
    }

    @Test func playsNewestFirstByDefault() async {
        let harness = Harness(liked: makeTracks(3))
        let session = harness.session()
        await session.load()
        #expect(session.current?.id == "t1")
        #expect(session.upcoming.map(\.id) == ["t2", "t3"])
    }

    @Test func oldestFirstOrder() async {
        let harness = Harness(liked: makeTracks(3))
        let session = harness.session()
        await session.load()
        session.setOrder(.reversed)
        #expect(session.current?.id == "t3")
        #expect(session.counterText == "1 / 3")
    }

    @Test func loadingFailureIsReported() async {
        let harness = Harness(liked: makeTracks(3))
        await harness.api.failNext(.savedTracks, with: .offline)
        let session = harness.session()
        await session.load()
        #expect(session.phase == .failed(.offline))
    }

    // MARK: Keep and reject

    @Test func keepChangesNothingInSpotify() async {
        let harness = Harness(liked: makeTracks(3))
        let session = harness.session()
        await session.load()
        let record = session.keep()

        #expect(record?.decision == .keep)
        #expect(session.current?.id == "t2")
        await harness.syncAll()
        #expect(await harness.writeCalls().isEmpty)
        #expect(await harness.likedIDs() == ["t1", "t2", "t3"])
    }

    @Test func rejectMovesTheSongToANewRejectedPlaylist() async throws {
        let harness = Harness(liked: makeTracks(3))
        let session = harness.session()
        await session.load()
        session.reject()

        // Held for the undo window: nothing has reached Spotify yet.
        await harness.sync.runOnce()
        #expect(await harness.writeCalls().isEmpty)

        await harness.syncAll()
        let playlist = try #require(await harness.rejectedPlaylist())
        #expect(playlist.name == "Rejected \u{2013} Liked Songs")
        #expect(playlist.uris == ["spotify:track:t1"])
        #expect(await harness.likedIDs() == ["t2", "t3"])
        #expect(await harness.writeCalls() == [
            .createPlaylist(name: "Rejected \u{2013} Liked Songs", isPublic: false),
            .addToPlaylist(playlistID: playlist.id, uris: ["spotify:track:t1"]),
            .removeFromLibrary(uris: ["spotify:track:t1"]),
        ])
        #expect(harness.store.state.rejectedPlaylistIDs["liked"] == playlist.id)
        #expect(harness.sync.unsentCount == 0)
    }

    @Test func quickRejectsAreBatched() async throws {
        let harness = Harness(liked: makeTracks(45))
        let session = harness.session()
        await session.load()
        for _ in 0..<45 { session.reject() }
        await harness.syncAll()

        let playlist = try #require(await harness.rejectedPlaylist())
        #expect(playlist.uris.count == 45)
        #expect(await harness.likedIDs().isEmpty)
        let writes = await harness.writeCalls()
        // One create, one add (≤ 100), and the removal split at Spotify's 40-URI limit.
        #expect(writes.count == 4)
        if case .removeFromLibrary(let uris) = writes[2] { #expect(uris.count == 40) } else { Issue.record("expected removal") }
        if case .removeFromLibrary(let uris) = writes[3] { #expect(uris.count == 5) } else { Issue.record("expected removal") }
        #expect(session.phase == .finished)
        #expect(session.counterText == "45 / 45")
    }

    @Test func songAlreadyInRejectedIsNotAddedTwice() async throws {
        let api = InMemorySpotifyAPI(liked: makeTracks(3))
        let existingID = await api.addPlaylist(name: "Rejected \u{2013} Liked Songs", uris: ["spotify:track:t1"])
        let harness = Harness(api: api)
        let session = harness.session()
        await session.load()
        session.reject()
        await harness.syncAll()

        let playlist = try #require(await api.playlist(id: existingID))
        #expect(playlist.uris == ["spotify:track:t1"])
        #expect(await harness.likedIDs() == ["t2", "t3"])
        #expect(!(await harness.writeCalls()).contains { if case .createPlaylist = $0 { true } else { false } })
        #expect(!(await harness.writeCalls()).contains { if case .addToPlaylist = $0 { true } else { false } })

        // Undo puts it back in Liked Songs but leaves it in Rejected, where it already was.
        session.undo()
        await harness.syncAll()
        #expect(await harness.likedIDs().contains("t1"))
        #expect(try #require(await api.playlist(id: existingID)).uris == ["spotify:track:t1"])
    }

    @Test func rejectIntoExistingRejectedPlaylistAppends() async throws {
        let api = InMemorySpotifyAPI(liked: makeTracks(3))
        let existingID = await api.addPlaylist(name: "Rejected \u{2013} Liked Songs", uris: ["spotify:track:old"])
        let harness = Harness(api: api)
        let session = harness.session()
        await session.load()
        session.reject()
        await harness.syncAll()
        #expect(try #require(await api.playlist(id: existingID)).uris == ["spotify:track:old", "spotify:track:t1"])
        #expect((await api.playlists).count == 1)
    }

    // MARK: Undo

    @Test func undoKeepBringsTheCardBack() async {
        let harness = Harness(liked: makeTracks(3))
        let session = harness.session()
        await session.load()
        session.keep()
        #expect(session.counterText == "2 / 3")

        let undone = session.undo()
        #expect(undone?.trackID == "t1")
        #expect(session.current?.id == "t1")
        #expect(session.counterText == "1 / 3")
        #expect(!session.canUndo)
    }

    @Test func undoRejectInsideHoldNeverTouchesSpotify() async {
        let harness = Harness(liked: makeTracks(3))
        let session = harness.session()
        await session.load()
        session.reject()
        harness.clock.advance(by: 3)
        session.undo()

        #expect(session.current?.id == "t1")
        await harness.syncAll()
        #expect(await harness.writeCalls().isEmpty)
        #expect(await harness.likedIDs() == ["t1", "t2", "t3"])
    }

    @Test func undoRejectAfterSyncReversesSpotify() async throws {
        let harness = Harness(liked: makeTracks(3))
        let session = harness.session()
        await session.load()
        session.reject()
        await harness.syncAll()
        #expect(await harness.likedIDs() == ["t2", "t3"])

        await harness.api.clearCalls()
        session.undo()
        #expect(session.current?.id == "t1")
        await harness.sync.runOnce() // reversals aren't held

        let playlist = try #require(await harness.rejectedPlaylist())
        #expect(playlist.uris.isEmpty)
        #expect(await harness.likedIDs().contains("t1"))
        // Re-liked first, then taken out of Rejected: the song is never in neither place.
        #expect(await harness.writeCalls() == [
            .saveToLibrary(uris: ["spotify:track:t1"]),
            .removeFromPlaylist(playlistID: playlist.id, uris: ["spotify:track:t1"]),
        ])
    }

    @Test func repeatedUndoStepsBack() async {
        let harness = Harness(liked: makeTracks(4))
        let session = harness.session()
        await session.load()
        session.keep()
        session.reject()
        session.keep()
        #expect(session.current?.id == "t4")

        #expect(session.undo()?.trackID == "t3")
        #expect(session.undo()?.trackID == "t2")
        #expect(session.undo()?.trackID == "t1")
        #expect(session.undo() == nil)
        #expect(session.queue.map(\.id) == ["t1", "t2", "t3", "t4"])
        await harness.syncAll()
        #expect(await harness.writeCalls().isEmpty)
    }

    @Test func finishedAfterLastSongAndUndoReturnsToSorting() async {
        let harness = Harness(liked: makeTracks(2))
        let session = harness.session()
        await session.load()
        session.keep()
        session.keep()
        #expect(session.phase == .finished)
        #expect(session.counterText == "2 / 2")
        session.undo()
        #expect(session.phase == .sorting)
        #expect(session.counterText == "2 / 2")
    }

    // MARK: Resume and start over

    @Test func resumeContinuesWhereYouLeftOff() async {
        let first = Harness(liked: makeTracks(5))
        let session = first.session()
        await session.load()
        session.keep()   // t1 stays in Liked Songs
        session.reject() // t2 is about to leave
        #expect(session.counterText == "3 / 5")

        let relaunched = await first.relaunch()
        let resumed = relaunched.session()
        await resumed.load()
        #expect(resumed.current?.id == "t3")
        #expect(resumed.counterText == "3 / 5")
        #expect(!resumed.queue.contains { $0.id == "t1" || $0.id == "t2" })
    }

    @Test func pendingRejectIsSentAfterRelaunch() async throws {
        let first = Harness(liked: makeTracks(3))
        let session = first.session()
        await session.load()
        session.reject()
        // Quit before the hold window passed.
        let relaunched = await first.relaunch()
        await relaunched.syncAll()
        #expect(await relaunched.likedIDs() == ["t2", "t3"])
        #expect(try #require(await relaunched.rejectedPlaylist()).uris == ["spotify:track:t1"])
    }

    @Test func sortedSongsStayGoneInLaterSessionsAfterSync() async {
        let first = Harness(liked: makeTracks(4))
        let session = first.session()
        await session.load()
        session.keep()
        session.reject()
        await first.syncAll()

        let relaunched = await first.relaunch()
        let resumed = relaunched.session()
        await resumed.load()
        #expect(resumed.queue.map(\.id) == ["t3", "t4"])
        #expect(resumed.counterText == "3 / 4")
    }

    @Test func undoWorksAfterRelaunch() async {
        let first = Harness(liked: makeTracks(3))
        let session = first.session()
        await session.load()
        session.keep()
        let relaunched = await first.relaunch()
        let resumed = relaunched.session()
        await resumed.load()
        #expect(resumed.undo()?.trackID == "t1")
        #expect(resumed.current?.id == "t1")
    }

    @Test func startOverResortsTheCurrentLibrary() async throws {
        let harness = Harness(liked: makeTracks(3))
        let session = harness.session()
        await session.load()
        session.reject() // t1 → Rejected
        session.keep()
        session.keep()
        await harness.syncAll()
        #expect(session.phase == .finished)

        await session.startOver()
        #expect(session.queue.map(\.id) == ["t2", "t3"])
        #expect(session.counterText == "1 / 2")
        #expect(!session.canUndo)
        #expect(try #require(await harness.rejectedPlaylist()).uris == ["spotify:track:t1"])
    }

    @Test func startOverDoesNotBringBackASongThatIsBeingRejected() async {
        let harness = Harness(liked: makeTracks(3))
        let session = harness.session()
        await session.load()
        session.reject() // still held, not yet sent
        await session.startOver()
        #expect(session.queue.map(\.id) == ["t2", "t3"])
        await harness.syncAll()
        #expect(await harness.likedIDs() == ["t2", "t3"])
    }

    @Test func progressIsSavedTogetherWithPendingChanges() async throws {
        let harness = Harness(liked: makeTracks(3))
        let session = harness.session()
        await session.load()
        session.reject()
        await harness.store.flush()

        let saved = try #require(harness.persistence.savedState)
        #expect(saved.ledgers["liked"]?.records.map(\.trackID) == ["t1"])
        #expect(saved.outbox.writes.map(\.op.kind) == [.addToPlaylist, .removeFromLibrary])
        #expect(saved.ledgers["liked"]?.lastKnownTotal == 3)
    }
}
