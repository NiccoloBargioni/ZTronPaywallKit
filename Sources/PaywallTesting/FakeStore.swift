// Debug builds only: the fakes compile to nothing in a release build, so an app that links `ZTronPaywallSimulator`
// (or this product) ships none of them, and a non-debug reference to one is a compile error.
#if DEBUG
    public import Foundation
    public import PaywallCore

    /// A scriptable StoreKit stand-in. Counts the calls App Review cares about (`sync`, receipt refresh) so a test
    /// can assert that launch and foreground make none.
    ///
    /// Its passive reads (`currentEntitlements`, `allTransactions`, `appTransaction`) answer like StoreKit's: from the
    /// scripted state, offline or not, and they never throw. `setReachable(false)` is the one failure StoreKit can
    /// show there, a read that never answers: the reads wait until the store is reachable again (`pendingReads` counts
    /// them), and the network calls (`products`, `purchase`, `sync`, the subscription status) fail at once.
    /// `setPassiveReadFailure(_:)` makes the passive reads throw instead: that is not StoreKit behaviour, only what a
    /// host-written `StoreClient` may do, and it is what the engine's `.storeUnavailable` path exists for.
    public actor FakeStore: StoreClient {
        public enum Failure: Error, Hashable, Sendable { case unreachable, network, purchaseFailed }

        public var entitlements: [StoreTransaction] = []
        public var history: [StoreTransaction] = []
        public var app: AppTransactionSnapshot?
        public var catalogProducts: [PaywallProduct] = []
        /// `false`: the passive reads wait, the network calls fail.
        public var isReachable = true
        public var hasNetwork = true
        public var nextPurchase: NextPurchase = .succeed
        public var phase: SubscriptionPhase?
        /// What `renewalGraceEnd(groupID:)` answers: the end of a billing grace period, or nil.
        public var graceEnd: Date?
        public var introEligible = true
        /// A failure the passive reads throw. Not StoreKit behaviour; see the type's doc.
        public var passiveReadFailure: Failure?
        /// `Storefront.current?.countryCode`: the fake sells in the US unless told otherwise.
        public var storefrontCountry: String? = "USA"
        /// `products(for:)` calls, so a test can assert when the storefront was fetched.
        public private(set) var productCalls = 0
        /// Transactions the engine has `finish()`ed, in order.
        public private(set) var finished: [UInt64] = []
        public private(set) var syncCalls = 0
        public private(set) var purchaseCalls = 0
        /// The offer each `purchase(productID:offer:)` was handed, in order: `nil` for a plain purchase.
        public private(set) var purchaseOffers: [SignedPromotionalOffer?] = []
        private var nextTransactionID: UInt64 = 1_000
        private var waiters: [CheckedContinuation<Void, Never>] = []

        public enum NextPurchase: Hashable, Sendable { case succeed, pending, cancel, fail }

        private var listeners: [UUID: AsyncStream<StoreTransaction>.Continuation] = [:]
        private var intentListeners: [UUID: AsyncStream<String>.Continuation] = [:]
        /// Dates purchases: the wall clock unless the test passes its `FakeClock` (`{ await clock.now }`), so a bought
        /// subscription expires on the clock the engine reads (the fake clock's default day is in 2027).
        public let now: @Sendable () async -> Date

        public init(
            entitlements: [StoreTransaction] = [],
            app: AppTransactionSnapshot? = nil,
            products: [PaywallProduct] = [],
            now: @escaping @Sendable () async -> Date = { Date() }
        ) {
            self.entitlements = entitlements
            self.app = app
            self.catalogProducts = products
            self.now = now
        }

        private func broadcast(_ transaction: StoreTransaction) {
            for continuation in listeners.values { continuation.yield(transaction) }
        }

        private func removeListener(_ id: UUID) { listeners[id] = nil }
        private func removeIntentListener(_ id: UUID) { intentListeners[id] = nil }

        public var listenerCount: Int { listeners.count }
        public var intentListenerCount: Int { intentListeners.count }
        /// The passive reads waiting for the store to be reachable again.
        public var pendingReads: Int { waiters.count }

        // MARK: Scripting

        public func setEntitlements(_ transactions: [StoreTransaction]) { entitlements = transactions }
        public func setApp(_ snapshot: AppTransactionSnapshot?) { app = snapshot }

        /// `false` holds every passive read until the store is reachable again; `true` releases them.
        public func setReachable(_ reachable: Bool) {
            isReachable = reachable
            guard reachable else { return }
            let waiting = waiters
            waiters = []
            for waiter in waiting { waiter.resume() }
        }

        public func setNetwork(_ network: Bool) { hasNetwork = network }
        public func setNextPurchase(_ next: NextPurchase) { nextPurchase = next }
        public func setProducts(_ products: [PaywallProduct]) { catalogProducts = products }
        public func setPhase(_ phase: SubscriptionPhase?) { self.phase = phase }
        public func setGraceEnd(_ date: Date?) { graceEnd = date }
        public func setIntroEligible(_ eligible: Bool) { introEligible = eligible }
        public func setStorefrontCountry(_ code: String?) { storefrontCountry = code }
        /// Makes the passive reads throw `failure` (`nil` stops). Models a host-written client, never StoreKit.
        public func setPassiveReadFailure(_ failure: Failure?) { passiveReadFailure = failure }
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

        /// The user tapped a promoted in-app purchase on the App Store: delivers the product id on `purchaseIntents()`.
        public func deliverPurchaseIntent(productID: String) {
            for continuation in intentListeners.values { continuation.yield(productID) }
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

        /// Waits while the store is unreachable, then throws the scripted failure if any.
        private func passiveRead() async throws {
            while !isReachable {
                await withCheckedContinuation { continuation in waiters.append(continuation) }
            }
            if let passiveReadFailure { throw passiveReadFailure }
        }

        public func currentEntitlements() async throws -> [StoreTransaction] {
            try await passiveRead()
            return entitlements
        }

        public func allTransactions() async throws -> [StoreTransaction] {
            try await passiveRead()
            return history
        }

        public func appTransaction() async throws -> AppTransactionSnapshot? {
            try await passiveRead()
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

        public func purchaseIntents() async -> AsyncStream<String> {
            let id = UUID()
            let (stream, continuation) = AsyncStream<String>.makeStream()
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeIntentListener(id) }
            }
            intentListeners[id] = continuation
            return stream
        }

        public func products(for ids: Set<String>) async throws -> [PaywallProduct] {
            productCalls += 1
            guard hasNetwork, isReachable else { throw Failure.network }
            return catalogProducts.filter { ids.contains($0.id) }
        }

        public func storefrontCountryCode() async -> String? { storefrontCountry }

        public func purchase(productID: String, offer: SignedPromotionalOffer?) async throws -> StorePurchaseResult {
            purchaseCalls += 1
            purchaseOffers.append(offer)
            guard hasNetwork, isReachable else { throw Failure.network }
            switch nextPurchase {
            case .succeed:
                let kind = catalogProducts.first { $0.id == productID }?.kind
                let now = await now()
                let type: StoreTransaction.ProductType
                var expiration: Date?
                switch kind {
                case .subscription(let tier):
                    type = .autoRenewable
                    expiration = now.addingTimeInterval(TimeInterval(tier.periodInDays) * 86_400)
                case .lifetime: type = .nonConsumable
                case .tokens, .none: type = .consumable
                }
                let transaction = StoreTransaction(
                    id: makeTransactionID(), productID: productID, productType: type, purchaseDate: now,
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

        public func renewalGraceEnd(groupID: String) async throws -> Date? {
            guard hasNetwork, isReachable else { throw Failure.network }
            return graceEnd
        }

        public func isEligibleForIntroOffer(groupID: String) async -> Bool { introEligible }
    }

    extension StoreTransaction {
        /// Test shorthand for a subscription transaction. `trial` is the introductory free trial.
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

        /// The same transaction as another family member's device reports it: shared, not bought here.
        public func familyShared() -> StoreTransaction {
            var shared = self
            shared.ownership = .familyShared
            return shared
        }

        public static func tokenPack(id: UInt64, productID: String, purchased: Date, revoked: Date? = nil) -> StoreTransaction {
            StoreTransaction(id: id, productID: productID, productType: .consumable, purchaseDate: purchased, revocationDate: revoked)
        }
    }
#endif
