import Foundation
import PaywallCore
import Testing

private let t0 = Date(timeIntervalSince1970: 1_000_000)

private struct Writer {
    var ledger = Ledger()
    var device = "A"
    var account = "acct"

    mutating func add(_ id: String, _ kind: LedgerEvent.Kind, at: Date = t0, gate: String? = nil) {
        let event = LedgerEvent(
            id: id, at: at, deviceID: device, accountKey: account,
            source: gate.map { PaywallSource(id: $0, fileID: "f", function: "g", line: 1) },
            previousHash: ledger.head(for: device), kind: kind)
        ledger.append(event)
    }
}

@Suite("Ledger")
struct LedgerTests {
    @Test func balance_is_derived_from_events() {
        var w = Writer()
        w.add("credit:1", .credit(tokens: 10, productID: "tokens.10", transactionID: 1))
        w.add("grant:1", .grant(tokens: 5, reason: "welcome"))
        w.add("debit:1", .debit(tokens: 3, leaseUntil: t0.addingTimeInterval(300)), gate: "g")
        w.add("debit:2", .debit(tokens: 2, leaseUntil: t0.addingTimeInterval(300)), gate: "h")
        w.add("refund:debit:2", .refund(debitID: "debit:2", reason: .bodyThrew("x")))
        #expect(w.ledger.balance(for: "acct") == 12)
    }

    @Test func revocation_can_drive_the_balance_negative() {
        var w = Writer()
        w.add("credit:1", .credit(tokens: 10, productID: "tokens.10", transactionID: 1))
        w.add("debit:1", .debit(tokens: 8, leaseUntil: t0), gate: "g")
        w.add("revocation:1", .revocation(transactionID: 1))
        #expect(w.ledger.balance(for: "acct") == -8)
        #expect(Wallet(balance: -8).available == 0)
        #expect(w.ledger.creditTokens(transactionID: 1) == 10)
        #expect(w.ledger.creditTokens(transactionID: 2) == nil)
    }

    @Test func revocation_without_its_credit_counts_nothing() {
        var w = Writer()
        w.add("revocation:9", .revocation(transactionID: 9))
        #expect(w.ledger.balance(for: "acct") == 0)
    }

    @Test func duplicate_ids_are_no_ops() {
        var w = Writer()
        w.add("credit:1", .credit(tokens: 10, productID: "tokens.10", transactionID: 1))
        w.add("credit:1", .credit(tokens: 10, productID: "tokens.10", transactionID: 1))
        #expect(w.ledger.events.count == 1)
        #expect(w.ledger.balance(for: "acct") == 10)
    }

    @Test func accounts_are_partitioned_and_unbound_events_count_everywhere() {
        var w = Writer()
        w.add("grant:a", .grant(tokens: 5, reason: "a"))
        w.account = "other"
        w.add("grant:b", .grant(tokens: 7, reason: "b"))
        w.account = unboundAccountKey
        w.add("grant:c", .grant(tokens: 1, reason: "c"))
        #expect(w.ledger.balance(for: "acct") == 6)
        #expect(w.ledger.balance(for: "other") == 8)
    }

    @Test func leases_come_from_the_latest_unrefunded_debit_plus_extensions() {
        var w = Writer()
        w.add("debit:1", .debit(tokens: 1, leaseUntil: t0.addingTimeInterval(300)), at: t0, gate: "g")
        w.add("debit:2", .debit(tokens: 1, leaseUntil: t0.addingTimeInterval(900)), at: t0.addingTimeInterval(600), gate: "g")
        w.add("ext", .leaseExtended(debitID: "debit:2", until: t0.addingTimeInterval(1_200)))
        w.add("ext2", .leaseExtended(debitID: "debit:2", until: t0.addingTimeInterval(1_000)))
        w.add("debit:3", .debit(tokens: 1, leaseUntil: t0.addingTimeInterval(300)), gate: "h")
        w.add("refund:debit:3", .refund(debitID: "debit:3", reason: .bodyThrew("x")))
        let leases = w.ledger.leases(for: "acct")
        #expect(leases["g"]?.debitID == "debit:2")
        #expect(leases["g"]?.expiresAt == t0.addingTimeInterval(1_200))
        #expect(leases["h"] == nil)
    }

