import Foundation
import PaywallTesting
import Testing

@testable import PaywallCore

private func event(_ id: String, tokens: Int = 1, device: String = "A", previous: String = paywallGenesisHash) -> LedgerEvent {
    LedgerEvent(
        id: id, at: Date(timeIntervalSince1970: 1_000), deviceID: device, accountKey: "acct", source: nil,
        previousHash: previous, kind: .grant(tokens: tokens, reason: "t"))
}

@Suite("Journal")
struct JournalTests {
    @Test func appends_survive_reopen() throws {
        let dir = makeTemporaryPaywallDirectory()
        do {
            let journal = try Journal(directory: dir)
            try journal.append(.event(event("a"), uploaded: false))
            try journal.append(.event(event("b"), uploaded: false))
        }
        let reopened = try Journal(directory: dir)
        #expect(reopened.ledgerEvents.map(\.id) == ["a", "b"])
        #expect(reopened.droppedTailBytes == 0)
    }

    @Test func journal_tail_torn_at_every_byte() throws {
        let dir = makeTemporaryPaywallDirectory()
        do {
            let journal = try Journal(directory: dir)
            try journal.append(.event(event("a", tokens: 3), uploaded: false))
            try journal.append(.event(event("b", tokens: 4), uploaded: false))
        }
        let url = dir.appendingPathComponent(Journal.fileName)
        let full = try Data(contentsOf: url)
        let firstFrame = try Journal.frame(.event(event("a", tokens: 3), uploaded: false)).count
        for cut in firstFrame..<full.count {
            try full.prefix(cut).write(to: url)
            let journal = try Journal(directory: dir)
            #expect(journal.ledgerEvents.map(\.id) == ["a"], "cut at \(cut)")
            #expect(Ledger(events: journal.ledgerEvents).balance(for: "acct") == 3)
            #expect(journal.droppedTailBytes == cut - firstFrame)
            // The torn tail was truncated: the next append lands on a clean boundary.
            try journal.append(.event(event("c", tokens: 5), uploaded: false))
            let after = try Journal(directory: dir)
            #expect(after.ledgerEvents.map(\.id) == ["a", "c"])
        }
    }

    @Test func corrupt_crc_drops_the_frame_and_everything_after() throws {
        let dir = makeTemporaryPaywallDirectory()
        do {
            let journal = try Journal(directory: dir)
            try journal.append(.event(event("a"), uploaded: false))
            try journal.append(.event(event("b"), uploaded: false))
        }
        let url = dir.appendingPathComponent(Journal.fileName)
        var bytes = [UInt8](try Data(contentsOf: url))
        bytes[bytes.count - 2] ^= 0xFF
        try Data(bytes).write(to: url)
        #expect(try Journal(directory: dir).ledgerEvents.map(\.id) == ["a"])
    }

    @Test func outbox_lists_unacknowledged_events() throws {
        let journal = try Journal(directory: makeTemporaryPaywallDirectory())
        try journal.append(.event(event("a"), uploaded: false))
        try journal.append(.event(event("b"), uploaded: true))
        try journal.append(.event(event("c"), uploaded: false))
        try journal.append(.uploaded(["a"]))
        #expect(journal.pendingUpload.map(\.id) == ["c"])
    }

    @Test func compaction_folds_markers_and_keeps_pending() throws {
        let dir = makeTemporaryPaywallDirectory()
        do {
            let journal = try Journal(directory: dir)
            try journal.append(.event(event("a"), uploaded: false))
            try journal.append(.event(event("b"), uploaded: false))
            try journal.append(.uploaded(["a"]))
        }
        let compacted = try Journal(directory: dir, compactionThreshold: 0)
        #expect(compacted.entries.count == 2)
        #expect(compacted.pendingUpload.map(\.id) == ["b"])
        try compacted.append(.event(event("c"), uploaded: false))
        #expect(try Journal(directory: dir).ledgerEvents.map(\.id) == ["a", "b", "c"])
    }

