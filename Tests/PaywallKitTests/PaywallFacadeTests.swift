import Combine
import Foundation
import PaywallCore
import PaywallTesting
import Testing

@testable import PaywallKit

let catalog = ProductCatalog(
    subscriptionGroupID: "pro", weekly: "pro.weekly", monthly: "pro.monthly", yearly: "pro.yearly", lifetime: "pro.lifetime",
    tokenPacks: [TokenPack(productID: "tokens.10", tokens: 10)])

let products: [PaywallProduct] = [
    PaywallProduct(id: "pro.weekly", kind: .subscription(.weekly), displayName: "Weekly", displayPrice: "€1.99", introOffer: .init(trialDays: 7)),
    PaywallProduct(id: "pro.monthly", kind: .subscription(.monthly), displayName: "Monthly", displayPrice: "€4.99"),
    PaywallProduct(id: "pro.yearly", kind: .subscription(.yearly), displayName: "Yearly", displayPrice: "€29.99"),
    PaywallProduct(id: "pro.lifetime", kind: .lifetime, displayName: "Lifetime", displayPrice: "€59.99"),
    PaywallProduct(id: "tokens.10", kind: .tokens(0), displayName: "10 tokens", displayPrice: "€0.99"),
]

struct Boom: Error {}

/// A configured, isolated facade (not `shared`) on a fresh directory.
@MainActor
func makePaywall(
    entitlements: [StoreTransaction] = [], tokens: Int = 0, audit: [any PaywallAuditSink] = []
) async -> (Paywall, FakeStore, FakeClock) {
    let paywall = Paywall()
    let store = FakeStore(entitlements: entitlements, products: products)
    let clock = FakeClock()
    var configuration = Paywall.Configuration(catalog: catalog)
    configuration.store = store
    configuration.clock = clock
    configuration.storageDirectory = makeTemporaryPaywallDirectory()
    configuration.includesDefaultAudit = false
    configuration.connectivity = nil
    configuration.audit = audit
    paywall.configure(configuration)
    await paywall.waitUntilStarted()
    if tokens > 0 { paywall.grant(tokens: tokens, reason: "test") }
    return (paywall, store, clock)
}

@MainActor
func settle() async {
    for _ in 0..<5 { await Task.yield() }
}

@Suite("Facade", .serialized)
@MainActor
struct PaywallFacadeTests {
    @Test func configure_mirrors_entitlement_and_wallet() async {
        let (paywall, _, _) = await makePaywall(entitlements: [.lifetime(id: 1, productID: "pro.lifetime", purchased: Date())], tokens: 4)
        #expect(paywall.entitlement == .lifetime(.purchase(transactionID: 1)))
        #expect(paywall.wallet.balance == 4)
        #expect(paywall.configurationError == nil)
    }

    @Test func unconfigured_facade_fails_closed() async throws {
        let paywall = Paywall()
        #expect(paywall.canPass(.free))
        #expect(!paywall.canPass(.paid))
        #expect(paywall.evaluate(.paid, id: "x").failure?.reason == .entitlementUnavailable)
        #expect(paywall.evaluate(.free, id: "x").value != nil)
        #expect(paywall.run(.tokens(1), source: PaywallSource(fileID: "f", function: "g", line: 1), scope: nil, holder: nil) { 1 }.failure != nil)
        #expect(paywall.run(.free, source: PaywallSource(fileID: "f", function: "g", line: 1), scope: nil, holder: nil) { 1 }.value == 1)
        await #expect(throws: StoreClientError.notConfigured) { _ = try await paywall.products() }
        await #expect(throws: StoreClientError.notConfigured) { try await paywall.restorePurchases() }
        await #expect(throws: StoreClientError.notConfigured) { _ = try await paywall.subscriptionPhase() }
        await #expect(throws: StoreClientError.notConfigured) { _ = try await paywall.purchase(products[0]) }
        #expect(!(await paywall.isEligibleForIntroOffer()))
        #expect(!paywall.grant(tokens: 1, reason: "x"))
        await #expect(throws: Paywall.ExportError.notConfigured) { _ = try await paywall.exportAudit() }
        let session = paywall.openSession(holder: UUID(), level: .paid, policy: .reserve, source: PaywallSource(fileID: "f", function: "g", line: 2), scope: nil) { _ in }
        #expect(!session.isOpen)
    }

