import CloudKit
import Foundation
import PaywallCloudSync
import PaywallCore
import PaywallTesting
import Testing

/// The live CloudKit lane of the design: the production `CloudKitDatabase` and `PaywallCloudSync` against a real
/// iCloud container, from the entitled test host on a simulator signed into an iCloud account. It is the only lane
/// that executes `CloudKitDatabase.init(containerIdentifier:)`, `PaywallCloudSync.init(containerIdentifier:keychain:)`
/// and the four `CKDatabase` forwarders; the rest of the target is exercised against `FakeCloudKit` in the package.
///
/// It runs only when `PAYWALL_CLOUDKIT_CONTAINER` names the container (the one in `TestHost.entitlements`;
/// `CKContainer` traps on any other), so the default, unsigned host lane skips the suite:
///
///     TEST_RUNNER_PAYWALL_CLOUDKIT_CONTAINER=iCloud.com.ztron.paywall.testhost xcodebuild test ...
///
/// Every test starts by deleting the ledger zone, so the container is empty and the balances below are absolute;
/// the production adapter recreates the zone on its first call.
enum LiveCloudKit {
    static let variable = "PAYWALL_CLOUDKIT_CONTAINER"

    static var containerIdentifier: String? {
        guard let value = ProcessInfo.processInfo.environment[variable], !value.isEmpty else { return nil }
        return value
    }

    static var isConfigured: Bool { containerIdentifier != nil }

    /// The container named by the environment, on a simulator that is signed in; otherwise the test cannot run.
    static func configuredContainer() async throws -> String {
        let container = try #require(containerIdentifier, "\(variable) is not set")
        let status = try await CKContainer(identifier: container).accountStatus()
        try #require(status == .available, "the simulator is not signed into iCloud (CKAccountStatus \(status.rawValue))")
        return container
    }

    /// Deletes the ledger zone, so the test starts from an empty container. A zone that is not there is fine.
    static func resetZone(in container: String) async throws {
        let database = CKContainer(identifier: container).privateCloudDatabase
        let zoneID = CKRecordZone.ID(zoneName: CloudKitDatabase.zoneName, ownerName: CKCurrentUserDefaultName)
        let results = try await database.modifyRecordZones(saving: [], deleting: [zoneID])
        for case .failure(let error) in results.deleteResults.values where (error as? CKError)?.code != .zoneNotFound {
            throw error
        }
    }

    /// What deleting the app does to the carrier's own file: the change token in Application Support goes too.
    static func removeTokenFile() {
        try? FileManager.default.removeItem(at: PaywallCloudSync.defaultTokenURL)
    }

    /// One "device": a started engine on its own directory (its own device id and change token) with the shared
    /// container as its carrier.
    @MainActor
    static func device(in container: String, directory: URL = makeTemporaryPaywallDirectory()) async throws -> GateEngine {
        let carrier = PaywallCloudSync(
            database: CloudKitDatabase(containerIdentifier: container), keychain: nil, minimumPullInterval: 0,
            tokenURL: directory.appendingPathComponent("cloudkit.token"))
        let engine = try GateEngine(directory: directory, catalog: hostCatalog, clock: SystemClock(), store: FakeStore(), sync: carrier)
        await engine.start()
        return engine
    }
}

private func liveSource(_ id: String) -> PaywallSource {
    PaywallSource(id: id, fileID: "TestHostTests/LiveCloudKitTests.swift", function: "test", line: 1)
}

/// A grant with a whole-second date: the canonical encoding is what the record carries, and what comes back
/// must equal what went in.
private func liveEvent(_ id: String, tokens: Int = 3) -> LedgerEvent {
    LedgerEvent(
        id: "\(id):\(UUID().uuidString)", at: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded()),
        deviceID: "live-adapter", accountKey: unboundAccountKey, source: nil, previousHash: paywallGenesisHash,
        kind: .grant(tokens: tokens, reason: "live"))
}

/// Polls `condition` until it holds or `seconds` passed; the container answers in its own time.
@MainActor
private func eventually(seconds: TimeInterval, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 500_000_000)
    }
    return await condition()
}

