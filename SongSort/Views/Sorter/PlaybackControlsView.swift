import SongSortCore
import SwiftUI

/// Progress bar plus play/pause, "from the middle" and "+15 s", or what to do when Spotify isn't ready.
struct PlaybackControlsView: View {
    let model: SorterModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            switch model.player.connection {
            case .connected, .idle:
                controls
            case .connecting:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Connecting to Spotify…")
                        .foregroundStyle(.secondary)
                }
            case .needsStart:
                VStack(spacing: 8) {
                    Button {
                        model.startSpotify()
                    } label: {
                        Label("Start playback in Spotify", systemImage: "play.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    Text("Spotify isn't running. This opens it for a moment and comes straight back.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            case .notInstalled:
                VStack(spacing: 8) {
                    Label("Spotify isn't installed", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Text("SongSort plays songs through the Spotify app. You can still sort, without sound.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Get Spotify from the App Store") { openURL(SpotifyLinks.appStore) }
                        .buttonStyle(.bordered)
                }
            case .failed(let message):
                VStack(spacing: 8) {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                    Button("Try again") { model.startSpotify() }
                        .buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 112)
    }

    private var controls: some View {
        VStack(spacing: 6) {
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                ScrubBar(
                    positionMs: position(at: context.date),
                    durationMs: model.session.current?.durationMs ?? 0,
                    onSeek: { model.seek(fraction: $0) }
                )
            }
            HStack(spacing: 44) {
                ControlButton(systemImage: "gobackward", caption: "Middle") { model.replayFromMiddle() }
                    .accessibilityLabel("Replay from the middle")
                Button {
                    model.togglePause()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .frame(width: 58, height: 58)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel(isPlaying ? "Pause" : "Play")
                ControlButton(systemImage: "goforward.15", caption: "15 s") { model.skipAhead() }
                    .accessibilityLabel("Jump ahead 15 seconds")
            }
            if let problem = model.player.problem {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var isPlaying: Bool {
        guard let state = model.player.state, state.trackURI == model.session.current?.uri else { return false }
        return !state.isPaused
    }

    private func position(at date: Date) -> Int {
        guard let track = model.session.current else { return 0 }
        if let state = model.player.state, state.trackURI == track.uri {
            return state.position(at: date)
        }
        return track.middleMs
    }
}

private struct ControlButton: View {
    let systemImage: String
    let caption: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .medium))
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 56, height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
    }
}

/// Song progress with a tick at the middle. Drag anywhere on it to jump.
struct ScrubBar: View {
    let positionMs: Int
    let durationMs: Int
    let onSeek: (Double) -> Void
    @State private var dragFraction: Double?

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                let fraction = dragFraction ?? currentFraction
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(Color.accentColor)
                        .frame(width: max(0, geometry.size.width * fraction))
                    Rectangle()
                        .fill(Color.primary.opacity(0.35))
                        .frame(width: 2, height: 12)
                        .offset(x: geometry.size.width / 2 - 1)
                }
                .frame(height: dragFraction == nil ? 6 : 10)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            dragFraction = Self.clamp(value.location.x / max(geometry.size.width, 1))
                        }
                        .onEnded { value in
                            onSeek(Self.clamp(value.location.x / max(geometry.size.width, 1)))
                            dragFraction = nil
                        }
                )
                .animation(.easeOut(duration: 0.15), value: dragFraction == nil)
            }
            .frame(height: 24)
            HStack {
                Text(DurationFormatter.string(fromMs: displayedPosition))
                Spacer()
                Text(DurationFormatter.string(fromMs: durationMs))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .accessibilityElement()
        .accessibilityLabel("Song position")
        .accessibilityValue("\(DurationFormatter.string(fromMs: displayedPosition)) of \(DurationFormatter.string(fromMs: durationMs))")
        .accessibilityAdjustableAction { direction in
            let step = 15_000.0 / Double(max(durationMs, 1))
            switch direction {
            case .increment: onSeek(Self.clamp(currentFraction + step))
            case .decrement: onSeek(Self.clamp(currentFraction - step))
            @unknown default: break
            }
        }
    }

    private var currentFraction: Double {
        durationMs > 0 ? Self.clamp(Double(positionMs) / Double(durationMs)) : 0
    }

    private var displayedPosition: Int {
        dragFraction.map { Int($0 * Double(durationMs)) } ?? positionMs
    }

    private static func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }
}

/// Reject · Undo · Keep, sized for thumbs.
struct DecisionBar: View {
    let model: SorterModel

    var body: some View {
        HStack(spacing: 34) {
            RoundButton(systemImage: "xmark", tint: .red, diameter: 76) { model.decide(.reject) }
                .accessibilityLabel("Reject")
                .accessibilityHint("Moves the song to the Rejected playlist")
            RoundButton(systemImage: "arrow.uturn.backward", tint: .gray, diameter: 52) {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { model.undo() }
            }
            .disabled(!model.session.canUndo)
            .opacity(model.session.canUndo ? 1 : 0.35)
            .accessibilityLabel("Undo")
            RoundButton(systemImage: "heart.fill", tint: .green, diameter: 76) { model.decide(.keep) }
                .accessibilityLabel("Keep")
        }
    }
}

private struct RoundButton: View {
    let systemImage: String
    let tint: Color
    let diameter: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: diameter * 0.36, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(tint.opacity(0.14)))
                .overlay(Circle().strokeBorder(tint.opacity(0.35), lineWidth: 1.5))
        }
        .buttonStyle(PressScaleStyle())
    }
}

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
