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
    /// Credits + grants + refunds − debits − revocations. Negative after a pack refund, or once the devices of one
    /// account spent the same tokens before their ledgers met (each decides against the balance it last pulled); token
    /// gates stay closed until it is repaid. Show `available` to the user.
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
public struct LeaseRecord: Codable, Hashable, Sendable {
    public let gateID: String
    public let debitID: String
    public let grantedAt: Date
    public let expiresAt: Date
}

/// Events written before any account key was known. Counted for every account (see HANDBOOK.md, "Accounts").
public let unboundAccountKey = "unbound"

/// The derived state of a `Ledger` at one point of its history: what the ledger keeps instead of the events, written
/// to `ledger.log` as a `.checkpoint` entry so compaction can drop the events it stands for (HANDBOOK.md, "Retention").
///
/// It carries everything a later event may still refer to, so a replay from it equals a replay of the whole history
/// (`LedgerIncrementalTests` proves it over random histories): the balances with their cross-account parts, the lease
/// table of every account partition, the per-device heads the next events link to, the credits a revocation may
/// reverse, every debit a refund may give back or a lease may fall back to, the refunds and revocations that arrived
/// before their counterpart, every event id, so a replay or a re-delivery of a forgotten event stays a no-op and the
/// sync union merge and the outbox stay exact, and what `firstBrokenLink()` needs to go on verifying the chains. It
/// grows with the ids and debits of the history, at a fraction of an event's size; nothing else survives it.
public struct LedgerCheckpoint: Hashable, Sendable {
    /// How many events the checkpoint stands for.
    public let eventCount: Int
    /// The last event appended before the checkpoint: what the Keychain snapshot names.
    public let lastEventID: String?
    /// Every event id applied so far.
    let ids: Set<String>
    /// The hash of the last event each device wrote: the head its next event links to.
    public let heads: [String: String]
    /// Per device, the hashes no event links to yet: the head, plus the ends of the gaps a sync has not filled.
    /// What a later event may link to.
    public let tips: [String: Set<String>]
    /// The devices whose first event (the one linking to genesis) has been seen: a second one would fork the stream.
    public let rooted: Set<String>
    /// The events whose predecessor had not arrived, in order: broken links until the sync delivers it.
    public let unlinked: [LedgerEvent]
    /// The first event that forked its stream, if any: a break nothing can mend.
    public let fork: LedgerEvent?
    let accountKeys: Set<String>
    let balances: Balances
    let leaseViews: [String: LeaseView]
    /// Every debit: those with a gate grouped per gate in append order, then the gateless ones by id.
    let debits: [Debit]
}

/// What the ledger keeps of a debit once its event is gone: its amount and account for a refund, its lease for the
/// fallback after a refund of a newer debit on the same gate.
struct Debit: Hashable, Sendable {
    var id: String
    var tokens: Int
    var accountKey: String
    var at: Date
    var leaseUntil: Date
    var gateID: String?
}

/// The append-only token ledger and everything derived from it. A pure value: no I/O.
///
/// The balances and the lease tables are maintained as events are appended, in whatever order a sync delivers
/// them, so a draw costs the same on a ten-year history as on a fresh install; only `firstBrokenLink()` walks
/// every event. The maintenance relies on what the event ids guarantee: one credit per transaction id
/// (`credit:<id>`) and one debit per debit id. A ledger starts from genesis or from a `LedgerCheckpoint`, in which
/// case `events` holds only what was appended since; every derivation agrees either way.
public struct Ledger: Hashable, Sendable {
    /// The events appended since the checkpoint this ledger started from (all of them, from genesis).
    public private(set) var events: [LedgerEvent] = []
    /// The last event appended, through checkpoints: what the Keychain snapshot names.
    public private(set) var lastEventID: String?
    private var ids: Set<String> = []
    /// The last event each device wrote since the checkpoint. Its hash is the head the device's next event links
    /// to, computed when asked rather than once per event at load.
    private var lastEvents: [String: LedgerEvent] = [:]
    /// The heads the checkpoint recorded, for the devices that wrote nothing since.
    private var checkpointHeads: [String: String] = [:]
    /// The chain as the checkpoint left it (see `LedgerCheckpoint`), for `firstBrokenLink()` to continue from.
    private var checkpointTips: [String: Set<String>] = [:]
    private var rooted: Set<String> = []
    private var unlinked: [LedgerEvent] = []
    private var fork: LedgerEvent?
    private var coveredEventCount = 0
    /// Every account key that appears in the history, `unbound` included.
    private var accountKeys: Set<String> = []
    private var balances = Balances()
    /// One lease table per partition: the unbound events alone, and each bound account with the unbound events it
    /// also counts. An account with no view of its own reads the unbound one, which is what its events derive.
    private var leaseViews: [String: LeaseView] = [:]
    private var debits: [String: Debit] = [:]
    /// The debit ids per gate in append order, for re-deriving a lease after a refund.
    private var debitsByGate: [String: [String]] = [:]

