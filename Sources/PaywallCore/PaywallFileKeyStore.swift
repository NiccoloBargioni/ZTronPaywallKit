public import Foundation

/// Where the key that authenticates the caches next to the journal lives (`app-transaction.json`, `entitlement.json`):
/// 32 random bytes made once per install, never backed up or synced, read at every launch. `KeychainFileKeyStore`
/// (PaywallKit) keeps it in the Keychain, this device only, after first unlock; `InMemoryFileKeyStore` (PaywallTesting)
/// in memory. `nil` means no key right now (the Keychain before first unlock, a transient error): the caches are then
/// neither written nor trusted, and the engine resolves from the store alone until a key is back.
///
/// A store creates a key only when none exists. It must never replace one on a transient failure, or every file
/// written so far is orphaned and dropped at the next launch.
public protocol PaywallFileKeyStore: Sendable {
    func fileKey() -> Data?
}

/// HMAC-SHA256 (RFC 2104) over the package's own SHA-256, so the core authenticates files on Linux too.
public enum HMACSHA256 {
    public static func tag(key: Data, message: Data) -> Data {
        var padded = key.count > 64 ? SHA256Digest.hash(key) : [UInt8](key)
        padded += [UInt8](repeating: 0, count: 64 - padded.count)
        let inner = SHA256Digest.hash(Data(padded.map { $0 ^ 0x36 }) + message)
        return Data(SHA256Digest.hash(Data(padded.map { $0 ^ 0x5C }) + Data(inner)))
    }
}
