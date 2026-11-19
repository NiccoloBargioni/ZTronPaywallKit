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
        #expect(await store.storefrontCountryCode() == "USA")
        await store.setStorefrontCountry(nil)
        #expect(await store.storefrontCountryCode() == nil)
        #expect(try await store.products(for: ["tokens.10"]).map(\.id) == ["tokens.10"])
        #expect(await store.productCalls == 1)
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
        await #expect(throws: FakeStore.Failure.network) { _ = try await store.renewalGraceEnd(groupID: "pro") }
        await store.setNetwork(true)
        await store.setGraceEnd(Date(timeIntervalSince1970: 1_800_000_000))
        #expect(try await store.renewalGraceEnd(groupID: "pro") == Date(timeIntervalSince1970: 1_800_000_000))
    }

    /// B14: offline, StoreKit answers its passive reads from its cache and never throws; only the network calls fail.
    @Test func fake_store_passive_reads_answer_like_storekit_when_offline() async throws {
        let now = Date()
        let snapshot = AppTransactionSnapshot(
            bundleID: "b", originalAppVersion: "1", originalPurchaseDate: now, environment: .production, origin: .appTransaction)
        let store = FakeStore(entitlements: [.lifetime(id: 7, productID: "pro.lifetime", purchased: now)], app: snapshot, products: products)
        await store.setNetwork(false)
        #expect(try await store.currentEntitlements().map(\.id) == [7])
        #expect(try await store.allTransactions().isEmpty)
        #expect(try await store.appTransaction() == snapshot)
        await #expect(throws: FakeStore.Failure.network) { _ = try await store.products(for: ["tokens.10"]) }
        await #expect(throws: FakeStore.Failure.network) { _ = try await store.purchase(productID: "tokens.10") }
        await #expect(throws: FakeStore.Failure.network) { try await store.sync() }
    }

    /// The one failure StoreKit's reads can show is never answering: `setReachable(false)` holds them until the store
    /// is reachable again. The throwing mode is named for what it is, a host client's behaviour.
    @Test func fake_store_unreachable_holds_passive_reads_until_released() async throws {
        let store = FakeStore(entitlements: [.lifetime(id: 7, productID: "pro.lifetime", purchased: Date())])
        await store.setReachable(false)
        let read = Task { try await store.currentEntitlements().map(\.id) }
        #expect(await eventually { await store.pendingReads == 1 })
        await #expect(throws: FakeStore.Failure.network) { _ = try await store.products(for: ["tokens.10"]) }
        await store.setReachable(true)
        #expect(try await read.value == [7])
        #expect(await store.pendingReads == 0)
        await store.setPassiveReadFailure(.unreachable)
        await #expect(throws: FakeStore.Failure.unreachable) { _ = try await store.allTransactions() }
        await #expect(throws: FakeStore.Failure.unreachable) { _ = try await store.appTransaction() }
        await store.setPassiveReadFailure(nil)
        #expect(try await store.appTransaction() == nil)
    }

    @Test func in_memory_sync_plain_pull_returns_everything_and_fails_offline() async throws {
        let cloud = InMemoryCloud()
        let sync = InMemoryLedgerSync(cloud: cloud)
        let event = LedgerEvent(
            id: "a", at: Date(), deviceID: "d", accountKey: unboundAccountKey, source: nil, previousHash: paywallGenesisHash,
            kind: .grant(tokens: 1, reason: "r"))
        _ = try await sync.push([event])
        #expect(try await sync.pull().map(\.id) == ["a"])
        await cloud.setReachable(false)
        await #expect(throws: FakeStore.Failure.network) { _ = try await sync.pull() }
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

        // Cancelled before it ever ran: the continuation is resumed throwing as it is enqueued, nothing is left behind.
        let stillborn = Task { try await clock.sleep(until: clock.now.addingTimeInterval(10)) }
        stillborn.cancel()
        await #expect(throws: CancellationError.self) { try await stillborn.value }
        #expect(clock.pendingSleepers == 0)
    }
}