    public init(events: [LedgerEvent] = []) {
        self.init(checkpoint: nil, events: events)
    }

    /// Starts from `checkpoint` (genesis when `nil`) and appends `events`. An event the checkpoint already counts is
    /// a replay and changes nothing, which is how the outbox a compaction kept behind a checkpoint reloads.
    public init(checkpoint: LedgerCheckpoint?, events: [LedgerEvent] = []) {
        if let checkpoint {
            coveredEventCount = checkpoint.eventCount
            lastEventID = checkpoint.lastEventID
            ids = checkpoint.ids
            checkpointHeads = checkpoint.heads
            checkpointTips = checkpoint.tips
            rooted = checkpoint.rooted
            unlinked = checkpoint.unlinked
            fork = checkpoint.fork
            accountKeys = checkpoint.accountKeys
            balances = checkpoint.balances
            leaseViews = checkpoint.leaseViews
            for debit in checkpoint.debits {
                debits[debit.id] = debit
                if let gateID = debit.gateID { debitsByGate[gateID, default: []].append(debit.id) }
            }
        }
        for event in events { append(event) }
    }

    /// Two ledgers are equal when they started from the same point of the history and hold the same events in the
    /// same order; everything else is derived. The checkpoint heads identify the starting point, since each hash
    /// covers its whole device stream. A replay from a checkpoint is therefore not equal to the full replay, although
    /// every derivation agrees (`LedgerIncrementalTests` checks them).
    public static func == (lhs: Ledger, rhs: Ledger) -> Bool {
        lhs.checkpointHeads == rhs.checkpointHeads && lhs.events == rhs.events
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(checkpointHeads)
        hasher.combine(events)
    }

    public func contains(_ id: String) -> Bool { ids.contains(id) }

    /// Whether any event counts for `accountKey` (its own, or written before an account was known).
    public func hasEvents(for accountKey: String) -> Bool {
        accountKeys.contains(accountKey) || accountKeys.contains(unboundAccountKey)
    }

    /// Appends unless an event with the same id exists. Returns whether the event was new.
    @discardableResult
    public mutating func append(_ event: LedgerEvent) -> Bool {
        guard ids.insert(event.id).inserted else { return false }
        events.append(event)
        lastEventID = event.id
        lastEvents[event.deviceID] = event
        accountKeys.insert(event.accountKey)
        if case .debit(let tokens, let leaseUntil) = event.kind {
            debits[event.id] = Debit(
                id: event.id, tokens: tokens, accountKey: event.accountKey, at: event.at, leaseUntil: leaseUntil,
                gateID: event.source?.id)
            if let gateID = event.source?.id { debitsByGate[gateID, default: []].append(event.id) }
        }
        balances.apply(event, debits: debits)
        if event.accountKey == unboundAccountKey {
            // Unbound events count for every account: every view sees them.
            if leaseViews[unboundAccountKey] == nil { leaseViews[unboundAccountKey] = LeaseView() }
            for key in Array(leaseViews.keys) { apply(event, toLeasesOf: key) }
        } else {
            // A new account starts from the unbound history it also counts.
            if leaseViews[event.accountKey] == nil { leaseViews[event.accountKey] = leaseViews[unboundAccountKey] ?? LeaseView() }
            apply(event, toLeasesOf: event.accountKey)
        }
        return true
    }

