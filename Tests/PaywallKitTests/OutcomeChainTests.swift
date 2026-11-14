import Foundation
import PaywallCore
import PaywallTesting
import Testing

@testable import PaywallKit

/// The pipeline style on the real entry points: `withPaywall` and `Paywall.purchase` hand their outcome to the
/// handlers, and what a handler sees is what the engine did.
@Suite("Outcome chains", .serialized)
@MainActor
struct OutcomeChainTests {
    @Test func withPaywall_chain_runs_onExecuted_on_an_open_gate_and_onBlocked_on_a_closed_one() async {
        let (paywall, _, _) = await makePaywall(tokens: 2)
        var exported: [String] = []
        var denied: [PaywallFailure] = []
        Paywall.$override.withValue(paywall) {
            withPaywall(.tokens(2), id: "export") { "pdf" }
                .onExecuted { exported.append($0) }
                .onBlocked { denied.append($0) }
            #expect(exported == ["pdf"])
            #expect(denied.isEmpty)
            #expect(paywall.wallet.balance == 0)
            // Empty wallet and no lease on this id: blocked, the body never runs, the handler gets the failure.
            withPaywall(.tokens(1), id: "heatmap") { exported.append("heatmap") }
                .onExecuted { exported.append("ran") }
                .onBlocked { denied.append($0) }
        }
        #expect(exported == ["pdf"])
        #expect(denied.map(\.reason) == [.insufficientTokens(needed: 1, available: 0)])
        #expect(denied.map(\.source.id) == ["heatmap"])
        // The handler holds the failure the engine published: left unclaimed, it is what the sheet receives.
        await settle()
        #expect(paywall.pendingFailure == denied.first)
    }

    @Test func claiming_from_onBlocked_keeps_the_denial_from_the_sheet() async {
        let (paywall, _, _) = await makePaywall()
        var claimed: PaywallFailure?
        Paywall.$override.withValue(paywall) {
            withPaywall(.paid, id: "pro") { 1 }
                .onExecuted { _ in Issue.record("a free user passed a paid gate") }
                .onBlocked { failure in failure.claim(); claimed = failure }
        }
        #expect(claimed?.reason == .requiresPaid)
        await settle()
        #expect(paywall.pendingFailure == nil)
    }

    @Test func async_withPaywall_chains_after_the_await() async {
        let (paywall, _, _) = await makePaywall(tokens: 1)
        var seen: [Int] = []
        await Paywall.$override.withValue(paywall) {
            await withPaywall(.tokens(1), id: "solve") { () async -> Int in 42 }
                .onExecuted { seen.append($0) }
                .onBlocked { _ in Issue.record("blocked with a token in the wallet") }
            await withPaywall(.tokens(1), id: "other") { () async -> Int in 0 }
                .onExecuted { _ in Issue.record("executed with an empty wallet") }
                .onBlocked { _ in seen.append(-1) }
        }
        #expect(seen == [42, -1])
        #expect(paywall.wallet.balance == 0)
    }

    @Test func purchase_chain_runs_the_handler_for_the_store_answer() async throws {
        let (paywall, store, _) = await makePaywall()
        let listed = try await paywall.products()
        let pack = try #require(listed.first { $0.id == "tokens.10" })
        var purchased: [UInt64] = []
        var pending = 0
        var cancelled = 0
        try await paywall.purchase(pack, source: PaywallSource(id: "export", fileID: "Tests", function: "test", line: 1))
            .onPurchaseCompleted { purchased.append($0) }
            .onPurchasePending { pending += 1 }
            .onPurchaseCancelled { cancelled += 1 }
        let issued = await store.history.last?.id
        #expect(issued != nil)
        #expect(purchased.first == issued)
        #expect(paywall.wallet.balance == 10)  // credited before the handler saw the id
        await store.setNextPurchase(.pending)
        try await paywall.purchase(pack)
            .onPurchaseCompleted { purchased.append($0) }
            .onPurchasePending { pending += 1 }
            .onPurchaseCancelled { cancelled += 1 }
        await store.setNextPurchase(.cancel)
        try await paywall.purchase(pack)
            .onPurchaseCompleted { purchased.append($0) }
            .onPurchasePending { pending += 1 }
            .onPurchaseCancelled { cancelled += 1 }
        #expect(purchased.count == 1)
        #expect(pending == 1)
        #expect(cancelled == 1)
        #expect(paywall.wallet.balance == 10)
        // A store error is thrown by `purchase` itself: no handler runs.
        await store.setNextPurchase(.fail)
        await #expect(throws: FakeStore.Failure.purchaseFailed) {
            try await paywall.purchase(pack)
                .onPurchaseCompleted { _ in Issue.record("purchased handler ran") }
                .onPurchasePending { Issue.record("pending handler ran") }
                .onPurchaseCancelled { Issue.record("cancelled handler ran") }
        }
    }
}
