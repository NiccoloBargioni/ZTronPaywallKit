import Foundation
import PaywallTesting
import Testing

@testable import PaywallCloudSync
@testable import PaywallCore

private let catalog = ProductCatalog(subscriptionGroupID: "pro", lifetime: "pro.lifetime", tokenPacks: [TokenPack(productID: "tokens.10", tokens: 10)])

private func source(_ id: String) -> PaywallSource { PaywallSource(id: id, fileID: "f", function: "g", line: 1) }

/// A bound Apple Account, so the key binds in the launch resolution as it does in production.
private let boundApp = AppTransactionSnapshot(
    bundleID: "com.example.app", originalAppVersion: "200", originalPurchaseDate: Date(timeIntervalSince1970: 1_700_000_000),
    environment: .production, origin: .appTransaction)

@MainActor
private func device(_ cloud: InMemoryCloudDatabase, keychain: KeychainWalletSnapshotStore? = nil) async throws -> GateEngine {
    try await launch(makeTemporaryPaywallDirectory(), sync: PaywallCloudSync(database: cloud, keychain: keychain, minimumPullInterval: 0))
}

@MainActor
private func launch(
    _ directory: URL, sync: any LedgerSync, settings: GateEngine.Settings = GateEngine.Settings(), store: FakeStore = FakeStore(),
    start: Bool = true
) async throws -> GateEngine {
    let engine = try GateEngine(
        directory: directory, catalog: catalog, settings: settings, clock: FakeClock(), store: store, sync: sync,
        fileKeyStore: InMemoryFileKeyStore())
    if start { await engine.start() }
    return engine
}

/// Stands in for the Keychain item: one snapshot that every launch of the same device reads and writes, and that a
/// reinstall finds (the directory is gone, the item is not).
private actor SharedSnapshotItem {
    var value: WalletSnapshot?
    func save(_ snapshot: WalletSnapshot) { value = snapshot }
}

/// `PaywallCloudSync` for the events, with the snapshot in the shared item instead of this device's own Keychain. One
/// instance per launch, like the real carrier.
private actor SharedKeychainCarrier: LedgerSync {
    private let events: PaywallCloudSync
    private let item: SharedSnapshotItem

    init(cloud: InMemoryCloudDatabase, item: SharedSnapshotItem, minimumPullInterval: TimeInterval = 0) {
        events = PaywallCloudSync(database: cloud, keychain: nil, minimumPullInterval: minimumPullInterval)
        self.item = item
    }

    func push(_ batch: [LedgerEvent]) async throws -> Set<String> { try await events.push(batch) }
    func pull() async throws -> [LedgerEvent] { try await events.pull() }
    func pull(since cursor: Data?) async throws -> LedgerPull? { try await events.pull(since: cursor) }
    func requestPull() async { await events.requestPull() }
    func loadSnapshot() async -> WalletSnapshot? { await item.value }
    func saveSnapshot(_ snapshot: WalletSnapshot) async { await item.save(snapshot) }
}

/// A carrier whose next pull waits on a continuation until released: a CloudKit fetch in flight while the facade
/// reconfigures.
private actor HoldingCarrier: LedgerSync {
    private let inner: PaywallCloudSync
    private var holdNext = false
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var isHolding = false

    init(cloud: InMemoryCloudDatabase) { inner = PaywallCloudSync(database: cloud, keychain: nil, minimumPullInterval: 0) }

    func holdNextPull() { holdNext = true }

    func release() {
        waiter?.resume()
        waiter = nil
        isHolding = false
    }

    func push(_ batch: [LedgerEvent]) async throws -> Set<String> { try await inner.push(batch) }
    func pull() async throws -> [LedgerEvent] { try await inner.pull() }

    func pull(since cursor: Data?) async throws -> LedgerPull? {
        if holdNext {
            holdNext = false
            isHolding = true
            await withCheckedContinuation { waiter = $0 }
        }
        return try await inner.pull(since: cursor)
    }

    func requestPull() async { await inner.requestPull() }
}

