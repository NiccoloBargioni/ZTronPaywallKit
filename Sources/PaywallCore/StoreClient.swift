public import Foundation

public enum StoreEnvironment: String, Hashable, Codable, CaseIterable, Sendable {
    case production, sandbox, xcode
}

/// A verified StoreKit transaction reduced to what resolution needs. Unverified results never get this far.
public struct StoreTransaction: Hashable, Codable, Sendable {
    public enum ProductType: String, Hashable, Codable, Sendable {
        case autoRenewable, nonConsumable, consumable, nonRenewable
    }

    /// `Transaction.ownershipType`: bought by this Apple Account, or shared by a family member.
    public enum Ownership: String, Hashable, Codable, Sendable {
        case purchased, familyShared
    }

    public var id: UInt64
    public var originalID: UInt64
    public var productID: String
    public var productType: ProductType
    public var purchaseDate: Date
    public var expirationDate: Date?
    public var revocationDate: Date?
    public var isUpgraded: Bool
    /// The transaction redeemed the introductory offer as a free trial. A paid introductory offer (pay as you go, pay
    /// up front) is a paying period like any other and reads `false` here: `Subscription.isTrial` and the `.freeTrial`
    /// tier come from this field.
    public var isIntroductoryOffer: Bool
    public var willAutoRenew: Bool
    public var subscriptionGroupID: String?
    public var ownership: Ownership

    public init(
        id: UInt64,
        originalID: UInt64? = nil,
        productID: String,
        productType: ProductType,
        purchaseDate: Date,
        expirationDate: Date? = nil,
        revocationDate: Date? = nil,
        isUpgraded: Bool = false,
        isIntroductoryOffer: Bool = false,
        willAutoRenew: Bool = true,
        subscriptionGroupID: String? = nil,
        ownership: Ownership = .purchased
    ) {
        self.id = id
        self.originalID = originalID ?? id
        self.productID = productID
        self.productType = productType
        self.purchaseDate = purchaseDate
        self.expirationDate = expirationDate
        self.revocationDate = revocationDate
        self.isUpgraded = isUpgraded
        self.isIntroductoryOffer = isIntroductoryOffer
        self.willAutoRenew = willAutoRenew
        self.subscriptionGroupID = subscriptionGroupID
        self.ownership = ownership
    }
}

/// The install's original purchase, from `AppTransaction` (iOS 16+) or the App Store receipt (iOS 15).
/// The grandfathering rule runs against this whichever API produced it.
public struct AppTransactionSnapshot: Hashable, Codable, Sendable {
    public enum Origin: String, Hashable, Codable, Sendable { case appTransaction, receipt, simulated }

    public var bundleID: String
    /// `CFBundleVersion` on iOS, `CFBundleShortVersionString` on macOS, `1.0` in the sandbox.
    public var originalAppVersion: String
    public var originalPurchaseDate: Date
    public var environment: StoreEnvironment
    /// `AppTransaction.appTransactionID` when the OS provides it (iOS 16 and later; the SDK back-deploys it): the key
    /// a server would use, and what a promotional offer signature is bound to. Never empty: a client that has no id
    /// passes `nil`, and the engine treats `""` as `nil`.
    public var appTransactionID: String?
    public var origin: Origin
    /// The raw signed payload (JWS or PKCS#7), kept for `exportAudit()`.
    public var signedPayload: Data?

    public init(
        bundleID: String,
        originalAppVersion: String,
        originalPurchaseDate: Date,
        environment: StoreEnvironment,
        appTransactionID: String? = nil,
        origin: Origin,
        signedPayload: Data? = nil
    ) {
        self.bundleID = bundleID
        self.originalAppVersion = originalAppVersion
        self.originalPurchaseDate = originalPurchaseDate
        self.environment = environment
        self.appTransactionID = appTransactionID
        self.origin = origin
        self.signedPayload = signedPayload
    }

