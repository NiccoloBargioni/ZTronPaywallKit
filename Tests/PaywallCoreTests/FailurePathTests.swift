import Foundation
import PaywallTesting
import Testing

@testable import PaywallCore

/// The paths a full disk, a failed fsync or a torn write take. Each one must leave the wallet unchanged or fail
/// closed; none may deliver value without a durable debit.
@Suite("Failure paths", .serialized)
@MainActor
struct FailurePathTests {
    private func grantEvent(_ id: String, device: String = "B") -> LedgerEvent {
        LedgerEvent(
            id: id, at: Date(timeIntervalSince1970: 1_000), deviceID: device, accountKey: unboundAccountKey,
            source: nil, previousHash: paywallGenesisHash, kind: .grant(tokens: 4, reason: "remote"))
    }

    @Test func debit_write_failure_fails_closed_and_runs_nothing() async throws {
        let harness = try await Harness.free(tokens: 5)
        harness.engine.journal.injectedFault = .write
        var ran = false
        let outcome = harness.engine.run(.tokens(2), source: source("g")) { ran = true }
        #expect(!ran)
        #expect(outcome.failure?.reason == .storageUnavailable)
        #expect(harness.engine.wallet.balance == 5)
        harness.engine.journal.injectedFault = nil
        #expect(try await harness.relaunch().wallet.balance == 5)
    }

    @Test func sync_failure_after_a_debit_still_delivers() async throws {
        let harness = try await Harness.free(tokens: 5)
        harness.engine.journal.injectedFault = .sync
        var ran = false
        _ = harness.engine.run(.tokens(2), source: source("g")) { ran = true }
        #expect(ran)
        #expect(harness.engine.wallet.balance == 3)
        harness.engine.journal.injectedFault = nil
        #expect(try await harness.relaunch().wallet.balance == 3)
    }

    @Test func ledger_append_failure_drops_the_event() async throws {
        let harness = try await Harness.free(tokens: 1)
        harness.engine.journal.injectedFault = .write
        harness.engine.grant(tokens: 10, reason: "lost")
        #expect(harness.engine.wallet.balance == 1)
        harness.engine.journal.injectedFault = nil
        #expect(try await harness.relaunch().wallet.balance == 1)
    }

    @Test func merge_failure_keeps_the_ledger_unchanged() async throws {
        let harness = try await Harness.free()
        harness.engine.journal.injectedFault = .write
        #expect(!harness.engine.merge([grantEvent("grant:remote")], cursor: Data("1".utf8)))
        #expect(harness.engine.wallet.balance == 0)
        #expect(harness.engine.journal.cursor == nil, "a failed merge moves no cursor")
        harness.engine.journal.injectedFault = nil
        #expect(harness.engine.merge([grantEvent("grant:remote")], cursor: Data("1".utf8)))
        #expect(harness.engine.wallet.balance == 4)
        #expect(harness.engine.journal.cursor == Data("1".utf8))
        #expect(harness.engine.merge([grantEvent("grant:remote")]))  // already present: no-op, still a success
        #expect(harness.events.filter { if case .syncMerged = $0 { true } else { false } }.count == 1)
    }

    // MARK: Credits (A2)

    private func completedPurchases(_ harness: Harness) -> Int {
        harness.events.filter { if case .purchase(.completed, _, _, _) = $0 { true } else { false } }.count
    }

