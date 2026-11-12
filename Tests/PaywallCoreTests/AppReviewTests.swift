import Foundation
import PaywallTesting
import Testing

@testable import PaywallCore

/// The package half of the design's App Review table: each test is named after the row it proves. The host half
/// (the paywall screen, routes, the StoreKit configuration file and the release archive) lives in the host app and in
/// `Scripts/check-release-symbols.sh`.
@Suite("App Review (package half)", .serialized)
@MainActor
struct AppReviewTests {
    private func grandfatheredHarness() async throws -> Harness {
        let now = FakeClock().now
        let policy = GrandfatheringPolicy(lastPaidBuild: "116", paidWindow: DateInterval(start: now.addingTimeInterval(-1e7), end: now))
        let h = try Harness(grandfathering: policy)
        await h.store.setApp(
            AppTransactionSnapshot(
                bundleID: "b", originalAppVersion: "90", originalPurchaseDate: now.addingTimeInterval(-1e6),
                environment: .production, origin: .appTransaction))
        await h.start()
        return h
    }

    /// 3.1.1 / 3.1.2: a user who paid for the app before freemium keeps every feature, tokens included.
    @Test func every_gate_opens_for_grandfathered_user() async throws {
        let h = try await grandfatheredHarness()
        #expect(h.engine.entitlement == .lifetime(.grandfathered(originalAppVersion: "90")))
        for level in [GateLevel.free, .paid, .tokens(1), .tokens(50)] {
            var ran = false
            let outcome = h.engine.run(level, source: source("g\(level.tokenCost)")) { ran = true }
            #expect(ran && outcome.failure == nil, "\(level) closed for a grandfathered user")
        }
        let holder = UUID()
        let state = h.engine.openSession(holder: holder, level: .tokens(3), policy: .reserve, source: source("view"), scope: nil)
        #expect(state.isOpen)
        #expect(h.engine.wallet.balance == 0)  // nothing drawn, nothing owed
        #expect(h.engine.reservations.total == 0)
    }

    /// 3.1.2: one subscription group, so a crossgrade leaves exactly one active subscription.
    @Test func one_active_subscription_after_crossgrade() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day: TimeInterval = 86_400
        let resolver = EntitlementResolver(catalog: catalog, grandfathering: nil)
        let monthly = StoreTransaction.subscription(
            id: 1, productID: "pro.monthly", purchased: now.addingTimeInterval(-10 * day), expires: now.addingTimeInterval(20 * day),
            upgraded: true)
        let yearly = StoreTransaction.subscription(
            id: 2, productID: "pro.yearly", purchased: now, expires: now.addingTimeInterval(365 * day))
        let upgraded = resolver.resolve(transactions: [monthly, yearly], appTransaction: nil, now: now)
        #expect(upgraded.entitlement == .subscription(.yearly, productID: "pro.yearly", expiresAt: now.addingTimeInterval(365 * day)))
        // A downgrade takes effect at renewal: until then StoreKit reports only the current product.
        let current = StoreTransaction.subscription(
            id: 3, productID: "pro.yearly", purchased: now.addingTimeInterval(-day), expires: now.addingTimeInterval(day))
        #expect(resolver.resolve(transactions: [current], appTransaction: nil, now: now).entitlement.isPaying)
    }

    /// 5.1.1 / 3.1.2: purchases never depend on iCloud; tokens keep working on a device with iCloud off.
    @Test func paid_features_work_without_icloud() async throws {
        let cloud = InMemoryCloud()
        await cloud.setReachable(false)
        let paying = try Harness(sync: InMemoryLedgerSync(cloud: cloud))
        await paying.store.setEntitlements([.lifetime(id: 1, productID: "pro.lifetime", purchased: paying.clock.now)])
        await paying.start()
        #expect(paying.engine.canPass(.paid) && paying.engine.canPass(.tokens(5)))

        let free = try Harness(sync: InMemoryLedgerSync(cloud: cloud))
        await free.start()
        free.engine.grant(tokens: 4, reason: "welcome")
        await free.engine.syncNow()
        var ran = false
        _ = free.engine.run(.tokens(2), source: source("x")) { ran = true }
        #expect(ran && free.engine.wallet.balance == 2)
        // Queued for when iCloud comes back, never lost.
        let pending = free.engine.journal.pendingUpload.map(\.kind)
        #expect(pending.contains { if case .grant(4, _) = $0 { true } else { false } })
        #expect(pending.contains { if case .debit(2, _) = $0 { true } else { false } })
    }

    /// 3.1.2(a): auto-renewable subscriptions last at least seven days.
    @Test func subscription_periods_are_at_least_seven_days() {
        #expect(SubscriptionTier.allCases.allSatisfy { $0.periodInDays >= 7 })
        for (tier, _) in catalog.subscriptions { #expect(tier.periodInDays >= 7) }
    }

    /// 5.1.1(v): no gate asks for an account, a login or the App Store. Decisions are synchronous reads; the only
    /// store calls on launch and foreground are the passive entitlement reads.
    @Test func no_login_anywhere_in_gate_path() async throws {
        let h = try await Harness.free(tokens: 3)
        await h.store.setReachable(false)
        for level in [GateLevel.free, .paid, .tokens(1), .tokens(9)] {
            _ = h.engine.evaluate(level, source: source("e"))
            _ = h.engine.run(level, source: source("r")) {}
            let holder = UUID()
            h.engine.openSession(holder: holder, level: level, policy: .reserve, source: source("s"), scope: nil)
            h.engine.closeSession(holder: holder)
        }
        await h.engine.didBecomeActive()
        #expect(await h.store.syncCalls == 0)
        #expect(await h.store.purchaseCalls == 0)
    }
}

