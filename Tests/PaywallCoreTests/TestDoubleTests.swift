import Foundation
import PaywallTesting
import Testing

@testable import PaywallCore

/// The fakes count toward coverage like any other code, and on Linux only this target exercises them.
@Suite("Test doubles and wire format", .serialized)
@MainActor
struct TestDoubleTests {
    @Test func ledger_events_round_trip_through_canonical_data() throws {
        let event = LedgerEvent(
            id: "debit:1", at: Date(timeIntervalSince1970: 100), deviceID: "A", accountKey: "k", source: source("g"),
            previousHash: paywallGenesisHash, kind: .debit(tokens: 2, leaseUntil: Date(timeIntervalSince1970: 400)))
        let data = try event.canonicalData()
        #expect(try LedgerEvent(canonicalData: data) == event)
        #expect(try event.canonicalData() == data)  // canonical: the same bytes every time
        #expect(throws: (any Error).self) { try LedgerEvent(canonicalData: Data("{}".utf8)) }
    }

    @Test func fake_store_failure_paths() async throws {
        let store = FakeStore(products: products)
        let pack = StoreTransaction.tokenPack(id: 1, productID: "tokens.10", purchased: Date())
        await store.deliver(pack)
        await store.deliver(pack)  // re-delivery replaces, never duplicates
        #expect(try await store.allTransactions().map(\.id) == [1])
        await store.refund(99, at: Date())  // unknown transaction: nothing happens
        #expect(try await store.allTransactions().allSatisfy { $0.revocationDate == nil })

        // Scripted subscription state, as SKTestSession would report it.
        await store.setPhase(.inGracePeriod)
        await store.setIntroEligible(false)
        #expect(try await store.subscriptionPhase(groupID: "pro") == .inGracePeriod)
        #expect(await !store.isEligibleForIntroOffer(groupID: "pro"))
        guard case .success(let bought) = try await store.purchase(productID: "pro.monthly") else {
            Issue.record("expected a purchase")
            return
        }
        #expect(bought.productType == .autoRenewable && bought.expirationDate != nil)
        let updates = await store.updates()
        #expect(await store.listenerCount == 1)
        _ = updates

        await store.setNetwork(false)
        await #expect(throws: FakeStore.Failure.network) { _ = try await store.subscriptionPhase(groupID: "pro") }
        await #expect(throws: FakeStore.Failure.network) { _ = try await store.purchase(productID: "tokens.10") }
        await store.setReachable(false)
        await #expect(throws: FakeStore.Failure.unreachable) { _ = try await store.allTransactions() }
        await #expect(throws: FakeStore.Failure.unreachable) { _ = try await store.appTransaction() }
    }

    @Test func fake_clock_wakes_sleepers_on_advance_and_wall_clock_changes() async throws {
        let clock = FakeClock()
        let start = clock.now
        let first = Task { try await clock.sleep(until: start.addingTimeInterval(10)) }
        let second = Task { try await clock.sleep(until: start.addingTimeInterval(100)) }
        #expect(await eventually { clock.pendingSleepers == 2 })
        clock.advance(by: 11)
        try await first.value
        #expect(clock.pendingSleepers == 1)
        clock.setWallClock(start.addingTimeInterval(200))
        try await second.value
        #expect(clock.pendingSleepers == 0)

        let cancelled = Task { try await clock.sleep(until: start.addingTimeInterval(1_000)) }
        #expect(await eventually { clock.pendingSleepers == 1 })
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        try await clock.sleep(until: start)  // a deadline in the past returns at once
    }
}
