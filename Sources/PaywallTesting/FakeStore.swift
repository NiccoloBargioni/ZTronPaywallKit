public import Foundation
public import PaywallCore

/// A scriptable StoreKit stand-in. Counts the calls App Review cares about (`sync`, receipt refresh) so a test
/// can assert that launch and foreground make none.
public actor FakeStore: StoreClient {
    public enum Failure: Error, Hashable, Sendable { case unreachable, network, purchaseFailed }

    public var entitlements: [StoreTransaction] = []
    public var history: [StoreTransaction] = []
    public var app: AppTransactionSnapshot?
    public var catalogProducts: [PaywallProduct] = []
    public var isReachable = true
    public var hasNetwork = true
    public var nextPurchase: NextPurchase = .succeed
    public var phase: SubscriptionPhase?
    public var introEligible = true
    /// Transactions the engine has `finish()`ed, in order.
    public private(set) var finished: [UInt64] = []
    public private(set) var syncCalls = 0
    public private(set) var purchaseCalls = 0
    private var nextTransactionID: UInt64 = 1_000

    public enum NextPurchase: Hashable, Sendable { case succeed, pending, cancel, fail }

    private var listeners: [UUID: AsyncStream<StoreTransaction>.Continuation] = [:]

    public init(
        entitlements: [StoreTransaction] = [],
        app: AppTransactionSnapshot? = nil,
        products: [PaywallProduct] = []
    ) {
        self.entitlements = entitlements
        self.app = app
        self.catalogProducts = products
    }

    private func broadcast(_ transaction: StoreTransaction) {
        for continuation in listeners.values { continuation.yield(transaction) }
    }

    private func removeListener(_ id: UUID) { listeners[id] = nil }

    public var listenerCount: Int { listeners.count }

    // MARK: Scripting

    public func setEntitlements(_ transactions: [StoreTransaction]) { entitlements = transactions }
    public func setApp(_ snapshot: AppTransactionSnapshot?) { app = snapshot }
    public func setReachable(_ reachable: Bool) { isReachable = reachable }
    public func setNetwork(_ network: Bool) { hasNetwork = network }
    public func setNextPurchase(_ next: NextPurchase) { nextPurchase = next }
    public func setProducts(_ products: [PaywallProduct]) { catalogProducts = products }
    public func setPhase(_ phase: SubscriptionPhase?) { self.phase = phase }
    public func setIntroEligible(_ eligible: Bool) { introEligible = eligible }
    public func addToHistory(_ transaction: StoreTransaction) { history.append(transaction) }

    public func makeTransactionID() -> UInt64 {
        nextTransactionID += 1
        return nextTransactionID
    }

    /// Delivers a transaction on `Transaction.updates`, like StoreKit does after a refund, a renewal, or an
    /// unfinished purchase at launch.
    public func deliver(_ transaction: StoreTransaction) {
        history.removeAll { $0.id == transaction.id }
        history.append(transaction)
        broadcast(transaction)
    }

    /// Refunds `transactionID`: removes it from current entitlements, marks it revoked in history, and delivers
    /// the revocation on updates (what `SKTestSession.refundTransaction` does).
    public func refund(_ transactionID: UInt64, at date: Date, deliver: Bool = true) {
        let original = (entitlements + history).first { $0.id == transactionID }
        entitlements.removeAll { $0.id == transactionID }
        guard var revoked = original else { return }
        revoked.revocationDate = date
        history.removeAll { $0.id == transactionID }
        history.append(revoked)
        if deliver { broadcast(revoked) }
    }

    // MARK: StoreClient

    public func currentEntitlements() async throws -> [StoreTransaction] {
        guard isReachable else { throw Failure.unreachable }
        return entitlements
    }

    public func allTransactions() async throws -> [StoreTransaction] {
        guard isReachable else { throw Failure.unreachable }
        return history
    }

    public func appTransaction() async throws -> AppTransactionSnapshot? {
        guard isReachable else { throw Failure.unreachable }
        return app
    }

    public func updates() async -> AsyncStream<StoreTransaction> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<StoreTransaction>.makeStream()
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeListener(id) }
        }
        listeners[id] = continuation
        return stream
    }

    public func products(for ids: Set<String>) async throws -> [PaywallProduct] {
        guard hasNetwork, isReachable else { throw Failure.network }
        return catalogProducts.filter { ids.contains($0.id) }
    }

    public func purchase(productID: String) async throws -> StorePurchaseResult {
        purchaseCalls += 1
        guard hasNetwork, isReachable else { throw Failure.network }
        switch nextPurchase {
        case .succeed:
            let kind = catalogProducts.first { $0.id == productID }?.kind
            let type: StoreTransaction.ProductType
            var expiration: Date?
            switch kind {
            case .subscription(let tier):
                type = .autoRenewable
                expiration = Date().addingTimeInterval(TimeInterval(tier.periodInDays) * 86_400)
            case .lifetime: type = .nonConsumable
            case .tokens, .none: type = .consumable
            }
            let transaction = StoreTransaction(
                id: makeTransactionID(), productID: productID, productType: type, purchaseDate: Date(),
                expirationDate: expiration)
            if type != .consumable { entitlements.append(transaction) }
            history.append(transaction)
            return .success(transaction)
        case .pending: return .pending
        case .cancel: return .userCancelled
        case .fail: throw Failure.purchaseFailed
        }
    }

    public func sync() async throws {
        syncCalls += 1
        guard hasNetwork, isReachable else { throw Failure.network }
    }

    public func finish(transactionID: UInt64) async { finished.append(transactionID) }

    public func subscriptionPhase(groupID: String) async throws -> SubscriptionPhase? {
        guard hasNetwork else { throw Failure.network }
        return phase
    }

    public func isEligibleForIntroOffer(groupID: String) async -> Bool { introEligible }
}

extension StoreTransaction {
    /// Test shorthand for a subscription transaction.
    public static func subscription(
        id: UInt64, productID: String, purchased: Date, expires: Date?, trial: Bool = false, upgraded: Bool = false
    ) -> StoreTransaction {
        StoreTransaction(
            id: id, productID: productID, productType: .autoRenewable, purchaseDate: purchased, expirationDate: expires,
            isUpgraded: upgraded, isIntroductoryOffer: trial)
    }

    public static func lifetime(id: UInt64, productID: String, purchased: Date) -> StoreTransaction {
        StoreTransaction(id: id, productID: productID, productType: .nonConsumable, purchaseDate: purchased)
    }

    public static func tokenPack(id: UInt64, productID: String, purchased: Date, revoked: Date? = nil) -> StoreTransaction {
        StoreTransaction(id: id, productID: productID, productType: .consumable, purchaseDate: purchased, revocationDate: revoked)
    }
}
