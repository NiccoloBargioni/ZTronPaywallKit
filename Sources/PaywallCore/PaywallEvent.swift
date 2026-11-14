public import Foundation

/// How an open gate let the user through.
public enum GateOpenMode: Hashable, Codable, Sendable {
    /// `.free` gate.
    case free
    /// A paying entitlement passed the gate without touching the wallet.
    case paying
    /// An active lease opened the gate without a draw.
    case leased
    /// `n` tokens were drawn (a durable debit was written).
    case drawn(Int)
    /// `n` tokens are held by a view reservation; nothing is spent until commit.
    case reserved(Int)
    /// `evaluate` only: the wallet covers `n` tokens, nothing was drawn or held.
    case affordable(Int)
}

/// The outcome of one evaluation, as the audit log records it.
public enum GateDecision: Hashable, Codable, Sendable {
    case open(GateOpenMode)
    case closed(PaywallFailure.Reason)
}

public enum PurchaseStage: Hashable, Codable, Sendable {
    case started, completed, pending, cancelled
    case failed(String)
}

public enum RestoreStage: Hashable, Codable, Sendable {
    case requested, completed
    case failed(String)
}

/// Every decision the engine makes, emitted once on one stream. The return value, the sheet coordinator,
/// the preference key and the callbacks are thin adapters over this.
public enum PaywallEvent: Hashable, Codable, Sendable {
    case gateEvaluated(source: PaywallSource, level: GateLevel, decision: GateDecision)
    case gateOpened(source: PaywallSource, level: GateLevel, mode: GateOpenMode)
    case gateDenied(PaywallFailure)

    case tokensReserved(n: Int, source: PaywallSource, holder: UUID)
    case tokensReleased(n: Int, source: PaywallSource, holder: UUID)
    /// A `.reserve` gate left the screen without committing: the misuse signal from the crash-safety rules.
    case reservedWithoutCommit(source: PaywallSource, holder: UUID)
    case tokensConsumed(n: Int, source: PaywallSource, debitID: String, leaseUntil: Date)
    case tokensRefunded(debitID: String, reason: RefundReason)
    case tokensCredited(n: Int, productID: String, transactionID: UInt64)
    case tokensRevoked(transactionID: UInt64, n: Int)
    case tokensGranted(n: Int, reason: String)

    case leaseGranted(gateID: String, expiresAt: Date, holders: Int)
    case leasePinned(gateID: String, expiresAt: Date, holders: Int)
    case leaseUnpinned(gateID: String, expiresAt: Date, holders: Int)
    case leaseExtended(gateID: String, expiresAt: Date)
    case leaseExpired(gateID: String, expiresAt: Date)

    case entitlementChanged(from: Entitlement, to: Entitlement, cause: EntitlementChangeCause)
    case purchase(stage: PurchaseStage, productID: String, source: PaywallSource?, transactionID: UInt64?)
    case restore(stage: RestoreStage)
    /// The user tapped a promoted in-app purchase on the App Store (`PurchaseIntent`, iOS 16.4+). The host opens
    /// its paywall on `productID`; the engine buys nothing on its own.
    case purchaseIntent(productID: String)
    /// The signer answered for a purchase with a promotional offer: the store is about to be asked to buy with it. The
    /// `.purchase` events around it say how that went.
    case promotionalOfferSigned(productID: String, offerID: String)
    case grandfathered(originalAppVersion: String, originalPurchaseDate: Date, environment: StoreEnvironment)
    case storeUnavailable(error: String, snapshotAge: TimeInterval?)
    case syncMerged(count: Int, fromDeviceIDs: [String])
    /// A storefront fetch changed what the paywall offers, a price or an offer: the products offered now, and the
    /// storefront's country.
    case storefrontChanged(productIDs: [String], countryCode: String?)
    /// A debit found in the journal at launch had no `tokensConsumed` record: the audit was rebuilt from it.
    case auditRepaired(debitID: String)

    /// The source of a gate event, for filtering.
    public var source: PaywallSource? {
        switch self {
        case .gateEvaluated(let source, _, _), .gateOpened(let source, _, _),
            .tokensReserved(_, let source, _), .tokensReleased(_, let source, _),
            .reservedWithoutCommit(let source, _), .tokensConsumed(_, let source, _, _):
            return source
        case .gateDenied(let failure):
            return failure.source
        case .purchase(_, _, let source, _):
            return source
        default:
            return nil
        }
    }

    /// The failure carried by `.gateDenied`.
    public var failure: PaywallFailure? {
        if case .gateDenied(let failure) = self { return failure }
        return nil
    }
}
