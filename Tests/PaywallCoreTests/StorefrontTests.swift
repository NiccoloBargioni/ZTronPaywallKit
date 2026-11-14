import Foundation
import PaywallTesting
import Testing

@testable import PaywallCore

/// What the App Store sells right now, kept current by the engine: fetched at launch and foreground when stale, after
/// every purchase and restore, on demand, and kept on disk between launches.
@Suite("Storefront", .serialized)
@MainActor
struct StorefrontTests {
    private func changes(_ h: Harness) -> Int {
        h.events.filter { if case .storefrontChanged = $0 { true } else { false } }.count
    }

    @Test func the_launch_fetch_lists_the_catalog_in_order_with_the_catalogs_kinds() async throws {
        let h = try await Harness.free()
        let storefront = try #require(h.engine.storefront)
        #expect(storefront.products.map(\.id) == ["pro.weekly", "pro.monthly", "pro.yearly", "pro.lifetime", "tokens.10", "tokens.50"])
        #expect(storefront.products.map(\.kind) == [.subscription(.weekly), .subscription(.monthly), .subscription(.yearly), .lifetime, .tokens(10), .tokens(50)])
        #expect(storefront.unavailableProductIDs.isEmpty)
        #expect(storefront.countryCode == "USA")
        #expect(storefront.fetchedAt == h.clock.now)
        #expect(storefront.product("tokens.50")?.kind == .tokens(50))
        #expect(storefront.product("nope") == nil)
        #expect(h.events.contains(.storefrontChanged(productIDs: storefront.products.map(\.id), countryCode: "USA")))
        #expect(await h.store.productCalls == 1)
    }

    @Test func products_the_store_does_not_return_are_unavailable_and_retired_ones_are_not_listed() async throws {
        let retiring = ProductCatalog(
            subscriptionGroupID: "pro", weekly: "pro.weekly", monthly: "pro.monthly", yearly: "pro.yearly", lifetime: "pro.lifetime",
            tokenPacks: [TokenPack(productID: "tokens.10", tokens: 10), TokenPack(productID: "tokens.50", tokens: 50)],
            retired: ["pro.monthly"])
        let store = FakeStore(products: products.filter { $0.id != "pro.yearly" })  // yearly removed from sale
        let clock = FakeClock()
        let engine = try GateEngine(directory: makeTemporaryPaywallDirectory(), catalog: retiring, clock: clock, store: store)
        await engine.start()
        let storefront = try #require(engine.storefront)
        #expect(storefront.products.map(\.id) == ["pro.weekly", "pro.lifetime", "tokens.10", "tokens.50"])
        #expect(storefront.unavailableProductIDs == ["pro.yearly"])
        // The retired plan still resolves: a subscriber to it stays paying.
        await store.setEntitlements([
            .subscription(id: 1, productID: "pro.monthly", purchased: clock.now, expires: clock.now.addingTimeInterval(86_400))
        ])
        await engine.refresh(cause: .update)
        #expect(engine.entitlement.isPaying)
        #expect(engine.tier == .monthly)
        engine.shutdown()
    }

    @Test func the_last_storefront_is_on_disk_before_the_first_fetch_of_a_launch() async throws {
        let h = try await Harness.free()
        let fetched = try #require(h.engine.storefront)
        await h.store.setNetwork(false)
        let relaunched = try await h.relaunch(start: false)
        #expect(relaunched.storefront == fetched)  // read in `init`, before anything is fetched
        await relaunched.start()  // offline: the fetch fails and the copy stands
        #expect(relaunched.storefront == fetched)
        #expect(changes(h) == 0)
        let offline = try await relaunched.products()
        #expect(offline.map(\.displayPrice) == fetched.products.map(\.displayPrice))
        #expect(offline.allSatisfy { !$0.isPurchasable && $0.priceAsOf == fetched.fetchedAt })
    }

    @Test func a_refresh_publishes_a_change_only_when_the_listing_changed() async throws {
        let h = try await Harness.free()
        #expect(changes(h) == 1)
        h.clock.advance(by: 10)
        _ = try await h.engine.refreshStorefront()
        #expect(changes(h) == 1)  // the same listing, fetched later
        #expect(h.engine.storefront?.fetchedAt == h.clock.now)
        var repriced = products
        repriced[2].displayPrice = "$34.99"
        await h.store.setProducts(repriced)
        let after = try await h.engine.refreshStorefront()
        #expect(changes(h) == 2)
        #expect(after.product("pro.yearly")?.displayPrice == "$34.99")
        await h.store.setStorefrontCountry("ITA")
        _ = try await h.engine.refreshStorefront()
        #expect(changes(h) == 3)
        #expect(h.engine.storefront?.countryCode == "ITA")
        await h.store.setProducts(repriced.filter { $0.id != "tokens.50" })
        _ = try await h.engine.refreshStorefront()
        #expect(changes(h) == 4)
        #expect(h.engine.storefront?.unavailableProductIDs == ["tokens.50"])
    }

