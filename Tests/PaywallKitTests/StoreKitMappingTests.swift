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

    /// A10: the introductory offer is a free trial only in free-trial mode; a paid introductory period (pay as you go,
    /// pay up front) is a paying period, and a free promotional or offer-code period is not the introductory trial.
    @Test func only_a_free_trial_introductory_offer_is_a_trial() {
        #expect(StoreKit2Client.isIntroductoryFreeTrial(offerType: .introductory, paymentModeRawValue: "FREE_TRIAL"))
        #expect(!StoreKit2Client.isIntroductoryFreeTrial(offerType: .introductory, paymentModeRawValue: "PAY_UP_FRONT"))
        #expect(!StoreKit2Client.isIntroductoryFreeTrial(offerType: .introductory, paymentModeRawValue: "PAY_AS_YOU_GO"))
        #expect(!StoreKit2Client.isIntroductoryFreeTrial(offerType: .introductory, paymentModeRawValue: nil))
        #expect(!StoreKit2Client.isIntroductoryFreeTrial(offerType: .promotional, paymentModeRawValue: "FREE_TRIAL"))
        #expect(!StoreKit2Client.isIntroductoryFreeTrial(offerType: .code, paymentModeRawValue: "FREE_TRIAL"))
        #expect(!StoreKit2Client.isIntroductoryFreeTrial(offerType: nil, paymentModeRawValue: "FREE_TRIAL"))
        #expect(!StoreKit2Client.isIntroductoryFreeTrial(offerType: nil, paymentModeRawValue: nil))
    }

    /// B6: the receipt stands in only when `AppTransaction.shared` could not answer. An answer that failed
    /// verification is an answer, and a planted receipt must not override it.
    @Test func the_receipt_stands_in_only_when_the_store_could_not_answer() {
        #expect(StoreKit2Client.usesReceipt(after: .failed))
        #expect(!StoreKit2Client.usesReceipt(after: .verified))
        #expect(!StoreKit2Client.usesReceipt(after: .unverified))
    }

    /// B10: `""`, what the back-deployed `appTransactionID` reads below iOS 18.4 when the payload has none, is no id.
    @Test func an_empty_app_transaction_id_is_no_id() {
        #expect(StoreKit2Client.normalizedAppTransactionID("") == nil)
        #expect(StoreKit2Client.normalizedAppTransactionID("7000000000000001") == "7000000000000001")
    }
}
