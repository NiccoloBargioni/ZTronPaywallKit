public import Foundation

/// Which installs keep what they paid for when the app goes freemium (guideline 3.1.2(a)).
public struct GrandfatheringPolicy: Hashable, Codable, Sendable {
    /// A real paid build whose `CFBundleVersion` equals the sandbox value `1.0`.
    public struct Sentinel: Hashable, Codable, Sendable {
        public var version: String
        public var onSaleWindow: DateInterval

        public init(version: String = "1.0", onSaleWindow: DateInterval) {
            self.version = version
            self.onSaleWindow = onSaleWindow
        }
    }

    public enum Grant: Hashable, Codable, Sendable {
        case lifetime
        case tokens(Int)
    }

    public var environments: Set<StoreEnvironment>
    /// `CFBundleVersion` of the last paid build (iOS), compared with `.numeric`.
    public var lastPaidBuild: String
    /// First paid release ..< the day the freemium build goes live.
    public var paidWindow: DateInterval
    public var legacySentinel: Sentinel?
    public var grant: Grant

    public init(
        environments: Set<StoreEnvironment> = [.production],
        lastPaidBuild: String,
        paidWindow: DateInterval,
        legacySentinel: Sentinel? = nil,
        grant: Grant = .lifetime
    ) {
        self.environments = environments
        self.lastPaidBuild = lastPaidBuild
        self.paidWindow = paidWindow
        self.legacySentinel = legacySentinel
        self.grant = grant
    }

    /// The four conditions, against one snapshot whichever API produced it.
    public func admits(_ snapshot: AppTransactionSnapshot) -> Bool {
        // 1. Production only, by default: sandbox and TestFlight always report 1.0.
        guard environments.contains(snapshot.environment) else { return false }
        // 2. Numeric comparison: a string comparison gets "2" < "13" wrong.
        guard snapshot.originalAppVersion.compare(lastPaidBuild, options: .numeric) != .orderedDescending else {
            return false
        }
        // 3. Bought while the app was paid.
        guard paidWindow.contains(snapshot.originalPurchaseDate) else { return false }
        // 4. "1.0" is also what sandbox, TestFlight and a reviewer's fresh install present: accept it only inside the
        //    sentinel's on-sale window, and never without a sentinel.
        if snapshot.originalAppVersion == (legacySentinel?.version ?? "1.0") {
            guard let legacySentinel, legacySentinel.onSaleWindow.contains(snapshot.originalPurchaseDate) else {
                return false
            }
        }
        return true
    }
}

/// What a transaction another family member bought is worth here. A value on the facade: a build that changes it
/// applies the new policy at its first resolution, and to the cached snapshot before that.
public enum FamilySharingPolicy: String, Hashable, Codable, CaseIterable, Sendable {
    /// Family-shared subscriptions and the lifetime purchase count as paying for every member. Tokens never
    /// cross members: consumables cannot be shared and the account key is per Apple Account.
    case sharedEntitlements
    /// Only transactions this Apple Account bought count; a family-shared one resolves as if absent.
    case purchaserOnly
}

/// The result of one resolution.
public struct EntitlementResolution: Hashable, Sendable {
    public var entitlement: Entitlement
    /// Set when the grandfather rule admitted the install (whatever the grant).
    public var grandfathered: AppTransactionSnapshot?
    /// The moment the subscription lapses, for the expiry timer.
    public var expiresAt: Date?
}

/// Pure: derives one `Entitlement` from verified transactions and the app transaction. Nothing else in the
/// package decides who is paying, and its only inputs are store values (guideline 3.1.1).
public struct EntitlementResolver: Sendable {
    public var catalog: ProductCatalog
    public var grandfathering: GrandfatheringPolicy?
    public var familySharing: FamilySharingPolicy

    public init(catalog: ProductCatalog, grandfathering: GrandfatheringPolicy?, familySharing: FamilySharingPolicy = .sharedEntitlements) {
        self.catalog = catalog
        self.grandfathering = grandfathering
        self.familySharing = familySharing
    }

    public func resolve(
        transactions: [StoreTransaction],
        appTransaction: AppTransactionSnapshot?,
        now: Date
    ) -> EntitlementResolution {
        // 1. Drop revoked, expired and upgraded transactions, and family-shared ones the policy refuses. The
        //    revocation filter is belt and braces.
        let live = transactions.filter { tx in
            tx.revocationDate == nil && !tx.isUpgraded && (tx.expirationDate.map { $0 > now } ?? true)
                && (familySharing == .sharedEntitlements || tx.ownership == .purchased)
        }
        let grandfathered = appTransaction.flatMap { snapshot in
            grandfathering?.admits(snapshot) == true ? snapshot : nil
        }

        // 2. The lifetime purchase wins.
        if let lifetime = live.first(where: { $0.productID == catalog.lifetimeProductID }) {
            let source: LifetimeSource =
                lifetime.ownership == .familyShared
                ? .familyShared(transactionID: lifetime.id) : .purchase(transactionID: lifetime.id)
            return EntitlementResolution(entitlement: .lifetime(source), grandfathered: grandfathered, expiresAt: nil)
        }
        // 2b. A grandfathered lifetime grant ranks with the purchase: it never expires.
        if let grandfathered, grandfathering?.grant == .lifetime {
            return EntitlementResolution(
                entitlement: .lifetime(.grandfathered(originalAppVersion: grandfathered.originalAppVersion)),
                grandfathered: grandfathered, expiresAt: nil)
        }
        // 3. A subscription in the group.
        let subscriptions = live.compactMap { tx -> (StoreTransaction, SubscriptionTier)? in
            catalog.tier(for: tx.productID).map { (tx, $0) }
        }
        if let (tx, tier) = subscriptions.max(by: { ($0.0.expirationDate ?? .distantFuture) < ($1.0.expirationDate ?? .distantFuture) }) {
            let subscription = Subscription(
                productID: tx.productID,
                tier: tier,
                expiresAt: tx.expirationDate,
                willAutoRenew: tx.willAutoRenew,
                isTrial: tx.isIntroductoryOffer,
                phase: .active,
                isFamilyShared: tx.ownership == .familyShared
            )
            return EntitlementResolution(entitlement: .subscribed(subscription), grandfathered: grandfathered, expiresAt: tx.expirationDate)
        }
        // 4–5. Free (a token grant for grandfathered installs is a ledger event, not an entitlement).
        return EntitlementResolution(entitlement: .free, grandfathered: grandfathered, expiresAt: nil)
    }
}
