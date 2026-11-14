import Foundation
@testable import PaywallCore
import Testing

private let t0 = Date(timeIntervalSince1970: 1_000_000)

private func belongs(_ event: LedgerEvent, _ accountKey: String) -> Bool {
    event.accountKey == accountKey || event.accountKey == unboundAccountKey
}

/// The derivations as a full replay over the events, the definition the incremental ledger must match.
private func referenceBalance(_ events: [LedgerEvent], for accountKey: String) -> Int {
    let mine = events.filter { belongs($0, accountKey) }
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
    return total
}

private func referenceLeases(_ events: [LedgerEvent], for accountKey: String) -> [String: LeaseRecord] {
    let mine = events.filter { belongs($0, accountKey) }
    let refunded = Set(
        mine.compactMap { event -> String? in
            if case .refund(let debitID, _) = event.kind { return debitID }
            return nil
        })
    var extensions: [String: Date] = [:]
    for event in mine {
        if case .leaseExtended(let debitID, let until) = event.kind { extensions[debitID] = max(extensions[debitID] ?? until, until) }
    }
    var leases: [String: LeaseRecord] = [:]
    for event in mine {
        guard case .debit(_, let leaseUntil) = event.kind, let gateID = event.source?.id, !refunded.contains(event.id) else { continue }
        let record = LeaseRecord(gateID: gateID, debitID: event.id, grantedAt: event.at, expiresAt: max(leaseUntil, extensions[event.id] ?? leaseUntil))
        if let existing = leases[gateID], existing.grantedAt > record.grantedAt { continue }
        leases[gateID] = record
    }
    return leases
}

private func referenceCreditTokens(_ events: [LedgerEvent], _ transactionID: UInt64) -> Int? {
    for event in events {
        if case .credit(let tokens, _, let id) = event.kind, id == transactionID { return tokens }
    }
    return nil
}

/// SplitMix64: the same history for the same seed on every platform.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Events across two accounts and the unbound partition, three gates and gateless debits, with refunds, extensions
/// and revocations that may precede what they refer to, and timestamps coarse enough to tie. Ids follow the
/// engine's conventions (one credit per transaction id, one debit per id), so repeats dedupe like replays do.
private func randomHistory(seed: UInt64, count: Int) -> [LedgerEvent] {
    var rng = SeededGenerator(state: seed)
    let accounts = ["acct", "other", unboundAccountKey]
    let gates: [String?] = ["g", "h", "i", nil]
    var events: [LedgerEvent] = []
    var credits = 0
    var debits = 0
    var extensions = 0
    var grants = 0
    for _ in 0..<count {
        let account = accounts.randomElement(using: &rng)!
        let at = t0.addingTimeInterval(Double(Int.random(in: 0..<6, using: &rng)) * 100)
        let id: String
        let kind: LedgerEvent.Kind
        var gate: String?
        switch Int.random(in: 0..<10, using: &rng) {
        case 0:
            credits += 1
            id = LedgerEvent.creditID(UInt64(credits))
            kind = .credit(tokens: Int.random(in: 1...50, using: &rng), productID: "tokens.10", transactionID: UInt64(credits))
        case 1:
            let transactionID = UInt64(Int.random(in: 1...(credits + 2), using: &rng))
            id = LedgerEvent.revocationID(transactionID)
            kind = .revocation(transactionID: transactionID)
        case 2, 3, 4:
            debits += 1
            id = "debit:\(debits)"
            gate = gates.randomElement(using: &rng)!
            kind = .debit(tokens: Int.random(in: 1...5, using: &rng), leaseUntil: at.addingTimeInterval(Double(Int.random(in: 1...600, using: &rng))))
        case 5:
            let debitID = "debit:\(Int.random(in: 1...(debits + 2), using: &rng))"
            id = LedgerEvent.refundID(debitID)
            kind = .refund(debitID: debitID, reason: .bodyThrew("x"))
        case 6, 7:
            extensions += 1
            id = "extend:\(extensions)"
            kind = .leaseExtended(
                debitID: "debit:\(Int.random(in: 1...(debits + 2), using: &rng))",
                until: at.addingTimeInterval(Double(Int.random(in: 1...900, using: &rng))))
        default:
            grants += 1
            id = "grant:\(grants)"
            kind = .grant(tokens: Int.random(in: 1...20, using: &rng), reason: "r")
        }
        events.append(
            LedgerEvent(
                id: id, at: at, deviceID: "A", accountKey: account,
                source: gate.map { PaywallSource(id: $0, fileID: "f", function: "g", line: 1) },
                previousHash: paywallGenesisHash, kind: kind))
    }
    return events
}

