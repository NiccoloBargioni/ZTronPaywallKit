import Foundation
public import PaywallCore
import Security

/// The wallet snapshot (balance, last event id, head hash) as a Keychain item. Keychain items outlive app deletion
/// on iOS, so delete-and-reinstall keeps the balance even with iCloud off; with `synchronizable` it rides iCloud
/// Keychain to the user's other devices (last writer wins).
public actor KeychainWalletSnapshotStore {
    public let service: String
    public let account: String
    public let synchronizable: Bool

    public init(service: String = "ztron.paywall", account: String = "wallet.snapshot", synchronizable: Bool = true) {
        self.service = service
        self.account = account
        self.synchronizable = synchronizable
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable ? kCFBooleanTrue as Any : kCFBooleanFalse as Any,
        ]
    }

    public func load() -> WalletSnapshot? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(WalletSnapshot.self, from: data)
    }

    @discardableResult
    public func save(_ snapshot: WalletSnapshot) -> Bool {
        guard let data = try? JSONEncoder().encode(snapshot) else { return false }
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    public func delete() -> Bool {
        let status = SecItemDelete(baseQuery as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
