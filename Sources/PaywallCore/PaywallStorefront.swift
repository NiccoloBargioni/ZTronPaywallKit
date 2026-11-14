public import Foundation

/// The catalog as the App Store sells it right now: every declared product the storefront returned, with its price
/// and offers, in catalog order. `GateEngine.refreshStorefront()` fetches it, at launch and foreground when the last
/// one is older than `Settings.storefrontRefreshInterval` and after every purchase and restore. The engine keeps the
/// last one next to the journal, so the paywall has prices before a launch's first fetch answers, and publishes
/// `.storefrontChanged` when a fetch changes the listing.
public struct PaywallStorefront: Hashable, Codable, Sendable {
    /// What the paywall may offer: the catalog's products the store returned, less the catalog's `retired` ones.
    public var products: [PaywallProduct]
    /// Declared products the store did not return: removed from sale, not approved yet, or not sold in this
    /// storefront. Resolution and crediting still honour them. Retired products are not listed here either.
    public var unavailableProductIDs: [String]
    /// The storefront's country, ISO 3166-1 alpha-3 as `Storefront.current` reports it, when the store said.
    public var countryCode: String?
    public var fetchedAt: Date

    public init(products: [PaywallProduct], unavailableProductIDs: [String] = [], countryCode: String? = nil, fetchedAt: Date) {
        self.products = products
        self.unavailableProductIDs = unavailableProductIDs
        self.countryCode = countryCode
        self.fetchedAt = fetchedAt
    }

    public func product(_ id: String) -> PaywallProduct? { products.first { $0.id == id } }

    /// The same products, prices, offers, availability and country; the fetch time may differ.
    public func hasSameListing(as other: PaywallStorefront) -> Bool {
        products == other.products && unavailableProductIDs == other.unavailableProductIDs && countryCode == other.countryCode
    }
}