private struct Writer {
    var ledger = Ledger()
    var account = "acct"

    mutating func add(_ id: String, _ kind: LedgerEvent.Kind, at: Date = t0, gate: String? = nil) {
        ledger.append(
            LedgerEvent(
                id: id, at: at, deviceID: "A", accountKey: account,
                source: gate.map { PaywallSource(id: $0, fileID: "f", function: "g", line: 1) },
                previousHash: ledger.head(for: "A"), kind: kind))
    }
}

/// Like `randomHistory`, on two devices whose events link into proper per-device chains, delivered in a shuffled
/// order as a sync may: an event can arrive before the one it links to. Without the repeated ids: shuffled, a replay
/// could arrive before the event it repeats and take its place in the chain.
private func chainedHistory(seed: UInt64, count: Int) -> [LedgerEvent] {
    var rng = SeededGenerator(state: seed &+ 7)
    var heads: [String: String] = [:]
    var events: [LedgerEvent] = []
    for (index, template) in randomHistory(seed: seed, count: count).enumerated() where !events.contains(where: { $0.id == template.id }) {
        let device = index % 3 == 0 ? "B" : "A"
        let event = LedgerEvent(
            id: template.id, at: template.at, deviceID: device, accountKey: template.accountKey, source: template.source,
            previousHash: heads[device] ?? paywallGenesisHash, kind: template.kind)
        heads[device] = event.hash
        events.append(event)
    }
    return events.shuffled(using: &rng)
}

/// Every observation a ledger offers, for comparing a replay from a checkpoint with the full replay.
private struct Observation: Equatable {
    var balances: [String: Int]
    var leases: [String: [String: LeaseRecord]]
    var hasEvents: [String: Bool]
    var credits: [UInt64: Int?]
    var heads: [String: String]
    var contains: [String: Bool]
    var brokenLink: LedgerEvent?
    var lastEventID: String?

    init(_ ledger: Ledger, ids: [String]) {
        let keys = ["acct", "other", unboundAccountKey, "never"]
        balances = Dictionary(uniqueKeysWithValues: keys.map { ($0, ledger.balance(for: $0)) })
        leases = Dictionary(uniqueKeysWithValues: keys.map { ($0, ledger.leases(for: $0)) })
        hasEvents = Dictionary(uniqueKeysWithValues: keys.map { ($0, ledger.hasEvents(for: $0)) })
        credits = Dictionary(uniqueKeysWithValues: (1...6).map { (UInt64($0), ledger.creditTokens(transactionID: UInt64($0))) })
        heads = Dictionary(uniqueKeysWithValues: ["A", "B", "C"].map { ($0, ledger.head(for: $0)) })
        contains = Dictionary(uniqueKeysWithValues: (ids + ["nope"]).map { ($0, ledger.contains($0)) })
        brokenLink = ledger.firstBrokenLink()
        lastEventID = ledger.lastEventID
    }
}