    @Test func compaction_interrupted_keeps_old_log() throws {
        let dir = makeTemporaryPaywallDirectory()
        do {
            let journal = try Journal(directory: dir)
            try journal.append(.event(event("a"), uploaded: false))
        }
        // A crash mid-compaction leaves a partial side file and the untouched log.
        let side = URL(fileURLWithPath: dir.appendingPathComponent(Journal.fileName).path + Journal.compactingSuffix)
        try Data([1, 2, 3]).write(to: side)
        let reopened = try Journal(directory: dir)
        #expect(reopened.ledgerEvents.map(\.id) == ["a"])
        #expect(!FileManager.default.fileExists(atPath: side.path))
    }

    @Test func fsync_only_mode_still_appends() throws {
        let dir = makeTemporaryPaywallDirectory()
        let journal = try Journal(directory: dir, fullSync: false)
        try journal.append(contentsOf: [.event(event("a"), uploaded: false), .event(event("b"), uploaded: false)])
        try journal.append(contentsOf: [])
        #expect(try Journal(directory: dir).ledgerEvents.count == 2)
    }

    @Test func unwritable_directory_fails_to_open() {
        #expect(throws: JournalError.self) {
            _ = try Journal(directory: URL(fileURLWithPath: "/dev/null/nope"))
        }
    }

    // MARK: Checkpoints

    /// Grants on one device stream, each linking to the one before.
    private struct Chain {
        var head = paywallGenesisHash
        mutating func next(_ id: String, tokens: Int = 1) -> LedgerEvent {
            let next = event(id, tokens: tokens, previous: head)
            head = next.hash
            return next
        }
    }

    @Test func a_checkpoint_leads_the_log_and_prunes_the_events_it_covers() throws {
        let dir = makeTemporaryPaywallDirectory()
        var chain = Chain()
        let journal = try Journal(directory: dir, fullSync: false)
        try journal.append(.event(chain.next("a", tokens: 3), uploaded: false))
        try journal.append(.event(chain.next("b", tokens: 4), uploaded: true))
        try journal.append(.uploaded(["a"]))
        try journal.append(.event(chain.next("c", tokens: 5), uploaded: false))
        let covered = Ledger(events: journal.ledgerEvents).checkpoint()
        try journal.compact(checkpoint: covered, keepingOutbox: true)
        // `a` and `b` are acknowledged and counted: gone. `c` is the outbox: counted by the checkpoint, so it leaves
        // the log for the outbox file, where no open decodes it, until the carrier acknowledges it.
        #expect(journal.entries == [.checkpoint(covered)])
        #expect(journal.checkpoint == covered)
        #expect(covered.eventCount == 3)
        #expect(journal.pendingUpload.map(\.id) == ["c"])
        #expect(journal.outboxEvents().map(\.id) == ["c"])
        #expect(journal.ledgerEvents.isEmpty)
        #expect(!journal.hasCoveredOutboxInLog)
        try journal.append(.event(chain.next("d", tokens: 6), uploaded: false))

        let reopened = try Journal(directory: dir)
        #expect(reopened.checkpoint == covered)
        #expect(reopened.ledgerEvents.map(\.id) == ["d"])
        #expect(reopened.pendingUpload.map(\.id) == ["c", "d"])
        let ledger = Ledger(checkpoint: reopened.checkpoint, events: reopened.ledgerEvents)
        #expect(ledger.events.map(\.id) == ["d"])
        #expect(ledger.balance(for: "acct") == 18)
        #expect(ledger.contains("a") && ledger.contains("c") && !ledger.contains("e"))
        #expect(ledger.head(for: "A") == chain.head)
        #expect(ledger.firstBrokenLink() == nil)
        #expect(Ledger(events: [chain.next("e")]).head(for: "A") != ledger.head(for: "A"))

        // Once the carrier acknowledges `c`, the outbox file is pruned (and goes, being empty); `d` gets a marker. The
        // checkpoint stays in front.
        try reopened.acknowledge(["c", "d"])
        #expect(!FileManager.default.fileExists(atPath: reopened.outboxURL.path))
        #expect(reopened.pendingUpload.isEmpty)
        #expect(reopened.uploadMarkerCount == 1)
        try reopened.compact()
        #expect(reopened.entries.count == 2)
        #expect(reopened.checkpoint == covered)
        #expect(reopened.ledgerEvents.map(\.id) == ["d"])
        #expect(reopened.pendingUpload.isEmpty)
        #expect(try Journal(directory: dir).ledgerEvents.map(\.id) == ["d"])
    }

    /// A9: what compaction moves to the outbox file is pushed from there, pruned as the carrier acknowledges it, and a
    /// log that still holds covered unacknowledged events in the old shape says so, so the engine moves them once.
    @Test func the_outbox_file_holds_the_covered_events_until_they_are_acknowledged() throws {
        let dir = makeTemporaryPaywallDirectory()
        var chain = Chain()
        let journal = try Journal(directory: dir, fullSync: false)
        let events = (1...3).map { chain.next("e\($0)", tokens: 1) }
        try journal.append(contentsOf: events.map { .event($0, uploaded: false) })
        let checkpoint = Ledger(events: journal.ledgerEvents).checkpoint()
        // The old shape: the checkpoint in front, the covered events still in the log.
        try journal.append(.checkpoint(checkpoint))
        #expect(journal.ledgerEvents.isEmpty && journal.pendingUpload.count == 3)
        #expect(journal.hasCoveredOutboxInLog)
        try journal.compact()
        #expect(!journal.hasCoveredOutboxInLog)
        #expect(journal.entries == [.checkpoint(checkpoint)])
        #expect(journal.outboxEvents().map(\.id) == ["e1", "e2", "e3"])
        #expect(journal.pendingUpload.map(\.id) == ["e1", "e2", "e3"])
        // Acknowledgements prune the file; an id the file does not hold costs nothing.
        try journal.acknowledge(["e2", "zz"])
        #expect(journal.outboxEvents().map(\.id) == ["e1", "e3"])
        #expect(journal.uploadMarkerCount == 0, "no marker for an event the log no longer holds")
        // A second compaction appends only what the file does not hold yet.
        try journal.append(.event(chain.next("e4"), uploaded: false))
        try journal.compact(checkpoint: Ledger(checkpoint: checkpoint, events: journal.ledgerEvents).checkpoint(), keepingOutbox: true)
        #expect(journal.outboxEvents().map(\.id) == ["e1", "e3", "e4"])
        #expect(try Journal(directory: dir).pendingUpload.map(\.id) == ["e1", "e3", "e4"])
        // A torn tail of the outbox file is truncated when it is read, as the log's is.
        let handle = try FileHandle(forWritingTo: journal.outboxURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([7, 0, 0, 0, 1]))
        try handle.close()
        #expect(journal.outboxEvents().map(\.id) == ["e1", "e3", "e4"])
        #expect(journal.outboxEvents().count == 3)
        // Without a carrier the covered events are dropped, as before, and nothing goes to the file.
        try journal.acknowledge(["e1", "e3", "e4"])
        let plain = try Journal(directory: makeTemporaryPaywallDirectory(), fullSync: false)
        try plain.append(.event(chain.next("p"), uploaded: false))
        try plain.compact(checkpoint: Ledger(events: plain.ledgerEvents).checkpoint(), keepingOutbox: false)
        #expect(!FileManager.default.fileExists(atPath: plain.outboxURL.path) && plain.pendingUpload.isEmpty)
    }

    /// A7: the head of the log is gone (a corrupt first frame): the outbox file goes with it, since the Keychain
    /// baseline counts those events and pushing them on top of it would count them twice; a corrupt frame is told apart
    /// from a torn tail.
    @Test func a_head_drop_takes_the_outbox_file_and_is_reported_as_corruption() throws {
        let dir = makeTemporaryPaywallDirectory()
        var chain = Chain()
        do {
            let journal = try Journal(directory: dir, fullSync: false)
            try journal.append(contentsOf: [chain.next("a"), chain.next("b")].map { .event($0, uploaded: false) })
            try journal.compact(checkpoint: Ledger(events: journal.ledgerEvents).checkpoint(), keepingOutbox: true)
            #expect(FileManager.default.fileExists(atPath: journal.outboxURL.path))
        }
        let url = dir.appendingPathComponent(Journal.fileName)
        var bytes = [UInt8](try Data(contentsOf: url))
        bytes[12] ^= 0xFF
        try Data(bytes).write(to: url)
        let dropped = try Journal(directory: dir)
        #expect(dropped.entries.isEmpty && dropped.droppedCorruptFrame && dropped.droppedTailBytes == bytes.count)
        #expect(!FileManager.default.fileExists(atPath: dropped.outboxURL.path))
        #expect(dropped.pendingUpload.isEmpty)
        // A torn tail is not corruption: the outbox file stays.
        let torn = makeTemporaryPaywallDirectory()
        do {
            let journal = try Journal(directory: torn, fullSync: false)
            try journal.append(.event(chain.next("c"), uploaded: false))
            try journal.compact(checkpoint: Ledger(events: journal.ledgerEvents).checkpoint(), keepingOutbox: true)
            let handle = try FileHandle(forWritingTo: journal.url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([9, 0, 0, 0]))
            try handle.close()
        }
        let reopened = try Journal(directory: torn)
        #expect(!reopened.droppedCorruptFrame && reopened.droppedTailBytes == 4)
        #expect(reopened.outboxEvents().map(\.id) == ["c"])
    }

    /// A6/A7: the cursor and the baseline records are state, kept through compaction: the last cursor in place, after
    /// the events it covers; the baseline that still stands written once; a settled one not at all.
    @Test func compaction_keeps_the_last_cursor_in_place_and_the_standing_baseline() throws {
        let dir = makeTemporaryPaywallDirectory()
        var chain = Chain()
        let journal = try Journal(directory: dir, fullSync: false)
        let snapshot = WalletSnapshot(accountKey: "acct", balance: 7, lastEventID: "old", headHash: "h")
        try journal.append(.baseline(snapshot))
        #expect(journal.baseline == snapshot)
        try journal.append(contentsOf: [.event(chain.next("m1"), uploaded: true), .cursor(Data("1".utf8))])
        try journal.append(.event(chain.next("local"), uploaded: false))
        try journal.append(contentsOf: [.event(chain.next("m2"), uploaded: true), .cursor(Data("2".utf8))])
        #expect(journal.cursor == Data("2".utf8) && journal.cursorCount == 2)
        try journal.compact()
        let ids = journal.entries.map { entry -> String in
            switch entry {
            case .event(let event, _): return event.id
            case .cursor(let data): return "cursor:" + String(decoding: data, as: UTF8.self)
            case .baseline: return "baseline"
            case .baselineSettled: return "settled"
            case .uploaded: return "uploaded"
            case .checkpoint: return "checkpoint"
            }
        }
        #expect(ids == ["baseline", "m1", "local", "m2", "cursor:2"])
        #expect(journal.cursorCount == 1 && journal.cursor == Data("2".utf8) && journal.baseline == snapshot)
        let reopened = try Journal(directory: dir)
        #expect(reopened.cursor == Data("2".utf8) && reopened.baseline == snapshot)
        // Settled: the state is gone from the next compaction.
        try reopened.append(.baselineSettled)
        #expect(reopened.baseline == nil)
        try reopened.compact()
        #expect(reopened.baseline == nil)
        #expect(!reopened.entries.contains { if case .baseline = $0 { true } else { false } })
        #expect(try Journal(directory: dir).baseline == nil)
        // A truncation at the second merge takes its cursor too: the survivor covers only what is left.
        let url = dir.appendingPathComponent(Journal.fileName)
        let full = try Data(contentsOf: url)
        let decoded = Journal.decodeFrames(full)
        var offset = 0
        var frames: [Int] = []
        for entry in decoded.entries {
            frames.append(offset)
            offset += try Journal.frame(entry).count
        }
        // Frames: m1, local, m2, cursor:2. Cut inside m2.
        try full.prefix(frames[2] + 3).write(to: url)
        let cut = try Journal(directory: dir)
        #expect(cut.ledgerEvents.map(\.id) == ["m1", "local"])
        #expect(cut.cursor == nil, "the cursor that covered m2 went with it; the one before was folded away")
    }

    /// A5: a closed journal takes nothing more, so a shut-down engine cannot write next to its successor.
    @Test func a_closed_journal_refuses_every_write() throws {
        let dir = makeTemporaryPaywallDirectory()
        let journal = try Journal(directory: dir, fullSync: false)
        try journal.append(.event(event("a"), uploaded: false))
        journal.close()
        #expect(journal.isClosed)
        #expect(throws: JournalError.writeFailed(errno: EBADF)) { try journal.write(.event(event("b"), uploaded: false)) }
        #expect(throws: JournalError.writeFailed(errno: EBADF)) { try journal.append(contentsOf: [.uploaded(["a"])]) }
        #expect(throws: JournalError.syncFailed(errno: EBADF)) { try journal.sync() }
        #expect(throws: JournalError.writeFailed(errno: EBADF)) { try journal.compact() }
        #expect(throws: JournalError.writeFailed(errno: EBADF)) { try journal.acknowledge(["a"]) }
        journal.close()  // idempotent
        #expect(try Journal(directory: dir).ledgerEvents.map(\.id) == ["a"])
    }

    @Test func without_an_outbox_to_keep_a_checkpoint_covers_the_pending_events_too() throws {
        let dir = makeTemporaryPaywallDirectory()
        var chain = Chain()
        let journal = try Journal(directory: dir, fullSync: false)
        try journal.append(.event(chain.next("a", tokens: 3), uploaded: false))
        try journal.append(.event(chain.next("b", tokens: 4), uploaded: false))
        try journal.compact(checkpoint: Ledger(events: journal.ledgerEvents).checkpoint(), keepingOutbox: false)
        #expect(journal.entries.count == 1)
        #expect(journal.pendingUpload.isEmpty)
        try journal.append(.event(chain.next("c", tokens: 5), uploaded: false))
        let reopened = try Journal(directory: dir)
        #expect(reopened.ledgerEvents.map(\.id) == ["c"])
        #expect(reopened.pendingUpload.map(\.id) == ["c"])
        #expect(Ledger(checkpoint: reopened.checkpoint, events: reopened.ledgerEvents).balance(for: "acct") == 12)
    }

    @Test func a_crash_between_the_checkpoint_and_the_rename_keeps_the_old_log() throws {
        let dir = makeTemporaryPaywallDirectory()
        var chain = Chain()
        let events = [chain.next("a", tokens: 3), chain.next("b", tokens: 4)]
        do {
            let journal = try Journal(directory: dir, fullSync: false)
            try journal.append(contentsOf: events.map { .event($0, uploaded: true) })
        }
        // The side file is complete, synced even, but the process died before `rename(2)`: it is not the log.
        let side = URL(fileURLWithPath: dir.appendingPathComponent(Journal.fileName).path + Journal.compactingSuffix)
        var bytes = try Journal.frame(.checkpoint(Ledger(events: events).checkpoint()))
        bytes += try Journal.frame(.event(chain.next("c"), uploaded: false))
        try Data(bytes).write(to: side)
        let reopened = try Journal(directory: dir)
        #expect(reopened.checkpoint == nil)
        #expect(reopened.ledgerEvents.map(\.id) == ["a", "b"])
        #expect(!FileManager.default.fileExists(atPath: side.path))
    }

    @Test func a_corrupt_or_torn_checkpoint_drops_the_log_like_any_bad_first_frame() throws {
        let dir = makeTemporaryPaywallDirectory()
        var chain = Chain()
        let url = dir.appendingPathComponent(Journal.fileName)
        do {
            let journal = try Journal(directory: dir, fullSync: false)
            try journal.append(.event(chain.next("a", tokens: 3), uploaded: true))
            try journal.compact(checkpoint: Ledger(events: journal.ledgerEvents).checkpoint(), keepingOutbox: true)
            try journal.append(.event(chain.next("b", tokens: 4), uploaded: false))
        }
        let intact = try Data(contentsOf: url)
        let checkpointFrame = try Journal.frame(.checkpoint(Ledger(events: [event("a", tokens: 3, previous: paywallGenesisHash)]).checkpoint())).count
        #expect(Journal.decodeFrames(intact).0.count == 2)

        // A bit flipped inside the checkpoint's payload: the CRC rejects it, and `b` behind it is unreachable.
        var corrupt = [UInt8](intact)
        corrupt[checkpointFrame / 2] ^= 0xFF
        try Data(corrupt).write(to: url)
        let afterCorruption = try Journal(directory: dir)
        #expect(afterCorruption.entries.isEmpty && afterCorruption.checkpoint == nil)
        #expect(afterCorruption.droppedTailBytes == intact.count)
        #expect(Ledger(checkpoint: afterCorruption.checkpoint, events: afterCorruption.ledgerEvents).balance(for: "acct") == 0)

        // Cut short inside the checkpoint: a torn first frame, truncated to nothing.
        try intact.prefix(checkpointFrame - 1).write(to: url)
        let afterTear = try Journal(directory: dir)
        #expect(afterTear.entries.isEmpty)
        #expect(afterTear.droppedTailBytes == checkpointFrame - 1)
        #expect(try Data(contentsOf: url).isEmpty)
        // The log is usable again from there.
        try afterTear.append(.event(chain.next("c", tokens: 5), uploaded: false))
        #expect(try Journal(directory: dir).ledgerEvents.map(\.id) == ["c"])
    }

    @Test func the_last_checkpoint_wins() throws {
        let dir = makeTemporaryPaywallDirectory()
        var chain = Chain()
        let journal = try Journal(directory: dir, fullSync: false)
        let a = chain.next("a", tokens: 3)
        let first = Ledger(events: [a]).checkpoint()
        try journal.append(.checkpoint(first))
        #expect(journal.checkpoint == first)
        let b = chain.next("b", tokens: 4)
        try journal.append(.event(b, uploaded: false))
        #expect(journal.ledgerEvents.map(\.id) == ["b"])
        let second = Ledger(checkpoint: first, events: [b]).checkpoint()
        try journal.append(contentsOf: [.checkpoint(second), .event(chain.next("c", tokens: 5), uploaded: false)])
        #expect(journal.checkpoint == second)
        #expect(journal.ledgerEvents.map(\.id) == ["c"])
        let reopened = try Journal(directory: dir)
        #expect(reopened.checkpoint == second)
        #expect(reopened.ledgerEvents.map(\.id) == ["c"])
        let ledger = Ledger(checkpoint: reopened.checkpoint, events: reopened.ledgerEvents)
        #expect(ledger.balance(for: "acct") == 12)
        #expect(ledger.lastEventID == "c")
        #expect(second.eventCount == 2 && second.lastEventID == "b")
    }

    @Test func a_checkpoint_round_trips_through_its_frame_and_refuses_another_version() throws {
        var chain = Chain()
        var ledger = Ledger(events: [chain.next("grant:1", tokens: 10)])
        ledger.append(
            LedgerEvent(
                id: "debit:1", at: Date(timeIntervalSince1970: 1_000), deviceID: "A", accountKey: "acct",
                source: PaywallSource(id: "g", fileID: "f", function: "t", line: 1), previousHash: ledger.head(for: "A"),
                kind: .debit(tokens: 2, leaseUntil: Date(timeIntervalSince1970: 1_300))))
        let checkpoint = ledger.checkpoint()
        let decoded = Journal.decodeFrames(Data(try Journal.frame(.checkpoint(checkpoint))))
        #expect(decoded.entries == [.checkpoint(checkpoint)])
        #expect(decoded.validLength == (try Journal.frame(.checkpoint(checkpoint))).count)
        #expect(!decoded.corrupt)

        let json = String(decoding: try CanonicalJSON.encoder().encode(checkpoint), as: UTF8.self)
        #expect(json.contains("\"version\":1"))
        #expect(json.contains("\"ids\":[\"grant:1\"]"), "debit ids are stored with their debits only")
        let decoder = CanonicalJSON.decoder()
        #expect(try decoder.decode(LedgerCheckpoint.self, from: Data(json.utf8)) == checkpoint)
        let newer = json.replacingOccurrences(of: "\"version\":1", with: "\"version\":2")
        #expect(throws: DecodingError.self) { try decoder.decode(LedgerCheckpoint.self, from: Data(newer.utf8)) }
        #expect(json.contains("\"debits\":[[\"debit:1\",2,0,1000,1300,\"g\"]]"), "a debit is stored as an array, its account as an index")
        let unknownAccount = json.replacingOccurrences(of: "[\"debit:1\",2,0,", with: "[\"debit:1\",2,7,")
        #expect(unknownAccount != json)
        #expect(throws: DecodingError.self) { try decoder.decode(LedgerCheckpoint.self, from: Data(unknownAccount.utf8)) }
    }
}

