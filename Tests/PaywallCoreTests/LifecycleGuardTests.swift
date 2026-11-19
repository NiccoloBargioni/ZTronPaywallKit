import Foundation
import PaywallTesting
import Testing

@testable import PaywallCore

/// Where the engine awaits the store. A `GatedStore` holds one of them until released, so a test can shut the engine
/// down while it waits, as a facade replacing its engine mid-flight does.
enum HoldPoint: String, CaseIterable, Sendable {
    case updates, purchaseIntents, currentEntitlements, appTransaction, allTransactions, renewalGraceEnd, products, purchase, sync, finish
}

private actor GatedStore: StoreClient {
    let inner: FakeStore
    private var holding: HoldPoint?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var held: [HoldPoint] = []

    init(_ inner: FakeStore) { self.inner = inner }

    func hold(_ point: HoldPoint?) { holding = point }

    func release() {
        holding = nil
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume() }
    }

    private func gate(_ point: HoldPoint) async {
        guard holding == point else { return }
        held.append(point)
        await withCheckedContinuation { waiters.append($0) }
    }

    func currentEntitlements() async throws -> [StoreTransaction] {
        await gate(.currentEntitlements)
        return try await inner.currentEntitlements()
    }
    func allTransactions() async throws -> [StoreTransaction] {
        await gate(.allTransactions)
        return try await inner.allTransactions()
    }
    func appTransaction() async throws -> AppTransactionSnapshot? {
        await gate(.appTransaction)
        return try await inner.appTransaction()
    }
    func updates() async -> AsyncStream<StoreTransaction> {
        await gate(.updates)
        return await inner.updates()
    }
    func purchaseIntents() async -> AsyncStream<String> {
        await gate(.purchaseIntents)
        return await inner.purchaseIntents()
    }
    func products(for ids: Set<String>) async throws -> [PaywallProduct] {
        await gate(.products)
        return try await inner.products(for: ids)
    }
    func purchase(productID: String, offer: SignedPromotionalOffer?) async throws -> StorePurchaseResult {
        await gate(.purchase)
        return try await inner.purchase(productID: productID, offer: offer)
    }
    func sync() async throws {
        await gate(.sync)
        try await inner.sync()
    }
    func finish(transactionID: UInt64) async {
        await gate(.finish)
        await inner.finish(transactionID: transactionID)
    }
    func subscriptionPhase(groupID: String) async throws -> SubscriptionPhase? { try await inner.subscriptionPhase(groupID: groupID) }
    func renewalGraceEnd(groupID: String) async throws -> Date? {
        await gate(.renewalGraceEnd)
        return try await inner.renewalGraceEnd(groupID: groupID)
    }
    func isEligibleForIntroOffer(groupID: String) async -> Bool { await inner.isEligibleForIntroOffer(groupID: groupID) }
    func storefrontCountryCode() async -> String? { await inner.storefrontCountryCode() }
}

/// A connectivity source that shuts the engine down while `paths()` is awaited.
private actor ShuttingDownConnectivity: PaywallConnectivity {
    let box: EngineBox
    init(_ box: EngineBox) { self.box = box }
    func paths() async -> AsyncStream<Bool> {
        await box.engine?.shutdown()
        return AsyncStream { $0.finish() }
    }
}

/// A carrier that shuts the engine down while the Keychain snapshot is awaited.
private actor ShuttingDownSync: LedgerSync {
    let box: EngineBox
    init(_ box: EngineBox) { self.box = box }
    func push(_ events: [LedgerEvent]) async throws -> Set<String> { Set(events.map(\.id)) }
    func pull() async throws -> [LedgerEvent] { [] }
    func loadSnapshot() async -> WalletSnapshot? {
        await box.engine?.shutdown()
        return WalletSnapshot(accountKey: unboundAccountKey, balance: 50, lastEventID: "e", headHash: "h")
    }
}

@MainActor
private final class Recorder {
    var events: [PaywallEvent] = []
}

