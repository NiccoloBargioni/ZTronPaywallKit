public import Foundation

/// The device-local fast path: a balance known on first launch after a reinstall, before any sync ran.
public struct WalletSnapshot: Codable, Hashable, Sendable {
    public var accountKey: String
    public var balance: Int
    public var lastEventID: String?
    public var headHash: String

    public init(accountKey: String, balance: Int, lastEventID: String?, headHash: String) {
        self.accountKey = accountKey
        self.balance = balance
        self.lastEventID = lastEventID
        self.headHash = headHash
    }
}

/// The token wallet as views see it.
public struct Wallet: Hashable, Sendable {
    /// Credits + grants + refunds − debits − revocations. Negative after a pack refund.
    public let balance: Int
    /// Held by live reservations on this device.
    public let reserved: Int
    public var available: Int { max(0, balance - reserved) }

    public init(balance: Int, reserved: Int = 0) {
        self.balance = balance
        self.reserved = reserved
    }

    public static let empty = Wallet(balance: 0)
}

/// A lease derived from the ledger: one per gate id, from the latest debit that was not refunded.
public struct LeaseRecord: Hashable, Sendable {
    public let gateID: String
    public let debitID: String
    public let grantedAt: Date
    public let expiresAt: Date
}

/// Events written before any account key was known. Counted for every account (see README, "Accounts").
public let unboundAccountKey = "unbound"

/// The append-only token ledger and everything derived from it. A pure value: no I/O.
public struct Ledger: Hashable, Sendable {
    public private(set) var events: [LedgerEvent] = []
    private var ids: Set<String> = []
    private var heads: [String: String] = [:]

    public init(events: [LedgerEvent] = []) {
        for event in events { append(event) }
    }

    public func contains(_ id: String) -> Bool { ids.contains(id) }

    /// Appends unless an event with the same id exists. Returns whether the event was new.
    @discardableResult
    public mutating func append(_ event: LedgerEvent) -> Bool {
        guard ids.insert(event.id).inserted else { return false }
        events.append(event)
        heads[event.deviceID] = event.hash
        return true
    }

    /// The hash the next event written by `deviceID` must link to.
    public func head(for deviceID: String) -> String {
        heads[deviceID] ?? paywallGenesisHash
    }

    private func belongs(_ event: LedgerEvent, to accountKey: String) -> Bool {
        event.accountKey == accountKey || event.accountKey == unboundAccountKey
    }

    /// The derived balance for one account. With a `baseline` (the Keychain snapshot) whose last event this
    /// ledger has not seen yet, the baseline stands in for the history that has not synced back.
    public func balance(for accountKey: String, baseline: WalletSnapshot? = nil) -> Int {
        let mine = events.filter { belongs($0, to: accountKey) }
        var credits: [UInt64: Int] = [:]
        var debits: [String: Int] = [:]
        for event in mine {
            switch event.kind {
            case .credit(let tokens, _, let transactionID): credits[transactionID] = tokens
            case .debit(let tokens, _): debits[event.id] = tokens
            default: break
            }
        }
        var total = 0
        for event in mine {
            switch event.kind {
            case .credit(let tokens, _, _): total += tokens
            case .grant(let tokens, _): total += tokens
            case .debit(let tokens, _): total -= tokens
            case .revocation(let transactionID): total -= credits[transactionID] ?? 0
            case .refund(let debitID, _): total += debits[debitID] ?? 0
            case .leaseExtended: break
            }
        }
        if let baseline, baseline.accountKey == accountKey, let last = baseline.lastEventID, !contains(last) {
            return baseline.balance + total
        }
        return total
    }

    /// Leases by gate id, derived from debits, extensions and refunds. Nothing else stores a lease.
    public func leases(for accountKey: String) -> [String: LeaseRecord] {
        let mine = events.filter { belongs($0, to: accountKey) }
        let refunded = Set(
            mine.compactMap { event -> String? in
                if case .refund(let debitID, _) = event.kind { return debitID }
                return nil
            })
        var extensions: [String: Date] = [:]
        for event in mine {
            if case .leaseExtended(let debitID, let until) = event.kind {
                extensions[debitID] = max(extensions[debitID] ?? until, until)
            }
        }
        var leases: [String: LeaseRecord] = [:]
        for event in mine {
            guard case .debit(_, let leaseUntil) = event.kind, let gateID = event.source?.id,
                !refunded.contains(event.id)
            else { continue }
            let expiresAt = max(leaseUntil, extensions[event.id] ?? leaseUntil)
            let record = LeaseRecord(gateID: gateID, debitID: event.id, grantedAt: event.at, expiresAt: expiresAt)
            if let existing = leases[gateID], existing.grantedAt > record.grantedAt { continue }
            leases[gateID] = record
        }
        return leases
    }

    /// Credits recorded for a transaction id, for revocation bookkeeping.
    public func creditTokens(transactionID: UInt64) -> Int? {
        for event in events {
            if case .credit(let tokens, _, let id) = event.kind, id == transactionID { return tokens }
        }
        return nil
    }

    /// The first event whose `previousHash` links to nothing in its own device stream, or forks it.
    /// Order-independent, because a sync can deliver another device's events in any order.
    public func firstBrokenLink() -> LedgerEvent? {
        var hashes: [String: Set<String>] = [:]
        for event in events { hashes[event.deviceID, default: []].insert(event.hash) }
        var used: [String: Set<String>] = [:]
        for event in events {
            let known = event.previousHash == paywallGenesisHash || hashes[event.deviceID]?.contains(event.previousHash) == true
            let fresh = used[event.deviceID, default: []].insert(event.previousHash).inserted
            if !known || !fresh { return event }
        }
        return nil
    }
}
