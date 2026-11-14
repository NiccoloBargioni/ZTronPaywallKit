public import Foundation
public import PaywallCore

/// The recommended carrier: ledger events in the CloudKit private database (the truth across devices, union
/// merge, no conflicts because events are immutable) plus the Keychain snapshot (the fast path after a
/// reinstall). Reservations and leases never sync. A device with no iCloud account is answered with nothing
/// rather than an error (`CloudDatabaseError.noAccount`): the engine then settles the welcome grant on its own,
/// and the next sync asks again, so signing in is picked up.
///
/// ```swift
/// var configuration = Paywall.Configuration(catalog: catalog)
/// configuration.sync = PaywallCloudSync(containerIdentifier: "iCloud.com.ztron.app")
/// ```
public actor PaywallCloudSync: LedgerSync {
    public let database: any CloudDatabase
    public let keychain: KeychainWalletSnapshotStore?
    /// Pulls run at most this often unless `requestPull()` asked for one (silent push, purchase, restore).
    public let minimumPullInterval: TimeInterval
    private let tokenURL: URL?
    private var changeToken: Data?
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
        self.tokenURL = tokenURL
        self.changeToken = tokenURL.flatMap { FileManager.default.contents(atPath: $0.path) }
    }

    /// CloudKit in `containerIdentifier` (or the default container), with the change token stored next to the
    /// journal in Application Support. Entitled hosts only: see `CloudKitDatabase.init(containerIdentifier:)`.
    public init(containerIdentifier: String? = nil, keychain: KeychainWalletSnapshotStore? = KeychainWalletSnapshotStore()) { self.init(database: CloudKitDatabase(containerIdentifier: containerIdentifier), keychain: keychain, tokenURL: Self.defaultTokenURL) }

    /// `Application Support/ztron.paywall/cloudkit.token`, next to the journal.
    public static var defaultTokenURL: URL { let base: URL; if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first { base = support } else { base = FileManager.default.temporaryDirectory }; return base.appendingPathComponent("ztron.paywall/cloudkit.token") }

    public func push(_ events: [LedgerEvent]) async throws -> Set<String> {
        let records = try events.map(CloudLedgerRecord.init)
        return try await database.save(records)
    }

    public func pull() async throws -> [LedgerEvent] {
        if !pullRequested, let lastPull, Date().timeIntervalSince(lastPull) < minimumPullInterval { return [] }
        let page: (records: [CloudLedgerRecord], token: Data?)
        do {
            page = try await database.fetchChanges(since: changeToken)
        } catch CloudDatabaseError.noAccount {
            // Nothing of this account exists anywhere for this device to take: the pull has answered, with nothing.
            // Neither the interval nor the token moves, so the next sync asks again.
            return []
        }
        changeToken = page.token
        if let tokenURL, let token = page.token {
            try? FileManager.default.createDirectory(at: tokenURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? token.write(to: tokenURL, options: .atomic)
        }
        lastPull = Date()
        pullRequested = false
        return page.records.compactMap { try? $0.event() }
    }

    public func requestPull() async { pullRequested = true }

    public func loadSnapshot() async -> WalletSnapshot? { await keychain?.load() }

    public func saveSnapshot(_ snapshot: WalletSnapshot) async { await keychain?.save(snapshot) }
}