/// A5: a shut-down engine makes nothing durable, whichever await it was parked on when `shutdown()` came.
@Suite("Lifecycle guards", .serialized)
@MainActor
struct LifecycleGuardTests {
    private func makeEngine(
        _ store: GatedStore, directory: URL = makeTemporaryPaywallDirectory(), welcomeTokens: Int = 100, sync: (any LedgerSync)? = nil,
        connectivity: (any PaywallConnectivity)? = nil
    ) throws -> (GateEngine, Recorder) {
        let engine = try GateEngine(
            directory: directory, catalog: catalog,
            settings: GateEngine.Settings(tolerance: 300, appVersion: "2.0", build: "200", welcomeTokens: welcomeTokens), clock: FakeClock(),
            store: store, sync: sync, connectivity: connectivity, fileKeyStore: InMemoryFileKeyStore())
        let recorder = Recorder()
        engine.onEvent = { recorder.events.append($0) }
        return (engine, recorder)
    }

    private func entitlementFile(_ engine: GateEngine) -> Bool {
        FileManager.default.fileExists(atPath: engine.directory.appendingPathComponent("entitlement.json").path)
    }

    /// `start()` parked on the store at each of its awaits, then shut down: no listener, no resolution, no welcome
    /// grant, no snapshot file.
    @Test(arguments: [HoldPoint.updates, .purchaseIntents, .currentEntitlements, .appTransaction, .allTransactions])
    func a_shutdown_while_start_awaits_the_store_leaves_nothing_behind(point: HoldPoint) async throws {
        let fake = FakeStore(products: products)
        let store = GatedStore(fake)
        let (engine, recorder) = try makeEngine(store)
        await store.hold(point)
        let started = Task { await engine.start() }
        #expect(await eventually { await store.held == [point] })
        engine.shutdown()
        await store.release()
        await started.value
        #expect(engine.isShutDown)
        // The resolution is applied before `Transaction.all` is read: parked there, the engine has resolved, and the
        // guard protects what follows (the revocation scan, the welcome grant, the sync, the storefront).
        let resolved = point == .allTransactions
        #expect(engine.entitlement == (resolved ? .free : .unknown), "\(point)")
        #expect(engine.wallet.balance == 0, "no welcome grant after shutdown: \(point)")
        #expect(try Journal(directory: engine.directory).ledgerEvents.isEmpty, "\(point)")
        #expect(entitlementFile(engine) == resolved, "\(point)")
        #expect(engine.updatesTask == nil && engine.intentsTask == nil, "\(point)")
        #expect(recorder.events.contains { if case .entitlementChanged = $0 { true } else { false } } == resolved, "\(point)")
        #expect(await eventually { await fake.listenerCount == 0 })
    }

    /// The storefront fetch at the end of `start()`: a shutdown while it loads persists no storefront.
    @Test func a_shutdown_while_the_storefront_loads_persists_no_storefront() async throws {
        let store = GatedStore(FakeStore(products: products))
        let (engine, _) = try makeEngine(store)
        await store.hold(.products)
        let started = Task { await engine.start() }
        #expect(await eventually { await store.held == [.products] })
        engine.shutdown()
        await store.release()
        await started.value
        #expect(engine.storefront == nil)
        #expect(!FileManager.default.fileExists(atPath: engine.directory.appendingPathComponent("storefront.json").path))
    }

    /// The awaits that are not the store's: the connectivity source and the carrier's snapshot.
    @Test func a_shutdown_while_connectivity_or_the_snapshot_loads_stops_start() async throws {
        let box = EngineBox()
        let store = GatedStore(FakeStore(products: products))
        let (engine, _) = try makeEngine(store, connectivity: ShuttingDownConnectivity(box))
        box.engine = engine
        await engine.start()
        #expect(engine.isShutDown && engine.entitlement == .unknown && engine.wallet.balance == 0)
        #expect(engine.connectivityTask == nil)

        let snapshotBox = EngineBox()
        let (withSync, _) = try makeEngine(GatedStore(FakeStore(products: products)), sync: ShuttingDownSync(snapshotBox))
        snapshotBox.engine = withSync
        await withSync.start()
        #expect(withSync.isShutDown && withSync.baseline == nil, "the snapshot that arrived after shutdown is not adopted")
        #expect(withSync.wallet.balance == 0)
        #expect(try Journal(directory: withSync.directory).baseline == nil)
    }

