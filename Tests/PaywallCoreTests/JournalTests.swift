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
        // `a` and `b` are acknowledged and counted: gone. `c` is the outbox: kept behind the checkpoint.
        #expect(journal.entries.count == 2)
        #expect(journal.entries.first == .checkpoint(covered))
        #expect(journal.checkpoint == covered)
        #expect(covered.eventCount == 3)
        #expect(journal.pendingUpload.map(\.id) == ["c"])
        #expect(journal.ledgerEvents.map(\.id) == ["c"])
        try journal.append(.event(chain.next("d", tokens: 6), uploaded: false))

        let reopened = try Journal(directory: dir)
        #expect(reopened.checkpoint == covered)
        #expect(reopened.ledgerEvents.map(\.id) == ["c", "d"])
        #expect(reopened.pendingUpload.map(\.id) == ["c", "d"])
        let ledger = Ledger(checkpoint: reopened.checkpoint, events: reopened.ledgerEvents)
        #expect(ledger.events.map(\.id) == ["d"], "the outbox is a replay to the ledger")
        #expect(ledger.balance(for: "acct") == 18)
        #expect(ledger.contains("a") && ledger.contains("c") && !ledger.contains("e"))
        #expect(ledger.head(for: "A") == chain.head)
        #expect(ledger.firstBrokenLink() == nil)
        #expect(Ledger(events: [chain.next("e")]).head(for: "A") != ledger.head(for: "A"))

        // Once the carrier acknowledges `c`, the marker compaction drops it; the checkpoint stays in front.
        try reopened.append(.uploaded(["c"]))
        try reopened.compact()
        #expect(reopened.entries.count == 2)
        #expect(reopened.checkpoint == covered)
        #expect(reopened.ledgerEvents.map(\.id) == ["d"])
        #expect(reopened.pendingUpload.map(\.id) == ["d"])
        #expect(try Journal(directory: dir).ledgerEvents.map(\.id) == ["d"])
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
        let (decoded, length) = Journal.decodeFrames(Data(try Journal.frame(.checkpoint(checkpoint))))
        #expect(decoded == [.checkpoint(checkpoint)])
        #expect(length == (try Journal.frame(.checkpoint(checkpoint))).count)

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
}