    /// The ledger's account partition: SHA-256 of the bundle id, the original purchase second and the original
    /// application version, three values both `AppTransaction` and the receipt expose for the same Apple Account, so
    /// iOS 15 and iOS 16+ devices of one account are meant to agree on it. The derivation is the same for both sources;
    /// that Apple's two sources carry the same values for one install is checked by the production-receipt lane
    /// (`ProductionReceiptTests`, with `PAYWALL_PRODUCTION_APP_TRANSACTION`), not by CI.
    public var accountKey: String {
        let seconds = Int64(originalPurchaseDate.timeIntervalSince1970.rounded(.down))
        return SHA256Digest.hex("\(bundleID)|\(seconds)|\(originalAppVersion)")
    }
}

public enum StorePurchaseResult: Hashable, Sendable {
    case success(StoreTransaction)
    /// Ask to Buy or SCA: the transaction arrives later on `updates`.
    case pending
    case userCancelled
}

public enum StoreClientError: Error, Hashable, Sendable {
    case unavailable(String)
    case productNotFound(String)
    case notConfigured
}

/// The StoreKit boundary. `StoreKit2Client` adapts StoreKit 2; `FakeStore` and `SimulatedStore` drive tests and
/// development. Nothing else in the package reads the store.
public protocol StoreClient: Sendable {
    /// `Transaction.currentEntitlements`, verified results only. Served from StoreKit's on-device cache.
    func currentEntitlements() async throws -> [StoreTransaction]
    /// `Transaction.all`, verified results only, including revoked consumables.
    func allTransactions() async throws -> [StoreTransaction]
    /// `AppTransaction.shared`, or the receipt on iOS 15. `nil` when neither exists. Never prompts.
    func appTransaction() async throws -> AppTransactionSnapshot?
    /// `Transaction.updates`, verified results only. One stream per call; it is live when this returns.
    func updates() async -> AsyncStream<StoreTransaction>
    /// `PurchaseIntent.intents` (iOS 16.4+): the product ids of promoted in-app purchases the user tapped on the
    /// App Store. Empty and finished where the OS has no such API. One stream per call.
    func purchaseIntents() async -> AsyncStream<String>
    func products(for ids: Set<String>) async throws -> [PaywallProduct]
    /// `product.purchase(options:)`. With `offer`, the options carry `Product.PurchaseOption.promotionalOffer(_:compactJWS:)`:
    /// the JWS the app's server signed for this install (`PromotionalOfferSigner`), good for this one request.
    func purchase(productID: String, offer: SignedPromotionalOffer?) async throws -> StorePurchaseResult
    /// `AppStore.sync()`. Can prompt for sign-in: user-initiated only.
    func sync() async throws
    /// `transaction.finish()`.
    func finish(transactionID: UInt64) async
    /// `Product.SubscriptionInfo.Status` for the group. Goes to the App Store: account screen only.
    func subscriptionPhase(groupID: String) async throws -> SubscriptionPhase?
    /// When the group's subscription is in a billing grace period, the date the grace ends
    /// (`RenewalInfo.gracePeriodExpirationDate`); `nil` otherwise. Goes to the App Store. The engine asks only when
    /// `currentEntitlements` lists a subscription whose expiration has passed, which is what StoreKit does during
    /// grace; a read that fails offline leaves the lapsed subscription free, as before. The default answers `nil`.
    func renewalGraceEnd(groupID: String) async throws -> Date?
    func isEligibleForIntroOffer(groupID: String) async -> Bool
    /// `Storefront.current?.countryCode`: the country the prices and offers are for. `nil` where the store cannot say.
    func storefrontCountryCode() async -> String?
}

extension StoreClient {
    /// A plain purchase: no offer.
    public func purchase(productID: String) async throws -> StorePurchaseResult {
        try await purchase(productID: productID, offer: nil)
    }

    public func renewalGraceEnd(groupID: String) async throws -> Date? { nil }
}
