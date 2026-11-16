import Foundation
import Testing
@testable import SongSortCore

@MainActor
@Suite("Rejected playlist and syncing")
struct SyncEngineTests {
    // MARK: Finding or creating the Rejected playlist

    @Test func createsAPrivatePlaylistWithTheRightNameOnFirstReject() async throws {
        let harness = Harness(liked: makeTracks(2))
        let session = harness.session()
        await session.load()
        session.reject()
        await harness.syncAll()

        let calls = await harness.api.calls
        #expect(calls.contains(.createPlaylist(name: "Rejected – Liked Songs", isPublic: false)))
        #expect(try #require(await harness.rejectedPlaylist()).ownerID == "me")
    }

    @Test func reusesTheRememberedPlaylist() async throws {
        let harness = Harness(liked: makeTracks(3))
        let session = harness.session()
        await session.load()
        session.reject()
        await harness.syncAll()
        let id = try #require(harness.store.state.rejectedPlaylistIDs["liked"])

        // Next app launch: the remembered ID is checked once and reused.
        let relaunched = await harness.relaunch()
        await relaunched.api.clearCalls()
        let next = relaunched.session()
        await next.load()
        next.reject()
        await relaunched.syncAll()

        let calls = await relaunched.api.calls
        #expect(calls.contains(.libraryContains(uris: ["spotify:playlist:\(id)"])))
        #expect(!calls.contains { if case .createPlaylist = $0 { true } else { false } })
        #expect(try #require(await relaunched.api.playlist(id: id)).uris == ["spotify:track:t1", "spotify:track:t2"])
    }

    @Test func findsAnExistingPlaylistByExactName() async throws {
        let api = InMemorySpotifyAPI(liked: makeTracks(2))
        await api.addPlaylist(name: "Rejected - Liked Songs") // hyphen, not en dash: not ours
        let ours = await api.addPlaylist(name: "Rejected – Liked Songs")
        let harness = Harness(api: api)
        let session = harness.session()
        await session.load()
        session.reject()
        await harness.syncAll()

        #expect(harness.store.state.rejectedPlaylistIDs["liked"] == ours)
        #expect(try #require(await api.playlist(id: ours)).uris == ["spotify:track:t1"])
        #expect((await api.playlists).count == 2)
    }

    @Test func ignoresSameNamedPlaylistOwnedBySomeoneElse() async throws {
        let api = InMemorySpotifyAPI(liked: makeTracks(2))
        let theirs = await api.addPlaylist(name: "Rejected – Liked Songs", ownerID: "someone-else", isCollaborative: true)
        let harness = Harness(api: api)
        let session = harness.session()
        await session.load()
        session.reject()
        await harness.syncAll()

        let ours = try #require(harness.store.state.rejectedPlaylistIDs["liked"])
        #expect(ours != theirs)
        #expect(try #require(await api.playlist(id: theirs)).uris.isEmpty)
    }

    @Test func recreatesThePlaylistIfYouDeletedIt() async throws {
        let harness = Harness(liked: makeTracks(3))
        let session = harness.session()
        await session.load()
        session.reject()
        await harness.syncAll()
        let first = try #require(harness.store.state.rejectedPlaylistIDs["liked"])
        await harness.api.unfollowPlaylist(id: first)

        let relaunched = await harness.relaunch()
        let next = relaunched.session()
        await next.load()
        next.reject()
        await relaunched.syncAll()

        let second = try #require(relaunched.store.state.rejectedPlaylistIDs["liked"])
        #expect(second != first)
        #expect(try #require(await relaunched.api.playlist(id: second)).uris == ["spotify:track:t2"])
        #expect(try #require(await relaunched.api.playlist(id: second)).name == "Rejected – Liked Songs")
    }

    @Test func undoNeverCreatesAPlaylistJustToRemoveFromIt() async throws {
        let harness = Harness(liked: makeTracks(2))
        let session = harness.session()
        await session.load()
        session.reject()
        await harness.syncAll()
        let id = try #require(harness.store.state.rejectedPlaylistIDs["liked"])
        await harness.api.unfollowPlaylist(id: id)

        let relaunched = await harness.relaunch()
        await relaunched.api.clearCalls()
        let resumed = relaunched.session()
        await resumed.load()
        resumed.undo()
        await relaunched.sync.runOnce()

        #expect(await relaunched.likedIDs().contains("t1"))
        #expect(!(await relaunched.api.calls).contains { if case .createPlaylist = $0 { true } else { false } })
        #expect(relaunched.sync.unsentCount == 0)
    }

