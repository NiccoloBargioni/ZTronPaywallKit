import Foundation
import PaywallTesting
import Testing

@testable import PaywallCore

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

private func ledgerEvent(_ id: String) -> LedgerEvent {
    LedgerEvent(id: id, at: t0, deviceID: "A", accountKey: "acct", source: nil, previousHash: paywallGenesisHash, kind: .grant(tokens: 1, reason: "r"))
}

private func auditRecord(at: Date = t0, event: PaywallEvent = .tokensGranted(n: 1, reason: "r"), balance: Int = 0) -> AuditRecord {
    AuditRecord(
        at: at, uptime: 0, sessionID: UUID(), deviceID: "A", appVersion: "1", build: "1", environment: "test", event: event,
        entitlementBefore: .free, entitlementAfter: .free, balanceBefore: 0, balanceAfter: balance, previousHash: paywallGenesisHash)
}

/// Stops the engine at one draw step, as a crash there would.
@MainActor
private final class TerminateAt: DrawObserver {
    let step: DrawStep
    init(_ step: DrawStep) { self.step = step }
    func engine(_ engine: GateEngine, reached step: DrawStep) -> DrawObservation { step == self.step ? .terminate : .proceed }
}

/// Holds the engine a sink shuts down from inside the audit repair.
@MainActor
private final class EngineBox {
    var engine: GateEngine?
}

/// A repairing sink that shuts the engine down while the repair waits on it, as a facade replacing its engine
/// mid-start would.
private actor ShuttingDownSink: PaywallAuditRepairing {
    let box: EngineBox
    init(_ box: EngineBox) { self.box = box }
    func write(_ record: AuditRecord) async {}
    func recordedDebitIDs() async -> Set<String> {
        await box.engine?.shutdown()
        return []
    }
    func lastRecordHash() async -> String? { nil }
}

private func isRepair(_ event: PaywallEvent) -> Bool {
    if case .auditRepaired = event { return true }
    return false
}

/// What a long-lived install must not pay for its history: the journal is compacted for its markers at open and
/// checkpointed at start, so a launch replays the events since the last checkpoint only; the audit log forgets by
/// rotation without the repair re-creating what it dropped.
@Suite("Retention", .serialized)
@MainActor
struct RetentionTests {
    private func settings(threshold: Int) -> GateEngine.Settings {
        GateEngine.Settings(tolerance: 300, appVersion: "2.0", build: "200", compactionThreshold: threshold)
    }

    // MARK: Checkpoints

    @Test func the_engine_checkpoints_at_start_and_the_next_launch_replays_from_it() async throws {
        let h = try await Harness.free(tokens: 10, settings: settings(threshold: 2))
        _ = h.engine.run(.tokens(1), source: source("g")) {}
        _ = h.engine.run(.tokens(2), source: source("h")) {}
        #expect(h.engine.journal.checkpoint == nil)
        // Three events at open exceed the threshold: this launch writes the checkpoint once its repair has run.
        let relaunched = try await h.relaunch()
        let checkpoint = try #require(relaunched.journal.checkpoint)
        #expect(checkpoint.eventCount == 3)
        #expect(relaunched.journal.entries.count == 1, "no carrier, so no outbox to keep")
        #expect(relaunched.ledger.events.count == 3, "the running ledger keeps what it replayed")
        #expect(relaunched.wallet.balance == 7)
        // The next launch replays from the checkpoint alone.
        let again = try await h.relaunch()
        #expect(again.ledger.events.isEmpty)
        #expect(again.journal.checkpoint == checkpoint)
        #expect(again.wallet.balance == 7)
        #expect(again.leases.records.keys.sorted() == ["g", "h"])
        #expect(again.run(.tokens(1), source: source("g")) { true }.value == true, "the lease derived from the checkpoint opens the gate")
        #expect(again.wallet.balance == 7)
        #expect(again.ledger.firstBrokenLink() == nil)
        _ = again.run(.tokens(3), source: source("i")) {}
        #expect(again.ledger.events.count == 1)
        #expect(again.ledger.events[0].previousHash == checkpoint.heads[again.deviceID])
        #expect(again.ledger.head(for: again.deviceID) == again.ledger.events[0].hash)
        let third = try await h.relaunch()
        #expect(third.journal.checkpoint == checkpoint, "one event since the checkpoint: below the threshold")
        #expect(third.ledger.events.count == 1 && third.wallet.balance == 4)
        #expect(third.ledger.firstBrokenLink() == nil)
    }

