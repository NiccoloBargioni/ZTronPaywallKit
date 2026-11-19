import Combine
import Foundation
import PaywallTesting
import SwiftUI
import Testing

@testable import PaywallCore
@testable import PaywallKit

#if canImport(AppKit)
    import AppKit
    private typealias ProviderHostWindow = NSWindow
#else
    import UIKit
    private typealias ProviderHostWindow = UIWindow
#endif

/// A configuration on a scripted store and a fresh directory, for either service: the label is the provider's.
@MainActor
private func fakeBacked(store: FakeStore = FakeStore(products: products), welcomeTokens: Int = 0) -> Paywall.Configuration {
    var configuration = Paywall.Configuration(catalog: catalog)
    configuration.fileKeyStore = InMemoryFileKeyStore()
    configuration.store = store
    configuration.clock = FakeClock()
    configuration.storageDirectory = makeTemporaryPaywallDirectory()
    configuration.includesDefaultAudit = false
    configuration.connectivity = nil
    configuration.welcomeTokens = welcomeTokens
    return configuration
}

/// A `FakeStore` whose next purchase waits until released: a payment sheet still up while the facade reconfigures.
private actor HoldingStore: StoreClient {
    let inner: FakeStore
    private var holdsLeft = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var heldPurchases = 0

    init(_ inner: FakeStore) { self.inner = inner }

    func holdNextPurchase() { holdsLeft += 1 }

    func release() {
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume() }
    }

    func currentEntitlements() async throws -> [StoreTransaction] { try await inner.currentEntitlements() }
    func allTransactions() async throws -> [StoreTransaction] { try await inner.allTransactions() }
    func appTransaction() async throws -> AppTransactionSnapshot? { try await inner.appTransaction() }
    func updates() async -> AsyncStream<StoreTransaction> { await inner.updates() }
    func purchaseIntents() async -> AsyncStream<String> { await inner.purchaseIntents() }
    func products(for ids: Set<String>) async throws -> [PaywallProduct] { try await inner.products(for: ids) }

    func purchase(productID: String, offer: SignedPromotionalOffer?) async throws -> StorePurchaseResult {
        if holdsLeft > 0 {
            holdsLeft -= 1
            heldPurchases += 1
            await withCheckedContinuation { waiters.append($0) }
        }
        return try await inner.purchase(productID: productID, offer: offer)
    }

    func sync() async throws { try await inner.sync() }
    func finish(transactionID: UInt64) async { await inner.finish(transactionID: transactionID) }
    func subscriptionPhase(groupID: String) async throws -> SubscriptionPhase? { try await inner.subscriptionPhase(groupID: groupID) }
    func renewalGraceEnd(groupID: String) async throws -> Date? { try await inner.renewalGraceEnd(groupID: groupID) }
    func isEligibleForIntroOffer(groupID: String) async -> Bool { await inner.isEligibleForIntroOffer(groupID: groupID) }
    func storefrontCountryCode() async -> String? { await inner.storefrontCountryCode() }
}

