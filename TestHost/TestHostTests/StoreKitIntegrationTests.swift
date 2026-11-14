import Combine
import CryptoKit
import Foundation
import StoreKit
import StoreKitTest
import Testing
import PaywallCore
import PaywallKit
import PaywallTesting

/// The `StoreKitIntegrationTests` lane of the design: the production `StoreKit2Client` against `SKTestSession` and
/// the package's `.storekit` file, inside an app host (StoreKit refuses purchases, `AppTransaction` and simulated
/// external purchases in a process that is not an app). Refunds, renewals at accelerated time, upgrades, Ask to Buy,
/// intro-offer eligibility, cancellation and restore, each driven through the `Paywall` facade.
///
/// StoreKit's group id is App Store Connect's numeric id (`21000000` in the file), so the catalog here names it;
/// the product ids are the ones `PaywallKitTests` checks against the same file.
final class HostBundleMarker {}

let hostCatalog = ProductCatalog(
    subscriptionGroupID: "21000000", weekly: "pro.weekly", monthly: "pro.monthly", yearly: "pro.yearly", lifetime: "pro.lifetime",
    tokenPacks: [TokenPack(productID: "tokens.10", tokens: 10), TokenPack(productID: "tokens.50", tokens: 50)])

@MainActor
private func waitUntil(_ seconds: TimeInterval = 10, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return await condition()
}

@MainActor
private final class EventLog {
    var events: [PaywallEvent] = []
    var subscription: AnyCancellable?
}

/// Every suite in the host reconfigures `Paywall.shared`, so the lane runs one test at a time.
@Suite(.serialized)
enum HostLane {}

extension HostLane {
@Suite("StoreKit integration (SKTestSession)", .serialized)
@MainActor
struct StoreKitIntegrationTests {
    /// A fresh StoreKit test environment and a freshly configured `Paywall.shared` on an empty directory. No welcome
    /// tokens unless the test asks: the balance is what it buys.
    private func start(
        timeRate: SKTestSession.TimeRate = .realTime, welcomeTokens: Int = 0, signer: (any PromotionalOfferSigner)? = nil
    ) async throws -> (SKTestSession, EventLog) {
        let url = try #require(Bundle(for: HostBundleMarker.self).url(forResource: "Paywall", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        session.timeRate = timeRate
        var configuration = Paywall.Configuration(catalog: hostCatalog)
        configuration.welcomeTokens = welcomeTokens
        configuration.storageDirectory = makeTemporaryPaywallDirectory()
        configuration.includesDefaultAudit = false
        configuration.connectivity = nil
        configuration.promotionalOfferSigner = signer
        Paywall.shared.configure(configuration)
        let log = EventLog()
        log.subscription = Paywall.shared.events.sink { log.events.append($0) }
        await Paywall.shared.waitUntilStarted()
        return (session, log)
    }

    private func product(_ id: String) async throws -> PaywallProduct {
        try #require(try await Paywall.shared.products().first { $0.id == id })
    }