/// A database that hands back no change token: the carrier keeps the cursor it was given.
private actor NilTokenDatabase: CloudDatabase {
    private var saved: [CloudLedgerRecord] = []
    func save(_ records: [CloudLedgerRecord]) async throws -> Set<String> {
        saved += records
        return Set(records.map(\.name))
    }
    func fetchChanges(since token: Data?) async throws -> (records: [CloudLedgerRecord], token: Data?) { (saved, nil) }
}

private func eventually(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<400 {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return await condition()
}

@MainActor
private func welcomeGrants(_ engine: GateEngine) -> Int { engine.ledger.events.filter { $0.id == "grant:welcome" }.count }

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

    /// The user's two devices share one snapshot item. B spends one token and uploads it; its snapshot (9, last
    /// event: B's debit) reaches A. A relaunches offline before pulling the debit: its ledger already holds the credit
    /// the snapshot counts, so the snapshot is not adopted. The balance is A's own 10, a draw of 15 is refused, and the
    /// pull settles both devices at 9.
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

    /// The carrier fetches from the cursor it is given and keeps no position of its own; inside its pull interval it
    /// answers `nil`, which is not an answer.
    @Test func pull_interval_is_respected_until_requested() async throws {
        let cloud = InMemoryCloudDatabase()
        let carrier = PaywallCloudSync(database: cloud, keychain: nil, minimumPullInterval: 3_600)
        let event = LedgerEvent(
            id: "grant:1", at: Date(), deviceID: "A", accountKey: "k", source: nil, previousHash: paywallGenesisHash,
            kind: .grant(tokens: 1, reason: "x"))
        let first = try #require(try await carrier.pull(since: nil))  // the first pull of the launch fetches (and is empty)
        #expect(first.events.isEmpty && first.accountAvailable)
        _ = try await carrier.push([event])
        #expect(try await carrier.pull(since: first.cursor) == nil)  // within the interval: did not look
        await carrier.requestPull()
        let second = try #require(try await carrier.pull(since: first.cursor))
        #expect(second.events.map(\.id) == ["grant:1"])
        await carrier.requestPull()
        #expect(try await carrier.pull(since: second.cursor)?.events.isEmpty == true)  // past it
        await carrier.requestPull()
        #expect(try await carrier.pull(since: first.cursor)?.events.map(\.id) == ["grant:1"], "the position is the caller's")
        #expect(try await carrier.pull().isEmpty, "the plain pull keeps the interval too")
        await carrier.requestPull()
        #expect(try await carrier.pull().map(\.id) == ["grant:1"], "and, once due, is everything from the start")
    }

    /// A6/A7: the cursor lives in the journal, written with the merged events. A relaunch pulls from it, so nothing is
    /// fetched twice, and a journal that lost it fetches everything again.
    @Test func the_cursor_lives_in_the_journal_and_a_relaunch_pulls_from_it() async throws {
        let cloud = InMemoryCloudDatabase()
        let event = LedgerEvent(
            id: "grant:1", at: Date(), deviceID: "A", accountKey: unboundAccountKey, source: nil, previousHash: paywallGenesisHash,
            kind: .grant(tokens: 1, reason: "x"))
        _ = try await cloud.save([CloudLedgerRecord(event)])
        let directory = makeTemporaryPaywallDirectory()
        let first = try await launch(directory, sync: PaywallCloudSync(database: cloud, keychain: nil, minimumPullInterval: 0))
        await first.syncNow()
        #expect(first.wallet.balance == 1)
        #expect(first.journal.cursor == Data("1".utf8))
        first.shutdown()
        var merges = 0
        let relaunched = try await launch(directory, sync: PaywallCloudSync(database: cloud, keychain: nil, minimumPullInterval: 0), start: false)
        relaunched.onEvent = { if case .syncMerged = $0 { merges += 1 } }
        await relaunched.start()
        await relaunched.syncNow()
        #expect(merges == 0, "nothing new past the cursor")
        #expect(relaunched.journal.cursor == Data("1".utf8) && relaunched.wallet.balance == 1)
    }

    @Test func a_database_without_change_tokens_keeps_the_cursor_it_was_given() async throws {
        let carrier = PaywallCloudSync(database: NilTokenDatabase(), keychain: nil, minimumPullInterval: 0)
        let event = LedgerEvent(
            id: "grant:1", at: Date(), deviceID: "A", accountKey: "k", source: nil, previousHash: paywallGenesisHash,
            kind: .grant(tokens: 1, reason: "x"))
        _ = try await carrier.push([event])
        let given = Data("where-i-was".utf8)
        let pull = try #require(try await carrier.pull(since: given))
        #expect(pull.events.map(\.id) == ["grant:1"] && pull.cursor == given && pull.accountAvailable)
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
        let answer = try #require(try await carrier.pull(since: nil))
        #expect(answer.events.isEmpty && !answer.accountAvailable && answer.cursor == nil)
        await #expect(throws: CloudDatabaseError.noAccount) { _ = try await carrier.push([event]) }
        await cloud.setAccount(true)
        let signedIn = try #require(try await carrier.pull(since: nil))  // the empty answer started no interval
        #expect(signedIn.events.map(\.id) == ["grant:1"] && signedIn.accountAvailable)
    }

    @Test func a_device_without_an_icloud_account_is_welcomed_on_its_own_and_uploads_once_signed_in() async throws {
        let cloud = InMemoryCloudDatabase()
        await cloud.setAccount(false)
        let carrier = PaywallCloudSync(database: cloud, keychain: nil, minimumPullInterval: 0)
        let engine = try await launch(makeTemporaryPaywallDirectory(), sync: carrier, settings: GateEngine.Settings(welcomeTokens: 100))
        await engine.syncNow()  // "no account" is an answer: nothing anywhere to take, so the grant is this device's
        #expect(engine.wallet.balance == 100)
        #expect(await cloud.count == 0)
        #expect(!engine.carrierHasAccount)
        await cloud.setAccount(true)
        await engine.syncNow()
        #expect(await cloud.count == 1)  // signed in: the grant reaches the account like any event, in the same sync
        #expect(engine.wallet.balance == 100)
        #expect(engine.carrierHasAccount)
    }

    @Test func default_token_file_lives_next_to_the_journal() {
        #expect(PaywallCloudSync.defaultTokenURL.lastPathComponent == "cloudkit.token")
        #expect(PaywallCloudSync.defaultTokenURL.deletingLastPathComponent().lastPathComponent == "ztron.paywall")
    }

    @Test func keychain_snapshot_round_trips() async throws {
        let service = "ztron.paywall.tests.\(UUID().uuidString)"
        let store = KeychainWalletSnapshotStore(service: service, account: "wallet")
        #expect(await !store.synchronizable, "per device by default: another device's balance comes from the carrier")
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
        // An item an earlier build wrote as synchronizable is still read when no local one exists, and deleted with it.
        let legacy = KeychainWalletSnapshotStore(service: service, account: "wallet", synchronizable: true)
        if await legacy.save(snapshot) {
            #expect(await store.load() == snapshot)
            #expect(await store.save(updated))
            #expect(await store.load()?.balance == 3, "the local item wins once written")
            #expect(await store.delete())
            #expect(await legacy.load() == nil)
            #expect(await store.load() == nil)
        }
    }

    // MARK: A6: a pull is committed only through a durable merge

    /// A6-1: the carrier's position moves only with the merged events. A merge the journal refuses leaves it, so the
    /// same events come back at the next pull, in this launch and after a relaunch.
    @Test func a_failed_merge_does_not_move_the_change_token() async throws {
        let cloud = InMemoryCloudDatabase()
        let a = try await device(cloud)
        await a.handle(.tokenPack(id: 9, productID: "tokens.10", purchased: Date()))
        await a.syncNow()

        let directoryB = makeTemporaryPaywallDirectory()
        let b = try await launch(directoryB, sync: PaywallCloudSync(database: cloud, keychain: nil), start: false)
        b.journal.injectedFault = .write  // a full disk for one sync
        await b.start()
        await b.syncNow()
        #expect(b.wallet.balance == 0 && b.journal.cursor == nil)
        b.journal.injectedFault = nil
        await b.syncNow()  // a plain sync, no requestPull from the test: the engine asked for the re-pull itself
        #expect(b.wallet.balance == 10)
        #expect(b.journal.cursor != nil)
        b.shutdown()
        let relaunched = try await launch(directoryB, sync: PaywallCloudSync(database: cloud, keychain: nil))
        await relaunched.syncNow()
        #expect(relaunched.wallet.balance == 10)
        #expect(relaunched.ledger.events.filter { $0.id == "credit:9" }.count == 1)
    }

    /// A6-2: a reinstall whose first merge fails keeps the Keychain baseline and writes no second welcome grant; once
    /// the disk recovers the history arrives and the balance is what it was.
    @Test func a_failed_merge_on_reinstall_keeps_the_baseline_and_grants_no_second_welcome() async throws {
        let cloud = InMemoryCloudDatabase()
        let item = SharedSnapshotItem()
        let settings = GateEngine.Settings(welcomeTokens: 100)
        let old = try await launch(makeTemporaryPaywallDirectory(), sync: SharedKeychainCarrier(cloud: cloud, item: item), settings: settings)
        await old.syncNow()
        await old.handle(.tokenPack(id: 5, productID: "tokens.10", purchased: Date()))
        await old.syncNow()
        #expect(await eventually { await item.value?.balance == 110 })
        old.shutdown()

        let directory = makeTemporaryPaywallDirectory()
        let reinstalled = try await launch(directory, sync: SharedKeychainCarrier(cloud: cloud, item: item), settings: settings, start: false)
        reinstalled.journal.injectedFault = .write
        await reinstalled.start()
        #expect(reinstalled.wallet.balance == 110)
        await reinstalled.syncNow()
        #expect(reinstalled.wallet.balance == 110 && reinstalled.baseline != nil)
        #expect(welcomeGrants(reinstalled) == 0)
        reinstalled.journal.injectedFault = nil
        await reinstalled.syncNow()
        #expect(reinstalled.wallet.balance == 110 && reinstalled.baseline == nil)
        #expect(reinstalled.ledger.contains("credit:5") && welcomeGrants(reinstalled) == 1)
        #expect(await cloud.count == 2, "the account's welcome grant is the only one")
        reinstalled.shutdown()
        let relaunched = try await launch(directory, sync: SharedKeychainCarrier(cloud: cloud, item: item), settings: settings)
        await relaunched.syncNow()
        #expect(relaunched.wallet.balance == 110 && welcomeGrants(relaunched) == 1)
    }

    /// A6-3: a pull that resolves after the engine shut down commits nothing: the successor fetches the same events.
    @Test func a_pull_that_resolves_after_shutdown_commits_nothing() async throws {
        let cloud = InMemoryCloudDatabase()
        let a = try await device(cloud)
        await a.handle(.tokenPack(id: 9, productID: "tokens.10", purchased: Date()))
        await a.syncNow()

        let directoryB = makeTemporaryPaywallDirectory()
        let holding = HoldingCarrier(cloud: cloud)
        await holding.holdNextPull()
        let b = try await launch(directoryB, sync: holding)  // `start()` schedules the first sync; its pull is held
        #expect(await eventually { await holding.isHolding })
        b.shutdown()
        await holding.release()
        #expect(await eventually { b.runningSync == nil })
        #expect(b.wallet.balance == 0 && b.journal.cursor == nil)
        let successor = try await launch(directoryB, sync: PaywallCloudSync(database: cloud, keychain: nil, minimumPullInterval: 0))
        await successor.syncNow()
        #expect(successor.wallet.balance == 10)
    }

    // MARK: A7: a dropped log is refilled from the carrier

    enum Damage: String, CaseIterable, Sendable { case firstFrame, newerCheckpoint, middleFrame }

    /// Welcome 100, a 10-pack and a 3-token draw, all uploaded, with the balance 107 in the Keychain item; then an
    /// ordinary relaunch that pulls, so the cursor is past the whole history.
    private func history(_ directory: URL, _ cloud: InMemoryCloudDatabase, _ item: SharedSnapshotItem, threshold: Int) async throws {
        let settings = GateEngine.Settings(compactionThreshold: threshold, welcomeTokens: 100)
        let first = try await launch(directory, sync: SharedKeychainCarrier(cloud: cloud, item: item), settings: settings)
        await first.syncNow()
        await first.handle(.tokenPack(id: 3, productID: "tokens.10", purchased: Date()))
        _ = first.run(.tokens(3), source: source("g")) {}
        await first.syncNow()
        #expect(first.wallet.balance == 107)
        #expect(await eventually { await item.value?.balance == 107 })
        first.shutdown()
        let second = try await launch(directory, sync: SharedKeychainCarrier(cloud: cloud, item: item), settings: settings)
        await second.syncNow()
        #expect(second.wallet.balance == 107 && second.journal.cursor != nil)
        second.shutdown()
        #expect(await cloud.count == 3)
    }

    private func damage(_ kind: Damage, in directory: URL) throws {
        let url = directory.appendingPathComponent(Journal.fileName)
        var bytes = [UInt8](try Data(contentsOf: url))
        let entries = Journal.decodeFrames(Data(bytes)).entries
        var offsets: [Int] = []
        var offset = 0
        for entry in entries {
            offsets.append(offset)
            offset += try Journal.frame(entry).count
        }
        switch kind {
        case .firstFrame:
            bytes[12] ^= 0xFF
        case .newerCheckpoint:
            // Frame 0 is the checkpoint (threshold 0): a CRC-valid record this build cannot decode takes its place.
            guard case .checkpoint = entries[0] else { throw TestFailure("frame 0 is not the checkpoint") }
            let payload = [UInt8](#"{"checkpointV2":{"_0":{"format":2}}}"#.utf8)
            var frame: [UInt8] = []
            for value in [UInt32(payload.count), CRC32.checksum(payload)] {
                for shift in stride(from: 0, to: 32, by: 8) { frame.append(UInt8(truncatingIfNeeded: value >> UInt32(shift))) }
            }
            bytes = frame + payload + Array(bytes[(offsets.count > 1 ? offsets[1] : bytes.count)...])
        case .middleFrame:
            let debit = try #require(entries.firstIndex { if case .event(let event, _) = $0, case .debit = event.kind { true } else { false } })
            bytes[offsets[debit] + 12] ^= 0xFF
        }
        try Data(bytes).write(to: url)
    }

    struct TestFailure: Error { let message: String; init(_ message: String) { self.message = message } }

    /// A7: after a head, middle or format drop, the next launch pulls from a cursor no newer than what survived and
    /// gets the whole history back: the events themselves, not only the balance, with exactly one welcome grant.
    @Test(arguments: Damage.allCases, [false, true])
    func a_dropped_log_is_refilled_from_the_carrier(kind: Damage, truncatingLaunchFirst: Bool) async throws {
        let cloud = InMemoryCloudDatabase()
        let item = SharedSnapshotItem()
        let directory = makeTemporaryPaywallDirectory()
        let threshold = kind == .newerCheckpoint ? 0 : 4096
        let settings = GateEngine.Settings(compactionThreshold: threshold, welcomeTokens: 100)
        try await history(directory, cloud, item, threshold: threshold)
        try damage(kind, in: directory)
        if truncatingLaunchFirst {
            // A launch that only opens the journal (and truncates it) before any pull.
            let opened = try await launch(directory, sync: SharedKeychainCarrier(cloud: cloud, item: item), settings: settings, start: false)
            #expect(opened.journal.droppedCorruptFrame)
            opened.shutdown()
        }
        let recovered = try await launch(directory, sync: SharedKeychainCarrier(cloud: cloud, item: item), settings: settings)
        await recovered.syncNow()
        let ids = Set(recovered.ledger.events.map(\.id))
        #expect(ids.count == 3 && ids.contains("grant:welcome") && ids.contains("credit:3"), "\(kind): \(ids)")
        #expect(recovered.wallet.balance == 107, "\(kind)")
        #expect(welcomeGrants(recovered) == 1)
        recovered.shutdown()
        let next = try await launch(directory, sync: SharedKeychainCarrier(cloud: cloud, item: item), settings: settings)
        await next.syncNow()
        #expect(next.wallet.balance == 107 && welcomeGrants(next) == 1, "\(kind)")
        #expect(await cloud.count == 3)
        #expect(next.ledger.firstBrokenLink() == nil)
    }

    // MARK: A1: the Keychain baseline outlives the first launch

    private func reinstall(_ cloud: InMemoryCloudDatabase, _ item: SharedSnapshotItem, store: FakeStore = FakeStore()) async throws -> (URL, GateEngine) {
        let directory = makeTemporaryPaywallDirectory()
        let engine = try await launch(
            directory, sync: SharedKeychainCarrier(cloud: cloud, item: item), settings: GateEngine.Settings(welcomeTokens: 100), store: store)
        await engine.syncNow()
        return (directory, engine)
    }

    private func relaunch(_ directory: URL, _ cloud: InMemoryCloudDatabase, _ item: SharedSnapshotItem, store: FakeStore = FakeStore()) async throws -> GateEngine {
        let engine = try await launch(
            directory, sync: SharedKeychainCarrier(cloud: cloud, item: item), settings: GateEngine.Settings(welcomeTokens: 100), store: store)
        await engine.syncNow()
        return engine
    }

    /// The old install: welcome plus two 10-packs, 120, with the account bound when `store` names an app transaction.
    private func oldInstall(_ cloud: InMemoryCloudDatabase, _ item: SharedSnapshotItem, store: FakeStore = FakeStore()) async throws {
        let old = try await launch(
            makeTemporaryPaywallDirectory(), sync: SharedKeychainCarrier(cloud: cloud, item: item), settings: GateEngine.Settings(welcomeTokens: 100),
            store: store)
        await old.syncNow()
        await old.handle(.tokenPack(id: 7, productID: "tokens.10", purchased: Date()))
        await old.handle(.tokenPack(id: 8, productID: "tokens.10", purchased: Date()))
        await old.syncNow()
        #expect(old.wallet.balance == 120)
        #expect(await eventually { await item.value?.balance == 120 })
        old.shutdown()
    }

    /// A1, iCloud off (the carrier answers "no account"): the snapshot's balance holds across two relaunches with no
    /// second welcome grant, survives a draw, and a second reinstall adopts it again.
    @Test(arguments: [false, true])
    func a_reinstall_with_icloud_off_keeps_its_balance_across_launches(bound: Bool) async throws {
        let cloud = InMemoryCloudDatabase()
        await cloud.setAccount(false)
        let item = SharedSnapshotItem()
        let store = { bound ? FakeStore(app: boundApp) : FakeStore() }
        try await oldInstall(cloud, item, store: store())
        if bound { #expect(await item.value?.accountKey == boundApp.accountKey) }

        let (directory, reinstalled) = try await reinstall(cloud, item, store: store())
        #expect(reinstalled.wallet.balance == 120)
        reinstalled.shutdown()
        for _ in 0..<2 {
            let again = try await relaunch(directory, cloud, item, store: store())
            #expect(again.wallet.balance == 120)
            #expect(welcomeGrants(again) == 0, "the snapshot stands for history: no second welcome grant")
            again.shutdown()
        }
        // A draw on the reinstall is counted on top of the baseline, launch after launch.
        let drawer = try await relaunch(directory, cloud, item, store: store())
        #expect(drawer.run(.tokens(1), source: source("g")) { 1 }.value == 1)
        #expect(drawer.wallet.balance == 119)
        #expect(await eventually { await item.value?.balance == 119 })
        drawer.shutdown()
        for _ in 0..<2 {
            let again = try await relaunch(directory, cloud, item, store: store())
            #expect(again.wallet.balance == 119 && again.canPass(.tokens(1)))
            again.shutdown()
        }
        // A second reinstall starts from the item the first one kept current.
        let (_, second) = try await reinstall(cloud, item, store: store())
        #expect(second.wallet.balance == 119)
        #expect(welcomeGrants(second) == 0)
    }

    /// A1 with the carrier unreachable (the pull throws) instead of answering "no account".
    @Test func a_reinstall_with_the_carrier_unreachable_keeps_its_balance_across_launches() async throws {
        let cloud = InMemoryCloudDatabase()
        let item = SharedSnapshotItem()
        try await oldInstall(cloud, item)
        await cloud.setReachable(false)
        let (directory, reinstalled) = try await reinstall(cloud, item)
        #expect(reinstalled.wallet.balance == 120)
        reinstalled.shutdown()
        for _ in 0..<2 {
            let again = try await relaunch(directory, cloud, item)
            #expect(again.wallet.balance == 120 && welcomeGrants(again) == 0)
            again.shutdown()
        }
    }

    /// A1 case 5: the history was uploaded. Two offline launches after the reinstall show 120 from the snapshot; the
    /// first online pull brings the old ids back, and the account keeps its one welcome grant.
    @Test func a_reinstall_offline_then_online_takes_the_uploaded_history_once() async throws {
        let cloud = InMemoryCloudDatabase()
        let item = SharedSnapshotItem()
        try await oldInstall(cloud, item)
        #expect(await cloud.count == 3)
        await cloud.setReachable(false)
        let (directory, reinstalled) = try await reinstall(cloud, item)
        #expect(reinstalled.wallet.balance == 120)
        reinstalled.shutdown()
        let offline = try await relaunch(directory, cloud, item)
        #expect(offline.wallet.balance == 120 && offline.ledger.events.isEmpty)
        await cloud.setReachable(true)
        await offline.syncNow()
        #expect(offline.wallet.balance == 120)
        #expect(Set(offline.ledger.events.map(\.id)) == ["grant:welcome", "credit:7", "credit:8"])
        #expect(offline.baseline == nil && welcomeGrants(offline) == 1)
        #expect(await cloud.count == 3)
    }

    /// A1 case 6: the old install ran with iCloud off (welcomed on its own, nothing uploaded) and the user signs in
    /// after the reinstall, so the container is empty. This install's own pushes come back as echoes; they are not the
    /// account's history, so the baseline stands and a purchase adds to it.
    @Test func an_echo_of_this_installs_own_pushes_does_not_settle_the_baseline() async throws {
        let cloud = InMemoryCloudDatabase()
        let item = SharedSnapshotItem()
        await cloud.setAccount(false)
        try await oldInstall(cloud, item)
        await cloud.setAccount(true)
        #expect(await cloud.count == 0)
        let (directory, reinstalled) = try await reinstall(cloud, item)
        #expect(reinstalled.wallet.balance == 120)
        await reinstalled.handle(.tokenPack(id: 9, productID: "tokens.10", purchased: Date()))
        await reinstalled.syncNow()
        await reinstalled.syncNow()
        #expect(reinstalled.wallet.balance == 130 && reinstalled.baseline != nil)
        #expect(await cloud.count == 1)
        reinstalled.shutdown()
        let again = try await relaunch(directory, cloud, item)
        #expect(again.wallet.balance == 130 && welcomeGrants(again) == 0)
    }

    /// A legacy item with no last event (what earlier builds wrote) is honoured on an empty ledger; one that says
    /// `{0, nil}` is no history, so a fresh install is still welcomed.
    @Test func legacy_items_are_honoured_and_an_empty_one_is_not_history() async throws {
        let cloud = InMemoryCloudDatabase()
        await cloud.setAccount(false)
        let legacy = SharedSnapshotItem()
        await legacy.save(WalletSnapshot(accountKey: unboundAccountKey, balance: 42, lastEventID: nil, headHash: paywallGenesisHash))
        let (_, honoured) = try await reinstall(cloud, legacy)
        #expect(honoured.wallet.balance == 42 && welcomeGrants(honoured) == 0)
        let empty = SharedSnapshotItem()
        await empty.save(WalletSnapshot(accountKey: unboundAccountKey, balance: 0, lastEventID: nil, headHash: paywallGenesisHash))
        let (_, fresh) = try await reinstall(cloud, empty)
        #expect(fresh.wallet.balance == 100 && welcomeGrants(fresh) == 1)
    }

    // MARK: A9: the outbox stays out of the log

    /// A device with no iCloud account checkpoints like any other: the covered, unacknowledged events wait in the outbox
    /// file, the log decodes the checkpoint and the events since it, and signing in uploads everything.
    @Test func a_device_without_an_icloud_account_still_bounds_its_journal() async throws {
        let cloud = InMemoryCloudDatabase()
        await cloud.setAccount(false)
        let directory = makeTemporaryPaywallDirectory()
        let settings = GateEngine.Settings(compactionThreshold: 50)
        func carrier() -> PaywallCloudSync { PaywallCloudSync(database: cloud, keychain: nil, minimumPullInterval: 0) }
        let first = try await launch(directory, sync: carrier(), settings: settings)
        await first.syncNow()
        first.grant(tokens: 1_000, reason: "seed")
        for i in 0..<300 { _ = first.run(.tokens(1), source: source("g\(i)")) {} }
        await first.syncNow()
        first.shutdown()
        let second = try await launch(directory, sync: carrier(), settings: settings)
        await second.syncNow()
        let checkpoint = try #require(second.journal.checkpoint)
        #expect(checkpoint.eventCount == 301)
        #expect(second.wallet.balance == 700)
        #expect(second.journal.entries.count <= 51, "the checkpoint plus at most 50 events decode at open: \(second.journal.entries.count)")
        #expect(second.journal.outboxEvents().count == 301)
        #expect(second.journal.pendingUpload.count == 301)
        second.shutdown()
        let third = try await launch(directory, sync: carrier(), settings: settings)
        #expect(third.journal.entries.count <= 51)
        await cloud.setAccount(true)
        await third.syncNow()
        #expect(await cloud.count == 301)
        #expect(third.journal.pendingUpload.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: third.journal.outboxURL.path))
        #expect(third.journal.entries.count <= 52)
        third.shutdown()
        // A reinstall from the container alone sees the same balance.
        let reinstalled = try await launch(makeTemporaryPaywallDirectory(), sync: carrier(), settings: settings)
        await reinstalled.syncNow()
        #expect(reinstalled.wallet.balance == 700)
    }

    /// A log in the shape earlier builds wrote (covered, unacknowledged events behind the checkpoint) is migrated at the
    /// first `start()`: the events move to the outbox file and are still pushed.
    @Test func a_log_in_the_old_shape_moves_its_covered_outbox_out_at_start() async throws {
        let cloud = InMemoryCloudDatabase()
        let directory = makeTemporaryPaywallDirectory()
        let journal = try Journal(directory: directory, fullSync: false)
        let events = (1...3).map { i in
            LedgerEvent(
                id: "grant:\(i)", at: Date(timeIntervalSince1970: Double(i)), deviceID: "old", accountKey: unboundAccountKey, source: nil,
                previousHash: paywallGenesisHash, kind: .grant(tokens: 1, reason: "r"))
        }
        try journal.append(contentsOf: events.map { .event($0, uploaded: false) })
        let checkpoint = Ledger(events: events).checkpoint()
        try journal.append(.checkpoint(checkpoint))
        journal.close()
        let engine = try await launch(directory, sync: PaywallCloudSync(database: cloud, keychain: nil, minimumPullInterval: 0), start: false)
        #expect(engine.journal.hasCoveredOutboxInLog)
        await engine.start()
        #expect(!engine.journal.hasCoveredOutboxInLog)
        #expect(engine.journal.outboxEvents().count == 3 && engine.wallet.balance == 3)
        await engine.syncNow()
        #expect(await cloud.count == 3)
        #expect(engine.journal.pendingUpload.isEmpty)
    }
}