    private mutating func apply(_ event: LedgerEvent, toLeasesOf key: String) {
        // `append` gave the partition its view before calling. A refund that cancelled the live lease names the
        // gate: the latest unrefunded debit the partition can see takes over.
        guard let gateID = leaseViews[key]?.apply(event), let view = leaseViews[key] else { return }
        let lease = deriveLease(gateID: gateID, from: view, visibleTo: key)
        leaseViews[key]?.records[gateID] = lease
    }

    /// The lease for `gateID` as the `key` partition sees it through `view`: its latest unrefunded debit, with that
    /// debit's extensions. The rule `LeaseView` applies as events arrive, replayed over this gate's debits only.
    private func deriveLease(gateID: String, from view: LeaseView, visibleTo key: String) -> LeaseRecord? {
        var lease: LeaseRecord?
        // A gate with a live lease has a debit on record, so the lookup never misses: `if let` rather than a
        // default, which would be a path nothing can take.
        if let ids = debitsByGate[gateID] {
            for id in ids {
                // Every id listed under a gate was recorded in `debits` by the same append, or restored next to it.
                let debit = debits[id]!
                guard debit.accountKey == key || debit.accountKey == unboundAccountKey, !view.refunded.contains(id) else { continue }
                let record = LeaseRecord(
                    gateID: gateID, debitID: id, grantedAt: debit.at,
                    expiresAt: max(debit.leaseUntil, view.extensions[id] ?? debit.leaseUntil))
                if let existing = lease, existing.grantedAt > record.grantedAt { continue }
                lease = record
            }
        }
        return lease
    }

    /// The hash the next event written by `deviceID` must link to.
    public func head(for deviceID: String) -> String {
        lastEvents[deviceID]?.hash ?? checkpointHeads[deviceID] ?? paywallGenesisHash
    }

    /// The derived balance for one account. With a `baseline` (the Keychain snapshot) for that account whose last
    /// event this ledger has not seen, the baseline stands in for the history that has not synced back. A baseline
    /// that names no last event (written by an install with no events of its own) stands until the engine settles it.
    public func balance(for accountKey: String, baseline: WalletSnapshot? = nil) -> Int {
        let total = balances.total(for: accountKey)
        if let baseline, baseline.accountKey == accountKey, !(baseline.lastEventID.map(contains) ?? false) {
            return baseline.balance + total
        }
        return total
    }

    /// Leases by gate id, derived from debits, extensions and refunds. Nothing else stores a lease.
    public func leases(for accountKey: String) -> [String: LeaseRecord] {
        (leaseViews[accountKey] ?? leaseViews[unboundAccountKey])?.records ?? [:]
    }

    /// Credits recorded for a transaction id, for revocation bookkeeping.
    public func creditTokens(transactionID: UInt64) -> Int? {
        balances.credits[String(transactionID)]?.tokens
    }

    /// The first event whose `previousHash` links to nothing in its own device stream, or forks it.
    /// Order-independent, because a sync can deliver another device's events in any order. After a checkpoint the
    /// retained chain continues from what it recorded: an event whose predecessor was still missing stays broken
    /// until the predecessor arrives, and a fork stays broken for good, reported first.
    public func firstBrokenLink() -> LedgerEvent? {
        let chain = verifyChain()
        return fork ?? chain.firstBroken
    }

