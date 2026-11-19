public import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// `write(2)` and `close(2)` at file scope, where the names do not collide with `Journal.write(_:)` and `Journal.close()`.
private func posixWrite(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
    write(fd, buffer, count)
}

private func posixClose(_ fd: Int32) {
    _ = close(fd)
}

/// One durable record of `ledger.log`.
public enum JournalEntry: Codable, Hashable, Sendable {
    /// A ledger event. `uploaded` is true for events that came from the sync carrier, and for every event
    /// once compaction folds the upload markers in.
    case event(LedgerEvent, uploaded: Bool)
    /// The sync carrier acknowledged these event ids. The journal doubles as the outbox.
    case uploaded([String])
    /// The ledger's derived state at one point of its history. It stands for every event the log held when it was
    /// written, so compaction can drop them; the ledger starts from the last checkpoint and replays the events after
    /// it. An event after it that the checkpoint already counts is part of the outbox, kept until the carrier
    /// acknowledges it, and reloads as a no-op.
    case checkpoint(LedgerCheckpoint)
    /// The carrier's position once the merged events written before it are durable: what the next pull starts from.
    /// Written in the same `write(2)` as those events, so a truncation that takes the events takes the cursor too, and
    /// the next pull fetches them again.
    case cursor(Data)
    /// The Keychain snapshot adopted at a reinstall: the balance of the history this install has not seen, standing in
    /// until the carrier delivers that history (see `GateEngine.baseline`).
    case baseline(WalletSnapshot)
    /// The baseline has done its job: the carrier delivered the account's history.
    case baselineSettled
}

public enum JournalError: Error, Hashable, Sendable {
    case openFailed(errno: Int32)
    case writeFailed(errno: Int32)
    case syncFailed(errno: Int32)
    case encodingFailed
}

/// `ledger.log`: one framed record per entry (`u32` length, `u32` CRC-32, JSON payload, little endian),
/// appended write-ahead. The single durable authority: leases, the Keychain snapshot and the audit log are
/// derived from it or repaired from it at launch, never the other way round.
///
/// A compacted log starts with a `.checkpoint`, followed by the events appended since. The events the checkpoint
/// counts that the carrier has not acknowledged yet move to `outbox.log` beside it, a second framed file that open never
/// decodes: `pendingUpload` reads it when a push runs, and an acknowledgement prunes it. The engine writes the
/// checkpoint; see "Retention" in HANDBOOK.md for when.
///
/// Not thread-safe by design: the `@MainActor` engine owns the only instance.
public final class Journal {
    public static let fileName = "ledger.log"
    public static let outboxFileName = "outbox.log"
    static let compactingSuffix = ".compacting"

    public let url: URL
    /// The covered, unacknowledged events compaction moved out of `ledger.log`. Absent until a compaction keeps one.
    public let outboxURL: URL
    /// Every entry that survived loading, in file order.
    public private(set) var entries: [JournalEntry] = []
    /// The `.uploaded` markers among `entries`: what compaction removes. Events stay whatever their number.
    public private(set) var uploadMarkerCount = 0
    /// The `.cursor` records among `entries`: compaction keeps the last one only.
    public private(set) var cursorCount = 0
    /// The last `.checkpoint` among `entries`: where the ledger starts from. `nil` for a log that was never
    /// checkpointed, whose events all replay from genesis.
    public private(set) var checkpoint: LedgerCheckpoint?
    /// The carrier's position as of the last durable merge, `nil` before the first one (or after a head drop).
    public private(set) var cursor: Data?
    /// The adopted Keychain snapshot that still stands, `nil` once settled or never adopted.
    public private(set) var baseline: WalletSnapshot?
    /// Bytes dropped from the end of the file during the last load: a torn tail, or a corrupt frame and everything after it.
    public private(set) var droppedTailBytes = 0
    /// Whether the load dropped a complete frame that failed its CRC or did not decode (storage corruption, or a record
    /// of a newer format), as opposed to a torn tail. Events the drop took may come back from the carrier, so the
    /// engine starts a new device stream rather than fork the old one.
    public private(set) var droppedCorruptFrame = false
    /// Compact at open when the log holds more upload markers and cursor records than this. Markers and cursors, not
    /// records: events never leave the log at open, so a count of records would rewrite a long history at every launch
    /// for nothing. The engine uses the same threshold for the events since the last checkpoint when it decides to
    /// write a new one.
    public let compactionThreshold: Int
    /// Whether this open rewrote the log.
    public private(set) var compactedOnOpen = false
    /// `false` uses `fsync` only, trading power-loss durability for latency (open decision in the design).
    public let fullSync: Bool
    /// Set by `close()`: a shut-down engine writes nothing more, its successor owns the files. Every later write fails.
    public private(set) var isClosed = false