    // MARK: Failures

    @Test func failedAddNeverRemovesTheSongFromLikedSongs() async throws {
        let harness = Harness(liked: makeTracks(2))
        await harness.api.failNext(.addToPlaylist, with: .forbidden("Spotify: Insufficient client scope"))
        let session = harness.session()
        await session.load()
        session.reject()
        await harness.syncAll()

        #expect(await harness.likedIDs() == ["t1", "t2"])
        #expect(harness.sync.failedWrites.count == 1)
        #expect(harness.sync.failedWrites.first?.state == .failed(message: "Spotify: Insufficient client scope"))
        #expect(harness.sync.unsentCount == 2)

        harness.sync.retryFailed()
        await harness.sync.runOnce()
        #expect(await harness.likedIDs() == ["t2"])
        #expect(try #require(await harness.rejectedPlaylist()).uris == ["spotify:track:t1"])
        #expect(harness.sync.failedWrites.isEmpty)
        #expect(harness.sync.status == .idle)
    }

    @Test func offlineChangesWaitAndSyncWhenBackOnline() async throws {
        let harness = Harness(liked: makeTracks(2))
        await harness.api.failNext(.currentUser, with: .offline)
        let session = harness.session()
        await session.load()
        session.reject()
        await harness.syncAll()

        #expect(harness.sync.status == .offline)
        #expect(harness.sync.unsentCount == 2)
        #expect(await harness.likedIDs() == ["t1", "t2"])

        // While offline, nothing is retried before the backoff…
        await harness.api.clearCalls()
        await harness.sync.runOnce()
        #expect(await harness.api.calls.isEmpty)

        // …but coming back online retries right away.
        harness.sync.networkBecameAvailable()
        await harness.sync.runOnce()
        #expect(await harness.likedIDs() == ["t2"])
        #expect(harness.sync.status == .idle)
    }

    @Test func expiredLoginPausesSyncUntilLoggedInAgain() async throws {
        let harness = Harness(liked: makeTracks(2))
        await harness.api.failNext(.removeFromLibrary, with: .loginRequired)
        let session = harness.session()
        await session.load()
        session.reject()
        await harness.syncAll()

        #expect(harness.sync.status == .needsLogin)
        #expect(try #require(await harness.rejectedPlaylist()).uris == ["spotify:track:t1"])
        #expect(await harness.likedIDs() == ["t1", "t2"])
        #expect(await harness.sync.runOnce() == nil)

        harness.sync.loginRestored()
        await harness.sync.runOnce()
        #expect(await harness.likedIDs() == ["t2"])
        #expect(harness.sync.status == .idle)
    }

    @Test func rateLimitBacksOff() async {
        let harness = Harness(liked: makeTracks(2))
        await harness.api.failNext(.currentUser, with: .rateLimited(retryAfter: 30))
        let session = harness.session()
        await session.load()
        session.reject()
        await harness.syncAll()

        guard case .backingOff(let until, let reason) = harness.sync.status else {
            Issue.record("expected backing off, got \(harness.sync.status)")
            return
        }
        #expect(reason == .rateLimited(retryAfter: 30))
        #expect(until == harness.clock.now.addingTimeInterval(30))

        harness.clock.advance(by: 31)
        await harness.sync.runOnce()
        #expect(await harness.likedIDs() == ["t2"])
    }

    @Test func quotaExceededWaitsLonger() async {
        let harness = Harness(liked: makeTracks(2))
        await harness.api.failNext(.currentUser, with: .quotaExceeded)
        let session = harness.session()
        await session.load()
        session.reject()
        await harness.syncAll()

        guard case .backingOff(let until, .quotaExceeded) = harness.sync.status else {
            Issue.record("expected quota backoff, got \(harness.sync.status)")
            return
        }
        #expect(until.timeIntervalSince(harness.clock.now) == 15 * 60)
    }

    @Test func flushSendsHeldChangesImmediately() async {
        let harness = Harness(liked: makeTracks(2))
        let session = harness.session()
        await session.load()
        session.reject()
        harness.sync.flushNow()
        await harness.sync.runOnce()
        #expect(await harness.likedIDs() == ["t2"])
    }
}

