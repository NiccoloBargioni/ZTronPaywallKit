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
        harness.engine.merge([grantEvent("grant:remote")])
        #expect(harness.engine.wallet.balance == 0)
        harness.engine.journal.injectedFault = nil
        harness.engine.merge([grantEvent("grant:remote")])
        #expect(harness.engine.wallet.balance == 4)
        harness.engine.merge([grantEvent("grant:remote")])  // already present: no-op
        #expect(harness.events.filter { if case .syncMerged = $0 { true } else { false } }.count == 1)
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
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        #expect(throws: JournalError.self) { try journal.compact() }
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

    @Test func a_read_only_journal_with_a_torn_tail_fails_to_open() throws {
        let directory = makeTemporaryPaywallDirectory()
        let journal = try Journal(directory: directory, fullSync: false)
        try journal.append(.event(grantEvent("grant:1"), uploaded: false))
        let handle = try FileHandle(forWritingTo: journal.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([9, 9, 9]))
        try handle.close()
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: journal.url.path)
        #expect(throws: JournalError.self) { try Journal(directory: directory) }
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
        FileManager.default.createFile(atPath: journal.url.appendingPathComponent("x").path, contents: Data())
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
    }

    @Test func audit_sink_with_one_file_rotates_by_truncation() async throws {
        let sink = JournalSink(directory: makeTemporaryPaywallDirectory(), maxBytes: 64, maxFiles: 1)
        for n in 1...3 {
            await sink.write(
                AuditRecord(
                    at: Date(), uptime: 0, sessionID: UUID(), deviceID: "A", appVersion: "1", build: "1",
                    environment: "test", event: .tokensGranted(n: n, reason: "r"), entitlementBefore: .free,
                    entitlementAfter: .free, balanceBefore: 0, balanceAfter: n, previousHash: paywallGenesisHash))
        }
        let records = await sink.records()
        #expect(records.map(\.balanceAfter) == [3])
        #expect(await sink.fileURLs().count == 1)
    }
}

@Suite("Small surfaces")
@MainActor
struct SmallSurfaceTests {
    private struct BareSync: LedgerSync {
        func push(_ events: [LedgerEvent]) async throws -> Set<String> { Set(events.map(\.id)) }
        func pull() async throws -> [LedgerEvent] { [] }
    }

    @Test func ledger_sync_defaults_are_inert() async {
        let sync = BareSync()
        #expect(await sync.loadSnapshot() == nil)
        await sync.saveSnapshot(WalletSnapshot(accountKey: "k", balance: 1, lastEventID: "e", headHash: "h"))
        await sync.requestPull()
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
