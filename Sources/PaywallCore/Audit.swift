public import Foundation

/// One line of the audit log: an event with the state around it, so the log alone can reconstruct a dispute.
public struct AuditRecord: Codable, Hashable, Sendable {
    /// Wall clock.
    public let at: Date
    /// Monotonic, to spot clock changes.
    public let uptime: TimeInterval
    /// One per process launch.
    public let sessionID: UUID
    public let deviceID: String
    public let appVersion: String
    public let build: String
    /// `production`, `sandbox`, `xcode`, or `simulated`.
    public let environment: String
    public let event: PaywallEvent
    public let entitlementBefore: Entitlement
    public let entitlementAfter: Entitlement
    public let balanceBefore: Int
    public let balanceAfter: Int
    /// SHA-256 of the previous record: the same chain as the ledger.
    public let previousHash: String

    public init(
        at: Date, uptime: TimeInterval, sessionID: UUID, deviceID: String, appVersion: String, build: String,
        environment: String, event: PaywallEvent, entitlementBefore: Entitlement, entitlementAfter: Entitlement,
        balanceBefore: Int, balanceAfter: Int, previousHash: String
    ) {
        self.at = at
        self.uptime = uptime
        self.sessionID = sessionID
        self.deviceID = deviceID
        self.appVersion = appVersion
        self.build = build
        self.environment = environment
        self.event = event
        self.entitlementBefore = entitlementBefore
        self.entitlementAfter = entitlementAfter
        self.balanceBefore = balanceBefore
        self.balanceAfter = balanceAfter
        self.previousHash = previousHash
    }

    public var hash: String {
        SHA256Digest.hex((try? CanonicalJSON.encoder().encode(self)) ?? Data())
    }

    /// The first record whose `previousHash` does not match the record before it, the chain starting from
    /// `anchor`: genesis for a log that was never rotated out, else the hash the last dropped record had
    /// (`JournalSink.chainAnchor()`).
    public static func firstBrokenLink(in records: [AuditRecord], after anchor: String = paywallGenesisHash) -> AuditRecord? {
        var previous = anchor
        for record in records {
            if record.previousHash != previous { return record }
            previous = record.hash
        }
        return nil
    }
}

/// Where audit records go. Writes happen off the main actor, in order, after the record was enqueued.
public protocol PaywallAuditSink: Sendable {
    func write(_ record: AuditRecord) async
}

/// A sink that can tell which debits it already recorded, so the engine can repair missing records at launch.
public protocol PaywallAuditRepairing: PaywallAuditSink {
    func recordedDebitIDs() async -> Set<String>
    func lastRecordHash() async -> String?
    /// The `at` of the oldest record the sink still holds once it has dropped older ones; `nil` while it holds
    /// everything it ever wrote. The launch repair leaves debits older than this alone: their records may simply
    /// have been dropped.
    func retainedSince() async -> Date?
}

extension PaywallAuditRepairing {
    public func retainedSince() async -> Date? { nil }
}

/// Forwards every record to a closure: the hook for analytics.
public struct ClosureSink: PaywallAuditSink {
    private let body: @Sendable (AuditRecord) async -> Void
    public init(_ body: @escaping @Sendable (AuditRecord) async -> Void) { self.body = body }
    public func write(_ record: AuditRecord) async { await body(record) }
}