    @Test func products_come_from_the_configuration_with_the_catalogs_kinds_and_the_trial() async throws {
        _ = try await start()
        let products = try await Paywall.shared.products()
        #expect(Set(products.map(\.id)) == hostCatalog.allProductIDs)
        #expect(products.first { $0.id == "tokens.50" }?.kind == .tokens(50))
        #expect(products.first { $0.id == "pro.lifetime" }?.kind == .lifetime)
        #expect(products.first { $0.id == "pro.yearly" }?.kind == .subscription(.yearly))
        #expect(products.first { $0.id == "pro.monthly" }?.kind == .subscription(.monthly))
        let weekly = try #require(products.first { $0.id == "pro.weekly" })
        #expect(weekly.kind == .subscription(.weekly))
        #expect(weekly.introOffer == .init(trialDays: 7))
        #expect(products.allSatisfy { $0.isPurchasable && !$0.displayPrice.isEmpty && $0.priceAsOf == nil })
        #expect(await Paywall.shared.isEligibleForIntroOffer())

        // Prices and offers as the configuration file has them: the figure behind the display string, the trial as
        // an eligible introductory offer, the monthly plan's promotional offer with no eligibility of its own.
        #expect(weekly.price == Decimal(string: "1.99") && weekly.currencyCode == "USD")
        #expect(products.allSatisfy { $0.price != nil && $0.currencyCode == "USD" })
        let trial = try #require(weekly.offers.first)
        #expect(weekly.offers.count == 1)
        #expect(trial.kind == .introductory && trial.paymentMode == .freeTrial && trial.id == nil)
        #expect(trial.periodDays == 7 && trial.periodCount == 1 && trial.price == 0 && trial.isEligible == true)
        let monthly = try #require(products.first { $0.id == "pro.monthly" })
        #expect(monthly.introOffer == nil)
        let comeback = try #require(monthly.offers.first { $0.kind == .promotional })
        #expect(comeback.id == "comeback" && comeback.paymentMode == .payAsYouGo && comeback.isEligible == nil)
        #expect(comeback.periodDays == 30 && comeback.periodCount == 3 && comeback.price == Decimal(string: "2.99"))
        #expect(products.first { $0.id == "tokens.10" }?.offers.isEmpty == true)

        // The launch fetched the storefront; the facade publishes it and the tier.
        let storefront = try #require(Paywall.shared.storefront)
        #expect(storefront.products.map(\.id) == ["pro.weekly", "pro.monthly", "pro.yearly", "pro.lifetime", "tokens.10", "tokens.50"])
        #expect(storefront.unavailableProductIDs.isEmpty)
        #expect(storefront.countryCode == "USA")
        #expect(Paywall.shared.tier == .free)
    }

    /// A new account gets the facade's default welcome tokens at its first launch and spends them like any others.
    @Test func a_fresh_install_gets_the_default_welcome_tokens() async throws {
        let (_, log) = try await start(welcomeTokens: Paywall.Configuration(catalog: hostCatalog).welcomeTokens)
        #expect(Paywall.shared.wallet.balance == 100)
        #expect(Paywall.shared.tier == .tokens)
        #expect(log.events.contains(.tokensGranted(n: 100, reason: "welcome")))
        #expect(withPaywall(.tokens(30), id: "export") { "pdf" }.value == "pdf")
        #expect(Paywall.shared.wallet.balance == 70)
    }

    @Test func app_transaction_binds_the_account_and_names_the_xcode_environment() async throws {
        _ = try await start()
        let engine = try #require(Paywall.shared.engine)
        #expect(engine.appTransaction?.origin == .appTransaction)
        #expect(engine.appTransaction?.environment == .xcode)
        #expect(engine.appTransaction?.bundleID == Bundle.main.bundleIdentifier)
        #expect(engine.accountKey != unboundAccountKey)
        #expect(engine.entitlement == .free)
        // The StoreKit Testing receipt is signed by Xcode's authority, not Apple's: the receipt path fails closed.
        #expect(try ReceiptClient().snapshot() == nil)
    }

    /// The design's criterion: a refund issued outside the app flips a paying user to free within a turn.
    @Test func lifetime_purchase_unlocks_and_a_refund_flips_to_free_on_updates() async throws {
        let (session, log) = try await start()
        let outcome = try await Paywall.shared.purchase(try await product("pro.lifetime"))
        guard case .purchased(let id) = outcome else { Issue.record("expected a purchase, got \(outcome)"); return }
        #expect(Paywall.shared.entitlement == .lifetime(.purchase(transactionID: id)))
        #expect(Paywall.shared.canPass(.paid) && Paywall.shared.canPass(.tokens(9)))
        #expect(log.events.contains(.purchase(stage: .completed, productID: "pro.lifetime", source: nil, transactionID: id)))
        #expect(session.allTransactions().count == 1)

        try session.refundTransaction(identifier: UInt(id))
        #expect(await waitUntil { Paywall.shared.entitlement == .free })
        #expect(log.events.contains { if case .entitlementChanged(_, .free, .revoked) = $0 { true } else { false } })
        #expect(!Paywall.shared.canPass(.paid))
    }

