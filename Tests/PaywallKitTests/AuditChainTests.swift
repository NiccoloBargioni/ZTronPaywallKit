import Foundation
import PaywallCore
import PaywallTesting
import Testing

@testable import PaywallKit

@Suite("Audit chain", .serialized)
@MainActor
struct AuditChainTests {
    /// Rotation drops the head of the chain; verification starts from the anchor the drop left, not from genesis.
    @Test func verify_audit_chain_stays_intact_after_rotation_dropped_files() async throws {
        let paywall = Paywall()
        var configuration = Paywall.Configuration(catalog: catalog)
        configuration.fileKeyStore = InMemoryFileKeyStore()
        configuration.store = FakeStore(products: products)
        let clock = FakeClock()
        configuration.clock = clock
        let directory = makeTemporaryPaywallDirectory()
        configuration.storageDirectory = directory
        configuration.includesDefaultAudit = false
        configuration.audit = [JournalSink(directory: directory, maxBytes: 4_000, maxFiles: 2)]
        paywall.configure(configuration)
        await paywall.waitUntilStarted()
        paywall.grant(tokens: 100, reason: "t")
        for i in 0..<30 {
            clock.advance(by: 1)
            _ = paywall.run(.tokens(1), source: PaywallSource(id: "g\(i)", fileID: "f", function: "g", line: i), scope: nil, holder: nil) {}
        }
        let chain = await paywall.verifyAuditChain()
        #expect(chain.audit == nil && chain.ledger == nil)
        let sink = JournalSink(directory: directory)
        #expect(await sink.chainAnchor() != paywallGenesisHash)
        #expect(AuditRecord.firstBrokenLink(in: await sink.records()) != nil)
        let zip = try await paywall.exportAudit()
        #expect(zip.pathExtension == "zip")
    }
}
