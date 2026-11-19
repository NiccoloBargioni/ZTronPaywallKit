/// What the app's server needs to sign a promotional offer for this install: the three identifiers the App Store
/// binds the signature to, and the transaction id that ties it to this customer.
public struct PromotionalOfferSigningRequest: Hashable, Codable, Sendable {
    public var bundleID: String
    public var productID: String
    /// The offer's identifier from App Store Connect (`PaywallProduct.Offer.id` of a `.promotional` offer).
    public var offerID: String
    /// `AppTransaction.appTransactionID` when the store reports it (iOS 16 and later). Apple recommends binding the
    /// signature to it; the signature is valid without it. Never empty.
    public var transactionID: String?

    public init(bundleID: String, productID: String, offerID: String, transactionID: String? = nil) {
        self.bundleID = bundleID
        self.productID = productID
        self.offerID = offerID
        self.transactionID = transactionID
    }
}

/// A promotional offer the app's server signed: the compact JWS `Product.PurchaseOption.promotionalOffer(_:compactJWS:)`
/// takes (ES256 under the In-App Purchase key, `kid` the key id; claims `iss`, `iat`, `aud: "promotional-offer"`,
/// `bid`, `nonce`, `productId`, `offerIdentifier` and the optional `transactionId`). Good for one buy request: the
/// engine asks for a fresh one at every purchase, never stores it, and never puts it in an error, an event or an audit
/// record (a mismatch names the product and offer the signer answered for, nothing more).
public struct SignedPromotionalOffer: Hashable, Codable, Sendable {
    public var productID: String
    public var offerID: String
    public var compactJWS: String

    public init(productID: String, offerID: String, compactJWS: String) {
        self.productID = productID
        self.offerID = offerID
        self.compactJWS = compactJWS
    }
}

/// Signs promotional offers with the In-App Purchase key, which stays on the server: `RemotePromotionalOfferSigner`
/// (PaywallKit) calls the worker in `Workers/PromotionalOfferSigner`; `FakePromotionalOfferSigner` (PaywallTesting)
/// scripts one. Nothing in the app ever holds the key.
public protocol PromotionalOfferSigner: Sendable {
    func sign(_ request: PromotionalOfferSigningRequest) async throws -> SignedPromotionalOffer
}

/// Why a purchase with a promotional offer never reached the store. `purchase` throws it after publishing
/// `.purchase(stage: .failed(String(describing: error)))`, like any store error: the `.failed` text reaches the audit
/// log and every sink, so a host-written signer's own errors must not embed tokens or attestations either.
public enum PromotionalOfferError: Error, Hashable, Sendable {
    /// `Paywall.Configuration.promotionalOfferSigner` is nil.
    case signerNotConfigured
    /// The offer is not a promotional offer with an id: an introductory offer applies on its own when the account is
    /// eligible, and a win-back offer takes the iOS 18 purchase option, not a signature.
    case notPromotional
    /// Neither the settings nor the app transaction name the app's bundle, so there is nothing to bind the signature to.
    case bundleIDUnknown
    /// The signer answered for another product or offer than the one asked for: these are the ids it named. The
    /// signature it sent is not kept.
    case signatureMismatch(productID: String, offerID: String)
}
