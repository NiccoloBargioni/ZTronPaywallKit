import CloudKit
import Foundation
import PaywallCore
import PaywallTesting
import Testing

@testable import PaywallCloudSync

/// A scriptable stand-in for the CloudKit private database at the level `CloudKitDatabase` talks to it. State lives
/// in an actor; the conformer converts to and from CloudKit objects on the caller's side.
private actor FakeCloudKitState {
    struct Stored: Sendable {
        var payload: Data?
        var serial: Int
    }

    var zones: Set<String> = []
    var subscriptions: [String] = []
    var records: [String: Stored] = [:]
    var serial = 0
    var pageSize = 1_000
    var saveBatches: [Int] = []
    var fetchCalls = 0
    var zoneSaveError: (any Error)?
    var subscriptionError: (any Error)?
    var saveError: (any Error)?
    var saveErrorsOnce: [any Error] = []
    var fetchErrorsOnce: [any Error] = []
    var perRecordErrors: [String: any Error] = [:]
    var deleteZoneOnNextFetch = false
    var deleteZoneOnNextSave = false

    func saveZone(_ name: String) throws {
        if let zoneSaveError { throw zoneSaveError }
        zones.insert(name)
    }

    func saveSubscription(_ id: String) throws {
        if let subscriptionError { throw subscriptionError }
        subscriptions.append(id)
    }

    func saveRecords(_ batch: [(name: String, payload: Data?)]) throws -> [String: Result<Void, any Error>] {
        if let saveError { throw saveError }
        if !saveErrorsOnce.isEmpty { throw saveErrorsOnce.removeFirst() }
        saveBatches.append(batch.count)
        if deleteZoneOnNextSave {
            deleteZoneOnNextSave = false
            zones = []
        }
        // What CloudKit does for a zone that is gone (measured in the live lane): the call succeeds and every
        // record reports `zoneNotFound`.
        guard !zones.isEmpty else {
            return Dictionary(uniqueKeysWithValues: batch.map { ($0.name, Result<Void, any Error>.failure(CKError(.zoneNotFound))) })
        }
        var results: [String: Result<Void, any Error>] = [:]
        for record in batch {
            if let error = perRecordErrors[record.name] {
                results[record.name] = .failure(error)
            } else if records[record.name] != nil {
                results[record.name] = .failure(CKError(.serverRecordChanged))
            } else {
                serial += 1
                records[record.name] = Stored(payload: record.payload, serial: serial)
                results[record.name] = .success(())
            }
        }
        return results
    }

    /// Returns `(records, lastSerialServed, moreComing)`; the caller's token is the serial, as text.
    func changes(since serial: Int) throws -> (records: [(name: String, payload: Data?)], last: Int, moreComing: Bool) {
        fetchCalls += 1
        if !fetchErrorsOnce.isEmpty { throw fetchErrorsOnce.removeFirst() }
        if deleteZoneOnNextFetch {
            deleteZoneOnNextFetch = false
            zones = []
            throw CKError(.userDeletedZone)
        }
        let ordered = records.filter { $0.value.serial > serial }.sorted { $0.value.serial < $1.value.serial }
        let page = Array(ordered.prefix(pageSize))
        let last = page.last?.value.serial ?? serial
        return (page.map { ($0.key, $0.value.payload) }, last, page.count < ordered.count)
    }

    func plant(_ name: String, payload: Data?) {
        serial += 1
        records[name] = Stored(payload: payload, serial: serial)
    }

    func set(pageSize: Int) { self.pageSize = pageSize }
    func set(zoneSaveError: (any Error)?) { self.zoneSaveError = zoneSaveError }
    func set(subscriptionError: (any Error)?) { self.subscriptionError = subscriptionError }
    func set(saveError: (any Error)?) { self.saveError = saveError }
    func set(saveErrorsOnce: [any Error]) { self.saveErrorsOnce = saveErrorsOnce }
    func set(fetchErrorsOnce: [any Error]) { self.fetchErrorsOnce = fetchErrorsOnce }
    func set(perRecordErrors: [String: any Error]) { self.perRecordErrors = perRecordErrors }
    func deleteZoneOnNextFetch(_ flag: Bool) { deleteZoneOnNextFetch = flag }
    func deleteZoneOnNextSave(_ flag: Bool) { deleteZoneOnNextSave = flag }
}

/// `CloudKitOperations` over the state actor. The change token is the last serial served, as bytes, which is what
/// the real adapter hands over too (an archived `CKServerChangeToken`).
private struct FakeCloudKit: CloudKitOperations {
    let state: FakeCloudKitState

    func saveZone(_ zone: CKRecordZone) async throws { try await state.saveZone(zone.zoneID.zoneName) }
    func saveSubscription(_ subscription: CKSubscription) async throws { try await state.saveSubscription(subscription.subscriptionID) }