/// `audit.jsonl` in the paywall directory, rotated at `maxBytes`, oldest file dropped past `maxFiles`. Dropping a
/// file writes `audit.anchor`, the hash of the last record dropped: where the retained chain continues from.
/// File I/O runs on this actor (the design's DurabilityWorker), never on the main actor.
public actor JournalSink: PaywallAuditRepairing {
    public static let fileName = "audit.jsonl"
    public static let anchorFileName = "audit.anchor"
    public let directory: URL
    public let maxBytes: Int
    public let maxFiles: Int

    public init(directory: URL, maxBytes: Int = 5 * 1024 * 1024, maxFiles: Int = 10) {
        self.directory = directory
        self.maxBytes = maxBytes
        self.maxFiles = maxFiles
    }

    private var currentURL: URL { directory.appendingPathComponent(Self.fileName) }

    private var anchorURL: URL { directory.appendingPathComponent(Self.anchorFileName) }

    private func rotatedURL(_ index: Int) -> URL { directory.appendingPathComponent("audit.\(index).jsonl") }

    /// The current file, then `audit.1.jsonl`, `audit.2.jsonl`, … up to the oldest slot.
    private var urlsNewestFirst: [URL] { [currentURL] + (1..<max(maxFiles, 1)).map(rotatedURL) }

    public func write(_ record: AuditRecord) async {
        guard var line = try? CanonicalJSON.encoder().encode(record) else { return }
        line.append(0x0A)
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: currentURL.path)[.size]) as? Int, size + line.count > maxBytes {
            rotate()
        }
        if let handle = try? FileHandle(forWritingTo: currentURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            _ = fm.createFile(atPath: currentURL.path, contents: line)
        }
    }

    /// Shifts the files up one slot and drops the oldest. The last record of the dropped file becomes the anchor
    /// the retained chain is verified from, and marks that records have been dropped at all.
    private func rotate() {
        let fm = FileManager.default
        let dropped = maxFiles > 1 ? rotatedURL(maxFiles - 1) : currentURL
        if let last = Self.edgeRecord(of: dropped, last: true) {
            try? Data(last.hash.utf8).write(to: anchorURL, options: .atomic)
        }
        try? fm.removeItem(at: dropped)
        if maxFiles > 1 {
            for index in stride(from: maxFiles - 2, through: 1, by: -1) where fm.fileExists(atPath: rotatedURL(index).path) {
                try? fm.moveItem(at: rotatedURL(index), to: rotatedURL(index + 1))
            }
            try? fm.moveItem(at: currentURL, to: rotatedURL(1))
        }
    }

    /// Every record, oldest file first.
    public func records() -> [AuditRecord] {
        urlsNewestFirst.reversed().flatMap(Self.records(in:))
    }

    private static func records(in url: URL) -> [AuditRecord] {
        guard let data = FileManager.default.contents(atPath: url.path) else { return [] }
        let decoder = CanonicalJSON.decoder()
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(AuditRecord.self, from: Data($0)) }
    }

    /// The first (or last) record of `url` that decodes, scanning from that end, so a torn line is skipped and
    /// nothing else in the file is decoded.
    private static func edgeRecord(of url: URL, last: Bool) -> AuditRecord? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        let decoder = CanonicalJSON.decoder()
        var lines = data.split(separator: 0x0A)
        if last { lines.reverse() }
        for line in lines {
            if let record = try? decoder.decode(AuditRecord.self, from: Data(line)) { return record }
        }
        return nil
    }

    /// The debits the retained files know: consumed, refunded, or repaired already.
    public func recordedDebitIDs() async -> Set<String> {
        Set(
            records().compactMap { record in
                switch record.event {
                case .tokensConsumed(_, _, let debitID, _), .tokensRefunded(let debitID, _), .auditRepaired(let debitID):
                    return debitID
                default:
                    return nil
                }
            })
    }

    /// The hash of the newest record, read from the tail of the newest file that has one.
    public func lastRecordHash() async -> String? {
        for url in urlsNewestFirst {
            if let record = Self.edgeRecord(of: url, last: true) { return record.hash }
        }
        return nil
    }

    /// The `at` of the oldest record on disk once rotation has dropped a file; `nil` while every record ever
    /// written is still here; `.distantFuture` when a file was dropped and nothing survives.
    public func retainedSince() async -> Date? {
        guard FileManager.default.fileExists(atPath: anchorURL.path) else { return nil }
        for url in urlsNewestFirst.reversed() {
            if let record = Self.edgeRecord(of: url, last: false) { return record.at }
        }
        return .distantFuture
    }

    /// Where the retained chain starts: the hash of the last record rotation dropped, or genesis.
    public func chainAnchor() -> String {
        guard let data = FileManager.default.contents(atPath: anchorURL.path), let anchor = String(data: data, encoding: .utf8)
        else { return paywallGenesisHash }
        return anchor
    }

    /// The audit files present on disk, for export: the records and, once rotation dropped a file, the anchor.
    public func fileURLs() -> [URL] {
        (urlsNewestFirst + [anchorURL]).filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

/// Builds the chained records on the main actor and hands them to the sinks, in order, on one stored task.
@MainActor
final class AuditTrail {
    private enum Item: Sendable {
        case record(AuditRecord)
        case barrier(CheckedContinuation<Void, Never>)
    }

    private let continuation: AsyncStream<Item>.Continuation
    private let drain: Task<Void, Never>
    private(set) var lastHash: String = paywallGenesisHash
    /// `false` until the repairing sinks reported where their chain ends; records wait here meanwhile.
    private var isReady: Bool
    private var waiting: [(String) -> AuditRecord] = []
    private var isDiscarding = false

    init(sinks: [any PaywallAuditSink], ready: Bool) {
        self.isReady = ready
        let (stream, continuation) = AsyncStream<Item>.makeStream()
        self.continuation = continuation
        self.drain = Task.detached {
            for await item in stream {
                switch item {
                case .record(let record):
                    for sink in sinks { await sink.write(record) }
                case .barrier(let done):
                    done.resume()
                }
            }
        }
    }

    /// Continues the chain after `hash` and releases the records that waited for it.
    func resume(after hash: String) {
        lastHash = hash
        isReady = true
        let pending = waiting
        waiting = []
        for make in pending { record(make) }
    }

    func record(_ make: @escaping (String) -> AuditRecord) {
        guard !isDiscarding else { return }
        guard isReady else {
            waiting.append(make)
            return
        }
        let record = make(lastHash)
        lastHash = record.hash
        continuation.yield(.record(record))
    }

    /// The process "died": nothing more is written.
    func discardPending() {
        isDiscarding = true
        waiting = []
    }

    /// Waits until every record enqueued so far reached every sink.
    func flush() async {
        await withCheckedContinuation { done in
            if case .terminated = continuation.yield(.barrier(done)) { done.resume() }
        }
    }

    deinit {
        // Finishing lets the drain write what is queued and then end; cancelling would drop records.
        continuation.finish()
    }
}