    @Test func launch_and_foreground_fetch_only_when_the_storefront_is_stale() async throws {
        var settings = GateEngine.Settings(tolerance: 300, appVersion: "2.0", build: "200")
        settings.storefrontRefreshInterval = 600
        let h = try await Harness.free(settings: settings)
        #expect(await h.store.productCalls == 1)
        await h.engine.didBecomeActive()
        #expect(await h.store.productCalls == 1)  // fresh
        h.clock.advance(by: 601)
        await h.engine.didBecomeActive()
        #expect(await h.store.productCalls == 2)
        try await h.relaunch()  // the copy on disk is fresh again
        #expect(await h.store.productCalls == 2)
        h.clock.advance(by: 601)
        try await h.relaunch()
        #expect(await h.store.productCalls == 3)
    }

    @Test func a_purchase_and_a_restore_refresh_in_the_background_one_at_a_time() async throws {
        let h = try await Harness.free()
        _ = try await h.engine.purchase(productID: "tokens.10", source: nil)
        #expect(await eventually { await h.store.productCalls == 2 })
        try await h.engine.restore()
        #expect(await eventually { await h.store.productCalls == 3 })
        #expect(await eventually { h.engine.storefrontTask == nil })
        h.engine.scheduleStorefrontRefresh()
        h.engine.scheduleStorefrontRefresh()  // one in flight already
        #expect(await eventually { await h.store.productCalls == 4 })
        #expect(await eventually { h.engine.storefrontTask == nil })
        h.engine.shutdown()
        h.engine.scheduleStorefrontRefresh()
        #expect(h.engine.storefrontTask == nil)
        #expect(await h.store.productCalls == 4)
    }

    @Test func a_refresh_that_outlives_the_engine_throws_and_changes_nothing() async throws {
        let h = try await Harness.free()
        let before = h.engine.storefront
        let task = Task { try await h.engine.refreshStorefront() }
        h.engine.shutdown()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(h.engine.storefront == before)
    }

    @Test func the_storefront_round_trips_with_prices_and_offers() throws {
        let offer = PaywallProduct.Offer(
            kind: .promotional, id: "comeback", paymentMode: .payAsYouGo, displayPrice: "€2.99",
            price: try #require(Decimal(string: "2.99")), periodDays: 30, periodCount: 3)
        let product = PaywallProduct(
            id: "pro.monthly", kind: .subscription(.monthly), displayName: "Monthly", displayPrice: "€4.99",
            price: Decimal(string: "4.99"), currencyCode: "EUR", offers: [offer])
        let storefront = PaywallStorefront(
            products: [product], unavailableProductIDs: ["pro.yearly"], countryCode: "ITA", fetchedAt: Date(timeIntervalSince1970: 1_000))
        let data = try CanonicalJSON.encoder().encode(storefront)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"price\":\"4.99\"") && json.contains("\"price\":\"2.99\""))
        #expect(try CanonicalJSON.decoder().decode(PaywallStorefront.self, from: data) == storefront)
        #expect(offer.totalDays == 90)
        #expect(storefront.hasSameListing(as: storefront))
        var later = storefront
        later.fetchedAt = Date(timeIntervalSince1970: 2_000)
        #expect(storefront.hasSameListing(as: later))
        later.countryCode = "USA"
        #expect(!storefront.hasSameListing(as: later))

        // A cache written before prices and offers existed still decodes.
        let old = Data(
            """
            {"id":"tokens.10","kind":{"tokens":{"_0":10}},"displayName":"10 tokens","description":"","displayPrice":"€0.99","isPurchasable":true}
            """.utf8)
        let decoded = try CanonicalJSON.decoder().decode(PaywallProduct.self, from: old)
        #expect(decoded.kind == .tokens(10) && decoded.price == nil && decoded.currencyCode == nil)
        #expect(decoded.offers.isEmpty && decoded.priceAsOf == nil && decoded.introOffer == nil && decoded.isPurchasable)

        // A corrupt price is refused rather than read as zero.
        let corrupt = Data(
            """
            {"id":"x","kind":{"lifetime":{}},"displayName":"x","description":"","displayPrice":"","price":"abc","isPurchasable":true}
            """.utf8)
        #expect(throws: DecodingError.self) { try CanonicalJSON.decoder().decode(PaywallProduct.self, from: corrupt) }
        let corruptOffer = Data(
            """
            {"kind":"introductory","paymentMode":"freeTrial","displayPrice":"","price":"nope","periodDays":7,"periodCount":1}
            """.utf8)
        #expect(throws: DecodingError.self) { try CanonicalJSON.decoder().decode(PaywallProduct.Offer.self, from: corruptOffer) }
    }

    @Test func the_catalog_validates_retired_ids_and_orders_its_entries() {
        let catalog = ProductCatalog(
            subscriptionGroupID: "g", weekly: "w", yearly: "y", lifetime: "l", tokenPacks: [TokenPack(productID: "t", tokens: 5)],
            retired: ["w", "ghost"])
        #expect(catalog.validate() == [.unknownRetiredProduct("ghost")])
        #expect(catalog.orderedProductIDs == ["w", "y", "l", "t"])
        #expect(catalog.allProductIDs == ["w", "y", "l", "t"])
        #expect(catalog.entries.map(\.isRetired) == [true, false, false, false])
        #expect(catalog.entries.map(\.kind) == [.subscription(.weekly), .subscription(.yearly), .lifetime, .tokens(5)])
        var honoured = catalog
        honoured.retired = ["w"]
        #expect(honoured.validate().isEmpty)
    }
}
