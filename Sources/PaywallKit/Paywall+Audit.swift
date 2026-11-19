public import Foundation
public import PaywallCore

extension Paywall {
    public enum ExportError: Error, Hashable, Sendable {
        case notConfigured
        case archiveFailed(String)
    }

    /// The first audit record whose hash does not match its predecessor (`nil`: the chain is intact), and the
    /// first ledger event whose per-device link is broken. The audit chain is checked from where the retained
    /// files start: genesis, or the hash rotation dropped at (`JournalSink.chainAnchor()`).
    public func verifyAuditChain() async -> (audit: AuditRecord?, ledger: LedgerEvent?) {
        guard let engine else { return (nil, nil) }
        await engine.flushAudit()
        let sink = JournalSink(directory: engine.directory)
        let records = await sink.records()
        return (AuditRecord.firstBrokenLink(in: records, after: await sink.chainAnchor()), engine.ledger.firstBrokenLink())
    }

    /// One zip for a support case or an App Store dispute: the audit journal, the ledger, the derived lease table,
    /// and the raw signed AppTransaction (or receipt). Hash-chained and timestamped twice (wall clock and uptime):
    /// it detects corruption and edits that do not rewrite the records after them. It is not tamper-proof against
    /// whoever controls the device: the chains are unkeyed, their heads are not anchored off the device, and dropping
    /// the newest records goes unnoticed. Only the signed AppTransaction or receipt can be verified by a third party;
    /// when evidence must hold against the user, forward records or the chain head to your server with a `ClosureSink`.
    public func exportAudit() async throws -> URL {
        guard let engine else { throw ExportError.notConfigured }
        await engine.flushAudit()
        let directory = engine.directory
        let leases = engine.ledger.leases(for: engine.accountKey).values
            .sorted { $0.gateID < $1.gateID }
            .map { ["gateID": $0.gateID, "debitID": $0.debitID, "grantedAt": $0.grantedAt.timeIntervalSince1970, "expiresAt": $0.expiresAt.timeIntervalSince1970] as [String: any Sendable] }
        let leaseData = try JSONSerialization.data(withJSONObject: leases, options: [.prettyPrinted, .sortedKeys])
        let signed = engine.appTransaction?.signedPayload
        let auditFiles = await JournalSink(directory: directory).fileURLs()
        let stamp = Int(engine.clock.now.timeIntervalSince1970)
        return try await Task.detached {
            try Self.writeArchive(
                directory: directory, auditFiles: auditFiles, leaseData: leaseData, signedPayload: signed, stamp: stamp)
        }.value
    }

    private nonisolated static func writeArchive(
        directory: URL, auditFiles: [URL], leaseData: Data, signedPayload: Data?, stamp: Int
    ) throws -> URL {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("paywall-export-\(stamp)", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        for file in auditFiles { try fm.copyItem(at: file, to: staging.appendingPathComponent(file.lastPathComponent)) }
        let ledger = directory.appendingPathComponent(Journal.fileName)
        if fm.fileExists(atPath: ledger.path) { try fm.copyItem(at: ledger, to: staging.appendingPathComponent(Journal.fileName)) }
        try leaseData.write(to: staging.appendingPathComponent("leases.json"))
        if let signedPayload { try signedPayload.write(to: staging.appendingPathComponent("app-transaction.signed")) }

        var archive: URL?
        var coordinationError: NSError?
        var copyError: (any Error)?
        NSFileCoordinator().coordinate(readingItemAt: staging, options: .forUploading, error: &coordinationError) { zipped in
            let destination = fm.temporaryDirectory.appendingPathComponent("paywall-audit-\(stamp).zip")
            try? fm.removeItem(at: destination)
            do {
                try fm.copyItem(at: zipped, to: destination)
                archive = destination
            } catch {
                copyError = error
            }
        }
        try? fm.removeItem(at: staging)
        if let coordinationError { throw ExportError.archiveFailed(coordinationError.localizedDescription) }
        if let copyError { throw ExportError.archiveFailed(String(describing: copyError)) }
        guard let archive else { throw ExportError.archiveFailed("no archive") }
        return archive
    }
}