@Suite("Edge cases", .serialized)
@MainActor
struct EdgeCaseTests {
    @Test func first_launch_offline_closes_gates_until_a_resolution_reopens_them() async throws {
        let h = try Harness()
        await h.store.setReachable(false)
        await h.start()
        #expect(h.engine.entitlement == .unknown)
        let holder = UUID()
        let state = h.engine.openSession(holder: holder, level: .paid, policy: .reserve, source: source("map"), scope: nil)
        #expect(state.failure?.reason == .entitlementUnavailable)
        #expect(h.engine.run(.tokens(1), source: source("t")) { 1 }.failure?.reason == .entitlementUnavailable)
        #expect(h.engine.run(.free, source: source("f")) { 1 }.value == 1)
        await h.store.setReachable(true)
        await h.store.setEntitlements([.lifetime(id: 1, productID: "pro.lifetime", purchased: h.clock.now)])
        await h.engine.didBecomeActive()
        #expect(h.engine.sessionState(holder)?.isOpen == true)  // the view on screen reopened by itself
    }

    @Test func offer_code_redeemed_in_the_app_store_arrives_on_updates() async throws {
        let h = try await Harness.free()
        let redeemed = StoreTransaction.subscription(
            id: 40, productID: "pro.monthly", purchased: h.clock.now, expires: h.clock.now.addingTimeInterval(30 * 86_400))
        await h.store.setEntitlements([redeemed])
        await h.store.deliver(redeemed)
        #expect(await eventually { await h.store.finished == [40] })
        #expect(h.engine.entitlement.isPaying)
        #expect(h.events.contains { if case .entitlementChanged(.free, _, .update) = $0 { true } else { false } })
    }

    @Test func family_sharing_removal_is_a_revocation() async throws {
        let h = try Harness()
        let shared = StoreTransaction.lifetime(id: 50, productID: "pro.lifetime", purchased: h.clock.now)
        await h.store.setEntitlements([shared])
        await h.start()
        #expect(h.engine.entitlement.isPaying)
        var removed = shared
        removed.revocationDate = h.clock.now
        await h.store.setEntitlements([])
        await h.store.deliver(removed)
        #expect(await eventually { h.engine.entitlement == .free })
        #expect(h.events.contains { if case .entitlementChanged(_, .free, .revoked) = $0 { true } else { false } })
    }

    @Test func outbox_waits_for_a_network_path_and_drains_when_it_returns() async throws {
        let connectivity = FakeConnectivity(hasPath: false)
        let sync = InMemoryLedgerSync()
        let h = try Harness(sync: sync, connectivity: connectivity)
        await h.start()
        #expect(await eventually { !h.engine.hasNetworkPath })
        h.engine.grant(tokens: 2, reason: "t")
        await h.engine.syncNow()
        #expect(await sync.cloud.pushCount == 0)
        await connectivity.set(true)
        #expect(await eventually { await sync.cloud.events.count == 1 })  // no syncNow: the return drained it
        #expect(h.engine.journal.pendingUpload.isEmpty)
        h.engine.shutdown()
        #expect(await eventually { await connectivity.listenerCount == 0 })
    }