@Suite("Outbox")
struct OutboxTests {
    let start = Date(timeIntervalSince1970: 1_000)

    func reject(_ outbox: inout Outbox, _ number: Int, hold: TimeInterval = 10) -> UUID {
        let decision = UUID()
        outbox.enqueue(SortSource.likedSongs.rejectOps(for: makeTrack(number)), decisionID: decision, now: start, hold: hold)
        return decision
    }

    @Test func nothingIsDueDuringTheHold() {
        var outbox = Outbox()
        _ = reject(&outbox, 1)
        #expect(outbox.nextBatch(now: start.addingTimeInterval(9)) == nil)
        #expect(outbox.nextEligibleDate(after: start) == start.addingTimeInterval(10))
        #expect(outbox.nextBatch(now: start.addingTimeInterval(10))?.kind == .addToPlaylist)
    }

    @Test func addAlwaysPrecedesRemovalForASong() {
        var outbox = Outbox()
        _ = reject(&outbox, 1, hold: 0)
        let first = outbox.nextBatch(now: start)!
        #expect(first.kind == .addToPlaylist)
        outbox.markInFlight(first.writeIDs)
        // The removal is blocked while the add is in flight.
        #expect(outbox.nextBatch(now: start) == nil)
        outbox.markDone(Dictionary(uniqueKeysWithValues: first.writeIDs.map { ($0, true) }), now: start)
        #expect(outbox.nextBatch(now: start)?.kind == .removeFromLibrary)
    }

    @Test func failedWriteBlocksOnlyItsOwnSong() {
        var outbox = Outbox()
        _ = reject(&outbox, 1, hold: 0)
        let batch = outbox.nextBatch(now: start)!
        #expect(batch.uris == ["spotify:track:t1"])
        outbox.markFailed(batch.writeIDs, message: "nope")
        #expect(outbox.nextBatch(now: start) == nil)

        _ = reject(&outbox, 2, hold: 0)
        let next = outbox.nextBatch(now: start)!
        #expect(next.kind == .addToPlaylist)
        #expect(next.uris == ["spotify:track:t2"])
        #expect(outbox.failedWrites.count == 1)
        #expect(outbox.unsentCount == 4)
    }

    @Test func undoOfUnsentWritesDropsThem() {
        var outbox = Outbox()
        let decision = reject(&outbox, 1)
        outbox.undo(decisionID: decision, now: start)
        #expect(outbox.writes.isEmpty)
    }

