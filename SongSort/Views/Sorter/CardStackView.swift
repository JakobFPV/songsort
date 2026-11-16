import SongSortCore
import SwiftUI

/// The current card on top of the next two. Drag the top card right to keep, left to reject.
struct CardStackView: View {
    let model: SorterModel

    var body: some View {
        GeometryReader { geometry in
            let cards = Array(model.session.queue.prefix(3).enumerated())
            ZStack {
                ForEach(cards.reversed(), id: \.element.id) { index, track in
                    let isTop = index == 0
                    TrackCardView(
                        track: track,
                        availableSize: geometry.size,
                        stamp: isTop ? stamp(width: geometry.size.width) : 0
                    )
                    .scaleEffect(1 - CGFloat(index) * 0.05, anchor: .bottom)
                    .offset(y: CGFloat(index) * 13)
                    .offset(isTop ? model.dragOffset : .zero)
                    .rotationEffect(.degrees(isTop ? Double(model.dragOffset.width / 22) : 0), anchor: .bottom)
                    .zIndex(Double(10 - index))
                    .transition(transition(for: track))
                    .accessibilityHidden(!isTop)
                    .accessibilityAction(named: "Keep") { if isTop { model.decide(.keep) } }
                    .accessibilityAction(named: "Reject") { if isTop { model.decide(.reject) } }
                }
                ForEach(model.flyingCards) { card in
                    FlyingCardView(card: card, availableSize: geometry.size) {
                        model.flyingCardFinished(card.id)
                    }
                    .zIndex(20)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(dragGesture(width: geometry.size.width))
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: model.session.current?.id)
        }
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                model.dragOffset = value.translation
            }
            .onEnded { value in
                let threshold = width * 0.28
                let dx = value.translation.width
                let predicted = value.predictedEndTranslation.width
                if dx > threshold || predicted > width * 0.9 {
                    model.decide(.keep, from: value.translation)
                } else if dx < -threshold || predicted < -width * 0.9 {
                    model.decide(.reject, from: value.translation)
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        model.dragOffset = .zero
                    }
                }
            }
    }

    /// -1 (fully "reject") … 1 (fully "keep") while dragging.
    private func stamp(width: CGFloat) -> CGFloat {
        let threshold = max(width * 0.28, 1)
        return min(max(model.dragOffset.width / threshold, -1), 1)
    }

    private func transition(for track: Track) -> AnyTransition {
        let insertion: AnyTransition = track.id == model.restoredTrackID
            ? .move(edge: model.restoredFromEdge).combined(with: .opacity)
            : .opacity
        return .asymmetric(insertion: insertion, removal: .identity)
    }
}

/// A decided card flying off screen while the next song already plays.
struct FlyingCardView: View {
    let card: SorterModel.FlyingCard
    let availableSize: CGSize
    let onFinish: () -> Void
    @State private var offset: CGSize

    init(card: SorterModel.FlyingCard, availableSize: CGSize, onFinish: @escaping () -> Void) {
        self.card = card
        self.availableSize = availableSize
        self.onFinish = onFinish
        _offset = State(initialValue: card.startOffset)
    }

    var body: some View {
        TrackCardView(track: card.track, availableSize: availableSize, stamp: card.decision == .keep ? 1 : -1)
            .offset(offset)
            .rotationEffect(.degrees(Double(offset.width / 22)), anchor: .bottom)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                let direction: CGFloat = card.decision == .keep ? 1 : -1
                withAnimation(.easeIn(duration: 0.26)) {
                    offset = CGSize(width: direction * availableSize.width * 1.5, height: card.startOffset.height + 60)
                } completion: {
                    onFinish()
                }
            }
    }
}

/// The swipe card: cover art, title, artists, album · year · length.
struct TrackCardView: View {
    let track: Track
    let availableSize: CGSize
    /// -1 … 1: how strongly to show the REJECT (negative) or KEEP (positive) stamp.
    var stamp: CGFloat = 0

    private let textHeight: CGFloat = 104

    var body: some View {
        // Leave room below the card for the next two cards to peek out.
        let side = max(140, min(availableSize.width, availableSize.height - textHeight - 30))
        VStack(alignment: .leading, spacing: 0) {
            ArtworkView(track: track)
                .frame(width: side, height: side)
                .overlay(alignment: .topLeading) {
                    StampLabel(text: "KEEP", color: .green)
                        .rotationEffect(.degrees(-14))
                        .padding(18)
                        .opacity(Double(max(0, stamp)))
                }
                .overlay(alignment: .topTrailing) {
                    StampLabel(text: "REJECT", color: .red)
                        .rotationEffect(.degrees(14))
                        .padding(18)
                        .opacity(Double(max(0, -stamp)))
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(track.name)
                    .font(.title3.weight(.bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Text(track.artistLine.isEmpty ? "Unknown artist" : track.artistLine)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(detailLine)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(width: side, height: textHeight, alignment: .topLeading)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.14), radius: 14, y: 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(track.name), by \(track.artistLine). \(detailLine)")
        .accessibilityHint("Swipe right to keep, left to reject.")
    }

    /// "Album · 1997 · 4:05"
    private var detailLine: String {
        var parts: [String] = []
        if !track.album.isEmpty { parts.append(track.album) }
        if let year = track.releaseYear { parts.append(String(year)) }
        parts.append(DurationFormatter.string(fromMs: track.durationMs))
        return parts.joined(separator: " · ")
    }
}

private struct StampLabel: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 30, weight: .heavy, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(color, lineWidth: 4))
    }
}
