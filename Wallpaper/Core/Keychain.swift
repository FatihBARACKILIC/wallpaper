import Foundation
import Security

/// Stores the user's Unsplash Access Key in the login keychain.
///
/// Not the data-protection keychain: that one requires a
/// `keychain-access-groups` entitlement, which in turn forces a provisioning
/// profile onto every build and onto the notarized DMG. The login keychain
/// needs no entitlement, is encrypted at rest, is unlocked with the user's
/// login, and binds the item to this app's code signature — which is the
/// protection that matters here.
///
/// The value is never logged and never written to UserDefaults.
enum Keychain {
    private static let service = "com.barackilic.Wallpaper"
    private static let account = "unsplash-access-key"

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

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func save(_ accessKey: String) throws {
        let data = Data(accessKey.utf8)

        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrDescription as String] = "Unsplash Access Key"

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

    static func read() -> String? {
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

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    /// `"abcd…Wx9Y"` — safe to show in the UI and in error messages.
    static func masked(_ accessKey: String) -> String {
        guard accessKey.count > 8 else { return String(repeating: "•", count: accessKey.count) }
        return "\(accessKey.prefix(4))…\(accessKey.suffix(4))"
    }
}
