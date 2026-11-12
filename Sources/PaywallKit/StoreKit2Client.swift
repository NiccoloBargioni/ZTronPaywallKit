import Foundation
public import PaywallCore
import StoreKit

/// The production `StoreClient`: a thin, stateless adapter over StoreKit 2. Unverified results never leave it.
/// Exercised with `SKTestSession` and a StoreKit configuration file in the host's test target.
public struct StoreKit2Client: StoreClient {
    /// The iOS 15 path for the app transaction, and the fallback when `AppTransaction` is unavailable offline.
    public var receipt: ReceiptClient

    public init(receipt: ReceiptClient = ReceiptClient()) {
        self.receipt = receipt
    }

    public func currentEntitlements() async throws -> [StoreTransaction] {
        var transactions: [StoreTransaction] = []
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result { transactions.append(Self.map(transaction)) }
        }
        return transactions
    }

    public func allTransactions() async throws -> [StoreTransaction] {
        var transactions: [StoreTransaction] = []
        for await result in Transaction.all {
            if case .verified(let transaction) = result { transactions.append(Self.map(transaction)) }
        }
        return transactions
    }

    /// `AppTransaction.shared` on iOS 16 / macOS 13, verified; otherwise, or when it throws offline, the receipt.
    /// Never refreshes either: both can prompt for an Apple ID password.
    public func appTransaction() async throws -> AppTransactionSnapshot? {
        if #available(iOS 16.0, macOS 13.0, *) {
            if let result = try? await AppTransaction.shared, case .verified(let app) = result {
                var appTransactionID: String?
                if #available(iOS 18.4, macOS 15.4, *) { appTransactionID = app.appTransactionID }
                return AppTransactionSnapshot(
                    bundleID: app.bundleID,
                    originalAppVersion: app.originalAppVersion,
                    originalPurchaseDate: app.originalPurchaseDate,
                    environment: Self.map(app.environment),
                    appTransactionID: appTransactionID,
                    origin: .appTransaction,
                    signedPayload: Data(result.jwsRepresentation.utf8))
            }
        }
        return try receipt.snapshot()
    }

    public func updates() async -> AsyncStream<StoreTransaction> {
        AsyncStream { continuation in
            let task = Task {
                for await result in Transaction.updates {
                    if case .verified(let transaction) = result { continuation.yield(Self.map(transaction)) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func products(for ids: Set<String>) async throws -> [PaywallProduct] {
        try await Product.products(for: ids).map(Self.map)
    }

    public func purchase(productID: String) async throws -> StorePurchaseResult {
        guard let product = try await Product.products(for: [productID]).first else {
            throw StoreClientError.productNotFound(productID)
        }
        switch try await product.purchase() {
        case .success(let verification):
            guard case .verified(let transaction) = verification else {
                throw StoreClientError.unavailable("unverified transaction")
            }
            return .success(Self.map(transaction))
        case .pending:
            return .pending
        case .userCancelled:
            return .userCancelled
        @unknown default:
            return .userCancelled
        }
    }

    public func sync() async throws {
        try await AppStore.sync()
    }

    /// Finds the transaction among the unfinished ones (purchases and updates stay there until finished).
    public func finish(transactionID: UInt64) async {
        for await result in Transaction.unfinished {
            if case .verified(let transaction) = result, transaction.id == transactionID {
                await transaction.finish()
                return
            }
        }
    }

    public func subscriptionPhase(groupID: String) async throws -> SubscriptionPhase? {
        let statuses = try await Product.SubscriptionInfo.status(for: groupID)
        for status in statuses {
            switch status.state {
            case .subscribed: return .active
            case .inGracePeriod: return .inGracePeriod
            case .inBillingRetryPeriod: return .inBillingRetryPeriod
            default: continue
            }
        }
        return nil
    }

    public func isEligibleForIntroOffer(groupID: String) async -> Bool {
        await Product.SubscriptionInfo.isEligibleForIntroOffer(for: groupID)
    }

    // MARK: Mapping

    static func map(_ transaction: Transaction) -> StoreTransaction {
        let type: StoreTransaction.ProductType
        switch transaction.productType {
        case .autoRenewable: type = .autoRenewable
        case .nonConsumable: type = .nonConsumable
        case .consumable: type = .consumable
        default: type = .nonRenewable
        }
        return StoreTransaction(
            id: transaction.id,
            originalID: transaction.originalID,
            productID: transaction.productID,
            productType: type,
            purchaseDate: transaction.purchaseDate,
            expirationDate: transaction.expirationDate,
            revocationDate: transaction.revocationDate,
            isUpgraded: transaction.isUpgraded,
            isIntroductoryOffer: transaction.offerType == .introductory,
            willAutoRenew: true,
            subscriptionGroupID: transaction.subscriptionGroupID)
    }

    @available(iOS 16.0, macOS 13.0, *)
    static func map(_ environment: AppStore.Environment) -> StoreEnvironment {
        switch environment {
        case .production: return .production
        case .sandbox: return .sandbox
        default: return .xcode
        }
    }

    static func map(_ product: Product) -> PaywallProduct {
        let kind: PaywallProduct.Kind
        switch product.type {
        case .autoRenewable:
            let period = product.subscription?.subscriptionPeriod
            switch period?.unit {
            case .week?, .day?: kind = .subscription(.weekly)
            case .year?: kind = .subscription(.yearly)
            default: kind = .subscription(.monthly)
            }
        case .nonConsumable: kind = .lifetime
        default: kind = .tokens(0)  // the engine replaces it with the catalog's pack size
        }
        var intro: PaywallProduct.IntroOffer?
        if let offer = product.subscription?.introductoryOffer, offer.paymentMode == .freeTrial {
            let days: Int
            switch offer.period.unit {
            case .day: days = offer.period.value
            case .week: days = offer.period.value * 7
            case .month: days = offer.period.value * 30
            case .year: days = offer.period.value * 365
            @unknown default: days = offer.period.value
            }
            intro = .init(trialDays: days)
        }
        return PaywallProduct(
            id: product.id, kind: kind, displayName: product.displayName, description: product.description,
            displayPrice: product.displayPrice, introOffer: intro)
    }
}
