import Foundation
import PaywallCore
import PaywallTesting
import Testing

/// The promotional offer path of `purchase`: the engine asks the signer for this install's signature and hands it to
/// the store, or fails the purchase before the store when it cannot. Nothing here holds a key: the fake signer answers
/// with a JWS-shaped token, and what reaches the store is checked to be exactly that.
@Suite("Promotional offers")
@MainActor
struct PromotionalOfferTests {
    static let comeback = PaywallProduct.Offer(
        kind: .promotional, id: "comeback", paymentMode: .payAsYouGo, displayPrice: "$2.99", price: Decimal(string: "2.99")!,
        periodDays: 30, periodCount: 3)
    static let trial = PaywallProduct.Offer(
        kind: .introductory, paymentMode: .freeTrial, displayPrice: "$0.00", price: 0, periodDays: 7, isEligible: true)
    static let app = AppTransactionSnapshot(
        bundleID: "com.example.app", originalAppVersion: "200", originalPurchaseDate: Date(timeIntervalSince1970: 1_700_000_000),
        environment: .production, appTransactionID: "7000000000000001", origin: .appTransaction)
    static let request = PromotionalOfferSigningRequest(
        bundleID: "com.example.app", productID: "pro.monthly", offerID: "comeback", transactionID: "7000000000000001")

    /// A started engine on a store that knows the app and dates purchases on the engine's clock, with the signer and the
    /// settings' bundle id given.
    private func harness(
        signer: FakePromotionalOfferSigner?, bundleID: String? = "com.example.app", app: AppTransactionSnapshot? = Self.app
    ) async throws -> Harness {
        let clock = FakeClock()
        let h = try Harness(
            store: FakeStore(app: app, products: products, now: { await clock.now }),
            clock: clock,
            promotionalOfferSigner: signer,
            settings: GateEngine.Settings(tolerance: 300, appVersion: "2.0", build: "200", bundleID: bundleID))
        await h.start()
        return h
    }

    @Test func a_promotional_offer_purchase_is_signed_for_this_install_then_bought_with_the_signature() async throws {
        let signer = FakePromotionalOfferSigner()
        let h = try await harness(signer: signer)
        let outcome = try await h.engine.purchase(productID: "pro.monthly", offer: Self.comeback, source: source("paywall"))
        guard case .purchased(let id) = outcome else {
            Issue.record("expected a purchase, got \(outcome)")
            return
        }
        // The request names the app, the product, the offer and the app transaction; the store got the signer's token.
        #expect(await signer.requests == [Self.request])
        let signed = SignedPromotionalOffer(productID: "pro.monthly", offerID: "comeback", compactJWS: "fake-jws.pro.monthly.comeback")
        #expect(await h.store.purchaseOffers == [signed])
        #expect(FakePromotionalOfferSigner.token(for: Self.request) == signed.compactJWS)
        if case .subscribed(let subscription) = h.engine.entitlement {
            #expect(subscription.tier == .monthly)
        } else {
            Issue.record("expected a subscription, got \(h.engine.entitlement)")
        }
        // Started, signed, completed, in that order, and the completion names the transaction.
        let stages = h.events.compactMap { event -> String? in
            switch event {
            case .purchase(.started, "pro.monthly", _, nil): return "started"
            case .promotionalOfferSigned("pro.monthly", "comeback"): return "signed"
            case .purchase(.completed, "pro.monthly", _, let transactionID) where transactionID == id: return "completed"
            default: return nil
            }
        }
        #expect(stages == ["started", "signed", "completed"])
        #expect(h.events.contains(.purchase(stage: .completed, productID: "pro.monthly", source: source("paywall"), transactionID: id)))
    }

