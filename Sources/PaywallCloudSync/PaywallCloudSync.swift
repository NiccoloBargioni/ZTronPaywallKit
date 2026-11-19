public import Foundation
public import PaywallCore

/// The recommended carrier: ledger events in the CloudKit private database (the truth across devices, union
/// merge, no conflicts because events are immutable) plus the Keychain snapshot (the fast path after a
/// reinstall). Reservations and leases never sync. The engine owns the pull position: `pull(since:)` fetches the
/// changes after the cursor the engine stored in its journal next to the last merged events, so a journal that lost
/// events fetches them again, and nothing here outlives a reinstall but the Keychain item.
///
/// A device with no iCloud account is answered with nothing rather than an error (`CloudDatabaseError.noAccount`):
/// the engine then settles the welcome grant on its own, stops pushing until a pull finds an account, and the next
/// pull asks again, so signing in is picked up.
///
/// ```swift
/// var configuration = Paywall.Configuration(catalog: catalog)
/// configuration.sync = PaywallCloudSync(containerIdentifier: "iCloud.com.ztron.app")
/// ```
public actor PaywallCloudSync: LedgerSync {
    public let database: any CloudDatabase
    public let keychain: KeychainWalletSnapshotStore?
    /// Pulls run at most this often unless `requestPull()` asked for one (silent push, purchase, restore, an
    /// engine's first sync, a merge that failed). Inside the interval `pull(since:)` answers `nil`: it did not look.
    public let minimumPullInterval: TimeInterval
    /// Where builds before this one kept the change token. Deleted at the first pull: the position lives in the
    /// journal now, and one full fetch is safe under the union merge.
    private let legacyTokenURL: URL?
    private var lastPull: Date?
    private var pullRequested = true

    public init(
        database: any CloudDatabase,
        keychain: KeychainWalletSnapshotStore? = KeychainWalletSnapshotStore(),
        minimumPullInterval: TimeInterval = 3_600,
        tokenURL: URL? = nil
    ) {
        self.database = database
        self.keychain = keychain
        self.minimumPullInterval = minimumPullInterval
        self.legacyTokenURL = tokenURL
    }

    /// CloudKit in `containerIdentifier` (or the default container). Entitled hosts only: see
    /// `CloudKitDatabase.init(containerIdentifier:)`.
    public init(containerIdentifier: String? = nil, keychain: KeychainWalletSnapshotStore? = KeychainWalletSnapshotStore()) { self.init(database: CloudKitDatabase(containerIdentifier: containerIdentifier), keychain: keychain, tokenURL: Self.defaultTokenURL) }

    /// `Application Support/ztron.paywall/cloudkit.token`, where builds before this one kept the change token.
    public static var defaultTokenURL: URL { let base: URL; if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first { base = support } else { base = FileManager.default.temporaryDirectory }; return base.appendingPathComponent("ztron.paywall/cloudkit.token") }

    public func push(_ events: [LedgerEvent]) async throws -> Set<String> {
        let records = try events.map(CloudLedgerRecord.init)
        return try await database.save(records)
    }

    /// Every event in the container, from the beginning.
    public func pull() async throws -> [LedgerEvent] {
        try await pull(since: nil)?.events ?? []
    }

    /// The changes after `cursor` (an archived `CKServerChangeToken`; everything for `nil`), with the token to store
    /// with them. `nil` inside the pull interval, when nothing asked for a pull. A device with no iCloud account gets an
    /// empty answer that says so, and neither the interval nor the position moves, so the next sync asks again.
    public func pull(since cursor: Data?) async throws -> LedgerPull? {
        if !pullRequested, let lastPull, Date().timeIntervalSince(lastPull) < minimumPullInterval { return nil }
        if let legacyTokenURL { try? FileManager.default.removeItem(at: legacyTokenURL) }
        let page: (records: [CloudLedgerRecord], token: Data?)
        do {
            page = try await database.fetchChanges(since: cursor)
        } catch CloudDatabaseError.noAccount {
            return LedgerPull(events: [], cursor: cursor, accountAvailable: false)
        }
        lastPull = Date()
        pullRequested = false
        return LedgerPull(events: page.records.compactMap { try? $0.event() }, cursor: page.token ?? cursor, accountAvailable: true)
    }

    public func requestPull() async { pullRequested = true }

    public func loadSnapshot() async -> WalletSnapshot? { await keychain?.load() }

    public func saveSnapshot(_ snapshot: WalletSnapshot) async { await keychain?.save(snapshot) }
}