    @Test func token_pack_credits_before_finish_and_a_refund_revokes_the_credit() async throws {
        let (session, log) = try await start()
        let outcome = try await Paywall.shared.purchase(try await product("tokens.10"))
        guard case .purchased(let id) = outcome else { Issue.record("expected a purchase, got \(outcome)"); return }
        #expect(Paywall.shared.wallet.balance == 10)
        #expect(log.events.contains(.tokensCredited(n: 10, productID: "tokens.10", transactionID: id)))
        #expect(withPaywall(.tokens(3), id: "export") { "pdf" }.value == "pdf")
        #expect(Paywall.shared.wallet.balance == 7)

        // A refunded consumable is a revoked entry of `Transaction.all` (the host's Info.plist sets
        // `SKIncludeConsumableInAppPurchaseHistory`, as the design asks of the app), which every resolution
        // reconciles: launch, foreground, updates, expiry timer. The key exists from iOS 18: before it a finished
        // consumable leaves `Transaction.all` for good and StoreKit Testing delivers no revocation for it on
        // `Transaction.updates` either, so on iOS 17 the credit stands and only the lease path is checked.
        let engine = try #require(Paywall.shared.engine)
        let listed = try await engine.store.allTransactions().contains { $0.id == id }
        guard #available(iOS 18, *) else {
            #expect(!listed, "iOS 17 lists a finished consumable in Transaction.all after all; drop the availability gate")
            try session.refundTransaction(identifier: UInt(id))
            await Paywall.shared.refresh()
            #expect(Paywall.shared.wallet.balance == 7)
            #expect(withPaywall(.tokens(3), id: "export") { "pdf" }.value == "pdf")
            return
        }
        #expect(listed, "the finished consumable is missing from Transaction.all: SKIncludeConsumableInAppPurchaseHistory is not in the host's Info.plist")
        try session.refundTransaction(identifier: UInt(id))
        let revoked = await waitUntil(20) {
            await Paywall.shared.refresh()
            return Paywall.shared.wallet.balance == -3
        }
        let all = try await Paywall.shared.engine?.store.allTransactions() ?? []
        #expect(revoked, "refund not reconciled; Transaction.all: \(all.map { "\($0.productID)#\($0.id) revoked=\($0.revocationDate != nil)" })")
        #expect(log.events.contains(.tokensRevoked(transactionID: id, n: 10)))
        #expect(withPaywall(.tokens(1), id: "other") { 1 }.failure?.reason == .insufficientTokens(needed: 1, available: 0))
        // The lease bought before the refund still opens its gate.
        #expect(withPaywall(.tokens(3), id: "export") { "pdf" }.value == "pdf")
    }

    @Test func trial_subscription_resolves_with_isTrial_and_expiry_flips_to_free() async throws {
        let (session, log) = try await start()
        #expect(await Paywall.shared.isEligibleForIntroOffer())
        let outcome = try await Paywall.shared.purchase(try await product("pro.weekly"))
        guard case .purchased = outcome else { Issue.record("expected a purchase, got \(outcome)"); return }
        guard case .subscribed(let subscription) = Paywall.shared.entitlement else {
            Issue.record("expected a subscription, got \(Paywall.shared.entitlement)")
            return
        }
        #expect(subscription.tier == .weekly)
        #expect(subscription.isTrial)
        #expect(subscription.expiresAt != nil)
        #expect(!subscription.isFamilyShared)
        #expect(Paywall.shared.tier == .freeTrial)
        #expect(try await Paywall.shared.subscriptionPhase() == .active)
        #expect(!(await Paywall.shared.isEligibleForIntroOffer()))
        // The purchase re-fetched the storefront: the trial is used up and the disclosure no longer offers it.
        #expect(await waitUntil { Paywall.shared.storefront?.product("pro.weekly")?.offers.first?.isEligible == false })
        #expect(Paywall.shared.storefront?.product("pro.weekly")?.introOffer == nil)

        try session.expireSubscription(productIdentifier: "pro.weekly")
        await Paywall.shared.refresh()
        #expect(await waitUntil { Paywall.shared.entitlement == .free })
        #expect(log.events.contains { if case .entitlementChanged(.subscribed, .free, _) = $0 { true } else { false } })
    }

