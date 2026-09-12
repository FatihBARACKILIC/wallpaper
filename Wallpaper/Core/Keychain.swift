import Foundation
import Security

/// Stores the user's API keys in the login keychain.
///
/// Not the data-protection keychain: that one requires a
/// `keychain-access-groups` entitlement, which in turn forces a provisioning
/// profile onto every build and onto the notarized DMG. The login keychain
/// needs no entitlement, is encrypted at rest, is unlocked with the user's
/// login, and binds the item to this app's code signature — which is the
/// protection that matters here.
///
/// Values are never logged and never written to UserDefaults.
struct Keychain {
    private static let service = "com.barackilic.Wallpaper"

    /// Required for the Unsplash sources (topic, collection, search).
    static let unsplashAccessKey = Keychain(
        account: "unsplash-access-key",
        label: "Unsplash Access Key"
    )

    /// Required for the NASA APOD source.
    static let nasaAPIKey = Keychain(
        account: "nasa-api-key",
        label: "NASA API Key"
    )

    /// Every item the app owns. The uninstaller walks this, so a key added here
    /// is removed there without anyone having to remember.
    static let all: [Keychain] = [unsplashAccessKey, nasaAPIKey]

    let account: String
    let label: String

    enum Failure: LocalizedError {
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
                return "Keychain error: \(message)"
            }
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
    }

    func save(_ value: String) throws {
        let data = Data(value.utf8)

        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrDescription as String] = label

        let status = SecItemAdd(attributes as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let update = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else { throw Failure.unexpectedStatus(updateStatus) }
        default:
            throw Failure.unexpectedStatus(status)
        }
    }

    func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8)
        else { return nil }

        return key
    }

    func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    /// `"abcd…Wx9Y"` — safe to show in the UI and in error messages.
    static func masked(_ value: String) -> String {
        guard value.count > 8 else { return String(repeating: "•", count: value.count) }
        return "\(value.prefix(4))…\(value.suffix(4))"
    }
}