    @Test func without_a_signer_the_purchase_fails_before_the_store() async throws {
        let h = try await harness(signer: nil)
        await #expect(throws: PromotionalOfferError.signerNotConfigured) {
            _ = try await h.engine.purchase(productID: "pro.monthly", offer: Self.comeback, source: nil)
        }
        #expect(await h.store.purchaseCalls == 0)
        #expect(h.events.contains(.purchase(stage: .failed("signerNotConfigured"), productID: "pro.monthly", source: nil, transactionID: nil)))
        #expect(!h.events.contains { if case .promotionalOfferSigned = $0 { true } else { false } })
        #expect(h.engine.entitlement == .free)
    }

    @Test func a_signer_failure_fails_the_purchase_and_nothing_is_bought() async throws {
        let signer = FakePromotionalOfferSigner(next: .fail)
        let h = try await harness(signer: signer)
        await #expect(throws: FakePromotionalOfferSigner.Failure.unreachable) {
            _ = try await h.engine.purchase(productID: "pro.monthly", offer: Self.comeback, source: nil)
        }
        #expect(await signer.requests == [Self.request])
        #expect(await h.store.purchaseCalls == 0)
        #expect(h.events.contains(.purchase(stage: .failed("unreachable"), productID: "pro.monthly", source: nil, transactionID: nil)))
        #expect(h.engine.entitlement == .free)
    }

    @Test func only_a_promotional_offer_with_an_id_is_signed() async throws {
        let signer = FakePromotionalOfferSigner()
        let h = try await harness(signer: signer)
        await #expect(throws: PromotionalOfferError.notPromotional) {
            _ = try await h.engine.purchase(productID: "pro.weekly", offer: Self.trial, source: nil)
        }
        var anonymous = Self.comeback
        anonymous.id = nil
        await #expect(throws: PromotionalOfferError.notPromotional) {
            _ = try await h.engine.purchase(productID: "pro.monthly", offer: anonymous, source: nil)
        }
        #expect(await signer.requests.isEmpty)
        #expect(await h.store.purchaseCalls == 0)
        let failed = h.events.filter { if case .purchase(.failed("notPromotional"), _, _, _) = $0 { true } else { false } }
        #expect(failed.count == 2)
    }

    @Test func the_signers_answer_must_name_the_product_and_the_offer_asked_for() async throws {
        let otherProduct = SignedPromotionalOffer(productID: "pro.yearly", offerID: "comeback", compactJWS: "x.y.z")
        let signer = FakePromotionalOfferSigner(next: .answer(otherProduct))
        let h = try await harness(signer: signer)
        await #expect(throws: PromotionalOfferError.signatureMismatch(received: otherProduct)) {
            _ = try await h.engine.purchase(productID: "pro.monthly", offer: Self.comeback, source: nil)
        }
        let otherOffer = SignedPromotionalOffer(productID: "pro.monthly", offerID: "winter", compactJWS: "x.y.z")
        await signer.setNext(.answer(otherOffer))
        await #expect(throws: PromotionalOfferError.signatureMismatch(received: otherOffer)) {
            _ = try await h.engine.purchase(productID: "pro.monthly", offer: Self.comeback, source: nil)
        }
        #expect(await signer.requests.count == 2)
        #expect(await h.store.purchaseCalls == 0)
        #expect(!h.events.contains(.promotionalOfferSigned(productID: "pro.monthly", offerID: "comeback")))
    }

    @Test func the_bundle_comes_from_the_settings_else_from_the_app_transaction() async throws {
        let signer = FakePromotionalOfferSigner()
        // No bundle id in the settings: the app transaction names the app; without an app transaction id there is no
        // transaction to bind the signature to.
        var unbound = Self.app
        unbound.appTransactionID = nil
        let fromApp = try await harness(signer: signer, bundleID: nil, app: unbound)
        _ = try await fromApp.engine.purchase(productID: "pro.monthly", offer: Self.comeback, source: nil)
        #expect(await signer.requests == [PromotionalOfferSigningRequest(bundleID: "com.example.app", productID: "pro.monthly", offerID: "comeback")])

        // The settings win over the snapshot: they are the running app's, the snapshot may be a cached one.
        let fromSettings = try await harness(signer: signer, bundleID: "com.example.app.beta")
        _ = try await fromSettings.engine.purchase(productID: "pro.monthly", offer: Self.comeback, source: nil)
        #expect(await signer.requests.last?.bundleID == "com.example.app.beta")
        #expect(await signer.requests.last?.transactionID == "7000000000000001")

        // Neither: nothing to bind the signature to, and the signer is not asked.
        let unknown = try await harness(signer: signer, bundleID: nil, app: nil)
        await #expect(throws: PromotionalOfferError.bundleIDUnknown) {
            _ = try await unknown.engine.purchase(productID: "pro.monthly", offer: Self.comeback, source: nil)
        }
        #expect(await signer.requests.count == 2)
        #expect(await unknown.store.purchaseCalls == 0)
    }

    @Test func a_plain_purchase_hands_the_store_no_offer_and_asks_no_signer() async throws {
        let signer = FakePromotionalOfferSigner()
        let h = try await harness(signer: signer)
        _ = try await h.engine.purchase(productID: "tokens.10", source: nil)
        // The protocol's convenience, a plain purchase, hands the store no offer either.
        _ = try await h.store.purchase(productID: "tokens.50")
        #expect(await h.store.purchaseOffers == [nil, nil])
        #expect(await signer.requests.isEmpty)
        #expect(h.engine.wallet.balance == 10)
    }

    @Test func the_fake_signer_is_scriptable_and_records_every_request() async throws {
        let signer = FakePromotionalOfferSigner()
        #expect(await signer.next == .sign)
        let signed = try await signer.sign(Self.request)
        #expect(signed == SignedPromotionalOffer(productID: "pro.monthly", offerID: "comeback", compactJWS: "fake-jws.pro.monthly.comeback"))
        let canned = SignedPromotionalOffer(productID: "a", offerID: "b", compactJWS: "c")
        await signer.setNext(.answer(canned))
        #expect(try await signer.sign(Self.request) == canned)
        await signer.setNext(.fail)
        await #expect(throws: FakePromotionalOfferSigner.Failure.unreachable) { _ = try await signer.sign(Self.request) }
        #expect(await signer.requests == [Self.request, Self.request, Self.request])
        #expect(await signer.next == .fail)
    }
}
