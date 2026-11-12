public import Foundation
public import PaywallCore

/// The recommended carrier: ledger events in the CloudKit private database (the truth across devices, union
/// merge, no conflicts because events are immutable) plus the Keychain snapshot (the fast path after a
/// reinstall). Reservations and leases never sync.
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
    /// journal in Application Support.
    public init(containerIdentifier: String? = nil, keychain: KeychainWalletSnapshotStore? = KeychainWalletSnapshotStore()) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.init(
            database: CloudKitDatabase(containerIdentifier: containerIdentifier), keychain: keychain,
            tokenURL: base.appendingPathComponent("ztron.paywall/cloudkit.token"))
    }

    public func push(_ events: [LedgerEvent]) async throws -> Set<String> {
        let records = try events.map(CloudLedgerRecord.init)
        return try await database.save(records)
    }

    public func pull() async throws -> [LedgerEvent] {
        if !pullRequested, let lastPull, Date().timeIntervalSince(lastPull) < minimumPullInterval { return [] }
        let (records, token) = try await database.fetchChanges(since: changeToken)
        changeToken = token
        if let tokenURL, let token {
            try? FileManager.default.createDirectory(at: tokenURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? token.write(to: tokenURL, options: .atomic)
        }
        lastPull = Date()
        pullRequested = false
        return records.compactMap { try? $0.event() }
    }

    public func requestPull() async { pullRequested = true }

    public func loadSnapshot() async -> WalletSnapshot? { await keychain?.load() }

    public func saveSnapshot(_ snapshot: WalletSnapshot) async { await keychain?.save(snapshot) }
}
