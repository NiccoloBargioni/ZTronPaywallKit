import CloudKit
public import Foundation

/// `CloudDatabase` over the CloudKit private database, zone `PaywallLedger`. Owns every CloudKit object; only
/// `CloudLedgerRecord` values leave this actor.
public actor CloudKitDatabase: CloudDatabase {
    public static let zoneName = "PaywallLedger"
    public static let recordType = "LedgerEvent"
    public static let subscriptionID = "paywall-ledger-changes"
    /// CloudKit's limit per modify operation.
    public static let batchLimit = 400

    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID
    private var zoneReady = false

    public init(containerIdentifier: String? = nil) {
        let container = containerIdentifier.map(CKContainer.init(identifier:)) ?? CKContainer.default()
        self.database = container.privateCloudDatabase
        self.zoneID = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
    }

    /// Creates the zone and the zone subscription (silent push) once per launch.
    private func ensureZone() async throws {
        guard !zoneReady else { return }
        _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        let subscription = CKRecordZoneSubscription(zoneID: zoneID, subscriptionID: Self.subscriptionID)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        _ = try? await database.modifySubscriptions(saving: [subscription], deleting: [])
        zoneReady = true
    }

    public func save(_ records: [CloudLedgerRecord]) async throws -> Set<String> {
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
            let (results, _) = try await database.modifyRecords(
                saving: ckRecords, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false)
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

    public func fetchChanges(since token: Data?) async throws -> (records: [CloudLedgerRecord], token: Data?) {
        try await ensureZone()
        var serverToken = token.flatMap {
            try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0)
        }
        var collected: [CloudLedgerRecord] = []
        var moreComing = true
        while moreComing {
            let changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: serverToken)
            for (id, result) in changes.modificationResultsByID {
                if case .success(let modification) = result, let payload = modification.record["payload"] as? Data {
                    collected.append(CloudLedgerRecord(name: id.recordName, payload: payload))
                }
            }
            serverToken = changes.changeToken
            moreComing = changes.moreComing
        }
        let encoded = serverToken.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
        return (collected, encoded)
    }
}
