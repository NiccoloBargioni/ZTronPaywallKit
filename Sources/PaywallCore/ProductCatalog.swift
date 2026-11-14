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

/// One catalog shared by code, the StoreKit configuration file and App Store Connect. Every product ever sold stays
/// declared: resolution and crediting look transactions up here, so a subscriber to a plan that is no longer
/// offered keeps resolving through it. What the paywall offers is the storefront's subset of it
/// (`PaywallStorefront`), less `retired`.
public struct ProductCatalog: Hashable, Codable, Sendable {
    /// The subscription group every tier belongs to, so at most one is active.
    public var subscriptionGroupID: String
    public var subscriptions: [SubscriptionTier: String]
    public var lifetimeProductID: String?
    public var tokenPacks: [TokenPack]
    /// Declared products the paywall no longer offers (a plan opted out of, a pack size dropped): the storefront
    /// leaves them out while their transactions still resolve and credit. Removing a product from sale in App Store
    /// Connect does the same without a release, because the store stops returning it.
    public var retired: Set<String>

    public init(
        subscriptionGroupID: String,
        weekly: String? = nil,
        monthly: String? = nil,
        yearly: String? = nil,
        lifetime: String? = nil,
        tokenPacks: [TokenPack] = [],
        retired: Set<String> = []
    ) {
        self.subscriptionGroupID = subscriptionGroupID
        var subscriptions: [SubscriptionTier: String] = [:]
        subscriptions[.weekly] = weekly
        subscriptions[.monthly] = monthly
        subscriptions[.yearly] = yearly
        self.subscriptions = subscriptions
        self.lifetimeProductID = lifetime
        self.tokenPacks = tokenPacks
        self.retired = retired
    }

    /// One declared product, in the order the paywall lists them: the tiers by period, the lifetime purchase, the
    /// packs as declared.
    public struct Entry: Hashable, Sendable {
        public var productID: String
        public var kind: PaywallProduct.Kind
        public var isRetired: Bool
    }

    public var entries: [Entry] {
        var entries: [Entry] = []
        for tier in SubscriptionTier.allCases {
            if let id = subscriptions[tier] {
                entries.append(Entry(productID: id, kind: .subscription(tier), isRetired: retired.contains(id)))
            }
        }
        if let lifetimeProductID {
            entries.append(Entry(productID: lifetimeProductID, kind: .lifetime, isRetired: retired.contains(lifetimeProductID)))
        }
        for pack in tokenPacks {
            entries.append(Entry(productID: pack.productID, kind: .tokens(pack.tokens), isRetired: retired.contains(pack.productID)))
        }
        return entries
    }

    /// Every product id, for `Product.products(for:)`.
    public var allProductIDs: Set<String> { Set(entries.map(\.productID)) }

    /// Every product id, in listing order.
    public var orderedProductIDs: [String] { entries.map(\.productID) }

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
        /// `retired` names a product the catalog does not declare.
        case unknownRetiredProduct(String)
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
        for id in retired.sorted() where !all.contains(id) { problems.append(.unknownRetiredProduct(id)) }
        return problems
    }
}

