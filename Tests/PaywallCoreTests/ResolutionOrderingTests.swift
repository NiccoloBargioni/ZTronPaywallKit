import Foundation
import PaywallTesting
import Testing

@testable import PaywallCore

/// A `FakeStore` whose next `appTransaction()` read can be held open, so two resolutions overlap: one stalled on the
/// App Store while a purchase, a refund or a launch resolves.
private actor LatchedStore: StoreClient {
    let inner: FakeStore
    private var holdsLeft = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var heldReads = 0

    init(_ inner: FakeStore) { self.inner = inner }

    /// Holds the next `appTransaction()` read until `release()`; the reads after it pass.
    func holdNextRead() { holdsLeft += 1 }

    func release() {
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume() }
    }

    func currentEntitlements() async throws -> [StoreTransaction] { try await inner.currentEntitlements() }
    func allTransactions() async throws -> [StoreTransaction] { try await inner.allTransactions() }

    func appTransaction() async throws -> AppTransactionSnapshot? {
        if holdsLeft > 0 {
            holdsLeft -= 1
            heldReads += 1
            await withCheckedContinuation { waiters.append($0) }
        }
        return try await inner.appTransaction()
    }

    func updates() async -> AsyncStream<StoreTransaction> { await inner.updates() }
    func purchaseIntents() async -> AsyncStream<String> { await inner.purchaseIntents() }
    func products(for ids: Set<String>) async throws -> [PaywallProduct] { try await inner.products(for: ids) }
    func purchase(productID: String, offer: SignedPromotionalOffer?) async throws -> StorePurchaseResult {
        try await inner.purchase(productID: productID, offer: offer)
    }
    func sync() async throws { try await inner.sync() }
    func finish(transactionID: UInt64) async { await inner.finish(transactionID: transactionID) }
    func subscriptionPhase(groupID: String) async throws -> SubscriptionPhase? { try await inner.subscriptionPhase(groupID: groupID) }
    func renewalGraceEnd(groupID: String) async throws -> Date? { try await inner.renewalGraceEnd(groupID: groupID) }
    func isEligibleForIntroOffer(groupID: String) async -> Bool { await inner.isEligibleForIntroOffer(groupID: groupID) }
    func storefrontCountryCode() async -> String? { await inner.storefrontCountryCode() }
}

@MainActor
private final class Recorder {
    var events: [PaywallEvent] = []
    var changes: [(from: Entitlement, to: Entitlement, cause: EntitlementChangeCause)] {
        events.compactMap { event in
            if case .entitlementChanged(let from, let to, let cause) = event { return (from, to, cause) }
            return nil
        }
    }
}

/// A4: resolutions overlap, and the one that finishes last must not undo what a newer one applied. Every test here
/// fails at `b5c20e4`, where the stale read applied its old transaction list.
@Suite("Resolution ordering", .serialized)
@MainActor
struct ResolutionOrderingTests {
    private func makeEngine(_ store: LatchedStore) throws -> (GateEngine, Recorder) {
        let engine = try GateEngine(
            directory: makeTemporaryPaywallDirectory(), catalog: catalog,
            settings: GateEngine.Settings(tolerance: 300, appVersion: "2.0", build: "200"), clock: FakeClock(), store: store,
            fileKeyStore: InMemoryFileKeyStore())
        let recorder = Recorder()
        engine.onEvent = { recorder.events.append($0) }
        return (engine, recorder)
    }

    /// A foreground resolution read "nothing" and then stalled on the App Store; a purchase resolved meanwhile. When
    /// the stale read returns it must not flip the new lifetime back to free.
    @Test func a_stale_resolution_does_not_undo_a_purchase() async throws {
        let store = LatchedStore(FakeStore(products: products))
        let (engine, recorder) = try makeEngine(store)
        await engine.start()
        #expect(engine.entitlement == .free)
        await store.holdNextRead()
        let stale = Task { await engine.refresh(cause: .foreground) }
        #expect(await eventually { await store.heldReads == 1 })
        let outcome = try await engine.purchase(productID: "pro.lifetime", source: nil)
        guard case .purchased(let id) = outcome else {
            Issue.record("expected a purchase, got \(outcome)")
            return
        }
        #expect(engine.entitlement == .lifetime(.purchase(transactionID: id)))
        await store.release()
        await stale.value
        #expect(engine.entitlement == .lifetime(.purchase(transactionID: id)))
        #expect(engine.canPass(.paid))
        #expect(recorder.changes.last?.to == .lifetime(.purchase(transactionID: id)), "nothing after the purchase: \(recorder.changes)")
        #expect(recorder.changes.filter { $0.to == .free }.count == 1, "only the launch resolution: \(recorder.changes)")
    }