    /// A3 meets A5: a shutdown while the grace end is read applies nothing.
    @Test func a_shutdown_during_the_grace_read_applies_nothing() async throws {
        let fake = FakeStore(products: products)
        let now = FakeClock().now
        let lapsed = StoreTransaction.subscription(id: 5, productID: "pro.monthly", purchased: now.addingTimeInterval(-30 * 86_400), expires: now.addingTimeInterval(-3_600))
        await fake.setEntitlements([lapsed])
        await fake.setGraceEnd(now.addingTimeInterval(10 * 86_400))
        let store = GatedStore(fake)
        let (engine, recorder) = try makeEngine(store)
        await engine.start()
        #expect(engine.entitlement.isPaying)
        await fake.setGraceEnd(nil)  // billing gave up
        await store.hold(.renewalGraceEnd)
        let refresh = Task { await engine.refresh(cause: .foreground) }
        #expect(await eventually { await store.held == [.renewalGraceEnd] })
        let changes = recorder.events.count
        engine.shutdown()
        await store.release()
        await refresh.value
        #expect(engine.entitlement.isPaying, "the dead engine applied nothing")
        #expect(recorder.events.count == changes)
    }

    /// The payment sheet still up when the engine is shut down: the transaction goes to `onOrphanedPurchase`, and
    /// without a taker the purchase reports `.pending` so the next launch's `Transaction.updates` delivers it.
    @Test func a_purchase_that_completes_after_shutdown_is_handed_off_or_left_pending() async throws {
        for taker in [nil, false, true] as [Bool?] {
            let fake = FakeStore(products: products)
            let store = GatedStore(fake)
            let (engine, recorder) = try makeEngine(store, welcomeTokens: 0)
            await engine.start()
            var handed: [UInt64] = []
            if let taker {
                engine.onOrphanedPurchase = { transaction, _ in
                    handed.append(transaction.id)
                    return taker
                }
            }
            await store.hold(.purchase)
            let purchase = Task { try await engine.purchase(productID: "tokens.10", source: nil) }
            #expect(await eventually { await store.held == [.purchase] })
            engine.shutdown()
            await store.release()
            let outcome = try await purchase.value
            let id = try #require(await fake.history.last?.id)
            #expect(outcome == (taker == true ? .purchased(transactionID: id) : .pending), "\(String(describing: taker))")
            #expect(handed == (taker == nil ? [] : [id]))
            #expect(engine.wallet.balance == 0 && engine.ledger.events.isEmpty, "nothing durable on the dead engine")
            #expect(await fake.finished.isEmpty, "the dead engine finishes nothing")
            #expect(!recorder.events.contains { if case .purchase(.completed, _, _, _) = $0 { true } else { false } })
        }
    }

    /// Shut down while the purchase's own resolution runs: the credit landed, the transaction is not finished and the
    /// outcome is `.pending`. Shut down while finishing: the outcome is `.purchased`, but no `.completed` is published
    /// and no sync is scheduled.
    @Test func a_shutdown_during_the_purchase_resolution_or_its_finish() async throws {
        for point in [HoldPoint.currentEntitlements, .finish] {
            let fake = FakeStore(products: products)
            let store = GatedStore(fake)
            let (engine, recorder) = try makeEngine(store, welcomeTokens: 0)
            await engine.start()
            await store.hold(point)
            let purchase = Task { try await engine.purchase(productID: "tokens.10", source: nil) }
            #expect(await eventually { await store.held == [point] })
            engine.shutdown()
            await store.release()
            let outcome = try await purchase.value
            let id = try #require(await fake.history.last?.id)
            #expect(engine.ledger.contains("credit:\(id)"), "\(point): the credit was written before the await")
            if point == .finish {
                #expect(outcome == .purchased(transactionID: id))
                #expect(await fake.finished == [id])
            } else {
                #expect(outcome == .pending, "\(point)")
                #expect(await fake.finished.isEmpty)
            }
            #expect(!recorder.events.contains { if case .purchase(.completed, _, _, _) = $0 { true } else { false } }, "\(point)")
        }
    }