    @Test func invalid_catalog_is_refused() {
        let paywall = Paywall()
        paywall.configure(Paywall.Configuration(catalog: ProductCatalog(subscriptionGroupID: "g")))
        #expect(paywall.configurationError == .invalidCatalog([.noProducts]))
        #expect(paywall.engine == nil)
    }

    @Test func unwritable_storage_is_reported() {
        let paywall = Paywall()
        var configuration = Paywall.Configuration(catalog: catalog)
        configuration.storageDirectory = URL(fileURLWithPath: "/dev/null/paywall")
        configuration.store = FakeStore()
        configuration.clock = FakeClock()
        paywall.configure(configuration)
        if case .journalUnavailable = paywall.configurationError {} else { Issue.record("expected journalUnavailable") }
    }

    @Test func withPaywall_sync_draws_and_leases() async {
        let (paywall, _, _) = await makePaywall(tokens: 5)
        Paywall.$override.withValue(paywall) {
            #expect(withPaywall(.tokens(2), id: "export") { "pdf" }.value == "pdf")
            #expect(withPaywall(.tokens(2), id: "export") { "pdf" }.value == "pdf")
            #expect(withPaywall(.paid, id: "pro") { 1 }.failure?.reason == .requiresPaid)
            #expect(withPaywall { 7 }.value == 7)
        }
        #expect(paywall.wallet.balance == 3)
    }

