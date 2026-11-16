import SongSortCore
import SwiftUI
import UIKit

/// Downloads and keeps cover art in memory, and prefetches the next cards' art so swiping never waits.
final class ArtworkCache {
    static let shared = ArtworkCache()

    private let cache = NSCache<NSURL, UIImage>()
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]

    init() {
        cache.countLimit = 60
    }

    func cachedImage(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func load(_ url: URL) async -> UIImage? {
        if let cached = cachedImage(for: url) { return cached }
        if let task = inFlight[url] { return await task.value }
        let task = Task<UIImage?, Never> {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode ?? 200 < 400,
                  let image = UIImage(data: data) else { return nil }
            return await image.byPreparingForDisplay() ?? image
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image {
            cache.setObject(image, forKey: url as NSURL)
        }
        return image
    }

    func prefetch(_ urls: [URL]) {
        for url in urls where cachedImage(for: url) == nil && inFlight[url] == nil {
            Task { _ = await load(url) }
        }
    }
}

/// Cover art, shown unmodified (Spotify's policy), with a generated placeholder while it loads.
struct ArtworkView: View {
    let track: Track
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image = image ?? cached {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                PlaceholderArtwork(seed: track.album.isEmpty ? track.name : track.album, title: track.album)
            }
        }
        .clipped()
        .accessibilityHidden(true)
        .task(id: track.artworkURL) {
            guard let url = track.artworkURL else { return }
            image = await ArtworkCache.shared.load(url)
        }
    }

    private var cached: UIImage? {
        track.artworkURL.flatMap { ArtworkCache.shared.cachedImage(for: $0) }
    }
}

/// A gradient square with the album's initials (demo mode, and while real art loads).
struct PlaceholderArtwork: View {
    let seed: String
    let title: String

    var body: some View {
        let hue = Double(Self.stableHash(seed) % 360) / 360
        LinearGradient(
            colors: [
                Color(hue: hue, saturation: 0.55, brightness: 0.85),
                Color(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.45),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            VStack(spacing: 8) {
                Image(systemName: "music.note")
                    .font(.system(size: 44, weight: .semibold))
                Text(initials)
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
            }
            .foregroundStyle(.white.opacity(0.85))
        }
    }

    private var initials: String {
        title.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }

    static func stableHash(_ string: String) -> UInt64 {
        string.unicodeScalars.reduce(5381) { ($0 &* 33) &+ UInt64($1.value) }
    }
}