/// The derivations are maintained as events arrive; these pin them to the replay they replace.
@Suite("Ledger derivations")
struct LedgerIncrementalTests {
    /// A checkpoint taken anywhere in a history, with the rest replayed on top, observes exactly what the full replay
    /// does, encodes and decodes unchanged, and checkpoints to the same record again.
    @Test(arguments: 1...40)
    func replay_from_a_checkpoint_matches_the_full_replay_at_every_split(seed: Int) throws {
        let history = chainedHistory(seed: UInt64(seed), count: 36)
        let ids = Array(Set(history.map(\.id))).sorted()
        let full = Ledger(events: history)
        let expected = Observation(full, ids: ids)
        #expect(expected.brokenLink == nil, "an honest history, however delivered, has no broken link")
        let decoder = CanonicalJSON.decoder()
        for split in 0...history.count {
            let checkpoint = Ledger(events: Array(history[..<split])).checkpoint()
            let decoded = try decoder.decode(LedgerCheckpoint.self, from: try CanonicalJSON.encoder().encode(checkpoint))
            #expect(decoded == checkpoint, "split \(split)")
            let restored = Ledger(checkpoint: decoded, events: Array(history[split...]))
            #expect(Observation(restored, ids: ids) == expected, "split \(split)")
            #expect(restored.events.count == Set(history[split...].map(\.id)).subtracting(history[..<split].map(\.id)).count)
            #expect(restored.checkpoint() == full.checkpoint(), "split \(split)")
            // The events before the split are replays to the restored ledger, as a kept outbox is.
            #expect(Observation(Ledger(checkpoint: decoded, events: history), ids: ids) == expected, "split \(split)")
        }
    }

    @Test func a_checkpoint_keeps_the_chain_verdicts() {
        var a = Writer()
        a.add("a1", .grant(tokens: 1, reason: "r"))
        a.add("a2", .grant(tokens: 1, reason: "r"))
        a.add("a3", .grant(tokens: 1, reason: "r"))
        let honest = a.ledger.events
        // A tampered event before the checkpoint: its successor's link is broken, and stays so after the checkpoint.
        var tampered = honest
        tampered[0] = LedgerEvent(
            id: "a1", at: t0, deviceID: "A", accountKey: "acct", source: nil, previousHash: paywallGenesisHash,
            kind: .grant(tokens: 1_000, reason: "r"))
        let full = Ledger(events: tampered)
        #expect(full.firstBrokenLink()?.id == "a2")
        let checkpoint = Ledger(events: Array(tampered[..<2])).checkpoint()
        #expect(checkpoint.unlinked.map(\.id) == ["a2"] && checkpoint.fork == nil)
        let restored = Ledger(checkpoint: checkpoint, events: Array(tampered[2...]))
        #expect(restored.firstBrokenLink()?.id == "a2")
        #expect(restored.checkpoint().unlinked.map(\.id) == ["a2"])

        // A gap the sync has not filled heals when the missing event arrives after the checkpoint.
        let gapped = Ledger(events: [honest[0], honest[2]]).checkpoint()
        #expect(gapped.unlinked.map(\.id) == ["a3"])
        #expect(gapped.tips["A"] == [honest[0].hash, honest[2].hash])
        #expect(Ledger(checkpoint: gapped).firstBrokenLink()?.id == "a3")
        let healed = Ledger(checkpoint: gapped, events: [honest[1]])
        #expect(healed.firstBrokenLink() == nil)
        #expect(healed.checkpoint().tips["A"] == [honest[2].hash])

        // A fork is reported first and for good: before the checkpoint, or after it against the recorded root.
        let fork = LedgerEvent(
            id: "a2bis", at: t0, deviceID: "A", accountKey: "acct", source: nil, previousHash: honest[0].hash,
            kind: .grant(tokens: 1, reason: "fork"))
        let forked = Ledger(events: honest + [fork]).checkpoint()
        #expect(forked.fork == fork)
        #expect(Ledger(checkpoint: forked, events: [honest[1]]).firstBrokenLink() == fork)
        let secondRoot = LedgerEvent(
            id: "a0", at: t0, deviceID: "A", accountKey: "acct", source: nil, previousHash: paywallGenesisHash,
            kind: .grant(tokens: 1, reason: "root"))
        let rooted = Ledger(events: honest).checkpoint()
        #expect(rooted.rooted == ["A"] && rooted.fork == nil && rooted.unlinked.isEmpty)
        #expect(Ledger(checkpoint: rooted, events: [secondRoot]).firstBrokenLink() == secondRoot)
        #expect(Ledger(events: honest + [secondRoot]).firstBrokenLink() == secondRoot)
        // A device the checkpoint never saw starts its own chain from genesis.
        let otherDevice = LedgerEvent(
            id: "b1", at: t0, deviceID: "B", accountKey: "acct", source: nil, previousHash: paywallGenesisHash,
            kind: .grant(tokens: 1, reason: "r"))
        #expect(Ledger(checkpoint: rooted, events: [otherDevice]).firstBrokenLink() == nil)
    }

