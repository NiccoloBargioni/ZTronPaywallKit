import Foundation
import PaywallCore
import PaywallTesting
import Testing

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let day: TimeInterval = 86_400

private let release10 = now.addingTimeInterval(-900 * day)
private let freemiumDay = now.addingTimeInterval(-1 * day)
private let policy = GrandfatheringPolicy(
    lastPaidBuild: "116",
    paidWindow: DateInterval(start: release10, end: freemiumDay),
    legacySentinel: .init(version: "1.0", onSaleWindow: DateInterval(start: release10, end: release10.addingTimeInterval(60 * day)))
)

private func app(_ version: String, purchased: Date, env: StoreEnvironment = .production) -> AppTransactionSnapshot {
    AppTransactionSnapshot(
        bundleID: "com.ztron.app", originalAppVersion: version, originalPurchaseDate: purchased, environment: env,
        origin: .appTransaction)
}

@Suite("Entitlement resolution")
struct ResolverTests {
    let resolver = EntitlementResolver(catalog: catalog, grandfathering: policy)

    @Test func nothing_resolves_free() {
        #expect(resolver.resolve(transactions: [], appTransaction: nil, now: now).entitlement == .free)
    }

    @Test func lifetime_wins_over_a_subscription() {
        let r = resolver.resolve(
            transactions: [
                .subscription(id: 1, productID: "pro.monthly", purchased: now, expires: now.addingTimeInterval(day)),
                .lifetime(id: 2, productID: "pro.lifetime", purchased: now),
            ], appTransaction: nil, now: now)
        #expect(r.entitlement == .lifetime(.purchase(transactionID: 2)))
        #expect(r.expiresAt == nil)
    }

    @Test func revoked_expired_and_upgraded_transactions_are_dropped() {
        var revoked = StoreTransaction.lifetime(id: 1, productID: "pro.lifetime", purchased: now)
        revoked.revocationDate = now
        let r = resolver.resolve(
            transactions: [
                revoked,
                .subscription(id: 2, productID: "pro.weekly", purchased: now, expires: now.addingTimeInterval(-1)),
                .subscription(id: 3, productID: "pro.monthly", purchased: now, expires: now.addingTimeInterval(day), upgraded: true),
            ], appTransaction: nil, now: now)
        #expect(r.entitlement == .free)
    }

    @Test func trial_resolves_as_subscribed_with_isTrial() {
        let expires = now.addingTimeInterval(7 * day)
        let r = resolver.resolve(
            transactions: [.subscription(id: 1, productID: "pro.weekly", purchased: now, expires: expires, trial: true)],
            appTransaction: nil, now: now)
        #expect(r.entitlement == .subscription(.weekly, isTrial: true, expiresAt: expires))
        #expect(r.expiresAt == expires)
    }

    @Test func token_packs_never_make_a_paying_user() {
        let r = resolver.resolve(
            transactions: [.tokenPack(id: 1, productID: "tokens.10", purchased: now)], appTransaction: nil, now: now)
        #expect(r.entitlement == .free)
    }

    @Test func grandfather_grants_inside_policy() {
        let r = resolver.resolve(transactions: [], appTransaction: app("88", purchased: now.addingTimeInterval(-300 * day)), now: now)
        #expect(r.entitlement == .lifetime(.grandfathered(originalAppVersion: "88")))
        #expect(r.grandfathered != nil)
    }

    @Test func grandfathered_user_who_also_subscribes_stays_lifetime() {
        let r = resolver.resolve(
            transactions: [.subscription(id: 1, productID: "pro.yearly", purchased: now, expires: now.addingTimeInterval(day))],
            appTransaction: app("88", purchased: now.addingTimeInterval(-300 * day)), now: now)
        #expect(r.entitlement == .lifetime(.grandfathered(originalAppVersion: "88")))
    }

