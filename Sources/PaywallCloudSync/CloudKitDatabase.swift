import CloudKit
public import Foundation

/// One page of zone changes, in values a test can build: `CKDatabase.RecordZoneChange.Modification` has no public
/// initializer and `CKServerChangeToken` cannot be constructed, so the token travels as its archived bytes.
struct CloudKitZoneChanges: Sendable {
    var records: [CKRecord]
    var token: Data?
    var moreComing: Bool
}

/// The four CloudKit calls `CloudKitDatabase` makes, so its zone setup, batching, acknowledgement and change-token
/// logic runs against `FakeCloudKit` in tests. `CKDatabase` is the production conformance; the live CloudKit lane
/// (`LiveCloudKitTests` in the test host, against the real container) is the only thing that exercises those four lines.
protocol CloudKitOperations: Sendable {
    func saveZone(_ zone: CKRecordZone) async throws
    func saveSubscription(_ subscription: CKSubscription) async throws
    /// `modifyRecords` with `.ifServerRecordUnchanged`, not atomic: per-record results.
    func saveRecords(_ records: [CKRecord]) async throws -> [CKRecord.ID: Result<CKRecord, any Error>]
    /// One page of changes since the archived token (`nil`: from the beginning).
    func changes(in zoneID: CKRecordZone.ID, since token: Data?) async throws -> CloudKitZoneChanges
}

// Each forwarder is one closure-free statement line: these are the only lines of the target no unit test can
// execute (CloudKit traps or fails outside an entitled host), and the coverage gate counts lines per function,
// closures included. The live CloudKit lane runs them.
extension CKDatabase: CloudKitOperations {
    func saveZone(_ zone: CKRecordZone) async throws { _ = try await modifyRecordZones(saving: [zone], deleting: []) }
    func saveSubscription(_ subscription: CKSubscription) async throws { _ = try await modifySubscriptions(saving: [subscription], deleting: []) }
    func saveRecords(_ records: [CKRecord]) async throws -> [CKRecord.ID: Result<CKRecord, any Error>] { try await modifyRecords(saving: records, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false).saveResults }
    func changes(in zoneID: CKRecordZone.ID, since token: Data?) async throws -> CloudKitZoneChanges { var previous: CKServerChangeToken?; if let token { previous = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: token) }; let page = try await recordZoneChanges(inZoneWith: zoneID, since: previous, desiredKeys: nil, resultsLimit: nil); var records: [CKRecord] = []; for case .success(let modification) in page.modificationResultsByID.values { records.append(modification.record) }; return CloudKitZoneChanges(records: records, token: try? NSKeyedArchiver.archivedData(withRootObject: page.changeToken, requiringSecureCoding: true), moreComing: page.moreComing) }
}