    private var fd: Int32 = -1

    /// Test seam for the crash-safety suite: makes the next writes or syncs fail as a full disk would. `shortWrite`
    /// lands half a frame and lets the rewind succeed; `poison` lands half a frame and makes the rewind fail.
    enum Fault { case write, shortWrite, poison, sync, truncate }
    var injectedFault: Fault?
    /// Set when a partial frame could not be rewound: the frame boundary is unknown, so nothing more is written
    /// until a relaunch reloads the file and drops the torn tail. Every write fails closed meanwhile.
    private(set) var isPoisoned = false

    /// Opens (creating if needed) the journal in `directory`, drops a torn tail, deletes the partial file of an
    /// interrupted compaction, and compacts when past the threshold.
    public convenience init(directory: URL, compactionThreshold: Int = 4096, fullSync: Bool = true) throws(JournalError) {
        try self.init(directory: directory, compactionThreshold: compactionThreshold, fullSync: fullSync, injecting: nil)
    }

    /// The test seam for faults that happen while opening (a torn tail that cannot be truncated).
    init(directory: URL, compactionThreshold: Int = 4096, fullSync: Bool = true, injecting fault: Fault?) throws(JournalError) {
        self.url = directory.appendingPathComponent(Self.fileName)
        self.outboxURL = directory.appendingPathComponent(Self.outboxFileName)
        self.compactionThreshold = compactionThreshold
        self.fullSync = fullSync
        self.injectedFault = fault
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // An interrupted compaction never renamed its file: the old log wins and the partial file goes.
        try? FileManager.default.removeItem(at: compactingURL)
        try load()
        if uploadMarkerCount + cursorCount > compactionThreshold {
            try compact()
            compactedOnOpen = true
        } else {
            try openForAppend()
        }
    }

    deinit {
        if fd >= 0 { posixClose(fd) }
    }

    private var compactingURL: URL { URL(fileURLWithPath: url.path + Self.compactingSuffix) }

    /// Closes the file. The engine calls it from `shutdown()`: a successor may own the directory from then on, so
    /// every later write and rewrite fails with `EBADF` instead of landing next to the successor's records.
    public func close() {
        isClosed = true
        if fd >= 0 {
            posixClose(fd)
            fd = -1
        }
    }

    // MARK: Loading