    /// 3.1.2(b): one group, so buying a higher tier upgrades; the old transaction is marked upgraded and ignored.
    @Test func one_active_subscription_after_crossgrade() async throws {
        _ = try await start()
        guard case .purchased = try await Paywall.shared.purchase(try await product("pro.monthly")) else { Issue.record("monthly"); return }
        #expect(Paywall.shared.entitlement == .subscription(.monthly, expiresAt: Paywall.shared.entitlement.expiresAt))
        guard case .purchased = try await Paywall.shared.purchase(try await product("pro.yearly")) else { Issue.record("yearly"); return }
        #expect(await waitUntil { if case .subscribed(let s) = Paywall.shared.entitlement { s.tier == .yearly } else { false } })
        let engine = try #require(Paywall.shared.engine)
        // StoreKit Testing keeps the upgraded monthly transaction in `currentEntitlements`, flagged `isUpgraded`;
        // the resolver drops it, which is why the entitlement above is the yearly one.
        let current = try await engine.store.currentEntitlements()
        #expect(current.filter { !$0.isUpgraded }.map(\.productID) == ["pro.yearly"])
        let all = try await engine.store.allTransactions()
        #expect(all.contains { $0.productID == "pro.monthly" && $0.isUpgraded })
    }

    /// Renewals at accelerated time move the expiry forward and publish the change. Three observers can be the
    /// one to notice (`Transaction.updates`, the expiry timer re-resolving at the old expiry, a foreground refresh);
    /// whichever runs first publishes it and the others find nothing changed. When the renewal lands after the old
    /// expiry (iOS 17.5's StoreKit Testing does that), the timer flips to free first and the renewal flips back.
    @Test func renewals_at_accelerated_time_move_the_expiry_and_publish_one_change() async throws {
        let (_, log) = try await start(timeRate: .oneRenewalEveryTwoSeconds)
        guard case .purchased = try await Paywall.shared.purchase(try await product("pro.monthly")) else { Issue.record("monthly"); return }
        let first = Paywall.shared.entitlement.expiresAt
        #expect(first != nil)
        let renewed = await waitUntil(30) {
            guard let later = Paywall.shared.entitlement.expiresAt, let first else { return false }
            return later > first
        }
        #expect(renewed, "no renewal observed at the accelerated rate")
        let changes = log.events.compactMap { event -> (from: Entitlement, to: Date?, cause: EntitlementChangeCause)? in
            if case .entitlementChanged(let from, let to, let cause) = event, case .subscribed = to {
                return (from, to.expiresAt, cause)
            }
            return nil
        }
        #expect(changes.contains { ($0.to ?? .distantPast) > (first ?? .distantFuture) }, "renewal changes: \(changes)")
    }

    /// 2.1(b): Ask to Buy. The purchase reports `.pending`, credits nothing, and the approval arrives on updates.
    @Test func ask_to_buy_is_pending_until_approved_then_credits_on_arrival() async throws {
        let (session, log) = try await start()
        session.askToBuyEnabled = true
        let outcome = try await Paywall.shared.purchase(try await product("tokens.10"))
        #expect(outcome == .pending)
        #expect(Paywall.shared.wallet.balance == 0)
        #expect(log.events.contains(.purchase(stage: .pending, productID: "tokens.10", source: nil, transactionID: nil)))
        let pending = try #require(session.allTransactions().first { $0.pendingAskToBuyConfirmation })
        try session.approveAskToBuyTransaction(identifier: pending.identifier)
        #expect(await waitUntil { Paywall.shared.wallet.balance == 10 })
        #expect(log.events.contains { if case .tokensCredited(10, "tokens.10", _) = $0 { true } else { false } })
    }

