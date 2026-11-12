public import Foundation

/// A consumable token pack: one App Store product per pack size.
public struct TokenPack: Hashable, Codable, Sendable {
    public var productID: String
    public var tokens: Int

    public init(productID: String, tokens: Int) {
        self.productID = productID
        self.tokens = tokens
    }
}

/// One catalog shared by code, the StoreKit configuration file and App Store Connect.
public struct ProductCatalog: Hashable, Codable, Sendable {
    /// The subscription group every tier belongs to, so at most one is active.
    public var subscriptionGroupID: String
    public var subscriptions: [SubscriptionTier: String]
    public var lifetimeProductID: String?
    public var tokenPacks: [TokenPack]

    public init(
        subscriptionGroupID: String,
        weekly: String? = nil,
        monthly: String? = nil,
        yearly: String? = nil,
        lifetime: String? = nil,
        tokenPacks: [TokenPack] = []
    ) {
        self.subscriptionGroupID = subscriptionGroupID
        var subscriptions: [SubscriptionTier: String] = [:]
        subscriptions[.weekly] = weekly
        subscriptions[.monthly] = monthly
        subscriptions[.yearly] = yearly
        self.subscriptions = subscriptions
        self.lifetimeProductID = lifetime
        self.tokenPacks = tokenPacks
    }

    /// Every product id, for `Product.products(for:)`.
    public var allProductIDs: Set<String> {
        var ids = Set(subscriptions.values)
        if let lifetimeProductID { ids.insert(lifetimeProductID) }
        ids.formUnion(tokenPacks.map(\.productID))
        return ids
    }

    public func tier(for productID: String) -> SubscriptionTier? {
        subscriptions.first { $0.value == productID }?.key
    }

    public func tokenPack(for productID: String) -> TokenPack? {
        tokenPacks.first { $0.productID == productID }
    }

    public func kind(of productID: String) -> PaywallProduct.Kind? {
        if productID == lifetimeProductID { return .lifetime }
        if let tier = tier(for: productID) { return .subscription(tier) }
        if let pack = tokenPack(for: productID) { return .tokens(pack.tokens) }
        return nil
    }

    public enum Problem: Hashable, Sendable {
        case duplicateProductID(String)
        case emptyTokenPack(String)
        case noProducts
    }

    /// Configuration-time validation. Tier periods are fixed at seven days or more by `SubscriptionTier`.
    public func validate() -> [Problem] {
        var problems: [Problem] = []
        var all: [String] = Array(subscriptions.values) + tokenPacks.map(\.productID)
        if let lifetimeProductID { all.append(lifetimeProductID) }
        if all.isEmpty { problems.append(.noProducts) }
        var seen: Set<String> = []
        for id in all.sorted() where !seen.insert(id).inserted { problems.append(.duplicateProductID(id)) }
        for pack in tokenPacks where pack.tokens <= 0 { problems.append(.emptyTokenPack(pack.productID)) }
        return problems
    }
}

/// A product as the paywall screen shows it. Prices come only from StoreKit's `displayPrice`.
public struct PaywallProduct: Hashable, Identifiable, Sendable, Codable {
    public enum Kind: Hashable, Codable, Sendable {
        case subscription(SubscriptionTier)
        case lifetime
        case tokens(Int)
    }

    public struct IntroOffer: Hashable, Codable, Sendable {
        /// Free-trial length in days.
        public var trialDays: Int
        public init(trialDays: Int) { self.trialDays = trialDays }
    }

    public var id: String
    public var kind: Kind
    public var displayName: String
    public var description: String
    public var displayPrice: String
    /// Set when the price is the on-disk copy shown offline: the screen renders it with an "as of" note.
    public var priceAsOf: Date?
    public var introOffer: IntroOffer?
    /// `false` offline: the buy button is disabled.
    public var isPurchasable: Bool

    public init(
        id: String,
        kind: Kind,
        displayName: String,
        description: String = "",
        displayPrice: String,
        priceAsOf: Date? = nil,
        introOffer: IntroOffer? = nil,
        isPurchasable: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.description = description
        self.displayPrice = displayPrice
        self.priceAsOf = priceAsOf
        self.introOffer = introOffer
        self.isPurchasable = isPurchasable
    }
}
