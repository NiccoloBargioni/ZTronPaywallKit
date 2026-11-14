import Foundation
import PaywallCore
import StoreKit
import Testing

@testable import PaywallKit

/// The StoreKit values a test can build (payment modes, periods, offers of our own) through the client's mapping. The
/// `Product` and `SubscriptionOffer` paths run against `SKTestSession` in the host lane.
@Suite("StoreKit 2 mapping")
struct StoreKitMappingTests {
    @Test func payment_modes_map_one_to_one() {
        #expect(StoreKit2Client.map(Product.SubscriptionOffer.PaymentMode.freeTrial) == .freeTrial)
        #expect(StoreKit2Client.map(Product.SubscriptionOffer.PaymentMode.payAsYouGo) == .payAsYouGo)
        #expect(StoreKit2Client.map(Product.SubscriptionOffer.PaymentMode.payUpFront) == .payUpFront)
    }

    @available(iOS 16.4, macOS 13.3, *)
    @Test func periods_count_in_days() {
        #expect(StoreKit2Client.days(of: .weekly) == 7)
        #expect(StoreKit2Client.days(of: .monthly) == 30)
        #expect(StoreKit2Client.days(of: .yearly) == 365)
        #expect(StoreKit2Client.days(of: .everyTwoWeeks) == 14)
        #expect(StoreKit2Client.days(of: .everyThreeDays) == 3)
        #expect(StoreKit2Client.days(of: .everySixMonths) == 180)
    }

    @Test func the_disclosures_trial_is_the_eligible_free_introductory_offer() throws {
        let trial = PaywallProduct.Offer(kind: .introductory, paymentMode: .freeTrial, displayPrice: "$0.00", price: 0, periodDays: 7, isEligible: true)
        let paid = PaywallProduct.Offer(
            kind: .introductory, paymentMode: .payUpFront, displayPrice: "$0.99", price: try #require(Decimal(string: "0.99")), periodDays: 30,
            isEligible: true)
        let promo = PaywallProduct.Offer(kind: .promotional, id: "p", paymentMode: .freeTrial, displayPrice: "$0.00", price: 0, periodDays: 14)
        #expect(StoreKit2Client.introOffer(among: [promo, trial]) == PaywallProduct.IntroOffer(trialDays: 7))
        var used = trial
        used.isEligible = false
        #expect(StoreKit2Client.introOffer(among: [used]) == nil)
        #expect(StoreKit2Client.introOffer(among: [paid]) == nil)
        #expect(StoreKit2Client.introOffer(among: []) == nil)
        var twoWeeks = trial
        twoWeeks.periodCount = 2
        #expect(StoreKit2Client.introOffer(among: [twoWeeks])?.trialDays == 14)
    }
}