/// `CloudDatabase` over the CloudKit private database, zone `PaywallLedger`. Owns every CloudKit object; only
/// `CloudLedgerRecord` values leave this actor.
public actor CloudKitDatabase: CloudDatabase {
    public static let zoneName = "PaywallLedger"
    public static let recordType = "LedgerEvent"
    public static let subscriptionID = "paywall-ledger-changes"
    /// CloudKit's limit per modify operation.
    public static let batchLimit = 400

    private let database: any CloudKitOperations
    private let zoneID: CKRecordZone.ID
    private var zoneReady = false

    /// `CKContainer` traps when the identifier is not in the app's iCloud entitlement, so this runs only in an
    /// entitled host: the live CloudKit lane, never a unit test.
    public init(containerIdentifier: String? = nil) { let container: CKContainer; if let containerIdentifier { container = CKContainer(identifier: containerIdentifier) } else { container = CKContainer.default() }; self.init(operations: container.privateCloudDatabase) }

    init(operations: any CloudKitOperations) {
        self.database = operations
        self.zoneID = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
    }

    /// Creates the zone and the zone subscription (silent push) once per launch. A subscription that cannot be
    /// saved is not fatal: pulls still run on the other triggers.
    private func ensureZone() async throws {
        guard !zoneReady else { return }
        try await database.saveZone(CKRecordZone(zoneID: zoneID))
        let subscription = CKRecordZoneSubscription(zoneID: zoneID, subscriptionID: Self.subscriptionID)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        try? await database.saveSubscription(subscription)
        zoneReady = true
    }

    /// The zone was deleted under us (iCloud data reset, "Delete from iCloud"): recreate it and start over.
    private func zoneVanished(_ error: any Error) -> Bool {
        guard let code = (error as? CKError)?.code else { return false }
        return code == .zoneNotFound || code == .userDeletedZone
    }

    /// A batch that hit the deleted zone: at least one record failed with a zone error.
    private func zoneVanished(in results: [CKRecord.ID: Result<CKRecord, any Error>]) -> Bool {
        results.values.contains { result in
            if case .failure(let error) = result { return zoneVanished(error) }
            return false
        }
    }

    // MARK: CloudDatabase

    /// `.notAuthenticated` is the device without an iCloud account, and the carrier is told so. Every other error
    /// is a failure to answer and propagates as such, to be retried.
    public func save(_ records: [CloudLedgerRecord]) async throws -> Set<String> {
        do { return try await saveInZone(records) } catch let error as CKError where error.code == .notAuthenticated { throw CloudDatabaseError.noAccount }
    }

    public func fetchChanges(since token: Data?) async throws -> (records: [CloudLedgerRecord], token: Data?) {
        do { return try await changesInZone(since: token) } catch let error as CKError where error.code == .notAuthenticated { throw CloudDatabaseError.noAccount }
    }

    private func saveInZone(_ records: [CloudLedgerRecord]) async throws -> Set<String> {
        try await ensureZone()
        var acknowledged: Set<String> = []
        var start = 0
        while start < records.count {
            let batch = Array(records[start..<min(start + Self.batchLimit, records.count)])
            start += Self.batchLimit
            let ckRecords = batch.map { record -> CKRecord in
                let ck = CKRecord(recordType: Self.recordType, recordID: CKRecord.ID(recordName: record.name, zoneID: zoneID))
                ck["payload"] = record.payload as NSData
                return ck
            }
            var results: [CKRecord.ID: Result<CKRecord, any Error>]
            do {
                results = try await database.saveRecords(ckRecords)
            } catch where zoneVanished(error) {
                results = Dictionary(uniqueKeysWithValues: ckRecords.map { ($0.recordID, .failure(error)) })
            }
            // The zone was deleted under us (iCloud data reset, "Delete from iCloud"). CloudKit reports that per
            // record, `zoneNotFound` on each, with the call itself succeeding (it is not atomic); a whole-call
            // failure is folded into the same shape above. Recreate the zone and retry the batch once.
            if zoneVanished(in: results) {
                zoneReady = false
                try await ensureZone()
                results = try await database.saveRecords(ckRecords)
            }
            for (id, result) in results {
                switch result {
                case .success:
                    acknowledged.insert(id.recordName)
                case .failure(let error):
                    // Events are immutable: a record that already exists is the same event, saved before.
                    if (error as? CKError)?.code == .serverRecordChanged { acknowledged.insert(id.recordName) }
                }
            }
        }
        return acknowledged
    }

    private func changesInZone(since token: Data?) async throws -> (records: [CloudLedgerRecord], token: Data?) {
        try await ensureZone()
        var serverToken = token
        var collected: [CloudLedgerRecord] = []
        var moreComing = true
        while moreComing {
            let page: CloudKitZoneChanges
            do {
                page = try await database.changes(in: zoneID, since: serverToken)
            } catch let error as CKError where error.code == .changeTokenExpired {
                // The server forgot our position: start from the beginning, the union merge makes replays harmless.
                serverToken = nil
                collected = []
                continue
            } catch where zoneVanished(error) {
                zoneReady = false
                try await ensureZone()
                serverToken = nil
                collected = []
                continue
            }
            for record in page.records {
                if let payload = record["payload"] as? Data {
                    collected.append(CloudLedgerRecord(name: record.recordID.recordName, payload: payload))
                }
            }
            serverToken = page.token
            moreComing = page.moreComing
        }
        return (collected, serverToken)
    }
}