extension HostLane {
@Suite("Live CloudKit", .serialized, .enabled(if: LiveCloudKit.isConfigured, "set PAYWALL_CLOUDKIT_CONTAINER to the container in TestHost.entitlements to run the live CloudKit lane"))
@MainActor
struct LiveCloudKitTests {
    /// `CloudKitDatabase.init(containerIdentifier:)` and the carrier's production initialiser, zone setup, and the
    /// save and change-fetch round trips, each through the real `CKDatabase` forwarders.
    @Test func the_production_adapter_and_carrier_round_trip_against_the_container() async throws {
        let container = try await LiveCloudKit.configuredContainer()
        try await LiveCloudKit.resetZone(in: container)
        LiveCloudKit.removeTokenFile()

        // The first call creates the zone and its subscription; a fresh zone has no changes and a token.
        let database = CloudKitDatabase(containerIdentifier: container)
        let (nothing, start) = try await database.fetchChanges(since: nil)
        #expect(nothing.isEmpty)
        #expect(start != nil)

        let event = liveEvent("grant:live")
        let record = try CloudLedgerRecord(event)
        #expect(try await database.save([record]) == [record.name])
        // Events are immutable: the same record again is "already present", acknowledged and not duplicated.
        #expect(try await database.save([record]) == [record.name])
        let (changed, next) = try await database.fetchChanges(since: start)
        #expect(changed == [record])
        #expect(try changed.first?.event() == event)
        #expect(next != nil && next != start)
        #expect(try await database.fetchChanges(since: next).records.isEmpty)

        // The carrier over the same container. The position is the engine's to keep (in its journal), so the carrier
        // pulls from whatever cursor it is given and leaves no token file of its own in Application Support.
        try Data("legacy".utf8).write(to: PaywallCloudSync.defaultTokenURL)
        let carrier = PaywallCloudSync(containerIdentifier: container, keychain: nil)
        #expect(try await carrier.push([event]) == [event.id])
        let pulled = try #require(try await carrier.pull(since: nil))
        #expect(pulled.events == [event] && pulled.accountAvailable)
        #expect(!FileManager.default.fileExists(atPath: PaywallCloudSync.defaultTokenURL.path), "the legacy token file is deleted")
        // A relaunch that stored the cursor gets nothing new; one that lost it (a reinstall) gets the history again.
        let relaunched = PaywallCloudSync(containerIdentifier: container, keychain: nil)
        #expect(try await relaunched.pull(since: pulled.cursor)?.events.isEmpty == true)
        #expect(try await PaywallCloudSync(containerIdentifier: container, keychain: nil).pull() == [event])
    }

    /// Two devices on one iCloud account: a purchase on one is spendable on the other, and draws made before either
    /// heard of the other's leave both with the union of the two ledgers.
    @Test func two_devices_on_one_account_converge_on_one_ledger() async throws {
        let container = try await LiveCloudKit.configuredContainer()
        try await LiveCloudKit.resetZone(in: container)
        let a = try await LiveCloudKit.device(in: container)
        let b = try await LiveCloudKit.device(in: container)
        defer {
            a.shutdown()
            b.shutdown()
        }
        #expect(a.deviceID != b.deviceID)

        await a.handle(.tokenPack(id: 1, productID: "tokens.10", purchased: Date()))
        await a.syncNow()
        let credited = await eventually(seconds: 30) {
            await b.syncNow()
            return b.wallet.balance == 10
        }
        #expect(credited, "B did not receive A's credit: balance \(b.wallet.balance)")
        #expect(b.ledger.events.map(\.deviceID) == [a.deviceID])

        #expect(a.run(.tokens(2), source: liveSource("a.export")) { "pdf" }.value == "pdf")
        #expect(b.run(.tokens(3), source: liveSource("b.map")) { "map" }.value == "map")
        #expect(a.wallet.balance == 8)
        #expect(b.wallet.balance == 7)
        let converged = await eventually(seconds: 60) {
            await a.syncNow()
            await b.syncNow()
            return a.wallet.balance == 5 && b.wallet.balance == 5
        }
        #expect(converged, "balances did not converge: a=\(a.wallet.balance) b=\(b.wallet.balance)")
        #expect(a.ledger.events.count == 3)
        #expect(Set(a.ledger.events.map(\.id)) == Set(b.ledger.events.map(\.id)))
        #expect(Set(a.ledger.events.map(\.deviceID)) == [a.deviceID, b.deviceID])
    }