    @Test func heads_the_last_event_and_equality_through_a_checkpoint() {
        var w = Writer()
        w.add("a1", .grant(tokens: 1, reason: "r"))
        w.add("a2", .grant(tokens: 2, reason: "r"))
        let checkpoint = w.ledger.checkpoint()
        #expect(checkpoint.heads == ["A": w.ledger.events[1].hash])
        #expect(checkpoint.lastEventID == "a2" && checkpoint.eventCount == 2)
        let restored = Ledger(checkpoint: checkpoint)
        #expect(restored.head(for: "A") == w.ledger.head(for: "A"))
        #expect(restored.head(for: "B") == paywallGenesisHash)
        #expect(restored.lastEventID == "a2")
        #expect(restored.events.isEmpty)
        #expect(restored.hasEvents(for: "acct") && !restored.hasEvents(for: "other"))
        var continued = restored
        continued.append(
            LedgerEvent(
                id: "b1", at: t0, deviceID: "B", accountKey: "acct", source: nil, previousHash: paywallGenesisHash,
                kind: .grant(tokens: 4, reason: "r")))
        #expect(continued.head(for: "A") == w.ledger.head(for: "A"))
        #expect(continued.head(for: "B") == continued.events[0].hash)
        #expect(continued.lastEventID == "b1")
        #expect(continued.balance(for: "acct") == 7)
        #expect(continued.checkpoint().eventCount == 3)
        // Equal when started from the same checkpoint with the same events; the full replay is another ledger.
        #expect(restored == Ledger(checkpoint: checkpoint) && restored != w.ledger && continued != restored)
        #expect(Set([restored, Ledger(checkpoint: checkpoint), w.ledger]).count == 2)
        #expect(Ledger(checkpoint: Ledger().checkpoint()) == Ledger())
    }

    @Test(arguments: 1...120)
    func derivations_match_a_full_replay_after_every_append(seed: Int) {
        let history = randomHistory(seed: UInt64(seed), count: 50)
        var ledger = Ledger()
        for event in history {
            ledger.append(event)
            for key in ["acct", "other", unboundAccountKey, "never"] {
                #expect(ledger.balance(for: key) == referenceBalance(ledger.events, for: key))
                #expect(ledger.leases(for: key) == referenceLeases(ledger.events, for: key))
                #expect(ledger.hasEvents(for: key) == ledger.events.contains { belongs($0, key) })
            }
        }
        for transactionID in 1...4 {
            #expect(ledger.creditTokens(transactionID: UInt64(transactionID)) == referenceCreditTokens(ledger.events, UInt64(transactionID)))
        }
        #expect(ledger.head(for: "A") == ledger.events.last?.hash)
        #expect(ledger.head(for: "B") == paywallGenesisHash)
        let rebuilt = Ledger(events: history)
        #expect(rebuilt == ledger)
        #expect(Set([rebuilt, ledger]).count == 1)
    }

    @Test func a_refund_or_extension_that_arrives_before_its_debit_applies_on_arrival() {
        var w = Writer()
        w.add("refund:debit:1", .refund(debitID: "debit:1", reason: .bodyThrew("x")))
        w.add("ext", .leaseExtended(debitID: "debit:2", until: t0.addingTimeInterval(900)))
        w.add("debit:1", .debit(tokens: 3, leaseUntil: t0.addingTimeInterval(300)), gate: "g")
        w.add("debit:2", .debit(tokens: 1, leaseUntil: t0.addingTimeInterval(300)), gate: "h")
        #expect(w.ledger.balance(for: "acct") == -1)
        #expect(w.ledger.leases(for: "acct")["g"] == nil)
        #expect(w.ledger.leases(for: "acct")["h"]?.expiresAt == t0.addingTimeInterval(900))
    }

