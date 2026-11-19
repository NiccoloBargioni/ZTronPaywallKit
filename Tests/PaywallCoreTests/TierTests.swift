import Foundation
import PaywallTesting
import Testing

@testable import PaywallCore

/// The one scale the user's standing is measured on: declared in order, compared by that order, derived from the
/// entitlement and the wallet.
@Suite("Access tiers")
struct TierTests {
    @Test func the_order_is_the_declaration_order() {
        #expect(AccessTier.allCases == [.free, .freeTrial, .tokens, .weekly, .monthly, .yearly, .lifetime, .grandfathered])
        #expect(AccessTier.allCases.map(\.rank) == Array(0..<8))
        #expect(AccessTier.allCases.sorted() == AccessTier.allCases)
        #expect(AccessTier.grandfathered > .lifetime && AccessTier.lifetime > .yearly && AccessTier.yearly > .monthly)
        #expect(AccessTier.monthly > .weekly && AccessTier.weekly > .tokens && AccessTier.tokens > .freeTrial && AccessTier.freeTrial > .free)
        #expect(AccessTier.allCases.max() == .grandfathered && AccessTier.allCases.min() == .free)
        #expect(SubscriptionTier.weekly < .monthly && SubscriptionTier.monthly < .yearly)
        #expect(SubscriptionTier.allCases.map(\.accessTier) == [.weekly, .monthly, .yearly])
    }

    @Test func the_entitlement_and_the_wallet_place_the_user() {
        let now = Date()
        #expect(Entitlement.unknown.tier(wallet: .empty) == nil)
        #expect(Entitlement.free.tier(wallet: .empty) == .free)
        #expect(Entitlement.free.tier(wallet: Wallet(balance: -3)) == .free)  // in debt after a refund: nothing to spend
        #expect(Entitlement.free.tier(wallet: Wallet(balance: 1)) == .tokens)
        #expect(Entitlement.subscription(.monthly, isTrial: true, expiresAt: now).tier(wallet: Wallet(balance: 50)) == .freeTrial)
        #expect(Entitlement.subscription(.weekly, expiresAt: now).tier(wallet: .empty) == .weekly)
        #expect(Entitlement.subscription(.monthly, expiresAt: now).tier(wallet: .empty) == .monthly)
        #expect(Entitlement.subscription(.yearly, expiresAt: now).tier(wallet: Wallet(balance: 9)) == .yearly)
        #expect(Entitlement.lifetime(.purchase(transactionID: 1)).tier(wallet: .empty) == .lifetime)
        #expect(Entitlement.lifetime(.familyShared(transactionID: 1)).tier(wallet: .empty) == .lifetime)
        #expect(Entitlement.lifetime(.grandfathered(originalAppVersion: "90")).tier(wallet: .empty) == .grandfathered)
    }

    @Test func products_name_the_tier_they_buy() {
        #expect(products.map(\.tier) == [.weekly, .monthly, .yearly, .lifetime, .tokens, .tokens])
    }

    @MainActor
    @Test func the_engine_follows_the_entitlement_and_the_wallet() async throws {
        let h = try await Harness.free()
        #expect(h.engine.tier == .free)
        h.engine.grant(tokens: 3, reason: "t")
        #expect(h.engine.tier == .tokens)
        await h.store.setEntitlements([
            .subscription(id: 1, productID: "pro.yearly", purchased: h.clock.now, expires: h.clock.now.addingTimeInterval(86_400))
        ])
        await h.engine.refresh(cause: .update)
        #expect(h.engine.tier == .yearly)
        #expect((h.engine.tier ?? .free) > .tokens)
        let unanswered = try Harness()
        await unanswered.store.setReachable(false)
        let started = Task { await unanswered.start() }
        #expect(await eventually { await unanswered.store.pendingReads == 1 })
        #expect(unanswered.engine.tier == nil)
        await unanswered.store.setReachable(true)
        await started.value
        #expect(unanswered.engine.tier == .free)
    }
}
