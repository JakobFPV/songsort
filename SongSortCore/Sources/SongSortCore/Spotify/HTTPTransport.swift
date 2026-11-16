import Foundation

/// Sends HTTP requests. Swapped for a stub in tests.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw SpotifyError.invalidResponse("The server didn't answer with HTTP.")
            }
            return (data, http)
        } catch let error as URLError {
            throw Self.map(error)
        }
    }

    static func map(_ error: URLError) -> SpotifyError {
        switch error.code {
        case .cancelled: .cancelled
        default: .offline
        }
    }
}
