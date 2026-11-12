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
        let compacted = try Journal(directory: dir, compactionThreshold: 2)
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