    private func load() throws(JournalError) {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            entries = []
            return
        }
        let decoded = Self.decodeFrames(data)
        entries = decoded.entries
        for entry in decoded.entries { note(entry) }
        droppedTailBytes = data.count - decoded.validLength
        droppedCorruptFrame = decoded.corrupt
        if droppedTailBytes > 0 {
            // A torn tail can only be a partial last write (power loss); a corrupt frame hides everything after it.
            // Truncate so the next append is clean.
            guard injectedFault != .truncate, truncate(url.path, off_t(decoded.validLength)) == 0 else { throw .writeFailed(errno: errno) }
            if entries.isEmpty {
                // The whole history is gone: the outbox held events a checkpoint counted, and the checkpoint went with
                // it. The Keychain baseline counts them; pushing them on top of it would count them twice.
                try? FileManager.default.removeItem(at: outboxURL)
            }
        }
    }

    /// Keeps the counts and the state records in step with `entries` as records arrive.
    private func note(_ entry: JournalEntry) {
        switch entry {
        case .uploaded: uploadMarkerCount += 1
        case .checkpoint(let checkpoint): self.checkpoint = checkpoint
        case .cursor(let cursor):
            self.cursor = cursor
            cursorCount += 1
        case .baseline(let snapshot): baseline = snapshot
        case .baselineSettled: baseline = nil
        case .event: break
        }
    }

    /// Decodes frames until the first one that is short, fails its CRC, or does not decode. Returns the entries, the
    /// byte length of the valid prefix, and whether the stop was a complete frame that failed (corruption) rather than
    /// a short one (a torn tail).
    static func decodeFrames(_ data: Data) -> (entries: [JournalEntry], validLength: Int, corrupt: Bool) {
        let bytes = [UInt8](data)
        let decoder = CanonicalJSON.decoder()
        var entries: [JournalEntry] = []
        var offset = 0
        while offset + 8 <= bytes.count {
            let length = Int(readU32(bytes, offset))
            let crc = readU32(bytes, offset + 4)
            let start = offset + 8
            guard length <= bytes.count - start else { break }
            let payload = bytes[start..<(start + length)]
            guard CRC32.checksum(payload) == crc,
                let entry = try? decoder.decode(JournalEntry.self, from: Data(payload))
            else { return (entries, offset, true) }
            entries.append(entry)
            offset = start + length
        }
        return (entries, offset, false)
    }

    static func frame(_ entry: JournalEntry) throws(JournalError) -> [UInt8] {
        guard let payload = try? CanonicalJSON.encoder().encode(entry) else { throw .encodingFailed }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(payload.count + 8)
        appendU32(&bytes, UInt32(payload.count))
        appendU32(&bytes, CRC32.checksum(payload))
        bytes.append(contentsOf: payload)
        return bytes
    }

    private static func readU32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }

    private static func appendU32(_ bytes: inout [UInt8], _ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8(truncatingIfNeeded: value >> UInt32(shift))) }
    }

    // MARK: Appending

    private func openForAppend() throws(JournalError) {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard descriptor >= 0 else { throw .openFailed(errno: errno) }
        fd = descriptor
    }

    /// Step 2 of the write-ahead order: one `write(2)` of the whole frame. When it returns, the bytes belong to
    /// the kernel's page cache, which outlives the process.
    public func write(_ entry: JournalEntry) throws(JournalError) {
        try writeFully(fd, Self.frame(entry))
        entries.append(entry)
        note(entry)
    }

    private func writeFully(_ descriptor: Int32, _ bytes: [UInt8]) throws(JournalError) {
        guard !isClosed else { throw .writeFailed(errno: EBADF) }
        guard !isPoisoned else { throw .writeFailed(errno: EIO) }
        let end = lseek(descriptor, 0, SEEK_END)
        let written: Int
        switch injectedFault {
        case .write:
            written = -1
        case .shortWrite, .poison:
            written = bytes.withUnsafeBytes { buffer in posixWrite(descriptor, buffer.baseAddress, buffer.count / 2) }
        case .sync, .truncate, nil:
            written = bytes.withUnsafeBytes { buffer in posixWrite(descriptor, buffer.baseAddress, buffer.count) }
        }
        guard written == bytes.count else {
            let failure = errno
            // A partial frame left in the middle of the log would hide every record after it from the next load:
            // rewind to the frame boundary, and if even that fails, stop writing until a relaunch truncates it.
            if !rewind(descriptor, to: end) { isPoisoned = true }
            throw .writeFailed(errno: failure)
        }
    }

    /// Puts the file end back where it was before a failed write. `false` when the boundary is lost.
    private func rewind(_ descriptor: Int32, to end: off_t) -> Bool {
        injectedFault != .poison && end >= 0 && ftruncate(descriptor, end) == 0
    }

    /// Step 3: `F_FULLFSYNC` on Apple platforms, because `fsync` alone does not flush the drive's own cache.
    public func sync() throws(JournalError) {
        guard !isClosed else { throw .syncFailed(errno: EBADF) }
        try syncDescriptor(fd)
    }

    private func syncDescriptor(_ descriptor: Int32) throws(JournalError) {
        #if canImport(Darwin)
            if fullSync, injectedFault != .sync, fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        #endif
        guard injectedFault != .sync, fsync(descriptor) == 0 else { throw .syncFailed(errno: errno) }
    }

    /// `write` then `sync`.
    public func append(_ entry: JournalEntry) throws(JournalError) {
        try write(entry)
        try sync()
    }

    /// Several entries in one `write(2)` and one sync (sync merges).
    public func append(contentsOf newEntries: [JournalEntry]) throws(JournalError) {
        guard !newEntries.isEmpty else { return }
        var bytes: [UInt8] = []
        for entry in newEntries { bytes += try Self.frame(entry) }
        try writeFully(fd, bytes)
        entries += newEntries
        for entry in newEntries { note(entry) }
        try sync()
    }

    // MARK: Outbox

    /// The ids the markers in the log acknowledge.
    private var acknowledgedInLog: Set<String> {
        var acknowledged: Set<String> = []
        for entry in entries {
            if case .uploaded(let ids) = entry { acknowledged.formUnion(ids) }
        }
        return acknowledged
    }

    /// The events in the log with no upload acknowledgement yet, in write order.
    private var pendingInLog: [LedgerEvent] {
        let acknowledged = acknowledgedInLog
        return entries.compactMap { entry in
            guard case .event(let event, let uploaded) = entry, !uploaded, !acknowledged.contains(event.id) else {
                return nil
            }
            return event
        }
    }

    /// Ledger events with no upload acknowledgement yet, in write order: the outbox file first (what compaction
    /// moved out of the log), then the log's own. Reads `outbox.log` when it exists.
    public var pendingUpload: [LedgerEvent] {
        var seen: Set<String> = []
        return (outboxEvents() + pendingInLog).filter { seen.insert($0.id).inserted }
    }

    /// The events of `outbox.log`, decoded on demand: what a checkpoint counts that the carrier never acknowledged.
    /// A torn tail (a power loss during the append) is truncated, as in the log.
    public func outboxEvents() -> [LedgerEvent] {
        guard let data = FileManager.default.contents(atPath: outboxURL.path) else { return [] }
        let decoded = Self.decodeFrames(data)
        if decoded.validLength < data.count { _ = truncate(outboxURL.path, off_t(decoded.validLength)) }
        return decoded.entries.compactMap { entry in
            if case .event(let event, _) = entry { return event }
            return nil
        }
    }

    /// Whether the log still holds covered, unacknowledged events in the shape earlier builds wrote, before the
    /// outbox file existed: the engine compacts once to move them out.
    public var hasCoveredOutboxInLog: Bool {
        guard let checkpoint else { return false }
        return pendingInLog.contains { checkpoint.ids.contains($0.id) }
    }

    /// Records what the carrier acknowledged: a marker in the log for the events still in it, and a prune of the
    /// outbox file for the ones it holds. Either half is idempotent, so a crash between them costs one re-push.
    public func acknowledge(_ ids: [String]) throws(JournalError) {
        guard !ids.isEmpty else { return }
        var inLog: Set<String> = []
        for entry in entries {
            if case .event(let event, _) = entry { inLog.insert(event.id) }
        }
        let markers = ids.filter(inLog.contains)
        if !markers.isEmpty { try append(.uploaded(markers)) }
        try pruneOutbox(removing: Set(ids))
    }

    /// Rewrites `outbox.log` without `ids`, when it holds any of them.
    private func pruneOutbox(removing ids: Set<String>) throws(JournalError) {
        guard !isClosed else { throw .writeFailed(errno: EBADF) }
        let events = outboxEvents()
        let kept = events.filter { !ids.contains($0.id) }
        guard kept.count < events.count else { return }
        if kept.isEmpty {
            try? FileManager.default.removeItem(at: outboxURL)
            return
        }
        try writeOutbox(kept, appending: false)
    }

    /// Appends `events` to `outbox.log` (or replaces it) and syncs it, through a side file and a rename when replacing.
    func writeOutbox(_ events: [LedgerEvent], appending: Bool) throws(JournalError) {
        var bytes: [UInt8] = []
        for event in events { bytes += try Self.frame(.event(event, uploaded: false)) }
        let target = appending ? outboxURL : URL(fileURLWithPath: outboxURL.path + Self.compactingSuffix)
        let descriptor = open(target.path, O_WRONLY | O_CREAT | (appending ? O_APPEND : O_TRUNC), 0o600)
        guard descriptor >= 0 else { throw .openFailed(errno: errno) }
        do {
            try writeFully(descriptor, bytes)
            try syncDescriptor(descriptor)
        } catch {
            posixClose(descriptor)
            if !appending { try? FileManager.default.removeItem(at: target) }
            throw error
        }
        posixClose(descriptor)
        if !appending {
            guard rename(target.path, outboxURL.path) == 0 else { throw .writeFailed(errno: errno) }
        }
    }

    /// The events the ledger replays on top of `checkpoint`: every event after the last checkpoint, the outbox it
    /// already counts included (the ledger ignores those by id). Every event, for a log without a checkpoint.
    public var ledgerEvents: [LedgerEvent] {
        var events: [LedgerEvent] = []
        for entry in entries {
            switch entry {
            case .event(let event, _): events.append(event)
            case .uploaded, .cursor, .baseline, .baselineSettled: break
            case .checkpoint: events.removeAll()
            }
        }
        return events
    }

    // MARK: Compaction

    /// Rewrites the log with the upload markers folded into the events, to a side file that is synced and then
    /// renamed over the log. A crash before the rename leaves the old log intact. An existing checkpoint stays in
    /// front, the events it counts that the carrier has acknowledged since are dropped, and the ones it has not go to
    /// the outbox file.
    public func compact() throws(JournalError) {
        try rewrite(checkpoint: checkpoint, keepingOutbox: true)
    }

    /// Rewrites the log behind `checkpoint`: the checkpoint first, then the baseline that still stands, then every event
    /// it does not count with the upload markers folded in and the last cursor in place. The events it counts that the
    /// carrier has not acknowledged (the outbox) move to `outbox.log`, unless `keepingOutbox` is false because no carrier
    /// will ever acknowledge them. Same side file and rename as `compact()`; an interrupted rewrite leaves the old log
    /// intact, and an outbox written before the rename only re-pushes what the carrier holds already.
    public func compact(checkpoint: LedgerCheckpoint, keepingOutbox: Bool) throws(JournalError) {
        try rewrite(checkpoint: checkpoint, keepingOutbox: keepingOutbox)
    }

    private func rewrite(checkpoint: LedgerCheckpoint?, keepingOutbox: Bool) throws(JournalError) {
        guard !isClosed else { throw .writeFailed(errno: EBADF) }
        let pending = Set(pendingInLog.map(\.id))
        var folded: [JournalEntry] = []
        if let checkpoint { folded.append(.checkpoint(checkpoint)) }
        if let baseline { folded.append(.baseline(baseline)) }
        var toOutbox: [LedgerEvent] = []
        var lastCursor: Int?
        for entry in entries {
            switch entry {
            case .event(let event, _):
                let acknowledged = !pending.contains(event.id)
                if let checkpoint, checkpoint.ids.contains(event.id) {
                    // An event the checkpoint counts has nothing left to say once the carrier holds it; until then it
                    // waits in the outbox file, where no open decodes it.
                    if !acknowledged, keepingOutbox { toOutbox.append(event) }
                    continue
                }
                folded.append(.event(event, uploaded: acknowledged))
            case .cursor:
                // The last cursor stays where it is: after every merged event it covers.
                if let lastCursor { folded.remove(at: lastCursor) }
                folded.append(entry)
                lastCursor = folded.count - 1
            case .uploaded, .checkpoint, .baseline, .baselineSettled:
                // Markers fold into the flag; an older checkpoint is superseded by the one in front; the baseline state
                // is written once, at the front.
                continue
            }
        }
        if !toOutbox.isEmpty {
            // Durable before the log forgets them: a crash between here and the rename leaves them in both places,
            // and `pendingUpload` dedups by id.
            var seen = Set(outboxEvents().map(\.id))
            let fresh = toOutbox.filter { seen.insert($0.id).inserted }
            if !fresh.isEmpty { try writeOutbox(fresh, appending: true) }
        }
        var bytes: [UInt8] = []
        for entry in folded { bytes += try Self.frame(entry) }
        let side = open(compactingURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard side >= 0 else { throw .openFailed(errno: errno) }
        do {
            try writeFully(side, bytes)
        } catch {
            posixClose(side)
            try? FileManager.default.removeItem(at: compactingURL)
            throw error
        }
        #if canImport(Darwin)
            _ = fcntl(side, F_FULLFSYNC)
        #else
            _ = fsync(side)
        #endif
        posixClose(side)
        if fd >= 0 {
            posixClose(fd)
            fd = -1
        }
        guard rename(compactingURL.path, url.path) == 0 else { throw .writeFailed(errno: errno) }
        entries = folded
        uploadMarkerCount = 0
        cursorCount = lastCursor == nil ? 0 : 1
        self.checkpoint = checkpoint
        try openForAppend()
    }
}
