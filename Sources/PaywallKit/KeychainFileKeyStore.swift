public import Foundation
public import PaywallCore
import Security

/// The key that authenticates the caches next to the journal, as a Keychain item: 32 random bytes made the first time
/// nothing is there, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, never synchronizable and never in a backup
/// another device could restore. Before first unlock, or on any Keychain error other than "not found", the answer is
/// `nil` and the engine neither writes nor trusts the caches for that launch; the key is never replaced on such an
/// error, or every file written so far would be orphaned.
public struct KeychainFileKeyStore: PaywallFileKeyStore {
    public let service: String
    public let account: String

    public init(service: String = "ztron.paywall", account: String = "files.key") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    public func fileKey() -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 { return data }
        guard status == errSecItemNotFound else { return nil }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let key = Data(bytes)
        var add = baseQuery
        add[kSecValueData as String] = key
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        switch SecItemAdd(add as CFDictionary, nil) {
        case errSecSuccess:
            return key
        case errSecDuplicateItem:
            // Another process won the race: read what it stored.
            var again: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &again) == errSecSuccess, let data = again as? Data, data.count == 32 else {
                return nil
            }
            return data
        default:
            return nil
        }
    }

    /// Removes the key. Tests only: every cache written so far is dropped at the next launch.
    @discardableResult
    public func delete() -> Bool {
        let status = SecItemDelete(baseQuery as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
