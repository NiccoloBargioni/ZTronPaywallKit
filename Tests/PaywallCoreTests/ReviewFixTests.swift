import Foundation
import PaywallTesting
import Testing

@testable import PaywallCore

/// Regression tests for the defects the code review found; each is named after the rule it restores.
@Suite("Review fixes", .serialized)
@MainActor
struct ReviewFixTests {
    // MARK: Sessions

    /// A `.deductNow` appearance is one decision: `drawn(n)`. The re-evaluation `complete` triggers must not log a
    /// second, spurious `leased` open for the same view.
    @Test func deductNow_appearance_logs_one_open_and_stays_drawn() async throws {
        let h = try await Harness.free(tokens: 5)
        let holder = UUID()
        var changes: [GateSessionState] = []
        let state = h.engine.openSession(holder: holder, level: .tokens(2), policy: .deductNow, source: source("chart")) { changes.append($0) }
        #expect(state.decision == .open(.drawn(2)))
        let opens = h.events.compactMap { event -> GateOpenMode? in
            if case .gateOpened(_, _, let mode) = event { return mode }
            return nil
        }
        #expect(opens == [.drawn(2)])
        let evaluated = h.events.filter { if case .gateEvaluated = $0 { true } else { false } }
        #expect(evaluated.count == 1)
        // A later wallet change re-evaluates the view; its own lease keeps it open and the state stays `drawn`.
        h.engine.grant(tokens: 1, reason: "later")
        #expect(h.engine.sessionState(holder)?.decision == .open(.drawn(2)))
        #expect(changes.isEmpty)
        // The audit order holds: the debit's consumed record follows the open it paid for.
        let records = await h.records().map(\.event)
        let openIndex = try #require(records.firstIndex { if case .gateOpened = $0 { true } else { false } })
        let consumedIndex = try #require(records.firstIndex { if case .tokensConsumed = $0 { true } else { false } })
        #expect(openIndex < consumedIndex)
    }

    /// The denied view, the preference key and the published event all carry one failure, so `claim()` from the
    /// denied view claims what the sheet would present.
    @Test func a_closed_session_keeps_one_failure_until_its_reason_changes() async throws {
        let h = try await Harness.free(tokens: 1)
        let holder = UUID()
        let first = h.engine.openSession(holder: holder, level: .tokens(3), policy: .reserve, source: source("tool"))
        let published = try #require(h.events.compactMap(\.failure).last)
        #expect(first.failure == published)
        #expect(first.failure?.id == published.id)
        // Unrelated re-evaluations keep the same failure value.
        h.engine.openSession(holder: UUID(), level: .free, policy: .reserve, source: source("other"))
        #expect(h.engine.sessionState(holder)?.failure == published)
        // The reason changes: a new failure, published once.
        h.engine.grant(tokens: 1, reason: "t")
        let second = try #require(h.engine.sessionState(holder)?.failure)
        #expect(second.reason == .insufficientTokens(needed: 3, available: 2))
        #expect(second.id != published.id)
        #expect(h.events.compactMap(\.failure).filter { $0.source.id == "tool" }.count == 2)
    }

    @Test func a_denied_commit_does_not_count_as_committed() async throws {
        let h = try await Harness.free(tokens: 3)
        let holder = UUID()
        h.engine.openSession(holder: holder, level: .tokens(3), policy: .reserve, source: source("tool"))
        await h.store.setReachable(false)
        h.engine.setEntitlement(.unknown, cause: .simulation)  // the gate now fails closed
        #expect(h.engine.run(.tokens(3), source: source("tool"), holder: holder) { 1 }.failure?.reason == .entitlementUnavailable)
        h.engine.closeSession(holder: holder)
        #expect(!h.events.contains(.reservedWithoutCommit(source: source("tool"), holder: holder)))  // the hold was released by the denial
        h.engine.setEntitlement(.free, cause: .simulation)
        let again = UUID()
        h.engine.openSession(holder: again, level: .tokens(3), policy: .reserve, source: source("tool"))
        h.engine.closeSession(holder: again)
        #expect(h.events.contains(.reservedWithoutCommit(source: source("tool"), holder: again)))
    }

