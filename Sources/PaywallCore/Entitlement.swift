public import Foundation

/// The one value StoreKit keeps current. Everything else in the package hangs off it.
public enum Entitlement: Hashable, Codable, Sendable {
    /// Before the first resolution, with no snapshot on disk. Gates fail closed.
    case unknown
    case free
    case subscribed(Subscription)
    case lifetime(LifetimeSource)

    /// Subscribed or lifetime.
    public var isPaying: Bool {
        switch self {
        case .subscribed, .lifetime: return true
        case .unknown, .free: return false
        }
    }

    /// The paying entitlement came through Family Sharing: another member of the family bought it. Only a
    /// `FamilySharingPolicy` of `.sharedEntitlements` lets such a transaction resolve to paying.
    public var isFamilyShared: Bool {
        switch self {
        case .subscribed(let subscription): return subscription.isFamilyShared
        case .lifetime(.familyShared): return true
        case .unknown, .free, .lifetime(.purchase), .lifetime(.grandfathered): return false
        }
    }

    /// Convenience for tests and simulations: `.subscription(.weekly, isTrial: true, expiresAt: date)`.
    public static func subscription(
        _ tier: SubscriptionTier,
        productID: String? = nil,
        isTrial: Bool = false,
        expiresAt: Date? = nil,
        willAutoRenew: Bool = true,
        phase: SubscriptionPhase = .active,
        isFamilyShared: Bool = false,
        gracePeriodEndsAt: Date? = nil
    ) -> Entitlement {
        .subscribed(
            Subscription(
                productID: productID ?? "pro.\(tier.rawValue)",
                tier: tier,
                expiresAt: expiresAt,
                willAutoRenew: willAutoRenew,
                isTrial: isTrial,
                phase: phase,
                isFamilyShared: isFamilyShared,
                gracePeriodEndsAt: gracePeriodEndsAt
            ))
    }
}

public enum SubscriptionTier: String, Hashable, Codable, CaseIterable, Sendable {
    case weekly, monthly, yearly

    /// The App Store's minimum period for an auto-renewable subscription is seven days (guideline 3.1.2(a)).
    public var periodInDays: Int {
        switch self {
        case .weekly: return 7
        case .monthly: return 30
        case .yearly: return 365
        }
    }
}

/// Longer periods rank higher: `.weekly < .monthly < .yearly`.
extension SubscriptionTier: Comparable {
    public static func < (lhs: SubscriptionTier, rhs: SubscriptionTier) -> Bool { lhs.periodInDays < rhs.periodInDays }

    /// The access tier a plan of this period puts a subscriber in.
    public var accessTier: AccessTier {
        switch self {
        case .weekly: return .weekly
        case .monthly: return .monthly
        case .yearly: return .yearly
        }
    }
}

/// What the user has, on one scale, lowest first. The declaration order is the order, so the tiers compare:
/// `.free < .freeTrial < .tokens < .weekly < .monthly < .yearly < .lifetime < .grandfathered`. A paywall screen
/// offers what ranks above the current tier and an account screen names it; gates never read it (`GateEngine.decide`
/// decides, and a trial opens `.paid` gates like any subscription).
public enum AccessTier: String, Hashable, Codable, CaseIterable, Sendable {
    case free
    /// A subscription in its introductory free trial, whatever its period.
    case freeTrial
    /// No subscription, a positive token balance.
    case tokens
    case weekly, monthly, yearly
    /// The lifetime purchase, bought on this account or shared by a family member.
    case lifetime
    /// A paid-era install the grandfathering policy admitted with a lifetime grant.
    case grandfathered

    /// The position in the order, `0` for `.free`.
    public var rank: Int {
        switch self {
        case .free: return 0
        case .freeTrial: return 1
        case .tokens: return 2
        case .weekly: return 3
        case .monthly: return 4
        case .yearly: return 5
        case .lifetime: return 6
        case .grandfathered: return 7
        }
    }
}

extension AccessTier: Comparable {
    public static func < (lhs: AccessTier, rhs: AccessTier) -> Bool { lhs.rank < rhs.rank }
}