    /// Delete and reinstall: the journal, the device id and the change token are gone; the Keychain snapshot and
    /// the container are not. The snapshot answers before the first sync, the container's history after it, and
    /// the two are not added together.
    @Test func delete_and_reinstall_keeps_the_balance_through_the_keychain_snapshot_and_the_container() async throws {
        let container = try await LiveCloudKit.configuredContainer()
        try await LiveCloudKit.resetZone(in: container)
        LiveCloudKit.removeTokenFile()
        // A Keychain item of its own, so runs never see each other's snapshot.
        let keychain = KeychainWalletSnapshotStore(
            service: "ztron.paywall.live", account: "wallet.\(UUID().uuidString)", synchronizable: false)
        defer { Task { await keychain.delete() } }

        let directory = makeTemporaryPaywallDirectory()
        let installed = try GateEngine(
            directory: directory, catalog: hostCatalog, clock: SystemClock(), store: FakeStore(),
            sync: PaywallCloudSync(containerIdentifier: container, keychain: keychain))
        await installed.start()
        let outcome = try await installed.purchase(productID: "tokens.10", source: liveSource("paywall"))
        guard case .purchased = outcome else {
            Issue.record("expected a purchase, got \(outcome)")
            return
        }
        #expect(installed.wallet.balance == 10)
        #expect(installed.run(.tokens(4), source: liveSource("export")) { "pdf" }.value == "pdf")
        #expect(installed.wallet.balance == 6)
        await installed.syncNow()
        // The snapshot is written on its own task after every balance change.
        #expect(await eventually(seconds: 10) { await keychain.load()?.balance == 6 })
        let debitID = try #require(installed.ledger.events.last?.id)
        #expect(await keychain.load()?.lastEventID == debitID)

        installed.shutdown()
        try FileManager.default.removeItem(at: directory)
        LiveCloudKit.removeTokenFile()

        // A new directory is a new device; the Keychain item and the container are the same.
        let reinstalled = try GateEngine(
            directory: makeTemporaryPaywallDirectory(), catalog: hostCatalog, clock: SystemClock(), store: FakeStore(),
            sync: PaywallCloudSync(containerIdentifier: container, keychain: keychain))
        defer { reinstalled.shutdown() }
        #expect(reinstalled.wallet.balance == 0)
        #expect(reinstalled.deviceID != installed.deviceID)
        await reinstalled.start()
        // The fast path: the snapshot stands in before the container has answered.
        #expect(reinstalled.wallet.balance == 6)
        await reinstalled.syncNow()
        // The first sync: the account's history is back, and the snapshot has stepped aside.
        #expect(reinstalled.wallet.balance == 6)
        #expect(Set(reinstalled.ledger.events.map(\.id)) == Set(installed.ledger.events.map(\.id)))
        #expect(reinstalled.ledger.contains(debitID))
        // A different gate: "export" still holds the lease the first install drew.
        #expect(reinstalled.run(.tokens(1), source: liveSource("map")) { 1 }.value == 1)
        #expect(reinstalled.wallet.balance == 5)
        #expect(await eventually(seconds: 10) { await keychain.load()?.balance == 5 })
        #expect(await keychain.delete())
    }

    /// An iCloud data reset deletes the zone under a running adapter. The next save and the next fetch recreate
    /// it, and a change token from the old zone is stale: that fetch restarts from the beginning.
    @Test func a_zone_deleted_under_the_adapter_is_recreated_and_a_stale_token_restarts_from_the_beginning() async throws {
        let container = try await LiveCloudKit.configuredContainer()
        try await LiveCloudKit.resetZone(in: container)
        let database = CloudKitDatabase(containerIdentifier: container)
        let first = try CloudLedgerRecord(liveEvent("grant:live:first"))
        #expect(try await database.save([first]) == [first.name])
        let (_, token) = try await database.fetchChanges(since: nil)

        try await LiveCloudKit.resetZone(in: container)

        // The zone went away behind the adapter's back: the save recreates it and succeeds on the retry.
        let second = try CloudLedgerRecord(liveEvent("grant:live:second"))
        #expect(try await database.save([second]) == [second.name])
        // The token belongs to the old zone: the fetch restarts from the beginning and sees the new zone only.
        let (records, fresh) = try await database.fetchChanges(since: token)
        #expect(records == [second])
        #expect(fresh != nil)

        // Gone again: a fetch finds the zone missing, recreates it and reports it empty; the next save lands.
        try await LiveCloudKit.resetZone(in: container)
        let (afterReset, _) = try await database.fetchChanges(since: fresh)
        #expect(afterReset.isEmpty)
        #expect(try await database.save([first]) == [first.name])
    }
}
}