    // MARK: Snapshot baseline

    /// Device bought 10 (uploaded), drew 2 offline (never uploaded), was deleted. The Keychain snapshot says 8 with
    /// the debit as its last event. After the reinstall the carrier answers with the credit only: the snapshot must
    /// step aside instead of adding its 8 to the remote 10.
    @Test func reinstall_after_an_unuploaded_draw_does_not_double_count_on_the_first_pull() async throws {
        let cloud = InMemoryCloud()
        let sync = InMemoryLedgerSync(cloud: cloud)
        let h = try await Harness.free(sync: sync)
        await h.engine.handle(.tokenPack(id: 1, productID: "tokens.10", purchased: h.clock.now))
        await h.engine.syncNow()
        await cloud.setReachable(false)
        _ = h.engine.run(.tokens(2), source: source("x")) {}
        #expect(await eventually { await sync.snapshot?.balance == 8 })
        let debitID = try #require(h.engine.ledger.events.last?.id)
        #expect(await sync.snapshot?.lastEventID == debitID)

        let reinstalled = try Harness(sync: sync)
        await reinstalled.start()
        #expect(reinstalled.engine.wallet.balance == 8)  // the snapshot stands in while the carrier is silent
        await cloud.setReachable(true)
        await reinstalled.engine.syncNow()
        #expect(reinstalled.engine.wallet.balance == 10)  // the carrier's truth: the un-uploaded draw is the known gap
        #expect(reinstalled.engine.baseline == nil)
        await reinstalled.engine.syncNow()
        #expect(reinstalled.engine.wallet.balance == 10)
    }

    @Test func snapshot_whose_last_event_the_carrier_holds_steps_aside_too() async throws {
        let cloud = InMemoryCloud()
        let sync = InMemoryLedgerSync(cloud: cloud)
        let h = try await Harness.free(tokens: 10, sync: sync)
        _ = h.engine.run(.tokens(4), source: source("x")) {}
        await h.engine.syncNow()
        #expect(await eventually { await sync.snapshot?.balance == 6 })
        let reinstalled = try Harness(sync: sync)
        await reinstalled.start()
        #expect(await eventually { reinstalled.engine.baseline == nil })
        #expect(reinstalled.engine.wallet.balance == 6)
        _ = reinstalled.engine.run(.tokens(1), source: source("y")) {}
        #expect(reinstalled.engine.wallet.balance == 5)
    }