    func saveRecords(_ records: [CKRecord]) async throws -> [CKRecord.ID: Result<CKRecord, any Error>] {
        let plain = records.map { (name: $0.recordID.recordName, payload: $0["payload"] as? Data) }
        let results = try await state.saveRecords(plain)
        var mapped: [CKRecord.ID: Result<CKRecord, any Error>] = [:]
        for record in records {
            switch results[record.recordID.recordName] {
            case .success?: mapped[record.recordID] = .success(record)
            case .failure(let error)?: mapped[record.recordID] = .failure(error)
            case nil: break
            }
        }
        return mapped
    }

    func changes(in zoneID: CKRecordZone.ID, since token: Data?) async throws -> CloudKitZoneChanges {
        let since = token.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
        let page = try await state.changes(since: since)
        let records = page.records.map { stored -> CKRecord in
            let record = CKRecord(recordType: CloudKitDatabase.recordType, recordID: CKRecord.ID(recordName: stored.name, zoneID: zoneID))
            if let payload = stored.payload { record["payload"] = payload as NSData }
            return record
        }
        return CloudKitZoneChanges(records: records, token: Data(String(page.last).utf8), moreComing: page.moreComing)
    }
}

private func event(_ id: String, tokens: Int = 1) -> LedgerEvent {
    LedgerEvent(
        id: id, at: Date(timeIntervalSince1970: 1_000), deviceID: "A", accountKey: "k", source: nil,
        previousHash: paywallGenesisHash, kind: .grant(tokens: tokens, reason: "r"))
}

@Suite("CloudKit database", .serialized)
struct CloudKitDatabaseTests {
    private func makeDatabase() -> (CloudKitDatabase, FakeCloudKitState) {
        let state = FakeCloudKitState()
        return (CloudKitDatabase(operations: FakeCloudKit(state: state)), state)
    }

    @Test func creates_the_zone_and_subscription_once_and_tolerates_a_subscription_failure() async throws {
        let (database, state) = makeDatabase()
        await state.set(subscriptionError: CKError(.networkUnavailable))
        _ = try await database.save([try CloudLedgerRecord(event("grant:1"))])
        _ = try await database.fetchChanges(since: nil)
        #expect(await state.zones == [CloudKitDatabase.zoneName])
        #expect(await state.subscriptions.isEmpty)
        await state.set(subscriptionError: nil)
        _ = try await database.save([try CloudLedgerRecord(event("grant:2"))])
        #expect(await state.subscriptions.isEmpty)  // zone setup runs once per launch
        #expect(await state.saveBatches == [1, 1])
    }

    @Test func no_icloud_account_is_told_apart_from_other_failures() async throws {
        let (database, state) = makeDatabase()
        await state.set(zoneSaveError: CKError(.notAuthenticated))
        await #expect(throws: CloudDatabaseError.noAccount) { _ = try await database.save([try CloudLedgerRecord(event("grant:1"))]) }
        await #expect(throws: CloudDatabaseError.noAccount) { _ = try await database.fetchChanges(since: nil) }
        await state.set(zoneSaveError: nil)
        await state.set(fetchErrorsOnce: [CKError(.notAuthenticated)])  // signed out after the zone was set up
        await #expect(throws: CloudDatabaseError.noAccount) { _ = try await database.fetchChanges(since: nil) }
        #expect(try await database.fetchChanges(since: nil).records.isEmpty)
    }

    @Test func zone_creation_failure_propagates_and_is_retried_next_time() async throws {
        let (database, state) = makeDatabase()
        await state.set(zoneSaveError: CKError(.networkUnavailable))
        await #expect(throws: CKError.self) { _ = try await database.save([try CloudLedgerRecord(event("grant:1"))]) }
        await #expect(throws: CKError.self) { _ = try await database.fetchChanges(since: nil) }
        await state.set(zoneSaveError: nil)
        #expect(try await database.save([try CloudLedgerRecord(event("grant:1"))]) == ["grant:1"])
        #expect(await state.subscriptions == [CloudKitDatabase.subscriptionID])
    }

    @Test func saves_in_batches_of_four_hundred_and_acknowledges_existing_records() async throws {
        let (database, state) = makeDatabase()
        let records = try (0..<901).map { try CloudLedgerRecord(event("grant:\($0)")) }
        let acknowledged = try await database.save(records)
        #expect(acknowledged.count == 901)
        #expect(await state.saveBatches == [400, 400, 101])
        // A retried save of the same events is "already present": acknowledged, not duplicated.
        #expect(try await database.save(Array(records.prefix(3))) == ["grant:0", "grant:1", "grant:2"])
        #expect(await state.records.count == 901)
    }

    @Test func other_per_record_errors_are_not_acknowledged_and_whole_failures_throw() async throws {
        let (database, state) = makeDatabase()
        await state.set(perRecordErrors: ["grant:2": CKError(.quotaExceeded)])
        let acknowledged = try await database.save(try ["grant:1", "grant:2", "grant:3"].map { try CloudLedgerRecord(event($0)) })
        #expect(acknowledged == ["grant:1", "grant:3"])
        await state.set(saveError: CKError(.networkFailure))
        await #expect(throws: CKError.self) { _ = try await database.save([try CloudLedgerRecord(event("grant:9"))]) }
        #expect(try await database.save([]).isEmpty)
    }

