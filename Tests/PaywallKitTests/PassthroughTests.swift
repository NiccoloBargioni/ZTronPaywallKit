import Combine
import Foundation
import PaywallCore
import PaywallTesting
import Testing

@testable import PaywallKit

/// `Configuration.passthrough`, the toggle for progressive adoption. On, the package is inert: no engine, no journal,
/// no store call; every gate passes and every purchase "succeeds" without a payment.
@Suite("Passthrough", .serialized)
@MainActor
struct PassthroughTests {
    private let gate = PaywallSource(id: "map", fileID: "f", function: "g", line: 1)

    /// A passthrough facade over a store that would deny everything: no entitlement, no tokens.
    private func makePassthrough(catalog: ProductCatalog = catalog) -> (Paywall, FakeStore, URL) {
        let paywall = Paywall()
        let store = FakeStore(products: products)
        let directory = makeTemporaryPaywallDirectory()
        var configuration = Paywall.Configuration(catalog: catalog)
        configuration.passthrough = true
        configuration.store = store
        configuration.storageDirectory = directory
        configuration.includesDefaultAudit = false
        configuration.connectivity = nil
        configuration.onStart = { _ in Issue.record("onStart ran without an engine") }
        paywall.configure(configuration)
        return (paywall, store, directory)
    }

    @Test func passthrough_starts_nothing() async {
        let (paywall, store, directory) = makePassthrough()
        await paywall.waitUntilStarted()
        #expect(paywall.isPassthrough)
        #expect(paywall.engine == nil)
        #expect(paywall.configurationError == nil)
        #expect(paywall.configuration?.passthrough == true)
        #expect(paywall.entitlement == .unknown)
        #expect(paywall.wallet == .empty)
        // No journal was opened and no store call was made.
        let contents = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(contents?.isEmpty ?? true)
        #expect(await store.purchaseCalls == 0)
        #expect(await store.syncCalls == 0)
    }

    @Test func every_gate_passes_and_nothing_is_published() async {
        let (paywall, _, _) = makePassthrough()
        var published: [PaywallEvent] = []
        let cancellable = paywall.events.sink { published.append($0) }
        #expect(paywall.canPass(.paid))
        #expect(paywall.canPass(.tokens(5), id: "export"))
        #expect(paywall.evaluate(.tokens(3), id: "export").value != nil)
        var denied = 0
        Paywall.$override.withValue(paywall) {
            let paid = withPaywall(.paid, id: "pro") { 1 }.onBlocked { _ in denied += 1 }
            #expect(paid.value == 1)
            #expect(withPaywall(.tokens(2), id: "export") { "pdf" }.value == "pdf")
        }
        let awaited = await Paywall.$override.withValue(paywall) {
            await withPaywall(.tokens(1), id: "solve") { () async -> Int in 42 }
        }
        #expect(awaited.value == 42)
        // A view gate opens as `.free`, its session commits for free, and closing it is a no-op.
        let holder = UUID()
        let state = paywall.openSession(holder: holder, level: .paid, policy: .reserve, source: gate, scope: nil) { _ in
            Issue.record("a passthrough session changed")
        }
        #expect(state.isOpen)
        #expect(state.decision == .open(.free))
        let session = GateSession(level: .tokens(1), source: gate, isOpen: true, holder: holder)
        Paywall.$override.withValue(paywall) {
            #expect(session.withPaywall { 7 }.value == 7)
        }
        paywall.closeSession(holder: holder)
        #expect(denied == 0)
        #expect(published.isEmpty)
        #expect(paywall.wallet == .empty)
        await settle()
        #expect(paywall.pendingFailure == nil)
        cancellable.cancel()
    }

    @Test func purchases_succeed_without_a_payment_and_the_store_is_never_called() async throws {
        let (paywall, store, _) = makePassthrough()
        #expect(try await paywall.products().isEmpty)
        var purchased: [UInt64] = []
        try await paywall.purchase(products[3], source: gate)
            .onPurchaseCompleted { purchased.append($0) }
            .onPurchasePending { Issue.record("pending") }
            .onPurchaseCancelled { Issue.record("cancelled") }
        #expect(purchased == [0])
        try await paywall.restorePurchases()
        #expect(try await paywall.subscriptionPhase() == nil)
        #expect(!(await paywall.isEligibleForIntroOffer()))
        #expect(!paywall.grant(tokens: 5, reason: "welcome"))
        await paywall.refresh()
        await paywall.didBecomeActive()
        await paywall.syncNow()
        #expect(await store.purchaseCalls == 0)
        #expect(await store.syncCalls == 0)
        #expect(paywall.entitlement == .unknown)
        #expect(paywall.wallet == .empty)
    }

    @Test func the_toggle_flips_both_ways_on_reconfigure() async {
        let (paywall, store, directory) = makePassthrough()
        #expect(paywall.isPassthrough)
        // Live: the same free user with an empty wallet is denied.
        var live = Paywall.Configuration(catalog: catalog)
        live.store = store
        live.storageDirectory = directory
        live.includesDefaultAudit = false
        live.connectivity = nil
        paywall.configure(live)
        await paywall.waitUntilStarted()
        #expect(!paywall.isPassthrough)
        #expect(paywall.engine != nil)
        #expect(paywall.evaluate(.paid, id: "pro").failure?.reason == .requiresPaid)
        #expect(paywall.entitlement == .free)
        // And back: the engine is gone and the gate passes again.
        var off = live
        off.passthrough = true
        paywall.configure(off)
        #expect(paywall.isPassthrough)
        #expect(paywall.engine == nil)
        #expect(paywall.evaluate(.paid, id: "pro").value != nil)
        #expect(paywall.entitlement == .unknown)
    }

    @Test func an_invalid_catalog_is_logged_but_still_passes_through() {
        let (paywall, _, _) = makePassthrough(catalog: ProductCatalog(subscriptionGroupID: "g"))
        #expect(paywall.isPassthrough)
        #expect(paywall.configurationError == nil)
        #expect(paywall.canPass(.paid))
    }
}
