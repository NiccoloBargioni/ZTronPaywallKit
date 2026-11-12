public import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// `write(2)` at file scope, where the name does not collide with `Journal.write(_:)`.
private func posixWrite(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
    write(fd, buffer, count)
}

/// One durable record of `ledger.log`.
public enum JournalEntry: Codable, Hashable, Sendable {
    /// A ledger event. `uploaded` is true for events that came from the sync carrier, and for every event
    /// once compaction folds the upload markers in.
    case event(LedgerEvent, uploaded: Bool)
    /// The sync carrier acknowledged these event ids. The journal doubles as the outbox.
    case uploaded([String])
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
/// Not thread-safe by design: the `@MainActor` engine owns the only instance.
public final class Journal {
    public static let fileName = "ledger.log"
    static let compactingSuffix = ".compacting"

    public let url: URL
    /// Every entry that survived loading, in file order.
    public private(set) var entries: [JournalEntry] = []
    /// Bytes dropped from a torn tail during the last load.
    public private(set) var droppedTailBytes = 0
    /// Compact when the log holds more records than this at open.
    public let compactionThreshold: Int
    /// `false` uses `fsync` only, trading power-loss durability for latency (open decision in the design).
    public let fullSync: Bool

    private var fd: Int32 = -1

    /// Test seam for the crash-safety suite: makes the next writes or syncs fail as a full disk would.
    enum Fault { case write, sync, truncate }
    var injectedFault: Fault?

    /// Opens (creating if needed) the journal in `directory`, drops a torn tail, deletes the partial file of an
    /// interrupted compaction, and compacts when past the threshold.
    public convenience init(directory: URL, compactionThreshold: Int = 4096, fullSync: Bool = true) throws(JournalError) {
        try self.init(directory: directory, compactionThreshold: compactionThreshold, fullSync: fullSync, injecting: nil)
    }

    /// The test seam for faults that happen while opening (a torn tail that cannot be truncated).
    init(directory: URL, compactionThreshold: Int = 4096, fullSync: Bool = true, injecting fault: Fault?) throws(JournalError) {
        self.url = directory.appendingPathComponent(Self.fileName)
        self.compactionThreshold = compactionThreshold
        self.fullSync = fullSync
        self.injectedFault = fault
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // An interrupted compaction never renamed its file: the old log wins and the partial file goes.
        try? FileManager.default.removeItem(at: compactingURL)
        try load()
        if entries.count > compactionThreshold { try compact() } else { try openForAppend() }
    }

    deinit {
        if fd >= 0 { close(fd) }
    }

    private var compactingURL: URL { URL(fileURLWithPath: url.path + Self.compactingSuffix) }

    // MARK: Loading

    private func load() throws(JournalError) {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            entries = []
            return
        }
        let (decoded, goodLength) = Self.decodeFrames(data)
        entries = decoded
        droppedTailBytes = data.count - goodLength
        if droppedTailBytes > 0 {
            // A torn tail can only be a partial last write (power loss). Truncate it so the next append is clean.
            guard injectedFault != .truncate, truncate(url.path, off_t(goodLength)) == 0 else { throw .writeFailed(errno: errno) }
        }
    }

    /// Decodes frames until the first one that is short, fails its CRC, or does not decode.
    /// Returns the entries and the byte length of the valid prefix.
    static func decodeFrames(_ data: Data) -> ([JournalEntry], Int) {
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
            else { break }
            entries.append(entry)
            offset = start + length
        }
        return (entries, offset)
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
    }

    private func writeFully(_ descriptor: Int32, _ bytes: [UInt8]) throws(JournalError) {
        let written = injectedFault == .write ? -1 : bytes.withUnsafeBytes { buffer in
            posixWrite(descriptor, buffer.baseAddress, buffer.count)
        }
        guard written == bytes.count else { throw .writeFailed(errno: errno) }
    }

    /// Step 3: `F_FULLFSYNC` on Apple platforms, because `fsync` alone does not flush the drive's own cache.
    public func sync() throws(JournalError) {
        #if canImport(Darwin)
            if fullSync, injectedFault != .sync, fcntl(fd, F_FULLFSYNC) == 0 { return }
        #endif
        guard injectedFault != .sync, fsync(fd) == 0 else { throw .syncFailed(errno: errno) }
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
        try sync()
    }

    // MARK: Outbox

    /// Ledger events with no upload acknowledgement yet, in write order.
    public var pendingUpload: [LedgerEvent] {
        var acknowledged: Set<String> = []
        for entry in entries {
            if case .uploaded(let ids) = entry { acknowledged.formUnion(ids) }
        }
        return entries.compactMap { entry in
            guard case .event(let event, let uploaded) = entry, !uploaded, !acknowledged.contains(event.id) else {
                return nil
            }
            return event
        }
    }

    public var ledgerEvents: [LedgerEvent] {
        entries.compactMap { entry in
            if case .event(let event, _) = entry { return event }
            return nil
        }
    }

    // MARK: Compaction

    /// Rewrites the log with the upload markers folded into the events, to a side file that is synced and then
    /// renamed over the log. A crash before the rename leaves the old log intact.
    public func compact() throws(JournalError) {
        let pending = Set(pendingUpload.map(\.id))
        let folded: [JournalEntry] = ledgerEvents.map { .event($0, uploaded: !pending.contains($0.id)) }
        var bytes: [UInt8] = []
        for entry in folded { bytes += try Self.frame(entry) }
        let side = open(compactingURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard side >= 0 else { throw .openFailed(errno: errno) }
        do {
            try writeFully(side, bytes)
        } catch {
            close(side)
            try? FileManager.default.removeItem(at: compactingURL)
            throw error
        }
        #if canImport(Darwin)
            _ = fcntl(side, F_FULLFSYNC)
        #else
            _ = fsync(side)
        #endif
        close(side)
        if fd >= 0 {
            close(fd)
            fd = -1
        }
        guard rename(compactingURL.path, url.path) == 0 else { throw .writeFailed(errno: errno) }
        entries = folded
        try openForAppend()
    }
}
