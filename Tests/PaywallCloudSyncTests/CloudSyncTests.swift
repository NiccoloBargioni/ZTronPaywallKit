import Foundation
import PaywallCore
import PaywallTesting
import Testing

@testable import PaywallCloudSync

private let catalog = ProductCatalog(subscriptionGroupID: "pro", lifetime: "pro.lifetime", tokenPacks: [TokenPack(productID: "tokens.10", tokens: 10)])

private func source(_ id: String) -> PaywallSource { PaywallSource(id: id, fileID: "f", function: "g", line: 1) }

@MainActor
private func device(_ cloud: InMemoryCloudDatabase, keychain: KeychainWalletSnapshotStore? = nil) async throws -> GateEngine {
    let carrier = PaywallCloudSync(database: cloud, keychain: keychain, minimumPullInterval: 0)
    let engine = try GateEngine(
        directory: makeTemporaryPaywallDirectory(), catalog: catalog, clock: FakeClock(), store: FakeStore(), sync: carrier)
    await engine.start()
    return engine
}

@Suite("Cloud sync", .serialized)
@MainActor
struct CloudSyncTests {
    @Test func records_round_trip() throws {
        let event = LedgerEvent(
            id: "debit:1", at: Date(timeIntervalSince1970: 100), deviceID: "A", accountKey: "k", source: source("g"),
            previousHash: paywallGenesisHash, kind: .debit(tokens: 2, leaseUntil: Date(timeIntervalSince1970: 400)))
        let record = try CloudLedgerRecord(event)
        #expect(record.name == "debit:1")
        #expect(try record.event() == event)
    }

    @Test func two_simulators_converge_after_interleaved_draws() async throws {
        let cloud = InMemoryCloudDatabase()
        let a = try await device(cloud)
        let b = try await device(cloud)
        await a.handle(.tokenPack(id: 1, productID: "tokens.10", purchased: Date()))
        await a.syncNow()
        await b.syncNow()
        #expect(b.wallet.balance == 10)
        _ = a.run(.tokens(2), source: source("x")) {}
        _ = b.run(.tokens(3), source: source("y")) {}
        await a.syncNow()
        await b.syncNow()
        await a.syncNow()
        #expect(a.wallet.balance == 5)
        #expect(b.wallet.balance == 5)
        #expect(await cloud.count == 3)
    }

    @Test func offline_devices_overspend_and_block_until_repaid() async throws {
        let cloud = InMemoryCloudDatabase()
        let a = try await device(cloud)
        let b = try await device(cloud)
        await a.handle(.tokenPack(id: 1, productID: "tokens.10", purchased: Date()))
        await a.syncNow()
        await b.syncNow()
        await cloud.setReachable(false)
        _ = a.run(.tokens(8), source: source("x")) {}
        _ = b.run(.tokens(8), source: source("y")) {}
        await cloud.setReachable(true)
        await a.syncNow()
        await b.syncNow()
        await a.syncNow()
        #expect(a.wallet.balance == -6)
        #expect(a.run(.tokens(1), source: source("z")) { 1 }.failure?.reason == .insufficientTokens(needed: 1, available: 0))
    }

    @Test func pull_interval_is_respected_until_requested() async throws {
        let cloud = InMemoryCloudDatabase()
        let carrier = PaywallCloudSync(database: cloud, keychain: nil, minimumPullInterval: 3_600)
        let event = LedgerEvent(
            id: "grant:1", at: Date(), deviceID: "A", accountKey: "k", source: nil, previousHash: paywallGenesisHash,
            kind: .grant(tokens: 1, reason: "x"))
        #expect(try await carrier.pull().isEmpty)  // first pull of the launch runs (and is empty)
        _ = try await carrier.push([event])
        #expect(try await carrier.pull().isEmpty)  // within the interval: skipped
        await carrier.requestPull()
        #expect(try await carrier.pull().map(\.id) == ["grant:1"])
        await carrier.requestPull()
        #expect(try await carrier.pull().isEmpty)  // the change token moved past it
    }

    @Test func change_token_persists_across_launches() async throws {
        let cloud = InMemoryCloudDatabase()
        let tokenURL = makeTemporaryPaywallDirectory().appendingPathComponent("token")
        let event = LedgerEvent(
            id: "grant:1", at: Date(), deviceID: "A", accountKey: "k", source: nil, previousHash: paywallGenesisHash,
            kind: .grant(tokens: 1, reason: "x"))
        _ = try await cloud.save([CloudLedgerRecord(event)])
        let first = PaywallCloudSync(database: cloud, keychain: nil, minimumPullInterval: 0, tokenURL: tokenURL)
        #expect(try await first.pull().count == 1)
        let second = PaywallCloudSync(database: cloud, keychain: nil, minimumPullInterval: 0, tokenURL: tokenURL)
        #expect(try await second.pull().isEmpty)
    }

    @Test func offline_push_throws_and_keeps_the_outbox() async throws {
        let cloud = InMemoryCloudDatabase()
        let engine = try await device(cloud)
        engine.grant(tokens: 3, reason: "t")
        await cloud.setReachable(false)
        await engine.syncNow()
        #expect(await cloud.count == 0)
        await cloud.setReachable(true)
        await engine.syncNow()
        #expect(await cloud.count == 1)
        #expect(await cloud.saveOperations == 1)
    }

    @Test func keychain_snapshot_round_trips() async throws {
        let store = KeychainWalletSnapshotStore(
            service: "ztron.paywall.tests.\(UUID().uuidString)", account: "wallet", synchronizable: false)
        let snapshot = WalletSnapshot(accountKey: "k", balance: 7, lastEventID: "e", headHash: "h")
        guard await store.save(snapshot) else {
            // CI machines without a login keychain cannot run this; the carrier is covered by the fake above.
            return
        }
        #expect(await store.load() == snapshot)
        var updated = snapshot
        updated.balance = 3
        #expect(await store.save(updated))
        #expect(await store.load()?.balance == 3)
        let carrier = PaywallCloudSync(database: InMemoryCloudDatabase(), keychain: store)
        await carrier.saveSnapshot(snapshot)
        #expect(await carrier.loadSnapshot() == snapshot)
        #expect(await store.delete())
        #expect(await store.load() == nil)
    }
}