    /// One pass over `events`, hashing each: the chain as the ledger can see it, composed with what the checkpoint
    /// recorded. `firstBroken` is the first unlinked or forking event in order (the checkpoint's unlinked ones first).
    private func verifyChain() -> (tips: [String: Set<String>], rooted: Set<String>, unlinked: [LedgerEvent], fork: LedgerEvent?, firstBroken: LedgerEvent?) {
        var hashes = checkpointTips
        let eventHashes = events.map(\.hash)
        for (event, hash) in zip(events, eventHashes) { hashes[event.deviceID, default: []].insert(hash) }
        func knows(_ event: LedgerEvent) -> Bool {
            event.previousHash == paywallGenesisHash || hashes[event.deviceID]?.contains(event.previousHash) == true
        }
        var used: [String: Set<String>] = [:]
        for device in rooted { used[device] = [paywallGenesisHash] }
        for event in unlinked { used[event.deviceID, default: []].insert(event.previousHash) }
        var stillUnlinked: [LedgerEvent] = []
        var fork = fork
        var rooted = rooted
        var firstBroken: LedgerEvent?
        for event in unlinked where !knows(event) {
            stillUnlinked.append(event)
            if firstBroken == nil { firstBroken = event }
        }
        for event in events {
            if event.previousHash == paywallGenesisHash { rooted.insert(event.deviceID) }
            let known = knows(event)
            let fresh = used[event.deviceID, default: []].insert(event.previousHash).inserted
            if !known { stillUnlinked.append(event) }
            if !fresh, fork == nil { fork = event }
            if !known || !fresh, firstBroken == nil { firstBroken = event }
        }
        for (device, prevs) in used { hashes[device]?.subtract(prevs) }
        return (hashes, rooted, stillUnlinked, fork, firstBroken)
    }

    /// The derived state as a journal record. Costs one pass over `events`, hashing each for the chain.
    public func checkpoint() -> LedgerCheckpoint {
        var heads = checkpointHeads
        for (deviceID, event) in lastEvents { heads[deviceID] = event.hash }
        var ordered: [Debit] = []
        for (_, ids) in debitsByGate.sorted(by: { $0.key < $1.key }) { ordered += ids.map { debits[$0]! } }
        ordered += debits.values.filter { $0.gateID == nil }.sorted { $0.id < $1.id }
        let chain = verifyChain()
        return LedgerCheckpoint(
            eventCount: coveredEventCount + events.count, lastEventID: lastEventID, ids: ids, heads: heads,
            tips: chain.tips, rooted: chain.rooted, unlinked: chain.unlinked, fork: chain.fork, accountKeys: accountKeys,
            balances: balances, leaseViews: leaseViews, debits: ordered)
    }
}

extension LedgerCheckpoint: Codable {
    /// Bumped when a field changes meaning. A build older than the record it meets cannot decode it, and the journal
    /// treats the record as it treats any undecodable frame.
    static let version = 1

    private enum CodingKeys: String, CodingKey {
        case version, eventCount, lastEventID, ids, heads, tips, rooted, unlinked, fork, accounts, balances, leaseViews, debits
    }

    /// A debit as the record stores it, as the array `[id, tokens, account, at, leaseUntil, gate]`: debits are the
    /// bulk of a history, so the keys go, and the account becomes an index into the sorted account table, since a
    /// bound account key is 64 hex characters.
    private struct StoredDebit: Codable {
        var id: String
        var tokens: Int
        var account: Int
        var at: Date
        var leaseUntil: Date
        var gate: String?

        init(id: String, tokens: Int, account: Int, at: Date, leaseUntil: Date, gate: String?) {
            self.id = id
            self.tokens = tokens
            self.account = account
            self.at = at
            self.leaseUntil = leaseUntil
            self.gate = gate
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.unkeyedContainer()
            try container.encode(id)
            try container.encode(tokens)
            try container.encode(account)
            try container.encode(at)
            try container.encode(leaseUntil)
            try container.encode(gate)
        }