    #if DEBUG
        @Test func grandfather_override_admits_the_device_without_rebinding_the_wallet() async throws {
            let now = FakeClock().now
            let policy = GrandfatheringPolicy(lastPaidBuild: "116", paidWindow: DateInterval(start: now.addingTimeInterval(-1e7), end: now))
            let sandbox = AppTransactionSnapshot(
                bundleID: "b", originalAppVersion: "1.0", originalPurchaseDate: now, environment: .sandbox, origin: .appTransaction)

            let plain = try Harness(grandfathering: policy)
            await plain.store.setApp(sandbox)
            await plain.start()
            #expect(plain.engine.entitlement == .free)

            var settings = GateEngine.Settings(tolerance: 300, appVersion: "2.0", build: "200")
            let override = GrandfatherOverride(originalAppVersion: "90", originalPurchaseDate: now.addingTimeInterval(-1e6))
            settings = settings.with(grandfatherOverride: override)
            let h = try Harness(settings: settings, grandfathering: policy)
            await h.store.setApp(sandbox)
            await h.start()
            #expect(h.engine.entitlement == .lifetime(.grandfathered(originalAppVersion: "90")))
            #expect(h.engine.accountKey == sandbox.accountKey)
            #expect(h.engine.appTransaction == sandbox)

            // With no app transaction at all (a simulator without StoreKit), the override still answers.
            let bare = try Harness(settings: settings, grandfathering: policy)
            await bare.start()
            #expect(bare.engine.entitlement == .lifetime(.grandfathered(originalAppVersion: "90")))
            #expect(bare.engine.accountKey == unboundAccountKey)
        }
    #endif
}

@Suite("StoreKit configuration check")
struct StoreKitConfigurationCheckTests {
    private func file(_ products: String, _ groups: String) -> Data {
        Data(#"{ "identifier": "X", "products": [\#(products)], "subscriptionGroups": [\#(groups)], "version": { "major": 4, "minor": 0 } }"#.utf8)
    }

    private let products = #"""
        { "productID": "pro.lifetime", "type": "NonConsumable", "referenceName": "Lifetime" },
        { "productID": "tokens.10", "type": "Consumable", "referenceName": "10" },
        { "productID": "tokens.50", "type": "Consumable", "referenceName": "50" }
        """#
    private let group = #"""
        { "id": "1", "name": "Pro", "subscriptions": [
          { "productID": "pro.weekly", "recurringSubscriptionPeriod": "P1W", "groupNumber": 3 },
          { "productID": "pro.monthly", "recurringSubscriptionPeriod": "P1M", "groupNumber": 2 },
          { "productID": "pro.yearly", "recurringSubscriptionPeriod": "P1Y", "groupNumber": 1 } ] }
        """#

    /// The host runs this against its own `.storekit` file; here against a fixture that matches the test catalog.
    @Test func catalog_matches_storekit_configuration() throws {
        #expect(try catalog.mismatches(withStoreKitConfiguration: file(products, group)).isEmpty)
    }

    @Test func every_kind_of_drift_is_reported() throws {
        let drifted = #"""
            { "productID": "pro.lifetime", "type": "Consumable" },
            { "productID": "tokens.10", "type": "Consumable" },
            { "productID": "tokens.999", "type": "Consumable" }
            """#
        let groups = #"""
            { "name": "Pro", "subscriptions": [
              { "productID": "pro.weekly", "recurringSubscriptionPeriod": "P1M" },
              { "productID": "pro.monthly", "recurringSubscriptionPeriod": "P1M" } ] },
            { "name": "Legacy", "subscriptions": [ { "productID": "pro.yearly", "recurringSubscriptionPeriod": "P1Y" } ] }
            """#
        let problems = try catalog.mismatches(withStoreKitConfiguration: file(drifted, groups))
        #expect(Set(problems) == [
            .wrongType(productID: "pro.lifetime", expected: "NonConsumable", found: "Consumable"),
            .missingFromConfiguration(productID: "tokens.50"),
            .missingFromCatalog(productID: "tokens.999"),
            .wrongPeriod(productID: "pro.weekly", expected: "P1W", found: "P1M"),
            .subscriptionsSplitAcrossGroups(["Legacy", "Pro"]),
        ])
        #expect(throws: ProductCatalog.StoreKitConfigurationError.notAStoreKitConfiguration) {
            try catalog.mismatches(withStoreKitConfiguration: Data("not json".utf8))
        }
        let bare = Data(#"{ "subscriptionGroups": [ { "name": "Empty" } ] }"#.utf8)
        let missing = try catalog.mismatches(withStoreKitConfiguration: bare)
        #expect(missing.count == 6 && missing.allSatisfy { if case .missingFromConfiguration = $0 { true } else { false } })
        let empty = Data(#"{}"#.utf8)
        #expect(try ProductCatalog(subscriptionGroupID: "g").mismatches(withStoreKitConfiguration: empty).isEmpty)
    }
}
