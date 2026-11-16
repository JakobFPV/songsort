import Foundation
import Network
import Observation

/// Tracks whether the phone is online, so the app can say so and resume syncing when it's back.
@Observable
final class NetworkMonitor {
    private(set) var isOnline = true
    @ObservationIgnored var onChange: ((Bool) -> Void)?
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var started = false

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { @Sendable [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.update(online) }
        }
        monitor.start(queue: DispatchQueue(label: "SongSort.NetworkMonitor"))
    }

    private func update(_ online: Bool) {
        guard online != isOnline else { return }
        isOnline = online
        onChange?(online)
    }
}