    @Test func build_numbers_compare_numerically() {
        // "13" > "116" as strings, but 13 < 116 as builds.
        #expect(policy.admits(app("13", purchased: now.addingTimeInterval(-300 * day))))
        #expect(!policy.admits(app("117", purchased: now.addingTimeInterval(-300 * day))))
        #expect(policy.admits(app("116", purchased: now.addingTimeInterval(-300 * day))))
    }

    @Test func purchase_outside_the_paid_window_is_not_grandfathered() {
        #expect(!policy.admits(app("88", purchased: now)))
        #expect(!policy.admits(app("88", purchased: release10.addingTimeInterval(-day))))
    }

    @Test func sandbox_is_never_grandfathered_by_default() {
        #expect(!policy.admits(app("88", purchased: now.addingTimeInterval(-300 * day), env: .sandbox)))
        #expect(!policy.admits(app("88", purchased: now.addingTimeInterval(-300 * day), env: .xcode)))
    }

    @Test func sentinel_inside_on_sale_window_is_grandfathered() {
        #expect(policy.admits(app("1.0", purchased: release10.addingTimeInterval(10 * day))))
    }

    @Test func sentinel_outside_on_sale_window_is_not_grandfathered() {
        // A reviewer's fresh install reads 1.0 with the review day as purchase date.
        #expect(!policy.admits(app("1.0", purchased: freemiumDay.addingTimeInterval(-2 * day))))
    }

    @Test func no_sentinel_never_grandfathers_1_0() {
        var noSentinel = policy
        noSentinel.legacySentinel = nil
        #expect(!noSentinel.admits(app("1.0", purchased: release10.addingTimeInterval(10 * day))))
        #expect(noSentinel.admits(app("50", purchased: release10.addingTimeInterval(10 * day))))
    }

    @Test func token_grant_policy_keeps_the_user_free() {
        var tokensPolicy = policy
        tokensPolicy.grant = .tokens(25)
        let r = EntitlementResolver(catalog: catalog, grandfathering: tokensPolicy)
            .resolve(transactions: [], appTransaction: app("88", purchased: now.addingTimeInterval(-300 * day)), now: now)
        #expect(r.entitlement == .free)
        #expect(r.grandfathered != nil)
    }

    /// Guideline 3.1.1: the resolver's only inputs are store values; enumerate every combination of the
    /// transaction kinds and assert that paying requires a lifetime, a live subscription, or a grandfathered snapshot.
    @Test func entitlement_has_no_input_but_the_store() {
        let pool: [StoreTransaction] = [
            .lifetime(id: 1, productID: "pro.lifetime", purchased: now),
            .subscription(id: 2, productID: "pro.monthly", purchased: now, expires: now.addingTimeInterval(day)),
            .subscription(id: 3, productID: "pro.weekly", purchased: now, expires: now.addingTimeInterval(-day)),
            .tokenPack(id: 4, productID: "tokens.10", purchased: now),
        ]
        for mask in 0..<(1 << pool.count) {
            let subset = pool.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
            for snapshot in [nil, app("88", purchased: now.addingTimeInterval(-300 * day)), app("1.0", purchased: now)] {
                let paying = resolver.resolve(transactions: subset, appTransaction: snapshot, now: now).entitlement.isPaying
                let expected = subset.contains { $0.id == 1 || $0.id == 2 } || snapshot?.originalAppVersion == "88"
                #expect(paying == expected)
            }
        }
    }

