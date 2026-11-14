import Foundation
import PaywallCore
import PaywallTesting
import Testing

@testable import PaywallCloudSync

private let catalog = ProductCatalog(subscriptionGroupID: "pro", lifetime: "pro.lifetime", tokenPacks: [TokenPack(productID: "tokens.10", tokens: 10)])

private func source(_ id: String) -> PaywallSource { PaywallSource(id: id, fileID: "f", function: "g", line: 1) }

@MainActor
private func device(_ cloud: InMemoryCloudDatabase, keychain: KeychainWalletSnapshotStore? = nil) async throws -> GateEngine {
    try await launch(makeTemporaryPaywallDirectory(), sync: PaywallCloudSync(database: cloud, keychain: keychain, minimumPullInterval: 0))
}

@MainActor
private func launch(_ directory: URL, sync: any LedgerSync, settings: GateEngine.Settings = GateEngine.Settings()) async throws -> GateEngine {
    let engine = try GateEngine(directory: directory, catalog: catalog, settings: settings, clock: FakeClock(), store: FakeStore(), sync: sync)
    await engine.start()
    return engine
}

/// Stands in for iCloud Keychain: one `synchronizable` snapshot item that every device reads and writes.
private actor SharedSnapshotItem {
    var value: WalletSnapshot?
    func save(_ snapshot: WalletSnapshot) { value = snapshot }
}

/// `PaywallCloudSync` for the events, with the snapshot in the shared Keychain item instead of this device's own.
private actor SharedKeychainCarrier: LedgerSync {
    private let events: PaywallCloudSync
    private let item: SharedSnapshotItem

    init(cloud: InMemoryCloudDatabase, item: SharedSnapshotItem) {
        events = PaywallCloudSync(database: cloud, keychain: nil, minimumPullInterval: 0)
        self.item = item
    }

    func push(_ batch: [LedgerEvent]) async throws -> Set<String> { try await events.push(batch) }
    func pull() async throws -> [LedgerEvent] { try await events.pull() }
    func requestPull() async { await events.requestPull() }
    func loadSnapshot() async -> WalletSnapshot? { await item.value }
    func saveSnapshot(_ snapshot: WalletSnapshot) async { await item.save(snapshot) }
}

private func eventually(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<400 {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return await condition()
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

    /// The user's two devices share the synchronizable Keychain item. B spends one token and uploads it; its
    /// snapshot (9, last event: B's debit) reaches A. A relaunches offline before pulling the debit: its ledger
    /// already holds the credit the snapshot counts, so the snapshot is not adopted. The balance is A's own 10,
    /// a draw of 15 is refused, and the pull settles both devices at 9.
    @Test func another_devices_keychain_snapshot_does_not_inflate_an_offline_relaunch() async throws {
        let cloud = InMemoryCloudDatabase()
        let item = SharedSnapshotItem()
        let directoryA = makeTemporaryPaywallDirectory()
        let a = try await launch(directoryA, sync: SharedKeychainCarrier(cloud: cloud, item: item))
        let b = try await launch(makeTemporaryPaywallDirectory(), sync: SharedKeychainCarrier(cloud: cloud, item: item))
        await a.handle(.tokenPack(id: 1, productID: "tokens.10", purchased: Date()))
        await a.syncNow()
        await b.syncNow()
        _ = b.run(.tokens(1), source: source("y")) {}
        await b.syncNow()
        #expect(await eventually { await item.value?.balance == 9 })

        a.shutdown()
        await cloud.setReachable(false)
        let relaunched = try await launch(directoryA, sync: SharedKeychainCarrier(cloud: cloud, item: item))
        #expect(relaunched.wallet.balance == 10)
        #expect(relaunched.run(.tokens(15), source: source("x")) { 1 }.failure?.reason == .insufficientTokens(needed: 15, available: 10))
        await cloud.setReachable(true)
        await relaunched.syncNow()
        #expect(relaunched.wallet.balance == 9)
        #expect(b.wallet.balance == 9)
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

    @Test func no_account_answers_a_pull_with_nothing_and_leaves_the_next_one_due() async throws {
        let cloud = InMemoryCloudDatabase()
        let carrier = PaywallCloudSync(database: cloud, keychain: nil, minimumPullInterval: 3_600)
        let event = LedgerEvent(
            id: "grant:1", at: Date(), deviceID: "A", accountKey: "k", source: nil, previousHash: paywallGenesisHash,
            kind: .grant(tokens: 1, reason: "x"))
        _ = try await cloud.save([CloudLedgerRecord(event)])
        await cloud.setAccount(false)
        #expect(try await carrier.pull().isEmpty)
        await #expect(throws: CloudDatabaseError.noAccount) { _ = try await carrier.push([event]) }
        await cloud.setAccount(true)
        #expect(try await carrier.pull().map(\.id) == ["grant:1"])  // the empty answer started no interval
    }

    @Test func a_device_without_an_icloud_account_is_welcomed_on_its_own_and_uploads_once_signed_in() async throws {
        let cloud = InMemoryCloudDatabase()
        await cloud.setAccount(false)
        let carrier = PaywallCloudSync(database: cloud, keychain: nil, minimumPullInterval: 0)
        let engine = try await launch(makeTemporaryPaywallDirectory(), sync: carrier, settings: GateEngine.Settings(welcomeTokens: 100))
        await engine.syncNow()  // "no account" is an answer: nothing anywhere to take, so the grant is this device's
        #expect(engine.wallet.balance == 100)
        #expect(await cloud.count == 0)
        await cloud.setAccount(true)
        await engine.syncNow()
        #expect(await cloud.count == 1)  // signed in: the grant reaches the account like any event
        #expect(engine.wallet.balance == 100)
    }

    @Test func default_token_file_lives_next_to_the_journal() {
        #expect(PaywallCloudSync.defaultTokenURL.lastPathComponent == "cloudkit.token")
        #expect(PaywallCloudSync.defaultTokenURL.deletingLastPathComponent().lastPathComponent == "ztron.paywall")
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
        #expect(await store.delete())  // nothing left: still a clean result
    }
}
