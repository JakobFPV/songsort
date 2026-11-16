import Foundation
import Observation
import SongSortCore
import SwiftUI

/// Glue between the sort session (queue, decisions, undo) and playback for the sorter screen.
@Observable
final class SorterModel {
    struct FlyingCard: Identifiable {
        let id = UUID()
        let track: Track
        let decision: Decision
        let startOffset: CGSize
    }

    struct Toast: Equatable {
        let id = UUID()
        let text: String
    }

    let session: SortSession
    let player: any MusicPlayer
    let sync: SyncEngine

    /// How far the top card is dragged.
    var dragOffset: CGSize = .zero
    /// Cards animating off screen after a decision (the queue has already moved on).
    private(set) var flyingCards: [FlyingCard] = []
    private(set) var toast: Toast?
    /// The card brought back by undo slides in from the side it left.
    private(set) var restoredTrackID: String?
    private(set) var restoredFromEdge: Edge = .leading
    /// Changes on every keep/reject (drives haptics).
    private(set) var decisionCount = 0
    private(set) var undoCount = 0

    @ObservationIgnored private var toastTask: Task<Void, Never>?

    init(session: SortSession, player: any MusicPlayer, sync: SyncEngine) {
        self.session = session
        self.player = player
        self.sync = sync
    }

    // MARK: - Lifecycle

    func appear() async {
        player.activate()
        if case .idle = session.phase {
            await session.load()
        }
        playCurrent()
    }

    func disappear() {
        player.deactivate()
        sync.flushNow()
    }

    func reload() async {
        await session.load()
        playCurrent()
    }

    // MARK: - Decisions

    func decide(_ decision: Decision, from offset: CGSize = .zero) {
        guard let track = session.current else { return }
        let record = decision == .keep ? session.keep() : session.reject()
        guard record != nil else { return }
        flyingCards.append(FlyingCard(track: track, decision: decision, startOffset: offset))
        dragOffset = .zero
        restoredTrackID = nil
        decisionCount += 1
        playCurrent()
    }

    func flyingCardFinished(_ id: UUID) {
        flyingCards.removeAll { $0.id == id }
    }

    func undo() {
        guard let record = session.undo() else { return }
        restoredFromEdge = record.decision == .keep ? .trailing : .leading
        restoredTrackID = record.trackID
        undoCount += 1
        let name = record.track?.name ?? "the song"
        showToast(record.decision == .reject ? "Undone: “\(name)” stays in Liked Songs" : "Undone: “\(name)”")
        playCurrent()
    }

    func startOver() async {
        await session.startOver()
        playCurrent()
    }

    func setOrder(_ order: QueueOrder) {
        session.setOrder(order)
        playCurrent()
    }

    // MARK: - Playback

    func playCurrent() {
        ArtworkCache.shared.prefetch(session.queue.prefix(4).compactMap(\.artworkURL))
        guard let track = session.current else {
            player.pause()
            return
        }
        player.play(track, from: track.middleMs)
    }

    func startSpotify() {
        player.startSpotify(playing: session.current)
    }

    func togglePause() {
        guard let track = session.current else { return }
        if player.state?.trackURI == track.uri {
            player.togglePause()
        } else {
            player.play(track, from: track.middleMs)
        }
    }

    func replayFromMiddle() {
        guard let track = session.current else { return }
        if player.state?.trackURI == track.uri {
            player.seek(to: track.middleMs)
        } else {
            player.play(track, from: track.middleMs)
        }
    }

    func skipAhead(seconds: Int = 15) {
        guard let track = session.current, let state = player.state, state.trackURI == track.uri else { return }
        let target = min(state.position(at: Date()) + seconds * 1000, max(0, track.durationMs - 1_000))
        player.seek(to: target)
    }

    func seek(fraction: Double) {
        guard let track = session.current else { return }
        let position = Int(Double(track.durationMs) * min(max(fraction, 0), 1))
        if player.state?.trackURI == track.uri {
            player.seek(to: position)
        } else {
            player.play(track, from: position)
        }
    }

    // MARK: - Toast

    private func showToast(_ text: String) {
        toast = Toast(text: text)
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }
}