    /// A2: a pack whose credit the journal could not write is not finished and not reported as bought; StoreKit
    /// delivers it again at the next launch and it is credited exactly once.
    @Test func credit_write_failure_leaves_the_purchase_unfinished() async throws {
        let h = try await Harness.free()
        await h.store.setProducts(products)
        h.engine.journal.injectedFault = .write
        let outcome = try await h.engine.purchase(productID: "tokens.10", source: source("paywall"))
        #expect(outcome == .pending)
        #expect(await h.store.finished.isEmpty)
        #expect(h.engine.wallet.balance == 0)
        #expect(completedPurchases(h) == 0)
        #expect(h.events.contains { if case .purchase(.pending, "tokens.10", _, _) = $0 { true } else { false } })
        let tx = try #require(await h.store.history.last)
        h.engine.journal.injectedFault = nil
        let engine = try await h.relaunch()
        await h.store.deliver(tx)
        #expect(await eventually { await h.store.finished == [tx.id] })
        #expect(engine.wallet.balance == 10)
        #expect(engine.ledger.events.filter { $0.id == "credit:\(tx.id)" }.count == 1)
    }

    @Test func credit_write_failure_on_updates_leaves_the_transaction_unfinished() async throws {
        let h = try await Harness.free()
        h.engine.journal.injectedFault = .write
        let tx = StoreTransaction.tokenPack(id: 21, productID: "tokens.10", purchased: h.clock.now)
        #expect(await !h.engine.handle(tx))
        #expect(await h.store.finished.isEmpty)
        #expect(h.engine.wallet.balance == 0)
        h.engine.journal.injectedFault = nil
        let engine = try await h.relaunch()
        await h.store.deliver(tx)
        #expect(await eventually { await h.store.finished == [21] })
        #expect(engine.wallet.balance == 10)
        #expect(engine.ledger.events.filter { $0.id == "credit:21" }.count == 1)
    }

    /// A poisoned journal (a rewind that failed) refuses every write until a relaunch: the pack stays unfinished too.
    @Test func a_poisoned_journal_leaves_the_pack_unfinished_until_relaunch() async throws {
        let h = try await Harness.free(tokens: 1)
        h.engine.journal.injectedFault = .poison
        #expect(!h.engine.grant(tokens: 1, reason: "poison"))
        h.engine.journal.injectedFault = nil
        #expect(h.engine.journal.isPoisoned)
        let tx = StoreTransaction.tokenPack(id: 22, productID: "tokens.10", purchased: h.clock.now)
        #expect(await !h.engine.handle(tx))
        #expect(await h.store.finished.isEmpty)
        let engine = try await h.relaunch()
        #expect(engine.wallet.balance == 1)
        await h.store.deliver(tx)
        #expect(await eventually { await h.store.finished == [22] })
        #expect(engine.wallet.balance == 11)
        #expect(engine.ledger.events.filter { $0.id == "credit:22" }.count == 1)
    }

    /// A failed sync after a successful write is a landed credit (the frame is in the file), as on the draw path: the
    /// pack is finished, and the relaunch agrees.
    @Test func sync_failure_after_a_credit_still_lands_it() async throws {
        let h = try await Harness.free()
        await h.store.setProducts(products)
        h.engine.journal.injectedFault = .sync
        let outcome = try await h.engine.purchase(productID: "tokens.10", source: nil)
        guard case .purchased(let id) = outcome else {
            Issue.record("expected a purchase, got \(outcome)")
            return
        }
        #expect(h.engine.wallet.balance == 10)
        #expect(await h.store.finished == [id])
        h.engine.journal.injectedFault = nil
        let engine = try await h.relaunch()
        #expect(engine.wallet.balance == 10)
        #expect(engine.ledger.events.filter { $0.id == "credit:\(id)" }.count == 1)
    }

    /// The same session retries: once the journal takes writes again, the next resolution credits and finishes the
    /// pack without waiting for a relaunch.
    @Test func an_unfinished_pack_is_credited_at_the_next_resolution_in_the_same_session() async throws {
        let h = try await Harness.free()
        await h.store.setProducts(products)
        h.engine.journal.injectedFault = .write
        #expect(try await h.engine.purchase(productID: "tokens.10", source: nil) == .pending)
        let tx = try #require(await h.store.history.last)
        await h.engine.refresh(cause: .foreground)  // the journal still refuses: the pack keeps waiting
        #expect(h.engine.wallet.balance == 0)
        #expect(await h.store.finished.isEmpty)
        h.engine.journal.injectedFault = nil
        await h.engine.refresh(cause: .foreground)
        #expect(h.engine.wallet.balance == 10)
        #expect(await h.store.finished == [tx.id])
        await h.engine.refresh(cause: .foreground)
        #expect(await h.store.finished == [tx.id], "finished once")
        #expect(h.engine.ledger.events.filter { $0.id == "credit:\(tx.id)" }.count == 1)
    }