    @Test func withPaywall_async_runs_body_and_refunds_on_throw() async throws {
        let (paywall, _, _) = await makePaywall(tokens: 5)
        try await Paywall.$override.withValue(paywall) {
            let value = await withPaywall(.tokens(2), id: "solve") { () async -> Int in
                await Task.yield()
                return 42
            }
            #expect(value.value == 42)
            await #expect(throws: Boom.self) {
                try await withPaywall(.tokens(1), id: "fail") { () async throws -> Int in throw Boom() }
            }
            let blocked = try await withPaywall(.paid, id: "pro") { () async throws -> Int in 1 }
            #expect(blocked.failure?.reason == .requiresPaid)
        }
        #expect(paywall.wallet.balance == 3)
    }

    @Test func async_withPaywall_from_another_actor() async {
        let (paywall, _, _) = await makePaywall(tokens: 3)
        actor Exporter {
            func run(on paywall: Paywall) async -> Int? {
                await Paywall.$override.withValue(paywall) {
                    await withPaywall(.tokens(1), id: "bg") { () async -> Int in 9 }.value
                }
            }
        }
        #expect(await Exporter().run(on: paywall) == 9)
        #expect(paywall.wallet.balance == 2)
    }

    @Test func unclaimed_denial_becomes_pendingFailure() async {
        let (paywall, _, _) = await makePaywall()
        _ = paywall.evaluate(.paid, id: "heatmap")
        #expect(paywall.pendingFailure == nil)  // not before the end of the turn
        await settle()
        #expect(paywall.pendingFailure?.source.id == "heatmap")
        #expect(paywall.consumePendingFailure()?.source.id == "heatmap")
        #expect(paywall.pendingFailure == nil)
    }

    @Test func claimed_denial_does_not_fall_through() async {
        let (paywall, _, _) = await makePaywall()
        var handled: [PaywallFailure] = []
        let cancellable = paywall.failures(scope: nil, id: "heatmap").sink { failure in
            handled.append(failure)
            failure.claim()
        }
        _ = paywall.evaluate(.paid, id: "heatmap")
        _ = paywall.evaluate(.paid, id: "other")
        await settle()
        #expect(handled.count == 1)
        #expect(paywall.pendingFailure?.source.id == "other")
        cancellable.cancel()
    }

    @Test func failures_filter_by_scope() async {
        let (paywall, _, _) = await makePaywall()
        var home: [String] = []
        let cancellable = paywall.failures(scope: "home").sink { home.append($0.source.id) }
        paywall.engine?.openSession(holder: UUID(), level: .paid, policy: .reserve, source: PaywallSource(id: "a", fileID: "f", function: "g", line: 1), scope: "home")
        paywall.engine?.openSession(holder: UUID(), level: .paid, policy: .reserve, source: PaywallSource(id: "b", fileID: "f", function: "g", line: 1), scope: "maps")
        #expect(home == ["a"])
        cancellable.cancel()
    }

    @Test func event_stream_and_combine_see_the_same_events() async {
        let (paywall, _, _) = await makePaywall()
        var combine: [PaywallEvent] = []
        let cancellable = paywall.events.sink { combine.append($0) }
        let stream = paywall.eventStream
        _ = paywall.evaluate(.paid, id: "x")
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first == combine.first)
        #expect(combine.contains { $0.failure != nil })
        cancellable.cancel()
    }

    @Test func notification_bridge_posts_events() async {
        let (paywall, _, _) = await makePaywall()
        let center = NotificationCenter()
        @MainActor final class Counter { var value = 0 }
        let counter = Counter()
        let observer = center.addObserver(forName: .paywallEvent, object: nil, queue: nil) { note in
            let isEvent = note.userInfo?[PaywallNotificationKey.event] is PaywallEvent
            MainActor.assumeIsolated { if isEvent { counter.value += 1 } }
        }
        let bridge = paywall.bridgeToNotificationCenter(center)
        _ = paywall.evaluate(.paid, id: "x")
        #expect(counter.value >= 2)
        bridge.cancel()
        center.removeObserver(observer)
    }

    @Test func store_calls_go_through_the_engine() async throws {
        let (paywall, store, _) = await makePaywall()
        let listed = try await paywall.products()
        #expect(listed.first { $0.id == "tokens.10" }?.kind == .tokens(10))
        let outcome = try await paywall.purchase(listed.first { $0.id == "tokens.10" }!, source: nil)
        if case .purchased = outcome {} else { Issue.record("expected purchase") }
        #expect(paywall.wallet.balance == 10)
        await store.setEntitlements([.lifetime(id: 3, productID: "pro.lifetime", purchased: Date())])
        try await paywall.restorePurchases()
        #expect(paywall.entitlement.isPaying)
        await store.setPhase(.inGracePeriod)
        #expect(try await paywall.subscriptionPhase() == .inGracePeriod)
        #expect(await paywall.isEligibleForIntroOffer())
        await paywall.refresh()
        await paywall.didBecomeActive()
        await paywall.syncNow()
        #expect(await store.syncCalls == 1)
    }

    @Test func reconfigure_tears_down_the_previous_engine() async {
        let (paywall, _, _) = await makePaywall(tokens: 2)
        let first = paywall.engine
        var configuration = Paywall.Configuration(catalog: catalog)
        configuration.store = FakeStore()
        configuration.clock = FakeClock()
        configuration.storageDirectory = makeTemporaryPaywallDirectory()
        configuration.includesDefaultAudit = false
        var started = false
        configuration.onStart = { _ in started = true }
        paywall.configure(configuration)
        await paywall.waitUntilStarted()
        #expect(paywall.engine !== first)
        #expect(paywall.wallet.balance == 0)
        #expect(started)
    }

    @Test func gate_session_commits_its_reservation() async {
        let (paywall, _, _) = await makePaywall(tokens: 3)
        let holder = UUID()
        let source = PaywallSource(id: "tool", fileID: "f", function: "g", line: 1)
        let state = paywall.openSession(holder: holder, level: .tokens(3), policy: .reserve, source: source, scope: nil) { _ in }
        #expect(state.decision == .open(.reserved(3)))
        let session = GateSession(level: .tokens(3), source: source, isOpen: true, holder: holder)
        Paywall.$override.withValue(paywall) {
            #expect(session.withPaywall { "x" }.value == "x")
        }
        #expect(paywall.wallet == Wallet(balance: 0, reserved: 0))
        let again = await Paywall.$override.withValue(paywall) {
            await session.withPaywall { () async -> String in "y" }
        }
        #expect(again.value == "y")
        paywall.closeSession(holder: holder)
    }

    @Test func default_audit_writes_the_journal_and_exports() async throws {
        let paywall = Paywall()
        var configuration = Paywall.Configuration(catalog: catalog)
        configuration.store = FakeStore(products: products)
        configuration.clock = FakeClock()
        configuration.storageDirectory = makeTemporaryPaywallDirectory()
        paywall.configure(configuration)
        await paywall.waitUntilStarted()
        paywall.grant(tokens: 5, reason: "t")
        _ = paywall.run(.tokens(1), source: PaywallSource(id: "g", fileID: "f", function: "g", line: 1), scope: nil, holder: nil) {}
        let chain = await paywall.verifyAuditChain()
        #expect(chain.audit == nil && chain.ledger == nil)
        let zip = try await paywall.exportAudit()
        #expect(zip.pathExtension == "zip")
        let size = try FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? Int ?? 0
        #expect(size > 100)
    }
}

