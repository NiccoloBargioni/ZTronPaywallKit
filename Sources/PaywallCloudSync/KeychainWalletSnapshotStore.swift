import Foundation
public import PaywallCore
import Security

/// The wallet snapshot (balance, last event id, head hash) as a Keychain item. Keychain items outlive app deletion
/// on iOS, so delete-and-reinstall keeps the balance even with iCloud off. The item is this device's by default: a
/// synchronizable one would carry a balance to another device through iCloud Keychain even when that device's carrier
/// never delivers the history behind it, and the engine keeps an adopted snapshot until the history arrives, so the
/// account's history reaches other devices through the carrier instead. An item written as synchronizable by an
/// earlier build is still read when no local one exists.
public actor KeychainWalletSnapshotStore {
    public let service: String
    public let account: String
    public let synchronizable: Bool

    public init(service: String = "ztron.paywall", account: String = "wallet.snapshot", synchronizable: Bool = false) {
        self.service = service
        self.account = account
        self.synchronizable = synchronizable
    }

    private func baseQuery(synchronizable: Bool) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable ? kCFBooleanTrue as Any : kCFBooleanFalse as Any,
        ]
    }

    private var baseQuery: [String: Any] { baseQuery(synchronizable: synchronizable) }

    private func load(synchronizable: Bool) -> WalletSnapshot? {
        var query = baseQuery(synchronizable: synchronizable)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(WalletSnapshot.self, from: data)
    }

    /// The item as configured, else the one with the other synchronizable flag (what an earlier build wrote).
    public func load() -> WalletSnapshot? {
        load(synchronizable: synchronizable) ?? load(synchronizable: !synchronizable)
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

    /// Deletes the item as configured, and the one with the other flag where the process may see it: without the
    /// iCloud Keychain entitlement (a macOS test runner) synchronizable items answer `errSecMissingEntitlement`, and
    /// there is none to delete.
    @discardableResult
    public func delete() -> Bool {
        let own = SecItemDelete(baseQuery as CFDictionary)
        let other = SecItemDelete(baseQuery(synchronizable: !synchronizable) as CFDictionary)
        let clean: Set<OSStatus> = [errSecSuccess, errSecItemNotFound]
        return clean.contains(own) && (clean.contains(other) || other == errSecMissingEntitlement)
    }
}
