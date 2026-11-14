import Foundation
import Testing

@testable import PaywallCore

/// The pipeline-style handlers on the two outcome types: each runs exactly when its case matches, hands over the
/// case's payload, returns the outcome unchanged so the next call chains, and lets a throwing handler throw.
@Suite("Outcome callbacks")
struct OutcomeCallbackTests {
    private let failure = PaywallFailure(
        reason: .insufficientTokens(needed: 2, available: 0), level: .tokens(2), source: source("export"),
        at: Date(timeIntervalSince1970: 0))

    @Test func executed_outcome_runs_onExecuted_only_and_chains() {
        let outcome = PaywallOutcome<Int>.executed(7)
        var executed: [Int] = []
        var blocked: [PaywallFailure] = []
        let returned = outcome
            .onBlocked { blocked.append($0) }
            .onExecuted { executed.append($0) }
            .onExecuted { executed.append($0 * 10) }
        #expect(executed == [7, 70])
        #expect(blocked.isEmpty)
        #expect(returned == outcome)
    }

    @Test func blocked_outcome_runs_onBlocked_only_and_chains() {
        let outcome = PaywallOutcome<Int>.blocked(failure)
        var executed: [Int] = []
        var blocked: [PaywallFailure] = []
        let returned = outcome
            .onExecuted { executed.append($0) }
            .onBlocked { blocked.append($0) }
        #expect(executed.isEmpty)
        #expect(blocked == [failure])
        #expect(returned == outcome)
    }

    @Test func gate_handlers_rethrow_only_when_they_run() {
        #expect(throws: TestError.self) { try PaywallOutcome<Int>.executed(1).onExecuted { _ in throw TestError() } }
        #expect(throws: TestError.self) { try PaywallOutcome<Int>.blocked(failure).onBlocked { _ in throw TestError() } }
        #expect(throws: Never.self) { try PaywallOutcome<Int>.executed(1).onBlocked { _ in throw TestError() } }
        #expect(throws: Never.self) { try PaywallOutcome<Int>.blocked(failure).onExecuted { _ in throw TestError() } }
    }

    @Test(arguments: [PurchaseOutcome.purchased(transactionID: 42), .pending, .cancelled])
    func purchase_outcome_runs_its_own_handler_and_chains(_ outcome: PurchaseOutcome) {
        var purchased: [UInt64] = []
        var pending = 0
        var cancelled = 0
        let returned = outcome
            .onPurchaseCompleted { purchased.append($0) }
            .onPurchasePending { pending += 1 }
            .onPurchaseCancelled { cancelled += 1 }
        #expect(returned == outcome)
        switch outcome {
        case .purchased: #expect(purchased == [42] && pending == 0 && cancelled == 0)
        case .pending: #expect(purchased.isEmpty && pending == 1 && cancelled == 0)
        case .cancelled: #expect(purchased.isEmpty && pending == 0 && cancelled == 1)
        }
    }

    @Test func purchase_handlers_rethrow_only_when_they_run() {
        #expect(throws: TestError.self) { try PurchaseOutcome.purchased(transactionID: 1).onPurchaseCompleted { _ in throw TestError() } }
        #expect(throws: TestError.self) { try PurchaseOutcome.pending.onPurchasePending { throw TestError() } }
        #expect(throws: TestError.self) { try PurchaseOutcome.cancelled.onPurchaseCancelled { throw TestError() } }
        #expect(throws: Never.self) {
            try PurchaseOutcome.cancelled.onPurchaseCompleted { _ in throw TestError() }.onPurchasePending { throw TestError() }
        }
    }
}