@Suite("Disclosure and signals")
@MainActor
struct DisclosureTests {
    let terms = URL(string: "https://example.com/terms")!
    let privacy = URL(string: "https://example.com/privacy")!

    @Test func disclosure_is_complete_for_every_product() {
        for product in products {
            let disclosure = PaywallDisclosure(product: product, whatYouGet: "All tools", termsURL: terms, privacyURL: privacy)
            #expect(disclosure.isComplete, "\(product.id)")
            #expect(disclosure.links == [terms, privacy])
        }
        #expect(PaywallDisclosure(product: products[3], whatYouGet: "x", termsURL: terms, privacyURL: privacy).period == nil)
        #expect(!PaywallDisclosure(product: products[1], whatYouGet: "", termsURL: terms, privacyURL: privacy).isComplete)
    }

    /// 3.1.2(a): the trial length and what it costs afterwards, before the purchase.
    @Test func trial_disclosure_shows_length_and_post_trial_price() {
        let weekly = PaywallDisclosure(product: products[0], whatYouGet: "All tools", termsURL: terms, privacyURL: privacy)
        #expect(weekly.trial == "7-day free trial, then €1.99 per week")
        #expect(weekly.period == "per week")
        #expect(weekly.renewal?.contains("€1.99") == true)
        var noTrial = products[0]
        noTrial.introOffer = nil
        #expect(PaywallDisclosure(product: noTrial, whatYouGet: "x", termsURL: terms, privacyURL: privacy).trial == nil)
    }

    /// Package half of 3.1.1: the disclosure's price is StoreKit's `displayPrice`, and its only links are the
    /// Terms and Privacy URLs. The host's screen tests check that the paywall renders these values.
    @Test func paywall_prices_come_from_storekit_only() async throws {
        let (paywall, store, _) = await makePaywall()
        var repriced = products
        repriced[2].displayPrice = "$34.99"
        await store.setProducts(repriced)
        let yearly = try #require(try await paywall.products().first { $0.id == "pro.yearly" })
        let disclosure = PaywallDisclosure(product: yearly, whatYouGet: "x", termsURL: terms, privacyURL: privacy)
        #expect(disclosure.price == "$34.99")
        #expect(disclosure.links == [terms, privacy])
    }

    @Test func network_path_connectivity_reports_the_current_path() async {
        var first: Bool?
        for await hasPath in await NetworkPathConnectivity().paths() {
            first = hasPath
            break
        }
        #expect(first != nil)
    }

    #if DEBUG
        @Test func configuration_passes_the_grandfather_override_to_the_engine() async {
            let paywall = Paywall()
            var configuration = Paywall.Configuration(catalog: catalog)
            configuration.store = FakeStore(products: products)
            configuration.clock = FakeClock()
            configuration.connectivity = nil
            configuration.includesDefaultAudit = false
            configuration.storageDirectory = makeTemporaryPaywallDirectory()
            let override = GrandfatherOverride(originalAppVersion: "90", originalPurchaseDate: Date())
            configuration.grandfatherOverride = override
            paywall.configure(configuration)
            #expect(paywall.engine?.settings.grandfatherOverride == override)
        }
    #endif

    @Test func oslog_categories_cover_every_event() async {
        let failure = PaywallFailure(reason: .requiresPaid, level: .paid, source: PaywallSource(fileID: "f", function: "g", line: 1), at: Date())
        let events: [PaywallEvent] = [
            .gateDenied(failure), .tokensConsumed(n: 1, source: failure.source, debitID: "d", leaseUntil: Date()),
            .restore(stage: .requested),
        ]
        #expect(events.map(OSLogSink.category) == [.gate, .wallet, .store])
        let record = AuditRecord(
            at: Date(), uptime: 1, sessionID: UUID(), deviceID: "d", appVersion: "1", build: "1", environment: "xcode",
            event: events[0], entitlementBefore: .free, entitlementAfter: .free, balanceBefore: 0, balanceAfter: 0,
            previousHash: paywallGenesisHash)
        let sink = OSLogSink()
        await sink.write(record)
    }
}
