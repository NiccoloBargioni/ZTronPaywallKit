import Foundation
import PaywallTesting
import Testing

@testable import PaywallCore

/// One test per row of the design's audit event tables: each drives the trigger in "Written when" and asserts
/// the record it writes, payload and the state around it.
@Suite("Audit event table", .serialized)
@MainActor
struct AuditTableTests {
    private func first(_ records: [AuditRecord], _ match: (PaywallEvent) -> Bool) throws -> AuditRecord {
        try #require(records.first { match($0.event) })
    }

    @Test func gateEvaluated_on_every_decision() async throws {
        let h = try await Harness.free()
        _ = h.engine.evaluate(.paid, source: source("heatmap"))
        let record = try first(await h.records()) { if case .gateEvaluated = $0 { true } else { false } }
        #expect(record.event == .gateEvaluated(source: source("heatmap"), level: .paid, decision: .closed(.requiresPaid)))
        #expect(record.entitlementBefore == .free && record.entitlementAfter == .free)
        #expect(record.balanceBefore == 0 && record.balanceAfter == 0)
    }

    @Test func gateDenied_carries_the_failure() async throws {
        let h = try await Harness.free(tokens: 1)
        _ = h.engine.run(.tokens(3), source: source("solver"), scope: "game") {}
        let record = try first(await h.records()) { $0.failure != nil }
        let failure = try #require(record.event.failure)
        #expect(failure.reason == .insufficientTokens(needed: 3, available: 1))
        #expect(failure.source == source("solver") && failure.scope == "game" && failure.level == .tokens(3))
        #expect(record.balanceBefore == 1 && record.balanceAfter == 1)
    }

    @Test func tokensReserved_and_tokensReleased_name_the_holder() async throws {
        let h = try await Harness.free(tokens: 5)
        let holder = UUID()
        h.engine.openSession(holder: holder, level: .tokens(2), policy: .reserve, source: source("map"), scope: nil)
        h.engine.closeSession(holder: holder)
        let records = await h.records()
        let reserved = try first(records) { if case .tokensReserved = $0 { true } else { false } }
        let released = try first(records) { if case .tokensReleased = $0 { true } else { false } }
        #expect(reserved.event == .tokensReserved(n: 2, source: source("map"), holder: holder))
        #expect(released.event == .tokensReleased(n: 2, source: source("map"), holder: holder))
        #expect(reserved.balanceAfter == 5 && released.balanceAfter == 5)  // holds never move the balance
    }

    @Test func tokensConsumed_when_a_debit_is_written() async throws {
        let h = try await Harness.free(tokens: 5)
        _ = h.engine.run(.tokens(2), source: source("export")) {}
        let record = try first(await h.records()) { if case .tokensConsumed = $0 { true } else { false } }
        guard case .tokensConsumed(let n, let gate, let debitID, let leaseUntil) = record.event else { return }
        #expect(n == 2 && gate == source("export"))
        #expect(h.engine.ledger.contains(debitID))
        #expect(leaseUntil == h.clock.now.addingTimeInterval(300))
        #expect(record.balanceBefore == 5 && record.balanceAfter == 3)
    }

    @Test func tokensRefunded_when_the_body_throws_after_a_draw() async throws {
        let h = try await Harness.free(tokens: 5)
        #expect(throws: TestError.self) { try h.engine.run(.tokens(2), source: source("export")) { throw TestError() } }
        let record = try first(await h.records()) { if case .tokensRefunded = $0 { true } else { false } }
        guard case .tokensRefunded(let debitID, let reason) = record.event else { return }
        #expect(debitID.hasPrefix("debit:"))
        #expect(reason == .bodyThrew(String(describing: TestError())))
        #expect(record.balanceAfter == 5)
    }

    @Test func tokensCredited_when_a_pack_verifies() async throws {
        let h = try await Harness.free()
        await h.engine.handle(.tokenPack(id: 7, productID: "tokens.10", purchased: h.clock.now))
        let record = try first(await h.records()) { if case .tokensCredited = $0 { true } else { false } }
        #expect(record.event == .tokensCredited(n: 10, productID: "tokens.10", transactionID: 7))
        #expect(record.balanceBefore == 0 && record.balanceAfter == 10)
    }

    @Test func tokensRevoked_when_a_pack_refund_is_reconciled() async throws {
        let h = try await Harness.free()
        let pack = StoreTransaction.tokenPack(id: 8, productID: "tokens.10", purchased: h.clock.now)
        await h.engine.handle(pack)
        var refunded = pack
        refunded.revocationDate = h.clock.now
        await h.engine.handle(refunded)
        let record = try first(await h.records()) { if case .tokensRevoked = $0 { true } else { false } }
        #expect(record.event == .tokensRevoked(transactionID: 8, n: 10))
        #expect(record.balanceBefore == 10 && record.balanceAfter == 0)
    }