    @Test func engine_launches_over_a_torn_tail() async throws {
        let harness = try await Harness.free(tokens: 3)
        harness.engine.shutdown()
        let handle = try FileHandle(forWritingTo: harness.directory.appendingPathComponent(Journal.fileName))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x40, 0, 0, 0, 1, 2]))
        try handle.close()
        let engine = try await harness.relaunch()
        #expect(engine.journal.droppedTailBytes == 6)
        #expect(engine.wallet.balance == 3)
    }

    @Test func compaction_write_failure_leaves_the_log_and_no_side_file() throws {
        let directory = makeTemporaryPaywallDirectory()
        let journal = try Journal(directory: directory, fullSync: false)
        try journal.append(.event(grantEvent("grant:1"), uploaded: false))
        journal.injectedFault = .write
        #expect(throws: JournalError.self) { try journal.compact() }
        #expect(!FileManager.default.fileExists(atPath: journal.url.path + Journal.compactingSuffix))
        journal.injectedFault = nil
        #expect(try Journal(directory: directory).ledgerEvents.map(\.id) == ["grant:1"])
    }

    @Test func compaction_of_an_open_journal_keeps_appending() throws {
        let directory = makeTemporaryPaywallDirectory()
        let journal = try Journal(directory: directory, fullSync: false)
        try journal.append(.event(grantEvent("grant:1"), uploaded: false))
        try journal.append(.uploaded(["grant:1"]))
        try journal.compact()
        try journal.append(.event(grantEvent("grant:2"), uploaded: false))
        let reopened = try Journal(directory: directory)
        #expect(reopened.ledgerEvents.map(\.id) == ["grant:1", "grant:2"])
        #expect(reopened.pendingUpload.map(\.id) == ["grant:2"])
        #expect(reopened.entries.count == 2)
    }

    @Test func compaction_fails_when_the_side_file_cannot_be_created() throws {
        let directory = makeTemporaryPaywallDirectory()
        let journal = try Journal(directory: directory, fullSync: false)
        try journal.append(.event(grantEvent("grant:1"), uploaded: false))
        // A directory where the side file goes: open(2) fails with EISDIR, for root too.
        try FileManager.default.createDirectory(
            atPath: journal.url.path + Journal.compactingSuffix, withIntermediateDirectories: false)
        #expect(throws: JournalError.self) { try journal.compact() }
        #expect(try Journal(directory: directory).ledgerEvents.map(\.id) == ["grant:1"])
    }

    @Test func journal_sync_failure_is_reported() throws {
        let journal = try Journal(directory: makeTemporaryPaywallDirectory())
        journal.injectedFault = .sync
        #expect(throws: JournalError.self) { try journal.sync() }
        journal.injectedFault = .write
        #expect(throws: JournalError.self) { try journal.append(.uploaded(["x"])) }
        #expect(throws: JournalError.self) { try journal.append(contentsOf: [.uploaded(["x"])]) }
        #expect(journal.entries.isEmpty)
    }

    @Test func a_torn_tail_that_cannot_be_truncated_fails_to_open() throws {
        let directory = makeTemporaryPaywallDirectory()
        let journal = try Journal(directory: directory, fullSync: false)
        try journal.append(.event(grantEvent("grant:1"), uploaded: false))
        let handle = try FileHandle(forWritingTo: journal.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([9, 9, 9]))
        try handle.close()
        #expect(throws: JournalError.self) { try Journal(directory: directory, injecting: .truncate) }
        #expect(try Journal(directory: directory).droppedTailBytes == 3)
    }

    @Test func an_unencodable_event_is_refused_before_any_byte_is_written() throws {
        let journal = try Journal(directory: makeTemporaryPaywallDirectory())
        let broken = LedgerEvent(
            id: "grant:nan", at: Date(timeIntervalSince1970: .nan), deviceID: "A", accountKey: "k", source: nil,
            previousHash: paywallGenesisHash, kind: .grant(tokens: 1, reason: "x"))
        #expect(throws: JournalError.encodingFailed) { try journal.append(.event(broken, uploaded: false)) }
        #expect(journal.entries.isEmpty)
        #expect(broken.hash == SHA256Digest.hex(Data()))
    }

    @Test func compaction_fails_when_the_rename_fails() throws {
        let directory = makeTemporaryPaywallDirectory()
        let journal = try Journal(directory: directory, fullSync: false)
        try journal.append(.event(grantEvent("grant:1"), uploaded: false))
        // Put a non-empty directory where the log was: rename(2) cannot replace it.
        try FileManager.default.removeItem(at: journal.url)
        try FileManager.default.createDirectory(at: journal.url, withIntermediateDirectories: false)
        _ = FileManager.default.createFile(atPath: journal.url.appendingPathComponent("x").path, contents: Data())
        #expect(throws: JournalError.self) { try journal.compact() }
    }

    @Test func tickets_after_termination_or_without_a_draw_do_nothing() async throws {
        let harness = try await Harness.free(tokens: 5)
        let engine = harness.engine
        guard case .open(let free) = engine.begin(.free, source: source("free")) else {
            Issue.record("free gate closed")
            return
        }
        engine.complete(free)
        engine.abort(free, error: TestError())
        guard case .open(let drawn) = engine.begin(.tokens(2), source: source("g")) else {
            Issue.record("token gate closed")
            return
        }
        engine.terminate()
        let before = harness.events.count
        engine.complete(drawn)
        engine.abort(drawn, error: TestError())
        #expect(harness.events.count == before)
    }

    @Test func a_throwing_body_unpins_the_lease_it_was_pinning() async throws {
        let harness = try await Harness.free(tokens: 5)
        let holder = UUID()
        #expect(throws: TestError.self) {
            try harness.engine.run(.tokens(2), source: source("g"), holder: holder) { throw TestError() }
        }
        #expect(harness.engine.leases.holders(of: "g").isEmpty)
        #expect(harness.engine.wallet.balance == 5)
    }

    @Test func refunds_of_unknown_debits_and_foreign_reservations() {
        var ledger = Ledger()
        ledger.append(grantEvent("grant:1", device: "A"))
        ledger.append(
            LedgerEvent(
                id: "refund:ghost", at: Date(timeIntervalSince1970: 2_000), deviceID: "A", accountKey: unboundAccountKey,
                source: nil, previousHash: paywallGenesisHash, kind: .refund(debitID: "debit:ghost", reason: .bodyThrew("x"))))
        #expect(ledger.balance(for: "k") == 4)

        let table = ReservationTable()
        let a = UUID(), b = UUID(), stranger = UUID()
        table.hold(Reservation(holder: a, gateID: "g", tokens: 1, source: source("g")))
        table.hold(Reservation(holder: b, gateID: "g", tokens: 1, source: source("g")))
        let smallest = [a, b].min { $0.uuidString < $1.uuidString }
        #expect(table.reservation(forGate: "g", preferring: stranger)?.holder == smallest)
        #expect(table.reservation(forGate: "g", preferring: b)?.holder == b)
        #expect(table.reservation(forGate: "h", preferring: nil) == nil)
    }

    @Test func a_pack_refunded_before_its_credit_nets_to_zero() async throws {
        let harness = try await Harness.free()
        var refunded = StoreTransaction.tokenPack(id: 9, productID: "tokens.10", purchased: Date())
        refunded.revocationDate = Date()
        let planned = CreditReconciler.plan(for: refunded, catalog: catalog, ledger: harness.engine.ledger)
        #expect(planned.map(\.id) == [LedgerEvent.creditID(9), LedgerEvent.revocationID(9)])
        await harness.engine.handle(refunded)
        #expect(harness.engine.wallet.balance == 0)
        #expect(CreditReconciler.plan(for: refunded, catalog: catalog, ledger: harness.engine.ledger).isEmpty)
        #expect(CreditReconciler.plan(
            for: .lifetime(id: 10, productID: "pro.lifetime", purchased: Date()), catalog: catalog, ledger: harness.engine.ledger).isEmpty)
    }

    @Test func a_stored_unknown_entitlement_is_not_a_snapshot() throws {
        let directory = makeTemporaryPaywallDirectory()
        let snapshot = PaywallFiles.EntitlementSnapshot(entitlement: .unknown, resolvedAt: Date())
        try CanonicalJSON.encoder().encode(snapshot).write(to: directory.appendingPathComponent("entitlement.json"))
        #expect(PaywallFiles(directory: directory).entitlementSnapshot(now: Date()) == nil)
        // And the engine never writes one: `.unknown` is the absence of a resolution.
        let fresh = makeTemporaryPaywallDirectory()
        PaywallFiles(directory: fresh).saveEntitlementSnapshot(.unknown)
        #expect(!FileManager.default.fileExists(atPath: fresh.appendingPathComponent("entitlement.json").path))
    }

    @Test func a_lapsed_subscription_snapshot_launches_as_free() {
        let directory = makeTemporaryPaywallDirectory()
        let files = PaywallFiles(directory: directory)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        files.saveEntitlementSnapshot(.subscription(.monthly, expiresAt: now.addingTimeInterval(-1)), at: now.addingTimeInterval(-100))
        #expect(files.entitlementSnapshot(now: now) == .free)
        files.saveEntitlementSnapshot(.subscription(.monthly, expiresAt: now.addingTimeInterval(60)), at: now)
        #expect(files.entitlementSnapshot(now: now)?.isPaying == true)
    }

    /// A3: a snapshot taken inside a billing grace period launches as subscribed until the grace end, not until the
    /// failed renewal date.
    @Test func a_snapshot_inside_billing_grace_launches_as_subscribed_until_the_grace_ends() {
        let files = PaywallFiles(directory: makeTemporaryPaywallDirectory())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let graceEnd = now.addingTimeInterval(10 * 86_400)
        let inGrace = Entitlement.subscription(.monthly, expiresAt: now.addingTimeInterval(-3_600), phase: .inGracePeriod, gracePeriodEndsAt: graceEnd)
        files.saveEntitlementSnapshot(inGrace, at: now)
        #expect(files.entitlementSnapshot(now: now) == inGrace)
        #expect(files.entitlementSnapshot(now: graceEnd.addingTimeInterval(-1)) == inGrace)
        #expect(files.entitlementSnapshot(now: graceEnd) == .free)
    }

    @Test func audit_sink_with_one_file_rotates_by_truncation() async throws {
        let sink = JournalSink(directory: makeTemporaryPaywallDirectory(), maxBytes: 64, maxFiles: 1)
        var written: [AuditRecord] = []
        for n in 1...3 {
            let record = AuditRecord(
                at: Date(), uptime: 0, sessionID: UUID(), deviceID: "A", appVersion: "1", build: "1",
                environment: "test", event: .tokensGranted(n: n, reason: "r"), entitlementBefore: .free,
                entitlementAfter: .free, balanceBefore: 0, balanceAfter: n, previousHash: paywallGenesisHash)
            written.append(record)
            await sink.write(record)
        }
        let records = await sink.records()
        #expect(records.map(\.balanceAfter) == [3])
        #expect(await sink.fileURLs().filter { $0.pathExtension == "jsonl" }.count == 1)
        // Truncation drops records too: the anchor is the hash of the last one dropped.
        #expect(await sink.chainAnchor() == written[1].hash)
        #expect(await sink.retainedSince() == records.first?.at)
    }
}