    /// A3: a lapsed subscription StoreKit still lists is in its billing grace period when the store says so: the row
    /// stays subscribed until the grace ends, and is free without that answer or once the end has passed.
    @Test func a_subscription_in_billing_grace_stays_subscribed_until_grace_ends() {
        let lapsed = StoreTransaction.subscription(
            id: 1, productID: "pro.monthly", purchased: now.addingTimeInterval(-30 * day), expires: now.addingTimeInterval(-day))
        let live = StoreTransaction.subscription(id: 2, productID: "pro.yearly", purchased: now, expires: now.addingTimeInterval(day))
        let graceEnd = now.addingTimeInterval(15 * day)
        #expect(resolver.needsGraceEnd(transactions: [lapsed], now: now))
        #expect(!resolver.needsGraceEnd(transactions: [], now: now))
        #expect(!resolver.needsGraceEnd(transactions: [live], now: now), "a live row needs no grace read")
        #expect(
            !resolver.needsGraceEnd(transactions: [lapsed, .lifetime(id: 3, productID: "pro.lifetime", purchased: now)], now: now),
            "nothing to ask when something else pays")
        #expect(!resolver.needsGraceEnd(transactions: [.tokenPack(id: 4, productID: "tokens.10", purchased: now)], now: now))
        let openEnded = StoreTransaction.subscription(id: 8, productID: "pro.monthly", purchased: now, expires: nil)
        #expect(!resolver.needsGraceEnd(transactions: [openEnded], now: now), "a row with no expiration pays")
        #expect(!resolver.needsGraceEnd(transactions: [openEnded, lapsed], now: now))
        let noExpiry = resolver.resolve(transactions: [openEnded], appTransaction: nil, now: now, graceEnd: graceEnd)
        #expect(noExpiry.entitlement.isPaying && noExpiry.expiresAt == nil)
        let inGrace = resolver.resolve(transactions: [lapsed], appTransaction: nil, now: now, graceEnd: graceEnd)
        guard case .subscribed(let subscription) = inGrace.entitlement else {
            Issue.record("expected a subscription in grace, got \(inGrace.entitlement)")
            return
        }
        #expect(subscription.tier == .monthly && subscription.phase == .inGracePeriod)
        #expect(subscription.expiresAt == lapsed.expirationDate, "the failed renewal date stays the expiration")
        #expect(subscription.gracePeriodEndsAt == graceEnd && subscription.accessEndsAt == graceEnd)
        #expect(inGrace.expiresAt == graceEnd, "the expiry timer is armed for the grace end")
        #expect(inGrace.entitlement.isPaying)
        #expect(resolver.resolve(transactions: [lapsed], appTransaction: nil, now: now).entitlement == .free, "without the store's answer a lapsed row is free")
        #expect(resolver.resolve(transactions: [lapsed], appTransaction: nil, now: graceEnd, graceEnd: graceEnd).entitlement == .free, "at the grace end: free")
        #expect(resolver.resolve(transactions: [lapsed], appTransaction: nil, now: now, graceEnd: now.addingTimeInterval(-1)).entitlement == .free)
        // A live row is not in grace whatever the store says, and a lapsed row never beats a live one.
        let liveResolution = resolver.resolve(transactions: [live, lapsed], appTransaction: nil, now: now, graceEnd: graceEnd)
        if case .subscribed(let s) = liveResolution.entitlement {
            #expect(s.tier == .yearly && s.phase == .active && s.gracePeriodEndsAt == nil)
        } else {
            Issue.record("expected the live subscription, got \(liveResolution.entitlement)")
        }
    }

    /// B13: the key hangs on the bundle id, the version string as written and the purchase second, and on nothing
    /// the two sources report differently (origin, the app transaction id, the signed payload, the environment).
    @Test func account_key_matches_across_sources() {
        let a = app("88", purchased: Date(timeIntervalSince1970: 1_600_000_000.7))
        var receipt = a
        receipt.origin = .receipt
        receipt.originalPurchaseDate = Date(timeIntervalSince1970: 1_600_000_000.2)
        receipt.appTransactionID = nil
        receipt.signedPayload = Data("the receipt".utf8)
        var jws = a
        jws.appTransactionID = "70000000000"
        jws.signedPayload = Data("the jws".utf8)
        jws.environment = .sandbox
        #expect(a.accountKey == receipt.accountKey)
        #expect(a.accountKey == jws.accountKey)
        #expect(a.accountKey.count == 64)
        var version = a
        version.originalAppVersion = "88.0"
        var second = a
        second.originalPurchaseDate = Date(timeIntervalSince1970: 1_600_000_001)
        var bundle = a
        bundle.bundleID = "com.ztron.other"
        #expect(Set([a, version, second, bundle].map(\.accountKey)).count == 4)
    }
}