    @Test func a_checkpoint_keeps_the_outbox_until_the_carrier_acknowledges_it() async throws {
        let cloud = InMemoryCloud()
        let h = try Harness(sync: InMemoryLedgerSync(cloud: cloud), settings: settings(threshold: 0))
        await h.start()
        await cloud.setReachable(false)
        h.engine.grant(tokens: 10, reason: "t")
        _ = h.engine.run(.tokens(1), source: source("g")) {}
        await h.engine.syncNow()
        #expect(h.engine.journal.pendingUpload.count == 2)
        let relaunched = try await h.relaunch()
        #expect(relaunched.journal.checkpoint?.eventCount == 2)
        #expect(relaunched.journal.entries.count == 3, "the checkpoint, then the two unacknowledged events")
        #expect(relaunched.journal.pendingUpload.count == 2)
        #expect(relaunched.wallet.balance == 9)
        await cloud.setReachable(true)
        await relaunched.syncNow()
        #expect(await cloud.events.count == 2)
        #expect(relaunched.journal.pendingUpload.isEmpty && relaunched.journal.uploadMarkerCount == 1)
        // The marker compaction at the next open drops the acknowledged outbox; the checkpoint stays in front.
        let next = try await h.relaunch()
        #expect(next.journal.compactedOnOpen)
        #expect(next.journal.entries.count == 1)
        #expect(next.ledger.events.isEmpty && next.wallet.balance == 9)
        #expect(next.ledger.contains(try #require(await cloud.events.keys.first)))
    }

    @Test func the_keychain_snapshot_names_the_last_event_through_a_checkpoint() async throws {
        let sync = InMemoryLedgerSync()
        let h = try await Harness.free(tokens: 10, sync: sync, settings: settings(threshold: 0))
        await h.engine.syncNow()
        let grant = try #require(h.engine.ledger.lastEventID)
        #expect(await eventually { await sync.snapshot?.lastEventID == grant })
        let relaunched = try await h.relaunch()
        #expect(relaunched.journal.entries.count == 1, "acknowledged and covered: only the checkpoint remains")
        await sync.saveSnapshot(WalletSnapshot(accountKey: h.engine.accountKey, balance: 0, lastEventID: "stale", headHash: "h"))
        let again = try await h.relaunch()
        #expect(again.ledger.events.isEmpty && again.ledger.lastEventID == grant)
        #expect(again.baseline == nil, "a ledger with history for the account adopts no snapshot")
        #expect(await eventually { let snapshot = await sync.snapshot; return snapshot?.lastEventID == grant && snapshot?.balance == 10 })
        _ = again.run(.tokens(1), source: source("g")) {}
        #expect(await eventually { let snapshot = await sync.snapshot; return snapshot?.lastEventID == again.ledger.lastEventID && snapshot?.balance == 9 })
    }

    @Test func a_lost_audit_record_is_repaired_before_the_checkpoint_forgets_its_debit() async throws {
        let h = try await Harness.free(tokens: 10, settings: settings(threshold: 1))
        h.engine.drawObserver = TerminateAt(.valueDelivered)
        _ = h.engine.run(.tokens(1), source: source("lost")) {}
        let lost = try #require(h.engine.ledger.events.last?.id)
        await h.engine.flushAudit()
        #expect(!(await h.audit.recordedDebitIDs()).contains(lost))
        let relaunched = try await h.relaunch()
        #expect(h.events.contains(.auditRepaired(debitID: lost)))
        #expect(await h.audit.recordedDebitIDs().contains(lost))
        #expect(relaunched.journal.checkpoint?.eventCount == 2)
        #expect(relaunched.journal.entries.count == 1)
        // The debit is gone from the log and nothing needs it: the next launch repairs nothing.
        let next = try await h.relaunch()
        #expect(!h.events.contains(where: isRepair))
        #expect(next.wallet.balance == 9)
    }