@Suite("Small surfaces")
@MainActor
struct SmallSurfaceTests {
    private struct BareSync: LedgerSync {
        func push(_ events: [LedgerEvent]) async throws -> Set<String> { Set(events.map(\.id)) }
        func pull() async throws -> [LedgerEvent] { [] }
    }

    /// A `StoreClient` that implements only what the protocol requires.
    private struct BareStore: StoreClient {
        func currentEntitlements() async throws -> [StoreTransaction] { [] }
        func allTransactions() async throws -> [StoreTransaction] { [] }
        func appTransaction() async throws -> AppTransactionSnapshot? { nil }
        func updates() async -> AsyncStream<StoreTransaction> { AsyncStream { $0.finish() } }
        func purchaseIntents() async -> AsyncStream<String> { AsyncStream { $0.finish() } }
        func products(for ids: Set<String>) async throws -> [PaywallProduct] { [] }
        func purchase(productID: String, offer: SignedPromotionalOffer?) async throws -> StorePurchaseResult { .userCancelled }
        func sync() async throws {}
        func finish(transactionID: UInt64) async {}
        func subscriptionPhase(groupID: String) async throws -> SubscriptionPhase? { nil }
        func isEligibleForIntroOffer(groupID: String) async -> Bool { false }
        func storefrontCountryCode() async -> String? { nil }
    }