        init(from decoder: any Decoder) throws {
            var container = try decoder.unkeyedContainer()
            id = try container.decode(String.self)
            tokens = try container.decode(Int.self)
            account = try container.decode(Int.self)
            at = try container.decode(Date.self)
            leaseUntil = try container.decode(Date.self)
            gate = try container.decode(String?.self)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let accounts = accountKeys.sorted()
        let index = Dictionary(uniqueKeysWithValues: accounts.enumerated().map { ($1, $0) })
        let debitIDs = Set(debits.map(\.id))
        try container.encode(Self.version, forKey: .version)
        try container.encode(eventCount, forKey: .eventCount)
        try container.encodeIfPresent(lastEventID, forKey: .lastEventID)
        // The debit ids are the `id` of each stored debit already.
        try container.encode(ids.filter { !debitIDs.contains($0) }.sorted(), forKey: .ids)
        try container.encode(heads, forKey: .heads)
        try container.encode(tips.mapValues { $0.sorted() }, forKey: .tips)
        try container.encode(rooted.sorted(), forKey: .rooted)
        try container.encode(unlinked, forKey: .unlinked)
        try container.encodeIfPresent(fork, forKey: .fork)
        try container.encode(accounts, forKey: .accounts)
        try container.encode(balances, forKey: .balances)
        try container.encode(leaseViews, forKey: .leaseViews)
        // Every event's account key is in `accountKeys`, so the table has every debit's.
        let stored = debits.map { debit in
            StoredDebit(
                id: debit.id, tokens: debit.tokens, account: index[debit.accountKey]!, at: debit.at,
                leaseUntil: debit.leaseUntil, gate: debit.gateID)
        }
        try container.encode(stored, forKey: .debits)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.version else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: container, debugDescription: "checkpoint version \(version)")
        }
        eventCount = try container.decode(Int.self, forKey: .eventCount)
        lastEventID = try container.decodeIfPresent(String.self, forKey: .lastEventID)
        heads = try container.decode([String: String].self, forKey: .heads)
        tips = try container.decode([String: [String]].self, forKey: .tips).mapValues(Set.init)
        rooted = Set(try container.decode([String].self, forKey: .rooted))
        unlinked = try container.decode([LedgerEvent].self, forKey: .unlinked)
        fork = try container.decodeIfPresent(LedgerEvent.self, forKey: .fork)
        let accounts = try container.decode([String].self, forKey: .accounts)
        accountKeys = Set(accounts)
        balances = try container.decode(Balances.self, forKey: .balances)
        leaseViews = try container.decode([String: LeaseView].self, forKey: .leaseViews)
        var debits: [Debit] = []
        for stored in try container.decode([StoredDebit].self, forKey: .debits) {
            guard accounts.indices.contains(stored.account) else {
                throw DecodingError.dataCorruptedError(forKey: .debits, in: container, debugDescription: "account index \(stored.account)")
            }
            debits.append(
                Debit(
                    id: stored.id, tokens: stored.tokens, accountKey: accounts[stored.account], at: stored.at,
                    leaseUntil: stored.leaseUntil, gateID: stored.gate))
        }
        self.debits = debits
        ids = Set(try container.decode([String].self, forKey: .ids)).union(debits.map(\.id))
    }
}

/// The balance arithmetic, kept per account partition as events arrive in any order. Credits, grants and debits
/// count where they were written; a revocation or a refund counts wherever both of its events are visible.
struct Balances: Codable, Hashable, Sendable {
    struct Counterpart: Codable, Hashable, Sendable {
        var tokens: Int
        var accountKey: String
    }

    /// Credits + grants − debits, by the exact account key of the event.
    var direct: [String: Int] = [:]
    /// Revocation and refund amounts whose two events share one bound account, by that account.
    var crossAccount: [String: Int] = [:]
    /// Revocation and refund amounts whose two events are both unbound: they count for every account.
    var crossUnbound = 0
    /// By transaction id, as a string so the checkpoint encodes a keyed object.
    var credits: [String: Counterpart] = [:]
    /// The account keys of the revocations seen per transaction, applied when the credit arrives after them.
    var revocations: [String: [String]] = [:]
    /// The account keys of the refunds seen per debit, applied when the debit arrives after them.
    var refunds: [String: [String]] = [:]

