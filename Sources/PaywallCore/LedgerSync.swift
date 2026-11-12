import Foundation

/// The seam for cross-device and reinstall persistence: CloudKit plus the Keychain snapshot in
/// `ZTronPaywallCloudSync`, a server later. Carriers only add events, so no merge can remove a debit.
public protocol LedgerSync: Sendable {
    /// Uploads events and returns the ids the carrier now holds (already-present ids count as acknowledged).
    func push(_ events: [LedgerEvent]) async throws -> Set<String>
    /// Events the carrier holds that this device may not have. Union-merged by id.
    func pull() async throws -> [LedgerEvent]
    /// The fast-path balance known after a reinstall, before the first pull.
    func loadSnapshot() async -> WalletSnapshot?
    func saveSnapshot(_ snapshot: WalletSnapshot) async
    /// The next `pull()` should fetch even if the carrier's pull interval has not elapsed (after a purchase, a
    /// restore, or a silent push).
    func requestPull() async
}

extension LedgerSync {
    public func loadSnapshot() async -> WalletSnapshot? { nil }
    public func saveSnapshot(_ snapshot: WalletSnapshot) async {}
    public func requestPull() async {}
}
