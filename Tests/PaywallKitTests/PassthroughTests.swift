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
        configuration.fileKeyStore = InMemoryFileKeyStore()
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
        live.fileKeyStore = InMemoryFileKeyStore()
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

    private func live(_ store: FakeStore, _ directory: URL) -> Paywall.Configuration {
        var live = Paywall.Configuration(catalog: catalog)
        live.fileKeyStore = InMemoryFileKeyStore()
        live.store = store
        live.clock = FakeClock()
        live.storageDirectory = directory
        live.includesDefaultAudit = false
        live.connectivity = nil
        live.welcomeTokens = 0
        return live
    }

    /// A8: a `.paywallGated` view on screen is decided again when the facade leaves passthrough: the view that was
    /// open for free is now denied, and told, and the engine knows it.
    @Test func flipping_passthrough_off_re_evaluates_gated_views_on_screen() async throws {
        let (paywall, store, directory) = makePassthrough()
        let holder = UUID()
        var changes: [GateSessionState] = []
        let first = paywall.openSession(holder: holder, level: .paid, policy: .reserve, source: gate, scope: nil) { changes.append($0) }
        #expect(first.decision == .open(.free))
        paywall.configure(live(store, directory))
        await paywall.waitUntilStarted()
        let denied = try #require(changes.last)
        #expect(!denied.isOpen && denied.failure?.reason == .requiresPaid)
        #expect(paywall.engine?.sessionState(holder)?.isOpen == false, "the engine knows the view")
        paywall.closeSession(holder: holder)
        #expect(paywall.engine?.sessionState(holder) == nil && paywall.liveSessions[holder] == nil)
    }

    /// A8: the same flip for a view that draws on appear: it is decided once on the new engine, so it draws once.
    @Test func flipping_passthrough_off_draws_once_for_a_deductNow_view() async throws {
        let (paywall, store, directory) = makePassthrough()
        let holder = UUID()
        var changes: [GateSessionState] = []
        _ = paywall.openSession(holder: holder, level: .tokens(1), policy: .deductNow, source: gate, scope: nil) { changes.append($0) }
        var published: [PaywallEvent] = []
        let subscription = paywall.events.sink { published.append($0) }
        var configuration = live(store, directory)
        configuration.welcomeTokens = 1
        paywall.configure(configuration)
        await paywall.waitUntilStarted()
        #expect(changes.last?.decision == .open(.drawn(1)))
        #expect(paywall.wallet.balance == 0)
        #expect(published.filter { if case .tokensConsumed = $0 { true } else { false } }.count == 1)
        subscription.cancel()
    }

    /// A8: the other direction: a denied view opens for free the moment passthrough comes on.
    @Test func flipping_passthrough_on_opens_denied_views() async throws {
        let (paywall, _, _) = await makePaywall()
        let holder = UUID()
        var changes: [GateSessionState] = []
        let denied = paywall.openSession(holder: holder, level: .paid, policy: .reserve, source: gate, scope: nil) { changes.append($0) }
        #expect(denied.failure?.reason == .requiresPaid)
        var off = try #require(paywall.configuration)
        off.passthrough = true
        paywall.configure(off)
        #expect(changes.last?.decision == .open(.free))
        #expect(paywall.liveSessions[holder]?.state.isOpen == true)
        paywall.closeSession(holder: holder)
        #expect(paywall.liveSessions[holder] == nil)
    }

    @Test func an_invalid_catalog_is_logged_but_still_passes_through() {
        let (paywall, _, _) = makePassthrough(catalog: ProductCatalog(subscriptionGroupID: "g"))
        #expect(paywall.isPassthrough)
        #expect(paywall.configurationError == nil)
        #expect(paywall.canPass(.paid))
    }
}
