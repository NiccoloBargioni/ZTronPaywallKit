import Foundation
import Security
import Testing

@testable import PaywallKit

/// B1: the file key in the Keychain. Skipped where the process has no Keychain (a CI runner without a login keychain).
@Suite("Keychain file key store", .serialized)
struct KeychainFileKeyStoreTests {
    @Test func the_key_is_made_once_and_read_back_until_deleted() {
        let service = "ztron.paywall.tests.\(UUID().uuidString)"
        let store = KeychainFileKeyStore(service: service, account: "files.key")
        guard let key = store.fileKey() else { return }
        #expect(key.count == 32)
        #expect(store.fileKey() == key)
        #expect(KeychainFileKeyStore(service: service, account: "files.key").fileKey() == key, "another instance of the same install reads the same key")
        #expect(KeychainFileKeyStore(service: service, account: "other").fileKey() != key)
        #expect(store.delete())
        let fresh = store.fileKey()
        #expect(fresh != nil && fresh != key, "a new install, a new key")
        #expect(store.delete())
        #expect(store.delete(), "deleting nothing is clean")
        #expect(KeychainFileKeyStore(service: service, account: "other").delete())
    }

    @Test func an_item_of_the_wrong_size_is_no_key_and_is_not_replaced() {
        let service = "ztron.paywall.tests.\(UUID().uuidString)"
        let planted: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "files.key",
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any, kSecValueData as String: Data(repeating: 1, count: 16),
        ]
        guard SecItemAdd(planted as CFDictionary, nil) == errSecSuccess else { return }
        let store = KeychainFileKeyStore(service: service, account: "files.key")
        #expect(store.fileKey() == nil, "16 bytes under the key's name: not a key")
        #expect(store.fileKey() == nil, "and not replaced by one")
        #expect(store.delete())
        #expect(store.fileKey()?.count == 32)
        #expect(store.delete())
    }
}
