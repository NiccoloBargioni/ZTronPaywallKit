public import Foundation

/// Compares a `ProductCatalog` with an Xcode StoreKit configuration file (`.storekit`, JSON), so the catalog in
/// code, the file used in development and App Store Connect cannot drift. The host's
/// `catalog_matches_storekit_configuration` test calls `mismatches(withStoreKitConfiguration:)` on its own file.
extension ProductCatalog {
    public enum StoreKitMismatch: Hashable, Sendable {
        /// In the catalog, absent from the file.
        case missingFromConfiguration(productID: String)
        /// In the file, absent from the catalog: a product the code would never offer or credit.
        case missingFromCatalog(productID: String)
        /// Token packs must be consumables, the lifetime product a non-consumable.
        case wrongType(productID: String, expected: String, found: String)
        /// A tier's product renews over a different period than the tier says.
        case wrongPeriod(productID: String, expected: String, found: String)
        /// Every tier belongs to one subscription group, so at most one is active.
        case subscriptionsSplitAcrossGroups([String])
    }

    public enum StoreKitConfigurationError: Error, Hashable, Sendable {
        case notAStoreKitConfiguration
    }

    public func mismatches(withStoreKitConfiguration data: Data) throws(StoreKitConfigurationError) -> [StoreKitMismatch] {
        guard let file = try? JSONDecoder().decode(StoreKitFile.self, from: data) else {
            throw .notAStoreKitConfiguration
        }
        var problems: [StoreKitMismatch] = []
        var types: [String: String] = [:]
        for product in file.products ?? [] { types[product.productID] = product.type }
        var periods: [String: String] = [:]
        let groups = file.subscriptionGroups ?? []
        for group in groups {
            for subscription in group.subscriptions ?? [] {
                types[subscription.productID] = "RecurringSubscription"
                periods[subscription.productID] = subscription.recurringSubscriptionPeriod
            }
        }

        var expected: [String: String] = [:]
        for pack in tokenPacks { expected[pack.productID] = "Consumable" }
        if let lifetimeProductID { expected[lifetimeProductID] = "NonConsumable" }
        for id in subscriptions.values { expected[id] = "RecurringSubscription" }

        for (id, type) in expected.sorted(by: { $0.key < $1.key }) {
            guard let found = types[id] else {
                problems.append(.missingFromConfiguration(productID: id))
                continue
            }
            if found != type { problems.append(.wrongType(productID: id, expected: type, found: found)) }
        }
        for id in types.keys.sorted() where expected[id] == nil {
            problems.append(.missingFromCatalog(productID: id))
        }
        for (tier, id) in subscriptions.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            guard let found = periods[id] else { continue }
            let period = Self.isoPeriod(tier)
            if found != period { problems.append(.wrongPeriod(productID: id, expected: period, found: found)) }
        }
        let ours = Set(subscriptions.values)
        let groupsWithOurs = groups.filter { group in (group.subscriptions ?? []).contains { ours.contains($0.productID) } }
        if groupsWithOurs.count > 1 {
            problems.append(.subscriptionsSplitAcrossGroups(groupsWithOurs.map(\.name).sorted()))
        }
        return problems
    }

    static func isoPeriod(_ tier: SubscriptionTier) -> String {
        switch tier {
        case .weekly: "P1W"
        case .monthly: "P1M"
        case .yearly: "P1Y"
        }
    }
}

/// The subset of the `.storekit` JSON the check reads.
private struct StoreKitFile: Decodable {
    struct Product: Decodable {
        let productID: String
        let type: String
    }

    struct Subscription: Decodable {
        let productID: String
        let recurringSubscriptionPeriod: String
    }

    struct Group: Decodable {
        let name: String
        let subscriptions: [Subscription]?
    }

    let products: [Product]?
    let subscriptionGroups: [Group]?
}