    @Test func a_cancelled_purchase_changes_nothing() async throws {
        let (session, log) = try await start()
        try await session.setSimulatedError(.generic(.userCancelled), forAPI: .purchase)
        defer { Task { try? await session.setSimulatedError(nil, forAPI: .purchase) } }
        do {
            let outcome = try await Paywall.shared.purchase(try await product("tokens.10"))
            #expect(outcome == .cancelled)
            #expect(log.events.contains(.purchase(stage: .cancelled, productID: "tokens.10", source: nil, transactionID: nil)))
        } catch {
            // StoreKit may surface the simulated cancellation as a thrown error: still nothing bought.
            #expect(log.events.contains { if case .purchase(.failed, "tokens.10", _, _) = $0 { true } else { false } })
        }
        #expect(Paywall.shared.wallet.balance == 0)
        #expect(Paywall.shared.entitlement == .free)
    }

    /// A purchase made outside the app (another device, the App Store) arrives on updates and is credited once.
    @Test func an_external_purchase_arrives_on_updates_and_is_finished() async throws {
        let (session, log) = try await start()
        let transaction = try await session.buyProduct(identifier: "tokens.50")
        #expect(await waitUntil { Paywall.shared.wallet.balance == 50 })
        #expect(log.events.contains(.tokensCredited(n: 50, productID: "tokens.50", transactionID: transaction.id)))
        await Paywall.shared.refresh()
        #expect(Paywall.shared.wallet.balance == 50)  // idempotent against `Transaction.all`
    }

    @Test func restore_calls_app_store_sync_and_re_resolves() async throws {
        let (_, log) = try await start()
        guard case .purchased(let id) = try await Paywall.shared.purchase(try await product("pro.lifetime")) else { Issue.record("lifetime"); return }
        try await Paywall.shared.restorePurchases()
        #expect(Paywall.shared.entitlement == .lifetime(.purchase(transactionID: id)))
        #expect(log.events.contains(.restore(stage: .completed)))
    }

    /// A lapsed subscriber takes the monthly plan's promotional offer. The signer is asked for this install's JWS (the
    /// host's bundle, the product, the offer, the app transaction id), the store buys with
    /// `Product.PurchaseOption.promotionalOffer(_:compactJWS:)`, and the transaction StoreKit reports carries the offer.
    /// With `PAYWALL_OFFER_SIGNER_URL` set the JWS comes from the worker running there (the live signer lane); otherwise
    /// from the test key pair in `Paywall.storekit`, minting the worker's exact output. Either way the local store server
    /// verifies the signature against the configuration file's key pair before it accepts the purchase.
    @Test func a_lapsed_subscriber_buys_with_the_monthly_plans_promotional_offer() async throws {
        let configuration = try #require(Bundle(for: HostBundleMarker.self).url(forResource: "Paywall", withExtension: "storekit"))
        let local = try ThrowawayPromotionalOfferSigner(configuration: configuration)
        let remote = ProcessInfo.processInfo.environment["PAYWALL_OFFER_SIGNER_URL"].flatMap(URL.init(string:))
            .map { RemotePromotionalOfferSigner(endpoint: $0.appendingPathComponent("v1/promotional-offers/sign")) }
        let (session, log) = try await start(signer: remote ?? local)
        guard case .purchased = try await Paywall.shared.purchase(try await product("pro.monthly")) else { Issue.record("monthly"); return }
        try session.expireSubscription(productIdentifier: "pro.monthly")
        await Paywall.shared.refresh()
        #expect(await waitUntil { Paywall.shared.entitlement == .free })

        let monthly = try await product("pro.monthly")
        let comeback = try #require(monthly.offers.first { $0.kind == .promotional })
        let outcome = try await Paywall.shared.purchase(monthly, promotionalOffer: comeback)
        guard case .purchased(let id) = outcome else { Issue.record("expected a purchase, got \(outcome)"); return }
        #expect(log.events.contains(.promotionalOfferSigned(productID: "pro.monthly", offerID: "comeback")))
        #expect(log.events.contains(.purchase(stage: .completed, productID: "pro.monthly", source: nil, transactionID: id)))
        if case .subscribed(let subscription) = Paywall.shared.entitlement {
            #expect(subscription.tier == .monthly)
        } else {
            Issue.record("expected a subscription, got \(Paywall.shared.entitlement)")
        }

        if remote == nil {
            // The request named this app and bound the signature to its app transaction.
            let request = try #require(await local.requests.last)
            #expect(request.bundleID == Bundle.main.bundleIdentifier)
            #expect(request.productID == "pro.monthly" && request.offerID == "comeback")
            let engine = try #require(Paywall.shared.engine)
            #expect(request.transactionID == engine.appTransaction?.appTransactionID)
            if #available(iOS 18.4, *) { #expect(request.transactionID != nil, "AppTransaction.appTransactionID binds the offer to this customer") }
        }

        // StoreKit's own record of the purchase names the offer.
        if #available(iOS 17.2, *) {
            var redeemed: (id: String?, type: Transaction.OfferType?)?
            for await result in Transaction.currentEntitlements {
                guard case .verified(let transaction) = result, transaction.id == id else { continue }
                redeemed = (transaction.offer?.id, transaction.offer?.type)
            }
            #expect(redeemed?.id == "comeback")
            #expect(redeemed?.type == .promotional)
        }
    }

    @Test func the_configuration_file_matches_the_host_catalog() throws {
        let url = try #require(Bundle(for: HostBundleMarker.self).url(forResource: "Paywall", withExtension: "storekit"))
        #expect(try hostCatalog.mismatches(withStoreKitConfiguration: Data(contentsOf: url)).isEmpty)
    }
}
}

