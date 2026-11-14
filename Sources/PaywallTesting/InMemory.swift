public import Foundation
public import PaywallCore

/// Collects audit records in memory, and can report debits for the launch-time audit repair.
public actor InMemoryAuditSink: PaywallAuditRepairing {
    public private(set) var records: [AuditRecord] = []

    public init(records: [AuditRecord] = []) { self.records = records }

    public func write(_ record: AuditRecord) async { records.append(record) }

    public var events: [PaywallEvent] { records.map(\.event) }

    public func recordedDebitIDs() async -> Set<String> {
        Set(
            records.compactMap { record in
                switch record.event {
                case .tokensConsumed(_, _, let debitID, _), .tokensRefunded(let debitID, _), .auditRepaired(let debitID): return debitID
                default: return nil
                }
            })
    }

    public func lastRecordHash() async -> String? { records.last?.hash }
}

/// A shared in-memory "cloud": several `InMemoryLedgerSync` carriers pointed at one store converge like devices
/// signed into one iCloud account.
public actor InMemoryCloud {
    public private(set) var events: [String: LedgerEvent] = [:]
    public private(set) var pushCount = 0
    public var isReachable = true

    public init() {}

    public func setReachable(_ reachable: Bool) { isReachable = reachable }

    func save(_ batch: [LedgerEvent]) throws -> Set<String> {
        guard isReachable else { throw FakeStore.Failure.network }
        pushCount += 1
        for event in batch where events[event.id] == nil { events[event.id] = event }
        return Set(batch.map(\.id))
    }

    func all() throws -> [LedgerEvent] {
        guard isReachable else { throw FakeStore.Failure.network }
        return Array(events.values)
    }
}

public actor InMemoryLedgerSync: LedgerSync {
    public let cloud: InMemoryCloud
    public private(set) var snapshot: WalletSnapshot?

    public init(cloud: InMemoryCloud = InMemoryCloud(), snapshot: WalletSnapshot? = nil) {
        self.cloud = cloud
        self.snapshot = snapshot
    }

    public func push(_ events: [LedgerEvent]) async throws -> Set<String> { try await cloud.save(events) }
    public func pull() async throws -> [LedgerEvent] { try await cloud.all() }
    public func loadSnapshot() async -> WalletSnapshot? { snapshot }
    public func saveSnapshot(_ snapshot: WalletSnapshot) async { self.snapshot = snapshot }
}

/// A scripted entitlement timeline: at each offset from the start, the store's current entitlements become
/// the given transactions. `play(on:clock:engine:)` steps through it.
public struct EntitlementTimeline: Sendable {
    public struct Step: Sendable {
        public var after: TimeInterval
        public var transactions: [StoreTransaction]
        public init(after: TimeInterval, transactions: [StoreTransaction]) {
            self.after = after
            self.transactions = transactions
        }
    }

    public var steps: [Step]
    public init(_ steps: [Step]) { self.steps = steps }

    /// Applies each step in order, advancing the clock and refreshing the engine; returns the entitlement after
    /// every step.
    @MainActor
    public func play(on store: FakeStore, clock: FakeClock, engine: GateEngine) async -> [Entitlement] {
        var elapsed: TimeInterval = 0
        var seen: [Entitlement] = []
        for step in steps {
            clock.advance(by: step.after - elapsed)
            elapsed = step.after
            await store.setEntitlements(step.transactions)
            await engine.refresh(cause: .update)
            seen.append(engine.entitlement)
        }
        return seen
    }
}

/// A fresh temporary directory per call, for journals in tests (the crash proofs need a real file system).
public func makeTemporaryPaywallDirectory(_ name: String = #function) -> URL {
    let safe = name.filter { $0.isLetter || $0.isNumber }
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ztron-paywall-tests", isDirectory: true)
        .appendingPathComponent("\(safe)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