@MainActor
private func waitFor(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<400 {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return await condition()
}

private let mapGate = PaywallSource(id: "map", fileID: "f", function: "g", line: 1)

/// Puts `view` on screen in a real window (AppKit or UIKit).
@MainActor
private func show<V: View>(_ view: V) -> ProviderHostWindow {
    #if canImport(AppKit)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: view)
        window.orderFront(nil)
    #else
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
    #endif
    return window
}

/// Pumps layout so appear and change callbacks run.
@MainActor
private func pump(_ window: ProviderHostWindow) async {
    for _ in 0..<20 {
        #if canImport(AppKit)
            window.contentView?.layoutSubtreeIfNeeded()
        #else
            window.layoutIfNeeded()
        #endif
        await Task.yield()
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

@MainActor
private func dismiss(_ window: ProviderHostWindow) {
    #if canImport(AppKit)
        window.close()
    #else
        window.rootViewController = nil
        window.isHidden = true
    #endif
}

@MainActor
private final class Recorder: ObservableObject {
    var names: [String] = []
    var entitlements: [Entitlement?] = []
    var facades: [ObjectIdentifier] = []
    @Published var phase: ScenePhase = .background
}

/// Feeds a controllable scene phase to `content`, as a scene would.
private struct PhaseHost<Content: View>: View {
    @ObservedObject var recorder: Recorder
    let content: Content
    var body: some View { content.environment(\.scenePhase, recorder.phase) }
}

/// Reads both environment objects and the entitlement where a child of the root would, and records every change.
@available(iOS 17, macOS 14, *)
private struct ProviderProbe: View {
    @ObservedObject var recorder: Recorder
    @EnvironmentObject private var provider: PaywallServiceProvider
    @EnvironmentObject private var paywall: Paywall
    @Environment(\.paywallEntitlement) private var entitlement

    var body: some View {
        Text(provider.service.name)
            .onAppear { record() }
            .onChange(of: provider.service.name) { _, _ in record() }
            .onChange(of: entitlement) { _, _ in record() }
    }

    private func record() {
        recorder.names.append(provider.service.name)
        recorder.entitlements.append(entitlement)
        recorder.facades.append(ObjectIdentifier(paywall))
    }
}

@Suite("Service provider", .serialized)
@MainActor
struct ServiceProviderTests {
    @Test func a_provider_configures_its_facade_before_the_first_frame() async {
        let paywall = Paywall()
        let lifetime = StoreTransaction.lifetime(id: 3, productID: "pro.lifetime", purchased: Date())
        let provider = PaywallServiceProvider(
            .fake(fakeBacked(store: FakeStore(entitlements: [lifetime], products: products))), paywall: paywall)
        #expect(paywall.engine != nil, "configured synchronously: the journal is open and the wallet known at once")
        #expect(paywall.provider === provider)
        #expect(provider.paywall === paywall)
        #expect(provider.isFake)
        #expect(provider.service.isFake)
        #expect(provider.service.name == "fake")
        await paywall.waitUntilStarted()
        #expect(paywall.entitlement == .lifetime(.purchase(transactionID: 3)))
    }

    @Test func production_is_the_other_implementation() async {
        let paywall = Paywall()
        let provider = PaywallServiceProvider(.production(fakeBacked()), paywall: paywall)
        #expect(!provider.isFake)
        #expect(!provider.service.isFake)
        #expect(provider.service.name == "production")
        #expect(provider.service.configuration.catalog == catalog)
        await paywall.waitUntilStarted()
        #expect(paywall.entitlement == .free)
    }

    @Test func use_switches_implementation_and_rebuilds_the_engine() async {
        let paywall = Paywall()
        let provider = PaywallServiceProvider(.production(fakeBacked()), paywall: paywall)
        await paywall.waitUntilStarted()
        let first = paywall.engine
        var changes = 0
        let subscription = provider.objectWillChange.sink { _ in changes += 1 }
        let lifetime = StoreTransaction.lifetime(id: 9, productID: "pro.lifetime", purchased: Date())
        provider.use(.fake(fakeBacked(store: FakeStore(entitlements: [lifetime], products: products))))
        #expect(provider.isFake)
        #expect(changes >= 1)
        #expect(paywall.engine != nil)
        #expect(paywall.engine !== first, "configure again: the previous engine is torn down")
        await paywall.waitUntilStarted()
        #expect(paywall.entitlement == .lifetime(.purchase(transactionID: 9)))
        subscription.cancel()
    }

    @Test func facade_changes_reach_observers_of_the_provider() async {
        let paywall = Paywall()
        let provider = PaywallServiceProvider(.fake(fakeBacked()), paywall: paywall)
        await paywall.waitUntilStarted()
        var changes = 0
        let subscription = provider.objectWillChange.sink { _ in changes += 1 }
        paywall.grant(tokens: 3, reason: "test")
        #expect(changes >= 1, "a view observing the provider alone re-renders on a wallet change")
        #expect(paywall.wallet.balance == 3)
        subscription.cancel()
    }

    @Test func the_facade_holds_its_provider_weakly() async {
        let paywall = Paywall()
        var provider: PaywallServiceProvider? = PaywallServiceProvider(.fake(fakeBacked()), paywall: paywall)
        await paywall.waitUntilStarted()
        #expect(paywall.provider === provider)
        provider = nil
        #expect(paywall.provider == nil)
    }

    // MARK: Use methods

    @Test func use_methods_chain_and_useProduction_returns_to_the_last_production_configuration() async {
        let paywall = Paywall()
        let production = fakeBacked(welcomeTokens: 7)
        let provider = PaywallServiceProvider(.production(production), paywall: paywall)
        await paywall.waitUntilStarted()
        #expect(provider.productionConfiguration?.welcomeTokens == 7)
        #expect(paywall.wallet.balance == 7)

        let lifetime = StoreTransaction.lifetime(id: 4, productID: "pro.lifetime", purchased: Date())
        let chained = provider.useFake(fakeBacked(store: FakeStore(entitlements: [lifetime], products: products)))
        #expect(chained === provider)
        #expect(provider.isFake)
        await paywall.waitUntilStarted()
        #expect(paywall.entitlement == .lifetime(.purchase(transactionID: 4)))
        #expect(paywall.wallet.balance == 0)
        #expect(provider.productionConfiguration?.welcomeTokens == 7, "a fake does not replace the remembered production configuration")

        #expect(provider.useProduction() === provider)
        #expect(!provider.isFake)
        await paywall.waitUntilStarted()
        #expect(paywall.configuration?.welcomeTokens == 7)
        #expect(paywall.wallet.balance == 7, "the same journal as before the fake")
        #expect(paywall.entitlement == .free)
    }

    @Test func useProduction_with_a_configuration_replaces_the_remembered_one() async {
        let paywall = Paywall()
        let provider = PaywallServiceProvider(.production(fakeBacked(welcomeTokens: 1)), paywall: paywall)
        await paywall.waitUntilStarted()
        #expect(provider.useProduction(fakeBacked(welcomeTokens: 2)) === provider)
        await paywall.waitUntilStarted()
        #expect(!provider.isFake)
        #expect(provider.productionConfiguration?.welcomeTokens == 2)
        #expect(paywall.configuration?.welcomeTokens == 2)
    }

    @Test func useProduction_without_a_production_configuration_keeps_the_fake() async {
        let paywall = Paywall()
        let provider = PaywallServiceProvider(.fake(fakeBacked()), paywall: paywall)
        await paywall.waitUntilStarted()
        let engine = paywall.engine
        #expect(provider.productionConfiguration == nil)
        #expect(provider.useProduction() === provider)
        #expect(provider.isFake)
        #expect(paywall.engine === engine, "nothing to return to: the facade is not configured again")
    }

    // MARK: A8: views on screen follow the provider's switches

    @Test func a_denied_paid_view_opens_when_the_provider_switches_to_a_paying_fake() async throws {
        let paywall = Paywall()
        let provider = PaywallServiceProvider(.production(fakeBacked()), paywall: paywall)
        await paywall.waitUntilStarted()
        let holder = UUID()
        var changes: [GateSessionState] = []
        let denied = paywall.openSession(holder: holder, level: .paid, policy: .reserve, source: mapGate, scope: nil) { changes.append($0) }
        #expect(denied.failure?.reason == .requiresPaid)
        let lifetime = StoreTransaction.lifetime(id: 9, productID: "pro.lifetime", purchased: Date())
        provider.use(.fake(fakeBacked(store: FakeStore(entitlements: [lifetime], products: products))))
        await paywall.waitUntilStarted()
        #expect(changes.last?.decision == .open(.paying), "\(changes)")
        #expect(paywall.engine?.sessionState(holder)?.isOpen == true)
        paywall.closeSession(holder: holder)
    }

    @Test func a_denied_paid_view_opens_after_useProduction_and_a_purchase() async throws {
        let paywall = Paywall()
        let production = fakeBacked()
        let provider = PaywallServiceProvider(.production(production), paywall: paywall)
        await paywall.waitUntilStarted()
        _ = provider.useFake(fakeBacked())
        await paywall.waitUntilStarted()
        let holder = UUID()
        var changes: [GateSessionState] = []
        _ = paywall.openSession(holder: holder, level: .paid, policy: .reserve, source: mapGate, scope: nil) { changes.append($0) }
        _ = provider.useProduction()
        await paywall.waitUntilStarted()
        #expect(changes.last?.isOpen == false, "reopened on the production engine: still free")
        _ = try await paywall.purchase(products[3])
        #expect(changes.last?.decision == .open(.paying), "the production engine knows the view and flips it: \(changes)")
        paywall.closeSession(holder: holder)
    }

    /// A8: a view that drew its token on appear survives a same-journal `useProduction`: it is pinned first, so the
    /// successor draws nothing, and it stays open past the tolerance.
    @Test func a_drawn_view_survives_a_same_journal_switch_without_a_second_debit() async throws {
        let paywall = Paywall()
        let clock = FakeClock()
        var production = fakeBacked(welcomeTokens: 5)
        production.clock = clock
        let provider = PaywallServiceProvider(.production(production), paywall: paywall)
        await paywall.waitUntilStarted()
        #expect(paywall.wallet.balance == 5)
        let holder = UUID()
        var changes: [GateSessionState] = []
        let drawn = paywall.openSession(holder: holder, level: .tokens(1), policy: .deductNow, source: mapGate, scope: nil) { changes.append($0) }
        #expect(drawn.decision == .open(.drawn(1)) && paywall.wallet.balance == 4)
        _ = provider.useProduction(production)  // the same directory, store and clock: a successor on the same journal
        await paywall.waitUntilStarted()
        #expect(paywall.wallet.balance == 4, "no second debit")
        #expect(changes.last?.isOpen == true, "\(changes)")
        clock.advance(by: 301)  // past the tolerance: the pin keeps it
        await settle()
        #expect(paywall.engine?.sessionState(holder)?.isOpen == true)
        #expect(paywall.wallet.balance == 4)
        paywall.closeSession(holder: holder)
    }

    // MARK: A5: a payment sheet up across a reconfigure

    /// A5: the purchase completes on an engine the facade has replaced. The credit goes to the engine current when it
    /// lands, once, finished once, and both chains verify, with a successor that compacted at start (seeds past the
    /// compaction threshold) and one that did not.
    @Test(arguments: [4_100, 5])
    func a_purchase_that_completes_after_a_reconfigure_is_credited_by_the_successor(seeds: Int) async throws {
        let paywall = Paywall()
        let fake = FakeStore(products: products)
        let store = HoldingStore(fake)
        var configuration = fakeBacked()
        configuration.store = store
        configuration.fullSync = false
        configuration.audit = [JournalSink(directory: try #require(configuration.storageDirectory))]
        let provider = PaywallServiceProvider(.production(configuration), paywall: paywall)
        await paywall.waitUntilStarted()
        for i in 0..<seeds { paywall.grant(tokens: 1, reason: "seed", id: "grant:seed:\(i)") }
        #expect(paywall.wallet.balance == seeds)
        await store.holdNextPurchase()
        let purchase = Task { try await paywall.purchase(products[4]) }  // tokens.10: the sheet is up
        #expect(await waitFor { await store.heldPurchases == 1 })
        _ = provider.useProduction(configuration)  // the same directory: a successor engine, the predecessor shut down
        await paywall.waitUntilStarted()
        #expect((paywall.engine?.journal.checkpoint != nil) == (seeds > 4_096), "the successor compacts at start past the threshold")
        await store.release()
        let outcome = try await purchase.value
        guard case .purchased(let id) = outcome else {
            Issue.record("expected a purchase, got \(outcome)")
            return
        }
        #expect(paywall.wallet.balance == seeds + 10)
        #expect(await fake.finished == [id])
        #expect(paywall.engine?.ledger.events.filter { $0.id == "credit:\(id)" }.count == 1)
        let chains = await paywall.verifyAuditChain()
        #expect(chains.audit == nil && chains.ledger == nil)
        // The next launch sees the same.
        _ = provider.useProduction(configuration)
        await paywall.waitUntilStarted()
        #expect(paywall.wallet.balance == seeds + 10)
        #expect(paywall.engine?.ledger.events.filter { $0.id == "credit:\(id)" }.count == 1)
        let again = await paywall.verifyAuditChain()
        #expect(again.audit == nil && again.ledger == nil)
    }

    /// A5: the sheet completes after the facade went passthrough: no engine can take the transaction, so it stays
    /// unfinished for the next launch's `Transaction.updates`, and the purchase reports `.pending`.
    @Test func a_purchase_that_completes_after_a_switch_to_passthrough_stays_pending() async throws {
        let paywall = Paywall()
        let fake = FakeStore(products: products)
        let store = HoldingStore(fake)
        var configuration = fakeBacked()
        configuration.store = store
        paywall.configure(configuration)
        await paywall.waitUntilStarted()
        await store.holdNextPurchase()
        let purchase = Task { try await paywall.purchase(products[4]) }
        #expect(await waitFor { await store.heldPurchases == 1 })
        var off = configuration
        off.passthrough = true
        paywall.configure(off)
        await store.release()
        #expect(try await purchase.value == .pending)
        #expect(await fake.finished.isEmpty)
        #expect(paywall.engine == nil && paywall.isPassthrough)
    }

    /// A5: the sheet is cancelled after the reconfigure: nothing is credited or finished anywhere.
    @Test func a_purchase_cancelled_after_a_reconfigure_changes_nothing() async throws {
        let paywall = Paywall()
        let fake = FakeStore(products: products)
        let store = HoldingStore(fake)
        var configuration = fakeBacked(welcomeTokens: 3)
        configuration.store = store
        let provider = PaywallServiceProvider(.production(configuration), paywall: paywall)
        await paywall.waitUntilStarted()
        await store.holdNextPurchase()
        let purchase = Task { try await paywall.purchase(products[4]) }
        #expect(await waitFor { await store.heldPurchases == 1 })
        _ = provider.useProduction(configuration)
        await paywall.waitUntilStarted()
        await fake.setNextPurchase(.cancel)
        await store.release()
        #expect(try await purchase.value == .cancelled)
        #expect(paywall.wallet.balance == 3)
        #expect(await fake.finished.isEmpty)
        #expect(paywall.engine?.ledger.events.contains { $0.id.hasPrefix("credit:") } == false)
    }

    // MARK: Environment

    @available(iOS 17, macOS 14, *)
    @Test func paywall_provider_injects_the_provider_the_facade_and_the_entitlement() async {
        let paywall = Paywall()
        let lifetime = StoreTransaction.lifetime(id: 5, productID: "pro.lifetime", purchased: Date())
        let provider = PaywallServiceProvider(
            .fake(fakeBacked(store: FakeStore(entitlements: [lifetime], products: products))), paywall: paywall)
        let recorder = Recorder()
        let window = show(ProviderProbe(recorder: recorder).paywallProvider(provider))
        defer { dismiss(window) }
        await paywall.waitUntilStarted()
        await pump(window)
        #expect(recorder.names.first == "fake", "\(recorder.names)")
        #expect(!recorder.facades.isEmpty)
        #expect(recorder.facades.allSatisfy { $0 == ObjectIdentifier(paywall) })
        #expect(recorder.entitlements.last == .lifetime(.purchase(transactionID: 5)), "\(recorder.entitlements)")

        provider.use(.production(fakeBacked()))
        await paywall.waitUntilStarted()
        await pump(window)
        #expect(recorder.names.last == "production", "\(recorder.names)")
        #expect(recorder.entitlements.last == .free, "\(recorder.entitlements)")
    }

    @Test func paywall_provider_refreshes_the_entitlement_when_the_scene_becomes_active() async {
        let paywall = Paywall()
        let store = FakeStore(products: products)
        let provider = PaywallServiceProvider(.fake(fakeBacked(store: store)), paywall: paywall)
        let recorder = Recorder()
        let window = show(PhaseHost(recorder: recorder, content: Text("root").paywallProvider(provider)))
        defer { dismiss(window) }
        await paywall.waitUntilStarted()
        await pump(window)
        #expect(!paywall.entitlement.isPaying)
        await store.setEntitlements([.lifetime(id: 1, productID: "pro.lifetime", purchased: Date())])
        recorder.phase = .active
        for _ in 0..<50 where !paywall.entitlement.isPaying { await pump(window) }
        #expect(paywall.entitlement.isPaying)
    }

    #if canImport(UIKit) && !os(watchOS)
        /// The contract under UIKit layers: a `PaywallHostingController` puts the provider back, next to the facade
        /// and the entitlement it already re-injected.
        @available(iOS 17, *)
        @Test func a_hosting_controller_reinjects_the_provider() async {
            let paywall = Paywall()
            let provider = PaywallServiceProvider(.fake(fakeBacked()), paywall: paywall)
            await paywall.waitUntilStarted()
            let recorder = Recorder()
            let controller = Paywall.$override.withValue(paywall) {
                PaywallHostingController(rootView: ProviderProbe(recorder: recorder))
            }
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer { dismiss(window) }
            await pump(window)
            #expect(recorder.names.first == "fake", "\(recorder.names)")
            #expect(recorder.facades.first == ObjectIdentifier(paywall))
            #expect(recorder.entitlements.first == .free, "\(recorder.entitlements)")
        }

        /// A facade configured without a provider: the hosted root still gets the facade, and nothing to re-inject.
        @Test func a_hosting_controller_without_a_provider_still_injects_the_facade() async {
            let (paywall, _, _) = await makePaywall()
            let recorder = Recorder()
            struct FacadeProbe: View {
                @ObservedObject var recorder: Recorder
                @EnvironmentObject private var paywall: Paywall
                var body: some View {
                    Text("probe").onAppear { recorder.facades.append(ObjectIdentifier(paywall)) }
                }
            }
            let controller = Paywall.$override.withValue(paywall) {
                PaywallHostingController(rootView: FacadeProbe(recorder: recorder))
            }
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer { dismiss(window) }
            await pump(window)
            #expect(recorder.facades == [ObjectIdentifier(paywall)])
            #expect(paywall.provider == nil)
        }
    #endif
}
