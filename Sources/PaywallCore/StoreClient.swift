public import Foundation

public enum StoreEnvironment: String, Hashable, Codable, CaseIterable, Sendable {
    case production, sandbox, xcode
}

/// A verified StoreKit transaction reduced to what resolution needs. Unverified results never get this far.
public struct StoreTransaction: Hashable, Codable, Sendable {
    public enum ProductType: String, Hashable, Codable, Sendable {
        case autoRenewable, nonConsumable, consumable, nonRenewable
    }

    public var id: UInt64
    public var originalID: UInt64
    public var productID: String
    public var productType: ProductType
    public var purchaseDate: Date
    public var expirationDate: Date?
    public var revocationDate: Date?
    public var isUpgraded: Bool
    /// The transaction redeemed the introductory offer (the free trial).
    public var isIntroductoryOffer: Bool
    public var willAutoRenew: Bool
    public var subscriptionGroupID: String?

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
        subscriptionGroupID: String? = nil
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
    /// `AppTransaction.appTransactionID` when the OS provides it (iOS 16+): the key a server would use.
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

    /// The ledger's account partition: SHA-256 of three values both `AppTransaction` and the receipt expose for
    /// the same Apple Account, so iOS 15 and iOS 16+ devices of one account agree on it.
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
    func products(for ids: Set<String>) async throws -> [PaywallProduct]
    func purchase(productID: String) async throws -> StorePurchaseResult
    /// `AppStore.sync()`. Can prompt for sign-in: user-initiated only.
    func sync() async throws
    /// `transaction.finish()`.
    func finish(transactionID: UInt64) async
    /// `Product.SubscriptionInfo.Status` for the group. Goes to the App Store: account screen only.
    func subscriptionPhase(groupID: String) async throws -> SubscriptionPhase?
    func isEligibleForIntroOffer(groupID: String) async -> Bool
}