/// A product as the paywall screen shows it. Prices come only from StoreKit: `displayPrice` is the string to show,
/// `price` and `currencyCode` the figure behind it for savings maths. `offers` is what App Store Connect configured
/// on a subscription, eligible or not; the engine refreshes them with the storefront.
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

    /// An introductory, promotional or win-back offer on a subscription, as App Store Connect configured it.
    public struct Offer: Hashable, Sendable {
        public enum Kind: String, Hashable, Codable, Sendable {
            /// The one offer a new subscriber redeems automatically.
            case introductory
            /// For current and lapsed subscribers, redeemed with a signature from the app's server.
            case promotional
            /// iOS 18: for lapsed subscribers, redeemable without a signature.
            case winBack
        }

        public enum PaymentMode: String, Hashable, Codable, Sendable {
            case freeTrial, payAsYouGo, payUpFront
        }

        public var kind: Kind
        /// The offer id from App Store Connect; the introductory offer has none.
        public var id: String?
        public var paymentMode: PaymentMode
        /// What one period costs under the offer, formatted by StoreKit (a free trial shows the store's zero).
        public var displayPrice: String
        public var price: Decimal
        /// One offer period in days; `periodCount` of them in all (pay as you go bills each one).
        public var periodDays: Int
        public var periodCount: Int
        /// Whether this account can redeem it now. StoreKit answers for the introductory and win-back offers; a
        /// promotional offer's eligibility is the server's call, so `nil`.
        public var isEligible: Bool?

        public init(
            kind: Kind,
            id: String? = nil,
            paymentMode: PaymentMode,
            displayPrice: String,
            price: Decimal,
            periodDays: Int,
            periodCount: Int = 1,
            isEligible: Bool? = nil
        ) {
            self.kind = kind
            self.id = id
            self.paymentMode = paymentMode
            self.displayPrice = displayPrice
            self.price = price
            self.periodDays = periodDays
            self.periodCount = periodCount
            self.isEligible = isEligible
        }

        /// The whole offer, in days.
        public var totalDays: Int { periodDays * periodCount }
    }

    public var id: String
    public var kind: Kind
    public var displayName: String
    public var description: String
    public var displayPrice: String
    /// The figure behind `displayPrice`, in `currencyCode`; `nil` for a product built without one (a fake, an old
    /// cache).
    public var price: Decimal?
    public var currencyCode: String?
    /// Set when the price is the on-disk copy shown offline: the screen renders it with an "as of" note.
    public var priceAsOf: Date?
    /// The free trial among `offers` this account can still redeem, for the disclosure; `nil` otherwise.
    public var introOffer: IntroOffer?
    /// Every offer App Store Connect configured on the subscription; empty for one-time purchases.
    public var offers: [Offer]
    /// `false` offline: the buy button is disabled.
    public var isPurchasable: Bool

    public init(
        id: String,
        kind: Kind,
        displayName: String,
        description: String = "",
        displayPrice: String,
        price: Decimal? = nil,
        currencyCode: String? = nil,
        priceAsOf: Date? = nil,
        introOffer: IntroOffer? = nil,
        offers: [Offer] = [],
        isPurchasable: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.description = description
        self.displayPrice = displayPrice
        self.price = price
        self.currencyCode = currencyCode
        self.priceAsOf = priceAsOf
        self.introOffer = introOffer
        self.offers = offers
        self.isPurchasable = isPurchasable
    }

    /// Where the product puts its buyer: the plan's tier, `.lifetime`, or `.tokens` for a pack.
    public var tier: AccessTier {
        switch kind {
        case .subscription(let tier): return tier.accessTier
        case .lifetime: return .lifetime
        case .tokens: return .tokens
        }
    }
}

// MARK: Wire format

// By hand, for two reasons: a storefront cached before `price`, `currencyCode` and `offers` existed still decodes,
// and a price travels as its decimal string, which round-trips exactly on every OS version where a JSON number
// would not.

/// The text `Decimal.description` wrote, back; anything else is a corrupt cache, refused rather than read as zero.
private func decimal(from text: String, codingPath: [any CodingKey]) throws -> Decimal {
    guard let value = Decimal(string: text, locale: nil) else {
        throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: codingPath, debugDescription: "not a decimal: \(text)"))
    }
    return value
}

extension PaywallProduct {
    private enum CodingKeys: String, CodingKey {
        case id, kind, displayName, description, displayPrice, price, currencyCode, priceAsOf, introOffer, offers, isPurchasable
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(Kind.self, forKey: .kind)
        displayName = try container.decode(String.self, forKey: .displayName)
        description = try container.decode(String.self, forKey: .description)
        displayPrice = try container.decode(String.self, forKey: .displayPrice)
        price = try container.decodeIfPresent(String.self, forKey: .price).map { try decimal(from: $0, codingPath: container.codingPath) }
        currencyCode = try container.decodeIfPresent(String.self, forKey: .currencyCode)
        priceAsOf = try container.decodeIfPresent(Date.self, forKey: .priceAsOf)
        introOffer = try container.decodeIfPresent(IntroOffer.self, forKey: .introOffer)
        offers = try container.decodeIfPresent([Offer].self, forKey: .offers) ?? []
        isPurchasable = try container.decode(Bool.self, forKey: .isPurchasable)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(description, forKey: .description)
        try container.encode(displayPrice, forKey: .displayPrice)
        try container.encodeIfPresent(price?.description, forKey: .price)
        try container.encodeIfPresent(currencyCode, forKey: .currencyCode)
        try container.encodeIfPresent(priceAsOf, forKey: .priceAsOf)
        try container.encodeIfPresent(introOffer, forKey: .introOffer)
        try container.encode(offers, forKey: .offers)
        try container.encode(isPurchasable, forKey: .isPurchasable)
    }
}

extension PaywallProduct.Offer: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, id, paymentMode, displayPrice, price, periodDays, periodCount, isEligible
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        paymentMode = try container.decode(PaymentMode.self, forKey: .paymentMode)
        displayPrice = try container.decode(String.self, forKey: .displayPrice)
        price = try decimal(from: container.decode(String.self, forKey: .price), codingPath: container.codingPath)
        periodDays = try container.decode(Int.self, forKey: .periodDays)
        periodCount = try container.decode(Int.self, forKey: .periodCount)
        isEligible = try container.decodeIfPresent(Bool.self, forKey: .isEligible)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encode(paymentMode, forKey: .paymentMode)
        try container.encode(displayPrice, forKey: .displayPrice)
        try container.encode(price.description, forKey: .price)
        try container.encode(periodDays, forKey: .periodDays)
        try container.encode(periodCount, forKey: .periodCount)
        try container.encodeIfPresent(isEligible, forKey: .isEligible)
    }
}