extension Entitlement {
    /// The tier this entitlement puts the user in; `wallet` decides `.tokens` for a free user. `nil` while
    /// `.unknown`, so a screen shows a placeholder rather than the free tier.
    public func tier(wallet: Wallet) -> AccessTier? {
        switch self {
        case .unknown: return nil
        case .free: return wallet.balance > 0 ? .tokens : .free
        case .subscribed(let subscription): return subscription.isTrial ? .freeTrial : subscription.tier.accessTier
        case .lifetime(.grandfathered): return .grandfathered
        case .lifetime(.purchase), .lifetime(.familyShared): return .lifetime
        }
    }
}

/// Renewal state. `.inGracePeriod` is set by the resolver when StoreKit lists a lapsed subscription inside a billing
/// grace period; the account screen reads the full state from `Paywall.subscriptionPhase()`, which goes to the App Store.
public enum SubscriptionPhase: String, Hashable, Codable, Sendable {
    case active
    case inGracePeriod
    case inBillingRetryPeriod
}

public struct Subscription: Hashable, Codable, Sendable {
    public var productID: String
    public var tier: SubscriptionTier
    /// The transaction's expiration: the failed renewal date while in a billing grace period, when `gracePeriodEndsAt`
    /// is the end that counts.
    public var expiresAt: Date?
    /// A transaction does not say whether it will renew; `StoreKit2Client` reports `true` and the account screen
    /// reads the renewal state from `Paywall.subscriptionPhase()`, which goes to the App Store.
    public var willAutoRenew: Bool
    /// The subscription is in its introductory free trial. A paid introductory offer is not a trial.
    public var isTrial: Bool
    public var phase: SubscriptionPhase
    /// Bought by another family member and shared. Only the purchaser can manage it in Settings.
    public var isFamilyShared: Bool
    /// While `phase` is `.inGracePeriod`: when the grace ends and access with it, unless billing recovers first.
    public var gracePeriodEndsAt: Date?

    /// The moment access lapses: the grace end during a billing grace period, the expiration otherwise.
    public var accessEndsAt: Date? { gracePeriodEndsAt ?? expiresAt }

    public init(
        productID: String,
        tier: SubscriptionTier,
        expiresAt: Date?,
        willAutoRenew: Bool = true,
        isTrial: Bool = false,
        phase: SubscriptionPhase = .active,
        isFamilyShared: Bool = false,
        gracePeriodEndsAt: Date? = nil
    ) {
        self.productID = productID
        self.tier = tier
        self.expiresAt = expiresAt
        self.willAutoRenew = willAutoRenew
        self.isTrial = isTrial
        self.phase = phase
        self.isFamilyShared = isFamilyShared
        self.gracePeriodEndsAt = gracePeriodEndsAt
    }

    private enum CodingKeys: String, CodingKey {
        case productID, tier, expiresAt, willAutoRenew, isTrial, phase, isFamilyShared, gracePeriodEndsAt
    }

    /// Snapshots written before `isFamilyShared` or `gracePeriodEndsAt` existed decode as the purchaser's own, with
    /// no grace period.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        productID = try container.decode(String.self, forKey: .productID)
        tier = try container.decode(SubscriptionTier.self, forKey: .tier)
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        willAutoRenew = try container.decode(Bool.self, forKey: .willAutoRenew)
        isTrial = try container.decode(Bool.self, forKey: .isTrial)
        phase = try container.decode(SubscriptionPhase.self, forKey: .phase)
        isFamilyShared = try container.decodeIfPresent(Bool.self, forKey: .isFamilyShared) ?? false
        gracePeriodEndsAt = try container.decodeIfPresent(Date.self, forKey: .gracePeriodEndsAt)
    }
}

public enum LifetimeSource: Hashable, Codable, Sendable {
    case purchase(transactionID: UInt64)
    /// The lifetime purchase of another family member, shared with this account.
    case familyShared(transactionID: UInt64)
    case grandfathered(originalAppVersion: String)
}

/// Why the entitlement was re-resolved.
public enum EntitlementChangeCause: String, Hashable, Codable, Sendable {
    case launch, foreground, update, purchase, restore, revoked, expiryTimer, simulation
}