    @Test func a_shutdown_during_restore_stops_it() async throws {
        for point in [HoldPoint.sync, .currentEntitlements] {
            let store = GatedStore(FakeStore(products: products))
            let (engine, recorder) = try makeEngine(store, welcomeTokens: 0)
            await engine.start()
            await store.hold(point)
            let restore = Task { try await engine.restore() }
            #expect(await eventually { await store.held == [point] })
            engine.shutdown()
            await store.release()
            try await restore.value
            #expect(recorder.events.contains(.restore(stage: .requested)))
            #expect(!recorder.events.contains(.restore(stage: .completed)), "\(point)")
        }
    }

    @Test func handle_and_adopt_after_shutdown_do_nothing() async throws {
        let fake = FakeStore(products: products)
        let (engine, recorder) = try makeEngine(GatedStore(fake), welcomeTokens: 0)
        await engine.start()
        engine.shutdown()
        let pack = StoreTransaction.tokenPack(id: 77, productID: "tokens.10", purchased: FakeClock().now)
        #expect(await engine.handle(pack) == false)
        #expect(await engine.adoptPurchase(pack, source: nil) == false)
        #expect(engine.wallet.balance == 0 && engine.ledger.events.isEmpty)
        #expect(await fake.finished.isEmpty)
        #expect(!recorder.events.contains { if case .purchase = $0 { true } else { false } })
        #expect(!engine.grant(tokens: 1, reason: "late"), "nothing durable after shutdown")
    }

    /// A1: the Keychain item is per account. While an unbound engine stands on a bound account's baseline, nothing it
    /// writes replaces that account's item.
    @Test func a_bound_baseline_keeps_the_item_while_the_engine_is_unbound() async throws {
        let bound = WalletSnapshot(accountKey: "bound-account", balance: 5, lastEventID: "e1", headHash: "h")
        let sync = InMemoryLedgerSync(snapshot: bound)
        let engine = try GateEngine(
            directory: makeTemporaryPaywallDirectory(), catalog: catalog, settings: GateEngine.Settings(tolerance: 300, appVersion: "2.0", build: "200"),
            clock: FakeClock(), store: FakeStore(products: products), sync: sync, fileKeyStore: InMemoryFileKeyStore())
        await engine.start()
        #expect(engine.baseline == bound && engine.accountKey == unboundAccountKey)
        engine.grant(tokens: 2, reason: "unbound")
        await engine.syncNow()
        #expect(await sync.snapshot == bound, "the bound account's item is not replaced by the unbound engine")
        engine.shutdown()
    }

    @Test func closing_an_unknown_session_and_extending_a_fresh_or_missing_lease_do_nothing() async throws {
        let h = try await Harness.free(tokens: 5)
        h.engine.closeSession(holder: UUID())
        let before = h.engine.ledger.events.count
        h.engine.extendLease("never-drawn")
        _ = h.engine.run(.tokens(1), source: source("g")) {}
        h.engine.extendLease("g")  // the lease was just granted: nothing to extend yet
        #expect(h.engine.ledger.events.count == before + 1, "the draw, and no extension")
        #expect(!h.events.contains { if case .leaseExtended = $0 { true } else { false } })
    }