    @Test func refunding_the_live_lease_falls_back_to_the_previous_debit_with_its_extensions() {
        var w = Writer()
        w.add("debit:old", .debit(tokens: 1, leaseUntil: t0.addingTimeInterval(300)), at: t0, gate: "g")
        w.add("ext:old", .leaseExtended(debitID: "debit:old", until: t0.addingTimeInterval(500)))
        w.add("debit:new", .debit(tokens: 1, leaseUntil: t0.addingTimeInterval(900)), at: t0.addingTimeInterval(600), gate: "g")
        #expect(w.ledger.leases(for: "acct")["g"]?.debitID == "debit:new")
        w.add("refund:debit:new", .refund(debitID: "debit:new", reason: .bodyThrew("x")))
        let lease = w.ledger.leases(for: "acct")["g"]
        #expect(lease?.debitID == "debit:old")
        #expect(lease?.expiresAt == t0.addingTimeInterval(500))
        w.add("refund:debit:old", .refund(debitID: "debit:old", reason: .bodyThrew("x")))
        #expect(w.ledger.leases(for: "acct")["g"] == nil)
        #expect(w.ledger.balance(for: "acct") == 0)
    }

    @Test func an_account_bound_later_sees_the_unbound_history_and_other_accounts_do_not_see_its_own() {
        var w = Writer()
        w.account = unboundAccountKey
        w.add("debit:u", .debit(tokens: 1, leaseUntil: t0.addingTimeInterval(300)), gate: "g")
        w.account = "acct"
        w.add("debit:a", .debit(tokens: 1, leaseUntil: t0.addingTimeInterval(300)), at: t0.addingTimeInterval(10), gate: "h")
        w.account = unboundAccountKey
        w.add("ext:a", .leaseExtended(debitID: "debit:a", until: t0.addingTimeInterval(800)))
        #expect(w.ledger.leases(for: "acct").keys.sorted() == ["g", "h"])
        #expect(w.ledger.leases(for: "acct")["h"]?.expiresAt == t0.addingTimeInterval(800))
        #expect(w.ledger.leases(for: "other").keys.sorted() == ["g"])
        #expect(w.ledger.leases(for: unboundAccountKey).keys.sorted() == ["g"])
        #expect(w.ledger.hasEvents(for: "other"))
        #expect(!Ledger().hasEvents(for: "other"))
    }

    @Test func a_bound_account_first_starts_from_nothing() {
        var w = Writer()
        w.add("debit:a", .debit(tokens: 1, leaseUntil: t0.addingTimeInterval(300)), gate: "g")
        #expect(w.ledger.leases(for: "acct")["g"]?.debitID == "debit:a")
        #expect(w.ledger.leases(for: unboundAccountKey).isEmpty)
        #expect(w.ledger.leases(for: "other").isEmpty)
        #expect(w.ledger.balance(for: "other") == 0)
    }

    @Test func a_revocation_in_another_account_than_its_credit_counts_nowhere() {
        var w = Writer()
        w.add("credit:1", .credit(tokens: 10, productID: "tokens.10", transactionID: 1))
        w.account = "other"
        w.add("revocation:1", .revocation(transactionID: 1))
        #expect(w.ledger.balance(for: "acct") == 10)
        #expect(w.ledger.balance(for: "other") == 0)
        #expect(w.ledger.balance(for: unboundAccountKey) == 0)
        // Unbound on either side counts in the bound account; unbound on both sides counts everywhere.
        w.account = unboundAccountKey
        w.add("credit:2", .credit(tokens: 4, productID: "tokens.10", transactionID: 2))
        w.account = "acct"
        w.add("revocation:2", .revocation(transactionID: 2))
        #expect(w.ledger.balance(for: "acct") == 10)
        #expect(w.ledger.balance(for: "other") == 4)
        w.account = unboundAccountKey
        w.add("credit:3", .credit(tokens: 6, productID: "tokens.10", transactionID: 3))
        w.add("revocation:3", .revocation(transactionID: 3))
        #expect(w.ledger.balance(for: "acct") == 10)
        #expect(w.ledger.balance(for: "other") == 4)
        // The unbound partition keeps credit 2: its revocation sits in an account it cannot see.
        #expect(w.ledger.balance(for: unboundAccountKey) == 4)
    }
}