    @Test func a_checkpoint_covers_only_what_the_journal_held_at_open() async throws {
        let h = try await Harness.free(tokens: 10, settings: settings(threshold: 0))
        let relaunched = try await h.relaunch(start: false)
        _ = relaunched.run(.tokens(1), source: source("early")) {}
        let early = try #require(relaunched.ledger.events.last?.id)
        await relaunched.start()
        let checkpoint = try #require(relaunched.journal.checkpoint)
        #expect(checkpoint.eventCount == 1 && !checkpoint.ids.contains(early))
        #expect(relaunched.journal.ledgerEvents.map(\.id) == [early], "drawn since open: left for the next launch's repair")
        let next = try await h.relaunch()
        #expect(next.ledger.events.map(\.id) == [early] && next.wallet.balance == 9)
        #expect(!h.events.contains(where: isRepair))
    }

    @Test func no_checkpoint_is_written_once_the_engine_is_shut_down() async throws {
        let h = try await Harness.free(tokens: 10, settings: settings(threshold: 0))
        h.engine.shutdown()
        let box = EngineBox()
        let engine = try GateEngine(
            directory: h.directory, catalog: catalog, settings: h.settings, clock: h.clock, store: h.store,
            audit: [ShuttingDownSink(box)])
        box.engine = engine
        await engine.start()
        #expect(engine.isShutDown)
        #expect(engine.journal.checkpoint == nil)
        #expect(try Journal(directory: h.directory).checkpoint == nil)
    }

    @Test func a_failed_checkpoint_is_logged_and_the_engine_carries_on() async throws {
        let h = try await Harness.free(tokens: 10, settings: settings(threshold: 0))
        let relaunched = try await h.relaunch(start: false)
        relaunched.journal.injectedFault = .write
        await relaunched.start()
        #expect(relaunched.journal.checkpoint == nil)
        #expect(!FileManager.default.fileExists(atPath: relaunched.journal.url.path + Journal.compactingSuffix))
        relaunched.journal.injectedFault = nil
        #expect(relaunched.run(.tokens(1), source: source("g")) { 1 }.value == 1)
        #expect(try Journal(directory: h.directory).ledgerEvents.count == 2)
    }

    @Test func a_corrupt_checkpoint_is_recovered_from_the_snapshot_and_the_carrier() async throws {
        let sync = InMemoryLedgerSync()
        let h = try await Harness.free(tokens: 10, sync: sync, settings: settings(threshold: 0))
        _ = h.engine.run(.tokens(3), source: source("g")) {}
        await h.engine.syncNow()
        #expect(await eventually { await sync.snapshot?.balance == 7 })
        let relaunched = try await h.relaunch()
        #expect(relaunched.journal.entries.count == 1)
        relaunched.shutdown()
        let url = h.directory.appendingPathComponent(Journal.fileName)
        var bytes = [UInt8](try Data(contentsOf: url))
        bytes[bytes.count / 2] ^= 0xFF
        try Data(bytes).write(to: url)
        // The checkpoint no longer decodes: the log is empty, as after a reinstall. The Keychain snapshot stands in
        // until the carrier answers, and the pull brings the history back.
        await sync.cloud.setReachable(false)
        let recovered = try await h.relaunch()
        #expect(recovered.journal.droppedTailBytes == bytes.count && recovered.ledger.events.isEmpty)
        #expect(recovered.baseline != nil && recovered.wallet.balance == 7)
        await sync.cloud.setReachable(true)
        await recovered.syncNow()
        #expect(recovered.baseline == nil && recovered.wallet.balance == 7)
        #expect(recovered.ledger.events.count == 2)
    }