    /// `debits` already holds `event` when it is a debit; a refund reads its debit from there.
    mutating func apply(_ event: LedgerEvent, debits: [String: Debit]) {
        let account = event.accountKey
        switch event.kind {
        case .credit(let tokens, _, let transactionID):
            direct[account, default: 0] += tokens
            credits[String(transactionID)] = Counterpart(tokens: tokens, accountKey: account)
            for revoker in revocations[String(transactionID), default: []] { add(-tokens, revoker, account) }
        case .grant(let tokens, _):
            direct[account, default: 0] += tokens
        case .debit(let tokens, _):
            direct[account, default: 0] -= tokens
            for refunder in refunds[event.id, default: []] { add(tokens, refunder, account) }
        case .revocation(let transactionID):
            revocations[String(transactionID), default: []].append(account)
            if let credit = credits[String(transactionID)] { add(-credit.tokens, account, credit.accountKey) }
        case .refund(let debitID, _):
            refunds[debitID, default: []].append(account)
            if let debit = debits[debitID] { add(debit.tokens, account, debit.accountKey) }
        case .leaseExtended:
            break
        }
    }

    /// Where a pair of events counts: everywhere when both are unbound, in one account when the other event is
    /// unbound or in that same account, nowhere when they sit in two different accounts.
    private mutating func add(_ amount: Int, _ a: String, _ b: String) {
        switch (a == unboundAccountKey, b == unboundAccountKey) {
        case (true, true): crossUnbound += amount
        case (true, false): crossAccount[b, default: 0] += amount
        case (false, true): crossAccount[a, default: 0] += amount
        case (false, false): if a == b { crossAccount[a, default: 0] += amount }
        }
    }

    func total(for accountKey: String) -> Int {
        var total = direct[unboundAccountKey, default: 0] + crossUnbound
        if accountKey != unboundAccountKey { total += direct[accountKey, default: 0] + crossAccount[accountKey, default: 0] }
        return total
    }
}

/// The lease table one partition derives: the latest unrefunded debit per gate, extended by its extensions.
struct LeaseView: Hashable, Sendable {
    var records: [String: LeaseRecord] = [:]
    var refunded: Set<String> = []
    /// The latest `until` seen per debit, kept before its debit arrives too.
    var extensions: [String: Date] = [:]

    /// Applies `event`. Returns the gate whose lease must be re-derived: the one a refund just cancelled.
    mutating func apply(_ event: LedgerEvent) -> String? {
        switch event.kind {
        case .debit(_, let leaseUntil):
            guard let gateID = event.source?.id, !refunded.contains(event.id) else { return nil }
            let record = LeaseRecord(
                gateID: gateID, debitID: event.id, grantedAt: event.at,
                expiresAt: max(leaseUntil, extensions[event.id] ?? leaseUntil))
            if let existing = records[gateID], existing.grantedAt > record.grantedAt { return nil }
            records[gateID] = record
        case .leaseExtended(let debitID, let until):
            let latest = max(extensions[debitID] ?? until, until)
            extensions[debitID] = latest
            if let live = records.first(where: { $0.value.debitID == debitID }) {
                records[live.key] = LeaseRecord(
                    gateID: live.key, debitID: debitID, grantedAt: live.value.grantedAt,
                    expiresAt: max(live.value.expiresAt, latest))
            }
        case .refund(let debitID, _):
            refunded.insert(debitID)
            return records.first { $0.value.debitID == debitID }?.key
        case .credit, .revocation, .grant:
            break
        }
        return nil
    }
}

extension LeaseView: Codable {
    private enum CodingKeys: String, CodingKey { case records, refunded, extensions }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(records, forKey: .records)
        try container.encode(refunded.sorted(), forKey: .refunded)
        try container.encode(extensions, forKey: .extensions)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        records = try container.decode([String: LeaseRecord].self, forKey: .records)
        refunded = Set(try container.decode([String].self, forKey: .refunded))
        extensions = try container.decode([String: Date].self, forKey: .extensions)
    }
}