    @Test func lease_lifecycle_records() async throws {
        let h = try await Harness.free(tokens: 5)
        let holder = UUID()
        h.engine.openSession(holder: holder, level: .tokens(1), policy: .deductNow, source: source("map"), scope: nil)
        let expiresAt = h.clock.now.addingTimeInterval(300)
        h.engine.closeSession(holder: holder)
        h.clock.advance(by: 301)
        _ = h.engine.evaluate(.tokens(1), source: source("map"))
        let records = await h.records()
        #expect(try first(records) { if case .leaseGranted = $0 { true } else { false } }.event
            == .leaseGranted(gateID: "map", expiresAt: expiresAt, holders: 1))
        #expect(try first(records) { if case .leasePinned = $0 { true } else { false } }.event
            == .leasePinned(gateID: "map", expiresAt: expiresAt, holders: 1))
        #expect(try first(records) { if case .leaseUnpinned = $0 { true } else { false } }.event
            == .leaseUnpinned(gateID: "map", expiresAt: expiresAt, holders: 0))
        #expect(try first(records) { if case .leaseExpired = $0 { true } else { false } }.event
            == .leaseExpired(gateID: "map", expiresAt: expiresAt))
    }

    @Test func entitlementChanged_records_from_to_and_cause() async throws {
        let h = try await Harness.free()
        await h.store.setEntitlements([.lifetime(id: 9, productID: "pro.lifetime", purchased: h.clock.now)])
        await h.engine.didBecomeActive()
        let record = try first(await h.records()) {
            if case .entitlementChanged(.free, _, .foreground) = $0 { true } else { false }
        }
        #expect(record.entitlementBefore == .free)
        #expect(record.entitlementAfter == .lifetime(.purchase(transactionID: 9)))
    }

    @Test(arguments: [FakeStore.NextPurchase.succeed, .pending, .cancel, .fail])
    func purchase_stages(next: FakeStore.NextPurchase) async throws {
        let h = try await Harness.free()
        await h.store.setNextPurchase(next)
        _ = try? await h.engine.purchase(productID: "pro.lifetime", source: source("paywall"))
        let stages = await h.records().compactMap { record -> PurchaseStage? in
            if case .purchase(let stage, "pro.lifetime", source("paywall"), _) = record.event { return stage }
            return nil
        }
        #expect(stages.first == .started)
        switch next {
        case .succeed: #expect(stages.last == .completed)
        case .pending: #expect(stages.last == .pending)
        case .cancel: #expect(stages.last == .cancelled)
        case .fail:
            guard case .failed = stages.last else { Issue.record("expected failed, got \(stages)"); return }
        }
    }

    @Test func restore_requested_completed_and_failed() async throws {
        let h = try await Harness.free()
        try await h.engine.restore()
        await h.store.setReachable(false)
        await #expect(throws: (any Error).self) { try await h.engine.restore() }
        let stages = await h.records().compactMap { record -> RestoreStage? in
            if case .restore(let stage) = record.event { return stage }
            return nil
        }
        #expect(stages.prefix(3) == [.requested, .completed, .requested])
        guard case .failed = stages.last else { Issue.record("expected failed, got \(stages)"); return }
    }

    @Test func grandfathered_the_first_time_the_rule_passes() async throws {
        let now = FakeClock().now
        let bought = now.addingTimeInterval(-1e6)
        let policy = GrandfatheringPolicy(lastPaidBuild: "116", paidWindow: DateInterval(start: now.addingTimeInterval(-1e7), end: now))
        let h = try Harness(grandfathering: policy)
        await h.store.setApp(
            AppTransactionSnapshot(
                bundleID: "b", originalAppVersion: "90", originalPurchaseDate: bought, environment: .production,
                origin: .appTransaction))
        await h.start()
        let record = try first(await h.records()) { if case .grandfathered = $0 { true } else { false } }
        #expect(record.event == .grandfathered(originalAppVersion: "90", originalPurchaseDate: bought, environment: .production))
    }

    @Test func storeUnavailable_carries_the_error_and_snapshot_age() async throws {
        let h = try await Harness.free()
        await h.store.setReachable(false)
        h.clock.advance(by: 120)
        await h.engine.refresh(cause: .foreground)
        let record = try first(await h.records()) { if case .storeUnavailable = $0 { true } else { false } }
        guard case .storeUnavailable(let error, let age) = record.event else { return }
        #expect(error.contains("unreachable"))
        #expect(age == 120)
        #expect(record.entitlementAfter == .free)  // the snapshot stood in
    }

    @Test func syncMerged_counts_events_and_devices() async throws {
        let h = try await Harness.free()
        let remote = ["A", "B", "B"].enumerated().map { index, device in
            LedgerEvent(
                id: "grant:\(index)", at: Date(timeIntervalSince1970: Double(index)), deviceID: device,
                accountKey: unboundAccountKey, source: nil, previousHash: paywallGenesisHash, kind: .grant(tokens: 1, reason: "r"))
        }
        h.engine.merge(remote)
        let record = try first(await h.records()) { if case .syncMerged = $0 { true } else { false } }
        #expect(record.event == .syncMerged(count: 3, fromDeviceIDs: ["A", "B"]))
        #expect(record.balanceBefore == 0 && record.balanceAfter == 3)
    }
}
