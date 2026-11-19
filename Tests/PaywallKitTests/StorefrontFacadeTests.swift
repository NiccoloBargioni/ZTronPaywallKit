import Foundation
import PaywallCore
import PaywallTesting
import Testing

@testable import PaywallKit

/// The facade's view of the storefront, the tier and the welcome tokens.
@Suite("Storefront, tier and welcome tokens on the facade", .serialized)
@MainActor
struct StorefrontFacadeTests {
    @Test func the_facade_publishes_the_storefront_and_the_tier() async throws {
        let (paywall, store, _) = await makePaywall()
        #expect(paywall.tier == .free)
        let storefront = try #require(paywall.storefront)
        #expect(storefront.products.map(\.id) == ["pro.weekly", "pro.monthly", "pro.yearly", "pro.lifetime", "tokens.10", "tokens.50"])
        #expect(storefront.product("tokens.10")?.kind == .tokens(10))
        paywall.grant(tokens: 2, reason: "t")
        #expect(paywall.tier == .tokens)
        var repriced = products
        repriced[3].displayPrice = "€49.99"
        await store.setProducts(repriced)
        let refreshed = try await paywall.refreshStorefront()
        #expect(refreshed.product("pro.lifetime")?.displayPrice == "€49.99")
        #expect(paywall.storefront == refreshed)
        _ = try await paywall.purchase(products[3])
        #expect(paywall.tier == .lifetime)
        #expect((paywall.tier ?? .free) > .monthly)
    }

    @Test func unconfigured_passthrough_and_torn_down_facades_have_neither() async throws {
        let unconfigured = Paywall()
        #expect(unconfigured.tier == nil && unconfigured.storefront == nil)
        await #expect(throws: StoreClientError.notConfigured) { _ = try await unconfigured.refreshStorefront() }

        let passthrough = Paywall()
        var configuration = Paywall.Configuration(catalog: catalog)
        configuration.fileKeyStore = InMemoryFileKeyStore()
        configuration.passthrough = true
        configuration.store = FakeStore(products: products)
        configuration.storageDirectory = makeTemporaryPaywallDirectory()
        configuration.includesDefaultAudit = false
        configuration.connectivity = nil
        passthrough.configure(configuration)
        let empty = try await passthrough.refreshStorefront()
        #expect(empty.products.isEmpty && passthrough.storefront == nil && passthrough.tier == nil)

        let (configured, _, _) = await makePaywall()
        #expect(configured.storefront != nil && configured.tier == .free)
        configured.configure(Paywall.Configuration(catalog: ProductCatalog(subscriptionGroupID: "g")))  // invalid: the engine goes
        #expect(configured.storefront == nil && configured.tier == nil)
    }

    @Test func a_fresh_install_gets_the_default_welcome_tokens_once() async {
        let paywall = Paywall()
        var configuration = Paywall.Configuration(catalog: catalog)
        configuration.fileKeyStore = InMemoryFileKeyStore()
        #expect(configuration.welcomeTokens == 100)
        configuration.store = FakeStore(products: products)
        configuration.clock = FakeClock()
        configuration.storageDirectory = makeTemporaryPaywallDirectory()
        configuration.includesDefaultAudit = false
        configuration.connectivity = nil
        paywall.configure(configuration)
        await paywall.waitUntilStarted()
        #expect(paywall.wallet.balance == 100)
        #expect(paywall.tier == .tokens)
        Paywall.$override.withValue(paywall) { _ = withPaywall(.tokens(25), id: "export") {} }
        // The next release ships 50 for its new users: this install keeps its 100, less the 25 it spent.
        configuration.welcomeTokens = 50
        paywall.configure(configuration)
        await paywall.waitUntilStarted()
        #expect(paywall.wallet.balance == 75)
    }
}