    /// `.refreshOnReentry`: a view that finds a live lease extends it once, when it opens, not at every re-evaluation
    /// while it stays open.
    @Test func a_leased_view_extends_the_lease_once_per_entry() async throws {
        let h = try await Harness.free(tokens: 5, settings: GateEngine.Settings(tolerance: 300, leasePolicy: .refreshOnReentry, appVersion: "2.0", build: "200"))
        _ = h.engine.run(.tokens(1), source: source("g")) {}
        h.clock.advance(by: 10)
        let holder = UUID()
        let state = h.engine.openSession(holder: holder, level: .tokens(1), policy: .reserve, source: source("g"), scope: nil) { _ in }
        #expect(state.decision == .open(.leased))
        let extensions = { h.events.filter { if case .leaseExtended = $0 { true } else { false } }.count }
        #expect(extensions() == 1)
        h.engine.grant(tokens: 1, reason: "t")  // re-evaluates the open view
        h.engine.reevaluateSessions()
        #expect(extensions() == 1, "still open: no second extension")
        h.engine.closeSession(holder: holder)
    }

    /// A session's change handler that closes another session: the nested re-evaluation is folded into the running one.
    @Test func a_session_change_that_closes_another_session_does_not_recurse() async throws {
        let h = try Harness()
        await h.start()
        let a = UUID(), b = UUID()
        _ = h.engine.openSession(holder: b, level: .paid, policy: .reserve, source: source("b"), scope: nil) { _ in }
        var changes = 0
        _ = h.engine.openSession(holder: a, level: .paid, policy: .reserve, source: source("a"), scope: nil) { [engine = h.engine] state in
            changes += 1
            if state.isOpen { engine.closeSession(holder: b) }
        }
        await h.store.setEntitlements([.lifetime(id: 1, productID: "pro.lifetime", purchased: h.clock.now)])
        await h.engine.refresh(cause: .foreground)
        #expect(h.engine.sessionState(a)?.isOpen == true)
        #expect(h.engine.sessionState(b) == nil, "closed from inside a's change")
        #expect(changes == 1)
    }

    /// An acknowledgement the journal refuses (a full disk after the push) is retried: the events stay pending and the
    /// next push is a no-op upload the carrier dedups.
    @Test func an_acknowledgement_the_journal_refuses_is_retried_at_the_next_sync() async throws {
        let cloud = InMemoryCloud()
        let h = try await Harness.free(tokens: 3, sync: InMemoryLedgerSync(cloud: cloud))
        h.engine.journal.injectedFault = .write
        await h.engine.syncNow()
        #expect(await cloud.events.count == 1, "the push itself went through")
        #expect(h.engine.journal.pendingUpload.count == 1, "but the acknowledgement could not be written")
        h.engine.journal.injectedFault = nil
        await h.engine.syncNow()
        #expect(h.engine.journal.pendingUpload.isEmpty)
        #expect(await cloud.events.count == 1)
        #expect(await cloud.pushCount == 2)
    }

    /// A9 migration under a full disk: the old-shape log stays as it is, is still read correctly, and the next launch
    /// migrates it.
    @Test func a_failed_outbox_migration_is_logged_and_retried_at_the_next_launch() async throws {
        let directory = makeTemporaryPaywallDirectory()
        let journal = try Journal(directory: directory, fullSync: false)
        let events = (1...3).map { i in
            LedgerEvent(
                id: "grant:\(i)", at: Date(timeIntervalSince1970: Double(i)), deviceID: "old", accountKey: unboundAccountKey, source: nil,
                previousHash: paywallGenesisHash, kind: .grant(tokens: 1, reason: "r"))
        }
        try journal.append(contentsOf: events.map { .event($0, uploaded: false) })
        try journal.append(.checkpoint(Ledger(events: events).checkpoint()))
        journal.close()
        let sync = InMemoryLedgerSync()
        let h = try Harness(directory: directory, sync: sync)
        #expect(h.engine.journal.hasCoveredOutboxInLog)
        h.engine.journal.injectedFault = .write
        await h.start()
        #expect(h.engine.journal.hasCoveredOutboxInLog, "the migration failed and nothing was lost")
        #expect(h.engine.wallet.balance == 3)
        h.engine.journal.injectedFault = nil
        let relaunched = try await h.relaunch()
        #expect(!relaunched.journal.hasCoveredOutboxInLog)
        #expect(relaunched.journal.outboxEvents().count == 3 && relaunched.wallet.balance == 3)
    }
}