extension Entitlement {
    fileprivate var expiresAt: Date? {
        if case .subscribed(let subscription) = self { return subscription.expiresAt }
        return nil
    }
}

/// What `Workers/PromotionalOfferSigner` mints, on the test key pair stored in `Paywall.storekit`
/// (its top-level `subscriptionOffersKeyPair`), so the lane needs no server: the ES256 compact JWS with Apple's header and
/// claims. StoreKit Testing's local store server verifies promotional offer signatures against that same key pair.
/// Records every request.
actor ThrowawayPromotionalOfferSigner: PromotionalOfferSigner {
    private let key: P256.Signing.PrivateKey
    private let keyID: String
    private(set) var requests: [PromotionalOfferSigningRequest] = []

    /// Reads the key pair (`id`, base64 PKCS#8 DER `privateKey`) from the StoreKit configuration file at `url`.
    init(configuration url: URL) throws {
        struct Configuration: Decodable {
            struct KeyPair: Decodable { var id: String; var privateKey: String }
            var subscriptionOffersKeyPair: KeyPair
        }
        let pair = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url)).subscriptionOffersKeyPair
        guard let der = Data(base64Encoded: pair.privateKey, options: .ignoreUnknownCharacters) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "privateKey is not base64"))
        }
        key = try P256.Signing.PrivateKey(derRepresentation: der)
        keyID = pair.id
    }

    func sign(_ request: PromotionalOfferSigningRequest) throws -> SignedPromotionalOffer {
        requests.append(request)
        var claims: [String: Any] = [
            "iss": "57246542-96fe-1a63-e053-0824d011072a", "iat": Int(Date().timeIntervalSince1970), "aud": "promotional-offer",
            "bid": request.bundleID, "nonce": UUID().uuidString.lowercased(), "productId": request.productID,
            "offerIdentifier": request.offerID,
        ]
        if let transactionID = request.transactionID { claims["transactionId"] = transactionID }
        let input = "\(try Self.segment(["alg": "ES256", "kid": keyID, "typ": "JWT"])).\(try Self.segment(claims))"
        let signature = try key.signature(for: Data(input.utf8)).rawRepresentation
        return SignedPromotionalOffer(productID: request.productID, offerID: request.offerID, compactJWS: "\(input).\(Self.base64URL(signature))")
    }

    private static func segment(_ object: [String: Any]) throws -> String {
        base64URL(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