    @Test func undoOfSentWritesQueuesInversesInReverseOrder() {
        var outbox = Outbox()
        let decision = reject(&outbox, 1, hold: 0)
        let add = outbox.nextBatch(now: start)!
        outbox.markDone([add.writeIDs[0]: true], now: start)
        let remove = outbox.nextBatch(now: start)!
        outbox.markDone([remove.writeIDs[0]: true], now: start)

        outbox.undo(decisionID: decision, now: start)
        let pending = outbox.writes.filter { $0.state == .pending }.map(\.op)
        #expect(pending == [
            WriteOp(kind: .saveToLibrary, playlist: nil, uri: "spotify:track:t1"),
            WriteOp(kind: .removeFromPlaylist, playlist: .rejected(sourceKey: "liked"), uri: "spotify:track:t1"),
        ])
    }

    @Test func undoSkipsWritesThatChangedNothing() {
        var outbox = Outbox()
        let decision = reject(&outbox, 1, hold: 0)
        let add = outbox.nextBatch(now: start)!
        outbox.markDone([add.writeIDs[0]: false], now: start) // song was already in Rejected
        let remove = outbox.nextBatch(now: start)!
        outbox.markDone([remove.writeIDs[0]: true], now: start)

        outbox.undo(decisionID: decision, now: start)
        let pending = outbox.writes.filter { $0.state == .pending }.map(\.op)
        #expect(pending == [WriteOp(kind: .saveToLibrary, playlist: nil, uri: "spotify:track:t1")])
    }

    @Test func undoWhileInFlightReversesAfterCompletion() {
        var outbox = Outbox()
        let decision = reject(&outbox, 1, hold: 0)
        let add = outbox.nextBatch(now: start)!
        outbox.markInFlight(add.writeIDs)
        outbox.undo(decisionID: decision, now: start)
        // The pending removal is cancelled; the in-flight add will be reversed.
        #expect(outbox.writes.count == 1)

        outbox.markDone([add.writeIDs[0]: true], now: start)
        let pending = outbox.writes.filter { $0.state == .pending }.map(\.op)
        #expect(pending == [WriteOp(kind: .removeFromPlaylist, playlist: .rejected(sourceKey: "liked"), uri: "spotify:track:t1")])
    }

    @Test func undoWhileInFlightThenFailureDropsTheWrite() {
        var outbox = Outbox()
        let decision = reject(&outbox, 1, hold: 0)
        let add = outbox.nextBatch(now: start)!
        outbox.markInFlight(add.writeIDs)
        outbox.undo(decisionID: decision, now: start)
        outbox.markPending(add.writeIDs)
        #expect(outbox.writes.isEmpty)
    }

    @Test func inFlightWritesAreRetriedAfterACrash() {
        var outbox = Outbox()
        _ = reject(&outbox, 1, hold: 0)
        let add = outbox.nextBatch(now: start)!
        outbox.markInFlight(add.writeIDs)
        outbox.recoverAfterRelaunch()
        #expect(outbox.nextBatch(now: start)?.writeIDs == add.writeIDs)
    }

    @Test func batchRespectsSpotifyLimits() {
        var outbox = Outbox()
        for number in 1...150 { _ = reject(&outbox, number, hold: 0) }
        let adds = outbox.nextBatch(now: start)!
        #expect(adds.kind == .addToPlaylist)
        #expect(adds.uris.count == 100)
    }

    @Test func completedHistoryIsBounded() {
        var outbox = Outbox()
        for number in 1...600 { _ = reject(&outbox, number, hold: 0) }
        while let batch = outbox.nextBatch(now: start) {
            outbox.markDone(Dictionary(uniqueKeysWithValues: batch.writeIDs.map { ($0, true) }), now: start)
        }
        #expect(outbox.writes.count == Outbox.completedHistoryLimit)
        #expect(outbox.unsentCount == 0)
    }

    @Test func pendingRemovalsAreReportedPerSource() {
        var outbox = Outbox()
        _ = reject(&outbox, 1)
        #expect(outbox.urisPendingRemoval(from: .likedSongs) == ["spotify:track:t1"])
        #expect(outbox.urisPendingRemoval(from: .playlist(id: "p", name: "Road Trip")).isEmpty)
    }
}

@Suite("Rejected playlist naming")
struct RejectedPlaylistNamingTests {
    @Test func likedSongs() {
        #expect(RejectedPlaylistNaming.name(forSourceNamed: "Liked Songs") == "Rejected \u{2013} Liked Songs")
    }

    @Test func playlist() {
        #expect(RejectedPlaylistNaming.name(forSourceNamed: "Road Trip") == "Rejected \u{2013} Road Trip")
    }

    @Test func usesAnEnDash() {
        let name = RejectedPlaylistNaming.name(forSourceNamed: "Liked Songs")
        #expect(name.unicodeScalars.map(\.value).contains(0x2013))
        #expect(!name.contains("-"))
    }

    @Test func trimsAndHandlesEmptyNames() {
        #expect(RejectedPlaylistNaming.name(forSourceNamed: "  Road Trip \n") == "Rejected – Road Trip")
        #expect(RejectedPlaylistNaming.name(forSourceNamed: "   ") == "Rejected – Untitled playlist")
    }

    @Test func capsLongNames() {
        let name = RejectedPlaylistNaming.name(forSourceNamed: String(repeating: "a", count: 300))
        #expect(name.count == RejectedPlaylistNaming.maxLength)
        #expect(name.hasPrefix("Rejected – aaa"))
        #expect(name.hasSuffix("…"))
    }

    @Test func recognisesItsOwnPlaylists() {
        #expect(RejectedPlaylistNaming.isRejectedPlaylistName("Rejected – Road Trip"))
        #expect(!RejectedPlaylistNaming.isRejectedPlaylistName("Road Trip"))
    }

    @Test func playlistSourcesGetTheirOwnRejectedPlaylist() {
        let source = SortSource.playlist(id: "abc", name: "Road Trip")
        let ops = source.rejectOps(for: makeTrack(1))
        #expect(ops == [
            WriteOp(kind: .addToPlaylist, playlist: .rejected(sourceKey: "playlist:abc"), uri: "spotify:track:t1"),
            WriteOp(kind: .removeFromPlaylist, playlist: .id("abc"), uri: "spotify:track:t1"),
        ])
    }
}
