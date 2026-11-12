import Foundation
import PaywallCore
import PaywallTesting
import Testing

let catalog = ProductCatalog(
    subscriptionGroupID: "pro",
    weekly: "pro.weekly",
    monthly: "pro.monthly",
    yearly: "pro.yearly",
    lifetime: "pro.lifetime",
    tokenPacks: [TokenPack(productID: "tokens.10", tokens: 10), TokenPack(productID: "tokens.50", tokens: 50)]
)

let products: [PaywallProduct] = [
    PaywallProduct(id: "pro.weekly", kind: .subscription(.weekly), displayName: "Weekly", displayPrice: "€1.99",
                   introOffer: .init(trialDays: 7)),
    PaywallProduct(id: "pro.monthly", kind: .subscription(.monthly), displayName: "Monthly", displayPrice: "€4.99"),
    PaywallProduct(id: "pro.yearly", kind: .subscription(.yearly), displayName: "Yearly", displayPrice: "€29.99"),
    PaywallProduct(id: "pro.lifetime", kind: .lifetime, displayName: "Lifetime", displayPrice: "€59.99"),
    PaywallProduct(id: "tokens.10", kind: .tokens(10), displayName: "10 tokens", displayPrice: "€0.99"),
    PaywallProduct(id: "tokens.50", kind: .tokens(50), displayName: "50 tokens", displayPrice: "€3.99"),
]

func source(_ id: String) -> PaywallSource {
    PaywallSource(id: id, fileID: "Tests/Support.swift", function: "test", line: 1)
}

struct TestError: Error, Equatable {}

/// One "process": an engine on a directory, with its own fakes. `relaunch()` builds a fresh engine on the same
/// directory, discarding every in-memory object, as a process death would.
@MainActor
final class Harness {
    let directory: URL
    let store: FakeStore
    let clock: FakeClock
    let sync: InMemoryLedgerSync?
    let connectivity: FakeConnectivity?
    let audit: InMemoryAuditSink
    var settings: GateEngine.Settings
    let grandfathering: GrandfatheringPolicy?
    private(set) var engine: GateEngine
    private(set) var events: [PaywallEvent] = []

    init(
        directory: URL = makeTemporaryPaywallDirectory(),
        store: FakeStore = FakeStore(products: products),
        clock: FakeClock = FakeClock(),
        sync: InMemoryLedgerSync? = nil,
        connectivity: FakeConnectivity? = nil,
        audit: InMemoryAuditSink = InMemoryAuditSink(),
        settings: GateEngine.Settings = GateEngine.Settings(tolerance: 300, appVersion: "2.0", build: "200"),
        grandfathering: GrandfatheringPolicy? = nil
    ) throws {
        self.directory = directory
        self.store = store
        self.clock = clock
        self.sync = sync
        self.connectivity = connectivity
        self.audit = audit
        self.settings = settings
        self.grandfathering = grandfathering
        self.engine = try GateEngine(
            directory: directory, catalog: catalog, grandfathering: grandfathering, settings: settings, clock: clock,
            store: store, sync: sync, connectivity: connectivity, audit: [audit])
        engine.onEvent = { [weak self] in self?.events.append($0) }
    }

    func start() async { await engine.start() }

    @discardableResult
    func relaunch(start: Bool = true) async throws -> GateEngine {
        engine.shutdown()
        engine = try GateEngine(
            directory: directory, catalog: catalog, grandfathering: grandfathering, settings: settings, clock: clock,
            store: store, sync: sync, connectivity: connectivity, audit: [audit])
        events = []
        engine.onEvent = { [weak self] in self?.events.append($0) }
        if start { await engine.start() }
        return engine
    }

    /// Every audit record so far, after the trail drained.
    func records() async -> [AuditRecord] {
        await engine.flushAudit()
        return await audit.records
    }

    /// A started engine for a free user with `tokens` granted.
    static func free(tokens: Int = 0, sync: InMemoryLedgerSync? = nil, settings: GateEngine.Settings? = nil) async throws -> Harness {
        let harness = try Harness(sync: sync, settings: settings ?? GateEngine.Settings(tolerance: 300, appVersion: "2.0", build: "200"))
        await harness.start()
        if tokens > 0 { harness.engine.grant(tokens: tokens, reason: "test") }
        return harness
    }
}

/// Waits (yielding) until `condition` holds, for work the engine does on its own tasks.
@MainActor
func eventually(_ iterations: Int = 400, _ condition: () async -> Bool) async -> Bool {
    for _ in 0..<iterations {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return await condition()
}
