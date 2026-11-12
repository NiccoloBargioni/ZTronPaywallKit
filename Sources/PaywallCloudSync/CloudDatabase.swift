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

/// The CloudKit boundary, so merge, outbox and conflict logic run against an in-memory fake in tests.
public protocol CloudDatabase: Sendable {
    /// Saves records and returns the names the server now holds (already-present names included).
    func save(_ records: [CloudLedgerRecord]) async throws -> Set<String>
    /// Records changed since `token`, and the token to store for next time.
    func fetchChanges(since token: Data?) async throws -> (records: [CloudLedgerRecord], token: Data?)
}

/// An in-memory `CloudDatabase`: several carriers on one instance behave like devices on one iCloud account.
public actor InMemoryCloudDatabase: CloudDatabase {
    public enum Failure: Error, Hashable, Sendable { case offline }

    private var records: [String: (record: CloudLedgerRecord, serial: Int)] = [:]
    private var serial = 0
    public var isReachable = true
    public private(set) var saveOperations = 0

    public init() {}

    public func setReachable(_ reachable: Bool) { isReachable = reachable }
    public var count: Int { records.count }

    public func save(_ batch: [CloudLedgerRecord]) async throws -> Set<String> {
        guard isReachable else { throw Failure.offline }
        saveOperations += 1
        for record in batch where records[record.name] == nil {
            serial += 1
            records[record.name] = (record, serial)
        }
        return Set(batch.map(\.name))
    }

    public func fetchChanges(since token: Data?) async throws -> (records: [CloudLedgerRecord], token: Data?) {
        guard isReachable else { throw Failure.offline }
        let since = token.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
        let changed = records.values.filter { $0.serial > since }.sorted { $0.serial < $1.serial }.map(\.record)
        return (changed, Data(String(serial).utf8))
    }
}