    // MARK: Journal

    @Test func a_long_log_is_compacted_for_its_markers_not_its_events() throws {
        let dir = makeTemporaryPaywallDirectory()
        do {
            let journal = try Journal(directory: dir, compactionThreshold: 4)
            for i in 0..<10 { try journal.append(.event(ledgerEvent("e\(i)"), uploaded: true)) }
        }
        let reopened = try Journal(directory: dir, compactionThreshold: 4)
        #expect(!reopened.compactedOnOpen)
        #expect(reopened.uploadMarkerCount == 0 && reopened.entries.count == 10)
        for i in 0..<3 { try reopened.append(.uploaded(["e\(i)"])) }
        try reopened.append(contentsOf: [.uploaded(["e3"]), .event(ledgerEvent("e10"), uploaded: false), .uploaded(["e4", "e10"])])
        #expect(reopened.uploadMarkerCount == 5)
        #expect(!(try Journal(directory: dir, compactionThreshold: 5)).compactedOnOpen)
        let compacted = try Journal(directory: dir, compactionThreshold: 4)
        #expect(compacted.compactedOnOpen)
        #expect(compacted.uploadMarkerCount == 0 && compacted.entries.count == 11)
        #expect(compacted.pendingUpload.isEmpty)
        #expect(!(try Journal(directory: dir, compactionThreshold: 4)).compactedOnOpen)
    }

    @Test func the_engine_reports_a_compaction_at_open() async throws {
        let h = try await Harness.free(tokens: 5, sync: InMemoryLedgerSync())
        await h.engine.syncNow()
        #expect(h.engine.journal.uploadMarkerCount >= 1)
        h.settings.compactionThreshold = 0
        let relaunched = try await h.relaunch()
        #expect(relaunched.journal.compactedOnOpen)
        #expect(relaunched.journal.uploadMarkerCount == 0)
        #expect(relaunched.wallet.balance == 5)
    }

    // MARK: Audit rotation

    @Test func rotation_anchors_the_chain_and_the_repair_leaves_dropped_records_alone() async throws {
        let dir = makeTemporaryPaywallDirectory()
        let sink = JournalSink(directory: dir, maxBytes: 4_000, maxFiles: 2)
        let clock = FakeClock()
        let store = FakeStore(products: products)
        let first = try GateEngine(directory: dir, catalog: catalog, clock: clock, store: store, audit: [sink])
        await first.start()
        first.grant(tokens: 1_000, reason: "t")
        for i in 0..<40 {
            clock.advance(by: 1)
            _ = first.run(.tokens(1), source: source("g\(i)")) {}
        }
        await first.flushAudit()
        first.shutdown()
        let kept = await sink.recordedDebitIDs().count
        #expect(kept < 40)
        let retained = try #require(await sink.retainedSince())
        #expect(retained > t0 && retained <= clock.now)
        let anchor = await sink.chainAnchor()
        #expect(anchor != paywallGenesisHash)
        let records = await sink.records()
        #expect(AuditRecord.firstBrokenLink(in: records) == records.first)
        #expect(AuditRecord.firstBrokenLink(in: records, after: anchor) == nil)
        #expect(await sink.fileURLs().contains { $0.lastPathComponent == JournalSink.anchorFileName })

        // The debits whose records rotation dropped are not "lost": the next launch repairs nothing.
        var repaired: [String] = []
        let second = try GateEngine(directory: dir, catalog: catalog, clock: clock, store: store, audit: [sink])
        second.onEvent = { if case .auditRepaired(let debitID) = $0 { repaired.append(debitID) } }
        await second.start()
        #expect(repaired.isEmpty)

        // A record lost after the rotation, between delivery and the audit write, still is.
        second.drawObserver = TerminateAt(.valueDelivered)
        clock.advance(by: 1)
        _ = second.run(.tokens(1), source: source("lost")) {}
        let lost = try #require(second.ledger.events.last?.id)
        #expect(lost.hasPrefix("debit:"))
        let third = try GateEngine(directory: dir, catalog: catalog, clock: clock, store: store, audit: [sink])
        third.onEvent = { if case .auditRepaired(let debitID) = $0 { repaired.append(debitID) } }
        await third.start()
        #expect(repaired == [lost])
        await third.flushAudit()
        #expect(await sink.recordedDebitIDs().contains(lost))
        #expect(AuditRecord.firstBrokenLink(in: await sink.records(), after: await sink.chainAnchor()) == nil)
        third.shutdown()
    }

