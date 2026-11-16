import Foundation
import Security
import SongSortCore

/// Keeps the Spotify tokens in the Keychain so the login survives relaunches and reboots.
nonisolated struct KeychainTokenStore: TokenStore {
    private let service = "SongSort"
    private let account = "spotify-oauth-tokens"

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func loadTokens() -> OAuthTokens? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(OAuthTokens.self, from: data)
    }

    func saveTokens(_ tokens: OAuthTokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // Readable after the first unlock, so a background token refresh works; never synced off the device.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let query = baseQuery.merging(attributes) { _, new in new }
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    func deleteTokens() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