    @Test func an_older_debit_never_replaces_a_newer_lease() {
        var w = Writer()
        w.add("debit:new", .debit(tokens: 1, leaseUntil: t0.addingTimeInterval(900)), at: t0.addingTimeInterval(600), gate: "g")
        w.add("debit:old", .debit(tokens: 1, leaseUntil: t0.addingTimeInterval(300)), at: t0, gate: "g")
        #expect(w.ledger.leases(for: "acct")["g"]?.debitID == "debit:new")
    }

    @Test func hash_chain_detects_tampering_per_device_stream() {
        var w = Writer()
        w.add("a1", .grant(tokens: 1, reason: "x"))
        w.device = "B"
        w.add("b1", .grant(tokens: 1, reason: "x"))
        w.device = "A"
        w.add("a2", .grant(tokens: 1, reason: "x"))
        #expect(w.ledger.firstBrokenLink() == nil)
        // The other device's events may arrive in any order.
        #expect(Ledger(events: w.ledger.events.reversed()).firstBrokenLink() == nil)

        var tampered = w.ledger.events
        let forged = LedgerEvent(
            id: "a1", at: t0, deviceID: "A", accountKey: "acct", source: nil, previousHash: paywallGenesisHash,
            kind: .grant(tokens: 1_000, reason: "x"))
        tampered[0] = forged
        #expect(Ledger(events: tampered).firstBrokenLink()?.id == "a2")

        let fork = LedgerEvent(
            id: "a3", at: t0, deviceID: "A", accountKey: "acct", source: nil, previousHash: w.ledger.events[0].hash,
            kind: .grant(tokens: 1, reason: "fork"))
        #expect(Ledger(events: w.ledger.events + [fork]).firstBrokenLink()?.id == "a3")
    }

    @Test func baseline_stands_in_until_its_last_event_arrives() {
        var w = Writer()
        w.add("debit:new", .debit(tokens: 2, leaseUntil: t0), gate: "g")
        let baseline = WalletSnapshot(accountKey: "acct", balance: 20, lastEventID: "old", headHash: "h")
        #expect(w.ledger.balance(for: "acct", baseline: baseline) == 18)
        w.add("old", .grant(tokens: 20, reason: "synced back"))
        #expect(w.ledger.balance(for: "acct", baseline: baseline) == 18)
        let otherAccount = WalletSnapshot(accountKey: "else", balance: 99, lastEventID: "zzz", headHash: "h")
        #expect(w.ledger.balance(for: "acct", baseline: otherAccount) == 18)
    }

    @Test func gate_levels_and_policies() {
        #expect(GateLevel.tokens(3).tokenCost == 3)
        #expect(GateLevel.paid.tokenCost == 0)
        #expect(!GateLevel.tokens(0).isValid)
        #expect(GateLevel.free.isValid)
        #expect(Entitlement.subscription(.weekly).isPaying)
        #expect(!Entitlement.unknown.isPaying)
        #expect(SubscriptionTier.allCases.allSatisfy { $0.periodInDays >= 7 })
    }

    @Test func outcome_get_and_value() throws {
        let failure = PaywallFailure(reason: .requiresPaid, level: .paid, source: PaywallSource(fileID: "f", function: "g", line: 9), at: t0)
        #expect(failure.source.id == "f:9")
        let blocked = PaywallOutcome<Int>.blocked(failure)
        #expect(blocked.value == nil)
        #expect(blocked.failure == failure)
        #expect(throws: PaywallFailure.self) { try blocked.get() }
        #expect(try PaywallOutcome<Int>.executed(4).get() == 4)
        #expect(PaywallOutcome<Int>.executed(4).failure == nil)
    }

    @Test func catalog_validation() {
        #expect(catalog.validate().isEmpty)
        #expect(catalog.kind(of: "pro.lifetime") == .lifetime)
        #expect(catalog.kind(of: "pro.yearly") == .subscription(.yearly))
        #expect(catalog.kind(of: "tokens.50") == .tokens(50))
        #expect(catalog.kind(of: "nope") == nil)
        #expect(catalog.allProductIDs.count == 6)
        let bad = ProductCatalog(subscriptionGroupID: "g", weekly: "x", lifetime: "x", tokenPacks: [TokenPack(productID: "t", tokens: 0)])
        #expect(Set(bad.validate()) == [.duplicateProductID("x"), .emptyTokenPack("t")])
        #expect(ProductCatalog(subscriptionGroupID: "g").validate() == [.noProducts])
    }
}