    @Test func a_refunded_debit_is_known_to_the_audit_and_not_repaired() async throws {
        let h = try await Harness.free(tokens: 5)
        #expect(throws: TestError.self) { try h.engine.run(.tokens(1), source: source("boom")) { throw TestError() } }
        #expect(h.engine.wallet.balance == 5)
        try await h.relaunch()
        #expect(!h.events.contains { if case .auditRepaired = $0 { return true } else { return false } })
    }

    @Test func the_sink_reads_the_newest_hash_from_the_tail_and_skips_torn_lines() async throws {
        let dir = makeTemporaryPaywallDirectory()
        let sink = JournalSink(directory: dir)
        #expect(await sink.lastRecordHash() == nil)
        #expect(await sink.retainedSince() == nil)
        #expect(await sink.chainAnchor() == paywallGenesisHash)
        let records = [
            auditRecord(event: .tokensConsumed(n: 1, source: source("g"), debitID: "d1", leaseUntil: t0)),
            auditRecord(event: .tokensRefunded(debitID: "d2", reason: .bodyThrew("x"))),
            auditRecord(event: .auditRepaired(debitID: "d3")),
        ]
        for record in records { await sink.write(record) }
        #expect(await sink.lastRecordHash() == records[2].hash)
        let current = dir.appendingPathComponent(JournalSink.fileName)
        let handle = try FileHandle(forWritingTo: current)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("garbage\n{\"torn".utf8))
        try handle.close()
        #expect(await sink.lastRecordHash() == records[2].hash)
        #expect(await sink.records().count == 3)
        #expect(await sink.recordedDebitIDs() == ["d1", "d2", "d3"])
        #expect(await sink.fileURLs().map(\.lastPathComponent) == [JournalSink.fileName])
    }

    @Test func retained_since_starts_at_the_oldest_surviving_record() async throws {
        let dir = makeTemporaryPaywallDirectory()
        let sink = JournalSink(directory: dir, maxBytes: 64, maxFiles: 2)
        let r1 = auditRecord(at: t0, balance: 1)
        let r2 = auditRecord(at: t0.addingTimeInterval(1), balance: 2)
        let r3 = auditRecord(at: t0.addingTimeInterval(2), balance: 3)
        await sink.write(r1)
        await sink.write(r2)
        // Rotated once: nothing dropped yet.
        #expect(await sink.retainedSince() == nil)
        #expect(await sink.chainAnchor() == paywallGenesisHash)
        await sink.write(r3)
        // Rotated twice: r1 was dropped and anchors the chain; r2 is the oldest survivor.
        #expect(await sink.chainAnchor() == r1.hash)
        #expect(await sink.retainedSince() == r2.at)
        #expect(await sink.lastRecordHash() == r3.hash)
        #expect(await sink.records().map(\.balanceAfter) == [2, 3])
        // The newest file emptied by a truncated write: the hash comes from the file before it.
        try Data().write(to: dir.appendingPathComponent(JournalSink.fileName))
        #expect(await sink.lastRecordHash() == r2.hash)
        // Nothing decodable left at all: records were dropped, so no debit is covered.
        try Data("garbage\n".utf8).write(to: dir.appendingPathComponent("audit.1.jsonl"))
        #expect(await sink.retainedSince() == .distantFuture)
        #expect(await sink.lastRecordHash() == nil)
    }
}
