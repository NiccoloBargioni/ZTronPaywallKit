public import Foundation

/// Leases by gate id. The records are derived from the ledger (every debit carries `leaseUntil`); the only state
/// of its own is the in-memory set of pinning holders, rebuilt by views as they appear.
@MainActor
public final class LeaseTable {
    public private(set) var records: [String: LeaseRecord] = [:]
    private var pins: [String: Set<UUID>] = [:]
    private var reportedExpired: Set<String> = []

    public init() {}

    /// Replaces the derived records after the ledger changed. Pins survive.
    public func refresh(from records: [String: LeaseRecord]) {
        self.records = records
    }

    public func holders(of gateID: String) -> Set<UUID> { pins[gateID] ?? [] }

    /// Active while pinned, or while `grantedAt <= now < expiresAt`. A lease granted in the future
    /// (the clock moved back) is expired.
    public func isActive(_ gateID: String, now: Date) -> Bool {
        guard let record = records[gateID] else { return false }
        if !holders(of: gateID).isEmpty { return true }
        return record.grantedAt <= now && now < record.expiresAt
    }

    /// Returns `true` if `holder` was not pinning `gateID` before.
    @discardableResult
    public func pin(_ gateID: String, holder: UUID) -> Bool {
        pins[gateID, default: []].insert(holder).inserted
    }

    /// Returns `true` if `holder` was pinning `gateID`.
    @discardableResult
    public func unpin(_ gateID: String, holder: UUID) -> Bool {
        guard pins[gateID]?.remove(holder) != nil else { return false }
        if pins[gateID]?.isEmpty == true { pins[gateID] = nil }
        return true
    }

    /// The record for `gateID` if it has lapsed and was not reported yet; marks it reported.
    public func takeNewlyExpired(_ gateID: String, now: Date) -> LeaseRecord? {
        guard let record = records[gateID], !isActive(gateID, now: now), !reportedExpired.contains(record.debitID) else {
            return nil
        }
        reportedExpired.insert(record.debitID)
        return record
    }
}