    @Test func ledger_sync_defaults_are_inert() async throws {
        let sync = BareSync()
        #expect(await sync.loadSnapshot() == nil)
        await sync.saveSnapshot(WalletSnapshot(accountKey: "k", balance: 1, lastEventID: "e", headHash: "h"))
        await sync.requestPull()
        // A6: a carrier that forwards only `pull()` pulls everything every time and keeps no position.
        let pull = try #require(try await sync.pull(since: Data("anywhere".utf8)))
        #expect(pull.events.isEmpty && pull.cursor == nil && pull.accountAvailable)
        // A3: a store client without a grace read reports no grace.
        #expect(try await BareStore().renewalGraceEnd(groupID: "g") == nil)
    }

    @Test func system_clock_reads_and_sleeps() async throws {
        let clock = SystemClock()
        #expect(abs(clock.now.timeIntervalSinceNow) < 5)
        #expect(clock.uptime > 0)
        try await clock.sleep(until: Date().addingTimeInterval(-1))
        try await clock.sleep(until: Date().addingTimeInterval(0.01))
    }

    @Test func event_sources() {
        let gate = source("g")
        let holder = UUID()
        let failure = PaywallFailure(reason: .requiresPaid, level: .paid, source: gate, at: Date())
        let withSource: [PaywallEvent] = [
            .gateEvaluated(source: gate, level: .paid, decision: .closed(.requiresPaid)),
            .gateOpened(source: gate, level: .free, mode: .free),
            .gateDenied(failure),
            .tokensReserved(n: 1, source: gate, holder: holder),
            .tokensReleased(n: 1, source: gate, holder: holder),
            .reservedWithoutCommit(source: gate, holder: holder),
            .tokensConsumed(n: 1, source: gate, debitID: "d", leaseUntil: Date()),
            .purchase(stage: .started, productID: "p", source: gate, transactionID: nil),
        ]
        #expect(withSource.allSatisfy { $0.source == gate })
        #expect(PaywallEvent.tokensGranted(n: 1, reason: "r").source == nil)
        #expect(PaywallEvent.gateDenied(failure).failure == failure)
        #expect(PaywallEvent.auditRepaired(debitID: "d").failure == nil)
    }

    @available(*, deprecated)
    @Test func scale_now_is_deduct_now() {
        #expect(TokenPolicy.scaleNow == .deductNow)
    }
}
