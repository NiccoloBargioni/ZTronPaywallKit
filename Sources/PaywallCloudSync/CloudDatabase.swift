public import Foundation
public import PaywallCore

/// One ledger event as the cloud stores it: record name = event id, so a retried save is "already present".
public struct CloudLedgerRecord: Hashable, Sendable {
    public var name: String
    public var payload: Data

    public init(name: String, payload: Data) {
        self.name = name
        self.payload = payload
    }

    public init(_ event: LedgerEvent) throws {
        self.init(name: event.id, payload: try event.canonicalData())
    }

    public func event() throws -> LedgerEvent { try LedgerEvent(canonicalData: payload) }
}

/// The CloudKit boundary, so merge, outbox and conflict logic run against an in-memory fake in tests. Both calls
/// throw `CloudDatabaseError.noAccount` while the device has no account for the database.
public protocol CloudDatabase: Sendable {
    /// Saves records and returns the names the server now holds (already-present names included).
    func save(_ records: [CloudLedgerRecord]) async throws -> Set<String>
    /// Records changed since `token`, and the token to store for next time.
    func fetchChanges(since token: Data?) async throws -> (records: [CloudLedgerRecord], token: Data?)
}

/// What a `CloudDatabase` throws while the device has no account for it (no iCloud account signed in): there is
/// nothing to pull from and nothing to push to until one appears. `PaywallCloudSync` answers such a pull with
/// nothing, so the engine settles on its own what it would otherwise take from the account's history (the welcome
/// grant), and asks again at the next sync. Every other failure is what it is, a failure to answer, and is retried.
public enum CloudDatabaseError: Error, Hashable, Sendable { case noAccount }

/// An in-memory `CloudDatabase`: several carriers on one instance behave like devices on one iCloud account.
public actor InMemoryCloudDatabase: CloudDatabase {
    public enum Failure: Error, Hashable, Sendable { case offline }

    private var records: [String: (record: CloudLedgerRecord, serial: Int)] = [:]
    private var serial = 0
    public var isReachable = true
    /// `false` stands for a device with no iCloud account: every call throws `CloudDatabaseError.noAccount`.
    public var hasAccount = true
    public private(set) var saveOperations = 0

    public init() {}

    public func setReachable(_ reachable: Bool) { isReachable = reachable }
    public func setAccount(_ present: Bool) { hasAccount = present }
    public var count: Int { records.count }

    public func save(_ batch: [CloudLedgerRecord]) async throws -> Set<String> {
        guard hasAccount else { throw CloudDatabaseError.noAccount }
        guard isReachable else { throw Failure.offline }
        saveOperations += 1
        for record in batch where records[record.name] == nil {
            serial += 1
            records[record.name] = (record, serial)
        }
        return Set(batch.map(\.name))
    }

    public func fetchChanges(since token: Data?) async throws -> (records: [CloudLedgerRecord], token: Data?) {
        guard hasAccount else { throw CloudDatabaseError.noAccount }
        guard isReachable else { throw Failure.offline }
        let since = token.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
        let changed = records.values.filter { $0.serial > since }.sorted { $0.serial < $1.serial }.map(\.record)
        return (changed, Data(String(serial).utf8))
    }
}