/// A9: the outbox file's edges: foreign frames, empty acknowledgements, a closed journal, and every way its writes fail.
@Suite("Outbox file edges")
struct OutboxFileEdgeTests {
    private func event(_ id: String) -> LedgerEvent {
        LedgerEvent(
            id: id, at: Date(timeIntervalSince1970: 1), deviceID: "d", accountKey: unboundAccountKey, source: nil,
            previousHash: paywallGenesisHash, kind: .grant(tokens: 1, reason: "r"))
    }

    @Test func outbox_frames_that_are_not_events_are_skipped() throws {
        let journal = try Journal(directory: makeTemporaryPaywallDirectory())
        var bytes = try Journal.frame(.cursor(Data("7".utf8)))
        bytes += try Journal.frame(.event(event("e1"), uploaded: false))
        try Data(bytes).write(to: journal.outboxURL)
        #expect(journal.outboxEvents().map(\.id) == ["e1"])
        #expect(journal.pendingUpload.map(\.id) == ["e1"])
    }

    @Test func acknowledging_nothing_writes_nothing_and_a_closed_journal_refuses_to_prune() throws {
        let journal = try Journal(directory: makeTemporaryPaywallDirectory())
        try journal.append(.event(event("e1"), uploaded: false))
        let count = journal.entries.count
        try journal.acknowledge([])
        #expect(journal.entries.count == count)
        try Data(try Journal.frame(.event(event("o1"), uploaded: false))).write(to: journal.outboxURL)
        journal.close()
        #expect(throws: JournalError.writeFailed(errno: EBADF)) { try journal.acknowledge(["o1"]) }
        #expect(journal.outboxEvents().map(\.id) == ["o1"])
    }