    @Test func fetches_every_page_and_skips_records_without_a_payload() async throws {
        let (database, state) = makeDatabase()
        for index in 0..<5 { await state.plant("grant:\(index)", payload: try event("grant:\(index)").canonicalData()) }
        await state.plant("broken", payload: nil)
        await state.set(pageSize: 2)
        let (records, token) = try await database.fetchChanges(since: nil)
        #expect(records.map(\.name).sorted() == (0..<5).map { "grant:\($0)" })
        #expect(token == Data("6".utf8))  // the position after the last page
        #expect(await state.fetchCalls == 3)
        #expect(try records.map { try $0.event().id }.sorted() == records.map(\.name).sorted())
        // From that token nothing is new; after another record, exactly that one.
        #expect(try await database.fetchChanges(since: token).records.isEmpty)
        await state.plant("grant:9", payload: try event("grant:9").canonicalData())
        let (later, next) = try await database.fetchChanges(since: token)
        #expect(later.map(\.name) == ["grant:9"])
        #expect(next == Data("7".utf8))
    }

    @Test func an_expired_change_token_restarts_from_the_beginning() async throws {
        let (database, state) = makeDatabase()
        await state.plant("grant:1", payload: try event("grant:1").canonicalData())
        await state.set(fetchErrorsOnce: [CKError(.changeTokenExpired)])
        let (records, token) = try await database.fetchChanges(since: Data("99".utf8))  // a position the server forgot
        #expect(records.map(\.name) == ["grant:1"])
        #expect(token == Data("1".utf8))
        #expect(await state.fetchCalls == 2)
    }

    @Test func a_deleted_zone_is_recreated_on_fetch_and_on_save() async throws {
        let (database, state) = makeDatabase()
        _ = try await database.fetchChanges(since: nil)
        #expect(await state.zones.count == 1)
        await state.deleteZoneOnNextFetch(true)
        _ = try await database.fetchChanges(since: nil)
        #expect(await state.zones == [CloudKitDatabase.zoneName])
        #expect(await state.subscriptions.count == 2)  // set up again with the zone

        // A save that finds the zone gone recreates it and succeeds on the retry. CloudKit reports the zone per
        // record with the call succeeding (the shape the live lane measured) ...
        await state.deleteZoneOnNextSave(true)
        #expect(try await database.save([try CloudLedgerRecord(event("grant:1"))]) == ["grant:1"])
        #expect(await state.zones == [CloudKitDatabase.zoneName])
        #expect(await state.subscriptions.count == 3)
        #expect(await state.saveBatches.suffix(2) == [1, 1])
        // ... and a whole-call failure is handled the same way.
        await state.set(saveErrorsOnce: [CKError(.zoneNotFound)])
        #expect(try await database.save([try CloudLedgerRecord(event("grant:3"))]) == ["grant:3"])
        #expect(await state.subscriptions.count == 4)
        // The retry is made once: a zone that is gone again leaves the batch unacknowledged, for the next sync.
        await state.set(perRecordErrors: ["grant:4": CKError(.zoneNotFound)])
        #expect(try await database.save([try CloudLedgerRecord(event("grant:4"))]).isEmpty)
        #expect(await state.subscriptions.count == 5)
        await state.set(perRecordErrors: [:])
        // When the retry fails the same way the error propagates.
        await state.set(saveError: CKError(.userDeletedZone))
        await #expect(throws: CKError.self) { _ = try await database.save([try CloudLedgerRecord(event("grant:2"))]) }
        await state.set(saveError: nil)
        #expect(try await database.save([try CloudLedgerRecord(event("grant:2"))]) == ["grant:2"])
        // Errors that are not about the zone propagate unchanged.
        await state.set(fetchErrorsOnce: [CKError(.networkUnavailable)])
        await #expect(throws: CKError.self) { _ = try await database.fetchChanges(since: nil) }
        await state.set(fetchErrorsOnce: [URLError(.notConnectedToInternet)])
        await #expect(throws: URLError.self) { _ = try await database.fetchChanges(since: nil) }
    }

    @Test func carrier_over_the_cloudkit_database_pushes_pulls_and_persists_a_token_file() async throws {
        let (database, _) = makeDatabase()
        let tokenURL = makeTemporaryPaywallDirectory().appendingPathComponent("cloudkit.token")
        let carrier = PaywallCloudSync(database: database, keychain: nil, minimumPullInterval: 0, tokenURL: tokenURL)
        #expect(try await carrier.push([event("grant:1", tokens: 3)]) == ["grant:1"])
        #expect(try await carrier.pull().map(\.id) == ["grant:1"])
        #expect(FileManager.default.contents(atPath: tokenURL.path) == Data("1".utf8))
        // A new launch starts from the stored token: the pulled event is not delivered again.
        let relaunched = PaywallCloudSync(database: database, keychain: nil, minimumPullInterval: 0, tokenURL: tokenURL)
        #expect(try await relaunched.pull().isEmpty)
    }
}
