public import Foundation
public import PaywallCore

/// Everything guideline 3.1.2(c) requires before a purchase, in one value: what you get, price, period, trial
/// length, the renewal and cancellation sentences, and the Terms and Privacy links. The paywall screen renders it
/// and the tests check it, so the two cannot drift.
public struct PaywallDisclosure: Hashable, Sendable {
    public var productID: String
    public var whatYouGet: String
    /// From `Product.displayPrice` only.
    public var price: String
    /// "per week", "per month", "per year"; `nil` for one-time purchases.
    public var period: String?
    /// "7-day free trial, then €1.99 per week"; `nil` without an introductory offer.
    public var trial: String?
    public var renewal: String?
    public var cancellation: String?
    /// Set for cached offline prices: "Price as of <date>".
    public var priceAsOf: Date?
    public var termsURL: URL
    public var privacyURL: URL

    public init(product: PaywallProduct, whatYouGet: String, termsURL: URL, privacyURL: URL) {
        self.productID = product.id
        self.whatYouGet = whatYouGet
        self.price = product.displayPrice
        self.priceAsOf = product.priceAsOf
        self.termsURL = termsURL
        self.privacyURL = privacyURL
        switch product.kind {
        case .subscription(let tier):
            let unit: String
            switch tier {
            case .weekly: unit = "week"
            case .monthly: unit = "month"
            case .yearly: unit = "year"
            }
            period = "per \(unit)"
            trial = product.introOffer.map { "\($0.trialDays)-day free trial, then \(product.displayPrice) per \(unit)" }
            renewal = "Renews automatically at \(product.displayPrice) per \(unit) unless cancelled at least 24 hours before the end of the current period."
            cancellation = "Cancel anytime in Settings › Apple Account › Subscriptions."
        case .lifetime, .tokens:
            period = nil
            trial = nil
            renewal = nil
            cancellation = nil
        }
    }

    public var isSubscription: Bool { period != nil }

    /// Every field the guideline requires for this kind of product is present.
    public var isComplete: Bool {
        guard !whatYouGet.isEmpty, !price.isEmpty else { return false }
        if isSubscription { return renewal != nil && cancellation != nil }
        return true
    }

    /// The only URLs a paywall may carry (guideline 3.1.1(a)): no external purchase links.
    public var links: [URL] { [termsURL, privacyURL] }
}