    /// A full disk while the outbox is appended to or rewritten: the old file stands, no side file is left behind. A
    /// directory where the file should be: the append cannot open it, and the rewrite cannot rename over it.
    @Test func outbox_writes_fail_closed() throws {
        let journal = try Journal(directory: makeTemporaryPaywallDirectory())
        var bytes = try Journal.frame(.event(event("o1"), uploaded: false))
        bytes += try Journal.frame(.event(event("o2"), uploaded: false))
        try Data(bytes).write(to: journal.outboxURL)
        journal.injectedFault = .write
        #expect(throws: JournalError.self) { try journal.acknowledge(["o1"]) }  // the prune rewrites the file
        #expect(throws: JournalError.self) { try journal.writeOutbox([event("o3")], appending: true) }
        journal.injectedFault = nil
        #expect(journal.outboxEvents().map(\.id) == ["o1", "o2"], "the old outbox stands")
        #expect(!FileManager.default.fileExists(atPath: journal.outboxURL.path + Journal.compactingSuffix))
        try journal.acknowledge(["o1"])
        #expect(journal.outboxEvents().map(\.id) == ["o2"])

        let blocked = try Journal(directory: makeTemporaryPaywallDirectory())
        try FileManager.default.createDirectory(at: blocked.outboxURL, withIntermediateDirectories: false)
        #expect(throws: JournalError.self) { try blocked.writeOutbox([event("x")], appending: true) }
        #expect(throws: JournalError.self) { try blocked.writeOutbox([event("x")], appending: false) }
        #expect(blocked.outboxEvents().isEmpty)
    }
}

@Suite("Digests")
struct DigestTests {
    @Test func sha256_known_vectors() {
        #expect(SHA256Digest.hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(SHA256Digest.hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(
            SHA256Digest.hex(String(repeating: "a", count: 1000)).hasPrefix("41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3"))
    }

    @Test func crc32_known_vector() {
        #expect(CRC32.checksum(Array("123456789".utf8)) == 0xCBF4_3926)
    }

    /// RFC 4231 test cases 2 and 3 (a short key, and a key longer than a block).
    @Test func hmac_sha256_known_vectors() {
        let hex = { (data: Data) in data.map { String(format: "%02x", $0) }.joined() }
        #expect(
            hex(HMACSHA256.tag(key: Data("Jefe".utf8), message: Data("what do ya want for nothing?".utf8)))
                == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
        #expect(
            hex(HMACSHA256.tag(key: Data(repeating: 0xAA, count: 131), message: Data("Test Using Larger Than Block-Size Key - Hash Key First".utf8)))
                == "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54")
    }
}
