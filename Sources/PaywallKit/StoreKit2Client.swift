public import Foundation
public import PaywallCore
import StoreKit

/// The production `StoreClient`: a thin, stateless adapter over StoreKit 2. Unverified results never leave it.
/// Exercised with `SKTestSession` and a StoreKit configuration file on the iOS Simulator lane.
///
/// Every method is `@concurrent`: StoreKit's own work and the receipt parse run off the caller's actor, so the
/// main actor's only disk I/O stays the draw path (concurrency requirement 7).
public struct StoreKit2Client: StoreClient {
    /// The iOS 15 path for the app transaction, and the fallback when `AppTransaction.shared` throws (offline, with
    /// nothing cached for this app version).
    public var receipt: ReceiptClient

    public init(receipt: ReceiptClient = ReceiptClient()) {
        self.receipt = receipt
    }

    @concurrent
    public func currentEntitlements() async throws -> [StoreTransaction] {
        var transactions: [StoreTransaction] = []
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result { transactions.append(Self.map(transaction)) }
        }
        return transactions
    }

    @concurrent
    public func allTransactions() async throws -> [StoreTransaction] {
        var transactions: [StoreTransaction] = []
        for await result in Transaction.all {
            if case .verified(let transaction) = result { transactions.append(Self.map(transaction)) }
        }
        return transactions
    }

    /// What `AppTransaction.shared` answered, reduced to the decision the receipt fallback is made on.
    enum AppTransactionAnswer: Hashable, Sendable { case verified, unverified, failed }

    /// The receipt stands in only when the store could not answer. An answer that failed verification is an answer:
    /// falling back to the receipt there would let a planted receipt override what StoreKit said about this install.
    static func usesReceipt(after answer: AppTransactionAnswer) -> Bool { answer == .failed }

    /// `""` is what the back-deployed `appTransactionID` reads on iOS 16.0 to 18.3 when the payload lacks one; the
    /// signing worker refuses an empty id, so it is no id.
    static func normalizedAppTransactionID(_ id: String) -> String? { id.isEmpty ? nil : id }

    /// `AppTransaction.shared` on iOS 16 / macOS 13, verified; the receipt when it throws (offline with nothing
    /// cached) and on iOS 15. An unverified answer is nil: the receipt never overrides a StoreKit answer. Never
    /// refreshes either: both can prompt for an Apple ID password.
    @concurrent
    public func appTransaction() async throws -> AppTransactionSnapshot? {
        if #available(iOS 16.0, macOS 13.0, *) {
            let answer: AppTransactionAnswer
            do {
                let result = try await AppTransaction.shared
                if case .verified(let app) = result {
                    return AppTransactionSnapshot(
                        bundleID: app.bundleID,
                        originalAppVersion: app.originalAppVersion,
                        originalPurchaseDate: app.originalPurchaseDate,
                        environment: Self.map(app.environment),
                        // Declared for iOS 16 and back-deployed below 18.4, where it reads the payload's own id.
                        appTransactionID: Self.normalizedAppTransactionID(app.appTransactionID),
                        origin: .appTransaction,
                        signedPayload: Data(result.jwsRepresentation.utf8))
                }
                answer = .unverified
            } catch {
                answer = .failed
            }
            guard Self.usesReceipt(after: answer) else { return nil }
        }
        return try await receipt.snapshot()
    }

    @concurrent
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

    /// Promoted in-app purchases tapped on the App Store (`PurchaseIntent`, iOS 16.4 / macOS 14.4). Older systems
    /// get a finished stream.
    @concurrent
    public func purchaseIntents() async -> AsyncStream<String> {
        AsyncStream { continuation in
            if #available(iOS 16.4, macOS 14.4, *) {
                let task = Task {
                    for await intent in PurchaseIntent.intents { continuation.yield(intent.product.id) }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            } else {
                continuation.finish()
            }
        }
    }

    /// Each product with its offers, and for a subscription whether this account can still take the introductory one.
    @concurrent
    public func products(for ids: Set<String>) async throws -> [PaywallProduct] {
        var products: [PaywallProduct] = []
        for product in try await Product.products(for: ids) {
            var eligibleForIntro: Bool?
            if let subscription = product.subscription { eligibleForIntro = await subscription.isEligibleForIntroOffer }
            products.append(Self.map(product, eligibleForIntro: eligibleForIntro))
        }
        return products
    }

    /// `Storefront.current`: the country the prices and offers are for.
    @concurrent
    public func storefrontCountryCode() async -> String? { await Storefront.current?.countryCode }

    /// With `offer`, the purchase carries `Product.PurchaseOption.promotionalOffer(_:compactJWS:)`: the JWS the app's server
    /// signed, which StoreKit forwards to the App Store. The SDK back-deploys that option to iOS 15.
    @concurrent
    public func purchase(productID: String, offer: SignedPromotionalOffer?) async throws -> StorePurchaseResult {
        guard let product = try await Product.products(for: [productID]).first else {
            throw StoreClientError.productNotFound(productID)
        }
        var options: Set<Product.PurchaseOption> = []
        if let offer { options.formUnion(Product.PurchaseOption.promotionalOffer(offer.offerID, compactJWS: offer.compactJWS)) }
        switch try await product.purchase(options: options) {
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
            // Fail closed: a result this build does not know is neither a purchase nor a cancellation.
            throw StoreClientError.unavailable("unknown purchase result")
        }
    }

    @concurrent
    public func sync() async throws {
        try await AppStore.sync()
    }

    /// Finds the transaction among the unfinished ones (purchases and updates stay there until finished).
    @concurrent
    public func finish(transactionID: UInt64) async {
        for await result in Transaction.unfinished {
            if case .verified(let transaction) = result, transaction.id == transactionID {
                await transaction.finish()
                return
            }
        }
    }

    @concurrent
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

    /// The end of the group's billing grace period, from the verified renewal info of a status in grace; nil when the
    /// group is not in grace. Read by the engine only when `currentEntitlements` lists a lapsed subscription.
    @concurrent
    public func renewalGraceEnd(groupID: String) async throws -> Date? {
        for status in try await Product.SubscriptionInfo.status(for: groupID) where status.state == .inGracePeriod {
            if case .verified(let info) = status.renewalInfo { return info.gracePeriodExpirationDate }
        }
        return nil
    }

    @concurrent
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
            isIntroductoryOffer: isIntroductoryFreeTrial(transaction),
            // A transaction does not carry the renewal preference; `subscriptionPhase` reads it on demand.
            willAutoRenew: true,
            subscriptionGroupID: transaction.subscriptionGroupID,
            ownership: transaction.ownershipType == .familyShared ? .familyShared : .purchased)
    }

    /// The transaction redeemed the introductory offer as a free trial: the offer type and its payment mode together.
    /// A paid introductory offer (pay as you go, pay up front) is a paying period, and a free promotional, offer-code
    /// or win-back period is not the introductory trial.
    static func isIntroductoryFreeTrial(_ transaction: Transaction) -> Bool {
        if #available(iOS 17.2, macOS 14.2, *) {
            return transaction.offer?.type == .introductory && transaction.offer?.paymentMode == .freeTrial
        }
        // Both back-deployed to iOS 15: the payment mode is the signed transaction's own `offerDiscountType`.
        return isIntroductoryFreeTrial(offerType: transaction.offerType, paymentModeRawValue: transaction.offerPaymentModeStringRepresentation)
    }

    /// The pure decision, over the raw values the SDK reads on every OS version (`FREE_TRIAL`, `PAY_AS_YOU_GO`,
    /// `PAY_UP_FRONT`).
    static func isIntroductoryFreeTrial(offerType: Transaction.OfferType?, paymentModeRawValue: String?) -> Bool {
        offerType == .introductory && paymentModeRawValue == "FREE_TRIAL"
    }

    @available(iOS 16.0, macOS 13.0, *)
    static func map(_ environment: AppStore.Environment) -> StoreEnvironment {
        switch environment {
        case .production: return .production
        case .sandbox: return .sandbox
        default: return .xcode
        }
    }

    /// `eligibleForIntro` is `Product.SubscriptionInfo.isEligibleForIntroOffer`, read by the caller (it is async).
    static func map(_ product: Product, eligibleForIntro: Bool?) -> PaywallProduct {
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
        var offers: [PaywallProduct.Offer] = []
        if let subscription = product.subscription {
            if let intro = subscription.introductoryOffer { offers.append(map(intro, kind: .introductory, eligible: eligibleForIntro)) }
            for offer in subscription.promotionalOffers { offers.append(map(offer, kind: .promotional, eligible: nil)) }
            // StoreKit lists the win-back offers this account is eligible for, and only those.
            if #available(iOS 18.0, macOS 15.0, *) { for offer in subscription.winBackOffers { offers.append(map(offer, kind: .winBack, eligible: true)) } }
        }
        return PaywallProduct(
            id: product.id, kind: kind, displayName: product.displayName, description: product.description,
            displayPrice: product.displayPrice, price: product.price, currencyCode: product.priceFormatStyle.currencyCode,
            introOffer: introOffer(among: offers), offers: offers)
    }

    /// The disclosure's free trial: the introductory offer, when it is a free trial this account can still redeem.
    static func introOffer(among offers: [PaywallProduct.Offer]) -> PaywallProduct.IntroOffer? {
        offers.first { $0.kind == .introductory && $0.paymentMode == .freeTrial && $0.isEligible == true }
            .map { PaywallProduct.IntroOffer(trialDays: $0.totalDays) }
    }

    static func map(_ offer: Product.SubscriptionOffer, kind: PaywallProduct.Offer.Kind, eligible: Bool?) -> PaywallProduct.Offer {
        PaywallProduct.Offer(
            kind: kind, id: offer.id, paymentMode: map(offer.paymentMode), displayPrice: offer.displayPrice, price: offer.price,
            periodDays: days(of: offer.period), periodCount: offer.periodCount, isEligible: eligible)
    }

    static func map(_ mode: Product.SubscriptionOffer.PaymentMode) -> PaywallProduct.Offer.PaymentMode {
        switch mode {
        case .freeTrial: return .freeTrial
        case .payUpFront: return .payUpFront
        default: return .payAsYouGo
        }
    }

    /// A StoreKit period in days, the unit the catalog's tiers use: a month counts 30, a year 365.
    static func days(of period: Product.SubscriptionPeriod) -> Int {
        switch period.unit {
        case .day: return period.value
        case .week: return period.value * 7
        case .month: return period.value * 30
        case .year: return period.value * 365
        @unknown default: return period.value
        }
    }
}