    /// The mirror image: a resolution read the lifetime and stalled; a refund resolved `.free` meanwhile. The stale
    /// read must not bring the refunded lifetime back.
    @Test func a_stale_resolution_does_not_undo_a_refund() async throws {
        let fake = FakeStore(products: products)
        let now = FakeClock().now
        await fake.setEntitlements([.lifetime(id: 3, productID: "pro.lifetime", purchased: now)])
        let store = LatchedStore(fake)
        let (engine, recorder) = try makeEngine(store)
        await engine.start()
        #expect(engine.entitlement == .lifetime(.purchase(transactionID: 3)))
        await store.holdNextRead()
        let stale = Task { await engine.refresh(cause: .foreground) }  // read the lifetime, then stalled
        #expect(await eventually { await store.heldReads == 1 })
        await fake.refund(3, at: now)  // the revocation arrives on updates and resolves free
        #expect(await eventually { engine.entitlement == .free })
        await store.release()
        await stale.value
        #expect(engine.entitlement == .free)
        #expect(!engine.canPass(.paid))
        #expect(recorder.changes.filter { $0.to.isPaying }.count == 1, "no second flip to paying: \(recorder.changes)")
    }

    /// A stale resolution that bound a different app transaction than the applied one resolves once more, with a stamp
    /// of its own, so what the grandfather rule reads is never older than the bound snapshot.
    @Test func a_stale_resolution_that_bound_another_app_transaction_resolves_once_more() async throws {
        let now = FakeClock().now
        let policy = GrandfatheringPolicy(lastPaidBuild: "116", paidWindow: DateInterval(start: now.addingTimeInterval(-1e7), end: now))
        func app(_ version: String) -> AppTransactionSnapshot {
            AppTransactionSnapshot(
                bundleID: "b", originalAppVersion: version, originalPurchaseDate: now.addingTimeInterval(-1e6), environment: .production,
                origin: .appTransaction)
        }
        let fake = FakeStore(app: app("200"), products: products)
        let store = LatchedStore(fake)
        let engine = try GateEngine(
            directory: makeTemporaryPaywallDirectory(), catalog: catalog, grandfathering: policy,
            settings: GateEngine.Settings(tolerance: 300, appVersion: "2.0", build: "200"), clock: FakeClock(), store: store,
            fileKeyStore: InMemoryFileKeyStore())
        await engine.start()
        #expect(engine.entitlement == .free)
        await store.holdNextRead()
        let stale = Task { await engine.refresh(cause: .foreground) }
        #expect(await eventually { await store.heldReads == 1 })
        await fake.setApp(app("201"))
        await engine.refresh(cause: .update)  // applied first: binds 201, still a freemium build
        #expect(engine.appTransaction?.originalAppVersion == "201")
        await fake.setApp(app("90"))  // what the stale read comes back with: a paid-era install
        await store.release()
        await stale.value
        #expect(await eventually { engine.entitlement == .lifetime(.grandfathered(originalAppVersion: "90")) }, "the stale read bound 90 and a resolution of its own applied it")
        #expect(engine.appTransaction?.originalAppVersion == "90")
        engine.shutdown()
    }

    /// The launch resolution itself stalls (a first launch asks the App Store for the app transaction) while a
    /// purchase completes; when it returns it must not undo the purchase.
    @Test func a_stalled_launch_resolution_does_not_undo_a_purchase_made_meanwhile() async throws {
        let store = LatchedStore(FakeStore(products: products))
        let (engine, recorder) = try makeEngine(store)
        await store.holdNextRead()
        let started = Task { await engine.start() }
        #expect(await eventually { await store.heldReads == 1 })
        #expect(engine.entitlement == .unknown)
        let outcome = try await engine.purchase(productID: "pro.lifetime", source: nil)
        guard case .purchased(let id) = outcome else {
            Issue.record("expected a purchase, got \(outcome)")
            return
        }
        #expect(engine.entitlement == .lifetime(.purchase(transactionID: id)))
        await store.release()
        await started.value
        #expect(engine.entitlement == .lifetime(.purchase(transactionID: id)))
        #expect(!recorder.changes.contains { $0.to == .free }, "the stalled launch read applied nothing: \(recorder.changes)")
        engine.shutdown()
    }
}