    @Test func an_empty_carrier_leaves_the_snapshot_standing() async throws {
        let sync = InMemoryLedgerSync(snapshot: WalletSnapshot(accountKey: unboundAccountKey, balance: 7, lastEventID: "gone", headHash: "h"))
        let h = try await Harness.free(sync: sync)
        await h.engine.syncNow()
        #expect(h.engine.wallet.balance == 7)
        #expect(h.engine.baseline != nil)
        // Another account's events are not an answer for this one: merged, but the baseline stands.
        #expect(h.engine.merge([
            LedgerEvent(
                id: "grant:them", at: h.clock.now, deviceID: "B", accountKey: "someone-else", source: nil,
                previousHash: paywallGenesisHash, kind: .grant(tokens: 50, reason: "theirs"))
        ]))
        #expect(h.engine.baseline != nil)
        #expect(h.engine.wallet.balance == 7)
        // The journal holds the adopted baseline: a relaunch stands on it too, before any pull.
        let relaunched = try await h.relaunch(start: false)
        #expect(relaunched.baseline != nil && relaunched.wallet.balance == 7)
    }

    /// Two devices on one Apple Account. B spends one token, uploads the debit, and its Keychain snapshot (9, last
    /// event: B's debit) rides iCloud Keychain to A. A relaunches offline before it pulled the debit. A's ledger
    /// already holds the credit the snapshot counts, so the snapshot is not adopted: the balance is A's own 10, not
    /// 9 + 10, and the pull brings it to 9.
    @Test func another_devices_snapshot_is_not_adopted_over_a_ledger_with_history() async throws {
        let cloud = InMemoryCloud()
        let syncA = InMemoryLedgerSync(cloud: cloud)
        let syncB = InMemoryLedgerSync(cloud: cloud)
        let a = try await Harness.free(sync: syncA)
        let b = try await Harness.free(sync: syncB)
        await a.engine.handle(.tokenPack(id: 1, productID: "tokens.10", purchased: a.clock.now))
        await a.engine.syncNow()
        await b.engine.syncNow()
        #expect(b.engine.wallet.balance == 10)
        _ = b.engine.run(.tokens(1), source: source("y")) {}
        await b.engine.syncNow()
        #expect(await eventually { await syncB.snapshot?.balance == 9 })
        let fromB = try #require(await syncB.snapshot)
        #expect(!a.engine.ledger.contains(fromB.lastEventID ?? ""))

        a.engine.shutdown()
        await cloud.setReachable(false)
        let relaunched = try Harness(directory: a.directory, sync: InMemoryLedgerSync(cloud: cloud, snapshot: fromB))
        await relaunched.start()
        #expect(relaunched.engine.baseline == nil)
        #expect(relaunched.engine.wallet.balance == 10)
        #expect(relaunched.engine.run(.tokens(15), source: source("x")) { 1 }.failure?.reason == .insufficientTokens(needed: 15, available: 10))
        await cloud.setReachable(true)
        await relaunched.engine.syncNow()
        #expect(relaunched.engine.wallet.balance == 9)
    }

    /// The same rule covers this device's own snapshot when the journal lost its tail: the snapshot's last event is
    /// gone, the history it counts is not.
    @Test func a_snapshot_ahead_of_the_journal_is_not_adopted_either() async throws {
        let sync = InMemoryLedgerSync()
        let h = try await Harness.free(tokens: 10, sync: sync)
        #expect(await eventually { await sync.snapshot?.balance == 10 })
        await sync.saveSnapshot(WalletSnapshot(accountKey: h.engine.accountKey, balance: 9, lastEventID: "debit:lost", headHash: "h"))
        try await h.relaunch()
        #expect(h.engine.baseline == nil)
        #expect(h.engine.wallet.balance == 10)
    }

    // MARK: Sync scheduling

    /// Offline, the coalescing timer fires into a no-op; its handle must not block every later schedule.
    @Test func coalesced_sync_recovers_after_an_offline_timer() async throws {
        let connectivity = FakeConnectivity(hasPath: true)
        let sync = InMemoryLedgerSync()
        let h = try Harness(sync: sync, connectivity: connectivity, settings: GateEngine.Settings(syncCoalescing: 30))
        await h.start()
        await h.engine.syncNow()
        await connectivity.set(false)
        #expect(await eventually { !h.engine.hasNetworkPath })
        h.engine.grant(tokens: 1, reason: "a")  // schedules the coalescing timer
        #expect(h.engine.syncTask != nil)
        h.clock.advance(by: 31)  // the timer fires offline: nothing pushed
        #expect(await eventually { h.engine.syncTask == nil })
        #expect(await sync.cloud.events.isEmpty)
        // Still offline, a second event must be able to schedule again.
        h.engine.grant(tokens: 1, reason: "b")
        #expect(h.engine.syncTask != nil)
        await connectivity.set(true)
        #expect(await eventually { await sync.cloud.events.count == 2 })
    }

    /// A5: `shutdown()` is a hard stop. Nothing durable happens on the dead engine afterwards (no grant, no draw, no
    /// audit record, no sync, no `finish`), and its journal is closed so a successor owns the directory alone.
    @Test func a_shut_down_engine_starts_no_more_background_work() async throws {
        let sync = InMemoryLedgerSync()
        let h = try await Harness.free(tokens: 1, sync: sync)
        await h.engine.syncNow()
        let before = await sync.cloud.pushCount
        let old = h.engine
        old.shutdown()
        #expect(old.isShutDown && old.journal.isClosed)
        let events = h.events.count
        #expect(!old.grant(tokens: 1, reason: "late"))
        #expect(old.run(.tokens(1), source: source("late")) { 1 }.failure?.reason == .storageUnavailable)
        #expect(!old.canPass(.free))
        #expect(!old.merge([LedgerEvent(id: "grant:late", at: h.clock.now, deviceID: "B", accountKey: unboundAccountKey, source: nil, previousHash: paywallGenesisHash, kind: .grant(tokens: 1, reason: "r"))]))
        await old.handle(.tokenPack(id: 77, productID: "tokens.10", purchased: h.clock.now))
        await old.refresh(cause: .foreground)
        await old.syncNow()
        await old.start()  // a no-op
        #expect(await sync.cloud.pushCount == before)
        #expect(h.events.count == events, "a dead engine publishes nothing")
        #expect(await h.store.finished.isEmpty)
        #expect(old.wallet.balance == 1)
        // The next engine on the directory sees exactly what was there before the shutdown.
        let next = try await h.relaunch()
        #expect(next.wallet.balance == 1)
        #expect(!next.ledger.contains("credit:77") && !next.ledger.contains("grant:late"))
        await next.syncNow()
        #expect(next.journal.pendingUpload.isEmpty)
    }

    // MARK: Family Sharing

    @Test func family_sharing_policy_applies_on_the_next_resolution() async throws {
        let now = FakeClock().now
        let shared = StoreTransaction.subscription(id: 1, productID: "pro.monthly", purchased: now, expires: now.addingTimeInterval(86_400)).familyShared()
        let h = try Harness()
        await h.store.setEntitlements([shared])
        await h.start()
        #expect(h.engine.entitlement.isPaying && h.engine.entitlement.isFamilyShared)
        if case .subscribed(let subscription) = h.engine.entitlement { #expect(subscription.isFamilyShared) }

        // The same device on a build that refuses shared entitlements: the cached snapshot is downgraded before the
        // store answers, and the resolution agrees.
        h.settings.familySharing = .purchaserOnly
        let strict = try await h.relaunch(start: false)
        #expect(strict.entitlement == .free)
        await strict.start()
        #expect(strict.entitlement == .free)
        #expect(!strict.canPass(.paid))

        // Back to sharing: paying again at the first resolution.
        h.settings.familySharing = .sharedEntitlements
        let lenient = try await h.relaunch()
        #expect(lenient.entitlement.isPaying)

        // A shared lifetime purchase resolves to its own source and downgrades the same way.
        await h.store.setEntitlements([.lifetime(id: 2, productID: "pro.lifetime", purchased: now).familyShared()])
        await lenient.refresh(cause: .update)
        #expect(lenient.entitlement == .lifetime(.familyShared(transactionID: 2)))
        #expect(lenient.entitlement.isFamilyShared)
        h.settings.familySharing = .purchaserOnly
        let strictLifetime = try await h.relaunch(start: false)
        #expect(strictLifetime.entitlement == .free)
        #expect(PaywallFiles(directory: h.directory, keyStore: h.fileKeyStore).entitlementSnapshot(now: now, familySharing: .sharedEntitlements)?.isPaying == true)
    }

    @Test func purchased_entitlements_are_untouched_by_the_policy() {
        let now = FakeClock().now
        let own = StoreTransaction.lifetime(id: 3, productID: "pro.lifetime", purchased: now)
        let resolver = EntitlementResolver(catalog: catalog, grandfathering: nil, familySharing: .purchaserOnly)
        #expect(resolver.resolve(transactions: [own], appTransaction: nil, now: now).entitlement == .lifetime(.purchase(transactionID: 3)))
        #expect(resolver.resolve(transactions: [own.familyShared()], appTransaction: nil, now: now).entitlement == .free)
        #expect(!Entitlement.lifetime(.purchase(transactionID: 3)).isFamilyShared)
        #expect(!Entitlement.lifetime(.grandfathered(originalAppVersion: "1")).isFamilyShared)
        #expect(!Entitlement.unknown.isFamilyShared && !Entitlement.free.isFamilyShared)
        #expect(Entitlement.subscription(.weekly, isFamilyShared: true).isFamilyShared)
    }

    @Test func subscription_snapshots_written_before_family_sharing_still_decode() throws {
        let legacy = Data(#"{"expiresAt":1800086400,"isTrial":false,"phase":"active","productID":"pro.monthly","tier":"monthly","willAutoRenew":true}"#.utf8)
        let decoded = try CanonicalJSON.decoder().decode(Subscription.self, from: legacy)
        #expect(!decoded.isFamilyShared)
        #expect(decoded.tier == .monthly)
    }

    // MARK: Promoted in-app purchases

    /// 2.3.2: a promoted product tapped on the App Store reaches the host as an intent to open the paywall on it.
    @Test func promoted_purchase_intent_opens_paywall() async throws {
        let h = try await Harness.free()
        await h.store.deliverPurchaseIntent(productID: "pro.yearly")
        #expect(await eventually { h.events.contains(.purchaseIntent(productID: "pro.yearly")) })
        #expect(await h.store.purchaseCalls == 0)  // the engine never buys on its own
        let record = try #require(await h.records().first { if case .purchaseIntent = $0.event { true } else { false } })
        #expect(record.event == .purchaseIntent(productID: "pro.yearly"))
        h.engine.shutdown()
        #expect(await eventually { await h.store.intentListenerCount == 0 })
    }

    // MARK: Journal

    @Test func a_short_write_is_rewound_so_later_records_survive() throws {
        let directory = makeTemporaryPaywallDirectory()
        let journal = try Journal(directory: directory, fullSync: false)
        func grant(_ id: String) -> JournalEntry {
            .event(
                LedgerEvent(
                    id: id, at: Date(timeIntervalSince1970: 1_000), deviceID: "A", accountKey: unboundAccountKey, source: nil,
                    previousHash: paywallGenesisHash, kind: .grant(tokens: 1, reason: "r")), uploaded: false)
        }
        try journal.append(grant("grant:1"))
        journal.injectedFault = .shortWrite
        #expect(throws: JournalError.self) { try journal.append(grant("grant:2")) }
        journal.injectedFault = nil
        #expect(!journal.isPoisoned)
        try journal.append(grant("grant:3"))
        let reopened = try Journal(directory: directory)
        #expect(reopened.ledgerEvents.map(\.id) == ["grant:1", "grant:3"])
        #expect(reopened.droppedTailBytes == 0)

        // When even the rewind fails the journal stops writing; the relaunch truncates the torn frame.
        journal.injectedFault = .poison
        #expect(throws: JournalError.self) { try journal.append(grant("grant:4")) }
        journal.injectedFault = nil
        #expect(journal.isPoisoned)
        #expect(throws: JournalError.writeFailed(errno: EIO)) { try journal.append(grant("grant:5")) }
        let relaunched = try Journal(directory: directory)
        #expect(relaunched.ledgerEvents.map(\.id) == ["grant:1", "grant:3"])
        #expect(relaunched.droppedTailBytes > 0)
        try relaunched.append(grant("grant:6"))
        #expect(try Journal(directory: directory).ledgerEvents.map(\.id) == ["grant:1", "grant:3", "grant:6"])
    }

    @Test func the_engine_fails_closed_on_a_poisoned_journal_and_recovers_on_relaunch() async throws {
        let h = try await Harness.free(tokens: 5)
        h.engine.journal.injectedFault = .poison
        var ran = false
        #expect(h.engine.run(.tokens(1), source: source("g")) { ran = true }.failure?.reason == .storageUnavailable)
        h.engine.journal.injectedFault = nil
        #expect(!ran)
        #expect(h.engine.run(.tokens(1), source: source("g")) { ran = true }.failure?.reason == .storageUnavailable)
        #expect(h.engine.wallet.balance == 5)
        let engine = try await h.relaunch()
        #expect(engine.wallet.balance == 5)
        #expect(engine.run(.tokens(1), source: source("g")) { 1 }.value == 1)
    }
}
