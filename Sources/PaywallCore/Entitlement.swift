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

    /// Convenience for tests and simulations: `.subscription(.weekly, isTrial: true, expiresAt: date)`.
    public static func subscription(
        _ tier: SubscriptionTier,
        productID: String? = nil,
        isTrial: Bool = false,
        expiresAt: Date? = nil,
        willAutoRenew: Bool = true,
        phase: SubscriptionPhase = .active
    ) -> Entitlement {
        .subscribed(
            Subscription(
                productID: productID ?? "pro.\(tier.rawValue)",
                tier: tier,
                expiresAt: expiresAt,
                willAutoRenew: willAutoRenew,
                isTrial: isTrial,
                phase: phase
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

/// Renewal state. Read from `Product.SubscriptionInfo.Status` only when the account screen asks for it.
public enum SubscriptionPhase: String, Hashable, Codable, Sendable {
    case active
    case inGracePeriod
    case inBillingRetryPeriod
}

public struct Subscription: Hashable, Codable, Sendable {
    public var productID: String
    public var tier: SubscriptionTier
    public var expiresAt: Date?
    public var willAutoRenew: Bool
    public var isTrial: Bool
    public var phase: SubscriptionPhase

    public init(
        productID: String,
        tier: SubscriptionTier,
        expiresAt: Date?,
        willAutoRenew: Bool = true,
        isTrial: Bool = false,
        phase: SubscriptionPhase = .active
    ) {
        self.productID = productID
        self.tier = tier
        self.expiresAt = expiresAt
        self.willAutoRenew = willAutoRenew
        self.isTrial = isTrial
        self.phase = phase
    }
}

public enum LifetimeSource: Hashable, Codable, Sendable {
    case purchase(transactionID: UInt64)
    case grandfathered(originalAppVersion: String)
}

/// Why the entitlement was re-resolved.
public enum EntitlementChangeCause: String, Hashable, Codable, Sendable {
    case launch, foreground, update, purchase, restore, revoked, expiryTimer, simulation
}
