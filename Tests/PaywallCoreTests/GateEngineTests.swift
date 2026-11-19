import Foundation
import PaywallTesting
import Testing

@testable import PaywallCore

@Suite("Gate engine", .serialized)
@MainActor
struct GateEngineTests {
    // MARK: Levels

    @Test func free_gate_is_open_and_logged() async throws {
        let h = try await Harness.free()
        var ran = false
        let outcome = h.engine.run(.free, source: source("free")) { ran = true }
        #expect(ran)
        #expect(outcome.value != nil)
        #expect(h.events.contains(.gateOpened(source: source("free"), level: .free, mode: .free)))
    }

    @Test func paid_gate_denies_a_free_user_and_opens_for_a_subscriber() async throws {
        let h = try await Harness.free()
        let blocked = h.engine.run(.paid, source: source("pro")) { 1 }
        #expect(blocked.failure?.reason == .requiresPaid)
        #expect(h.events.contains { $0.failure?.source.id == "pro" })

        await h.store.setEntitlements([.subscription(id: 1, productID: "pro.monthly", purchased: h.clock.now, expires: h.clock.now.addingTimeInterval(86_400))])
        await h.engine.refresh(cause: .update)
        #expect(h.engine.run(.paid, source: source("pro")) { 1 }.value == 1)
    }

    /// StoreKit's passive reads never throw; the one failure they can show is never answering. While the launch
    /// resolution waits, a fresh install has no snapshot, so `.paid` and token gates fail closed and `.free` runs.
    @Test func gates_fail_closed_on_unknown_entitlement() async throws {
        let h = try Harness()
        await h.store.setReachable(false)
        let started = Task { await h.start() }
        #expect(await eventually { await h.store.pendingReads == 1 })
        #expect(h.engine.entitlement == .unknown)
        #expect(h.engine.run(.paid, source: source("p")) { 1 }.failure?.reason == .entitlementUnavailable)
        #expect(h.engine.run(.tokens(1), source: source("t")) { 1 }.failure?.reason == .entitlementUnavailable)
        #expect(h.engine.run(.free, source: source("f")) { 1 }.value == 1)
        #expect(!h.events.contains { if case .storeUnavailable = $0 { return true } else { return false } })

        // The answer lands: the resolution reopens everything.
        await h.store.setReachable(true)
        await started.value
        #expect(h.engine.entitlement == .free)
    }

    /// A host-written store client whose reads throw (StoreKit's never do): the engine publishes `.storeUnavailable`
    /// and keeps whatever snapshot it has, nothing on a fresh install.
    @Test func a_throwing_store_client_leaves_the_entitlement_unknown_and_is_reported() async throws {
        let h = try Harness()
        await h.store.setPassiveReadFailure(.unreachable)
        await h.start()
        #expect(h.engine.entitlement == .unknown)
        #expect(h.engine.run(.paid, source: source("p")) { 1 }.failure?.reason == .entitlementUnavailable)
        #expect(h.events.contains { if case .storeUnavailable(_, nil) = $0 { return true } else { return false } })
        await h.store.setPassiveReadFailure(nil)
        await h.engine.refresh(cause: .foreground)
        #expect(h.engine.entitlement == .free)
    }

    /// A relaunch whose store never answers: the snapshot on disk stands in, and `.paid` passes, until it does.
    @Test func offline_launch_keeps_the_last_snapshot() async throws {
        let h = try Harness()
        await h.store.setEntitlements([.lifetime(id: 7, productID: "pro.lifetime", purchased: h.clock.now)])
        await h.start()
        await h.store.setReachable(false)
        let engine = try await h.relaunch(start: false)
        #expect(engine.entitlement == .lifetime(.purchase(transactionID: 7)))
        let started = Task { await engine.start() }
        #expect(await eventually { await h.store.pendingReads == 1 })
        #expect(engine.entitlement == .lifetime(.purchase(transactionID: 7)))
        #expect(engine.canPass(.paid))
        await h.store.setReachable(true)
        await started.value
        #expect(engine.canPass(.paid))
    }

    @Test func zero_token_gate_fails_closed() async throws {
        let h = try await Harness.free(tokens: 10)
        #expect(h.engine.run(.tokens(0), source: source("z")) { 1 }.failure?.reason == .requiresPaid)
    }

    // MARK: Tokens and leases

    @Test func token_gate_draws_once_and_leases_for_S() async throws {
        let h = try await Harness.free(tokens: 10)
        #expect(h.engine.run(.tokens(3), source: source("export")) { "pdf" }.value == "pdf")
        #expect(h.engine.wallet.balance == 7)
        h.clock.advance(by: 299)
        #expect(h.engine.run(.tokens(3), source: source("export")) { "pdf" }.value == "pdf")
        #expect(h.engine.wallet.balance == 7)
        #expect(h.events.contains(.gateOpened(source: source("export"), level: .tokens(3), mode: .leased)))
        h.clock.advance(by: 1)
        _ = h.engine.run(.tokens(3), source: source("export")) { "pdf" }
        #expect(h.engine.wallet.balance == 4)
        #expect(h.events.contains { if case .leaseExpired(gateID: "export", _) = $0 { return true } else { return false } })
    }

    @Test func insufficient_tokens_reports_needed_and_available() async throws {
        let h = try await Harness.free(tokens: 1)
        let outcome = h.engine.run(.tokens(3), source: source("export")) { 0 }
        #expect(outcome.failure?.reason == .insufficientTokens(needed: 3, available: 1))
        #expect(h.engine.wallet.balance == 1)
    }

    @Test func paying_user_passes_token_gates_without_a_draw() async throws {
        let h = try await Harness.free(tokens: 5)
        await h.store.setEntitlements([.lifetime(id: 1, productID: "pro.lifetime", purchased: h.clock.now)])
        await h.engine.refresh(cause: .purchase)
        #expect(h.engine.run(.tokens(3), source: source("t")) { 1 }.value == 1)
        #expect(h.engine.wallet.balance == 5)
        #expect(h.events.contains(.gateOpened(source: source("t"), level: .tokens(3), mode: .paying)))
    }

    @Test func throwing_body_refunds_the_draw_and_grants_no_lease() async throws {
        let h = try await Harness.free(tokens: 10)
        #expect(throws: TestError.self) {
            try h.engine.run(.tokens(4), source: source("x")) { () throws -> Int in throw TestError() }
        }
        #expect(h.engine.wallet.balance == 10)
        #expect(h.engine.leases.records["x"] == nil)
        #expect(h.events.contains { if case .tokensRefunded = $0 { return true } else { return false } })
    }

    @Test func refresh_on_reentry_extends_the_window() async throws {
        var settings = GateEngine.Settings(tolerance: 100)
        settings.leasePolicy = .refreshOnReentry
        let h = try await Harness.free(tokens: 10, settings: settings)
        _ = h.engine.run(.tokens(1), source: source("g")) {}
        h.clock.advance(by: 90)
        _ = h.engine.run(.tokens(1), source: source("g")) {}
        h.clock.advance(by: 90)
        _ = h.engine.run(.tokens(1), source: source("g")) {}
        #expect(h.engine.wallet.balance == 9)
        #expect(h.events.contains { if case .leaseExtended(gateID: "g", _) = $0 { return true } else { return false } })
    }

    @Test func clock_moved_back_expires_the_lease() async throws {
        let h = try await Harness.free(tokens: 10)
        _ = h.engine.run(.tokens(1), source: source("g")) {}
        h.clock.setWallClock(h.clock.now.addingTimeInterval(-3_600))
        #expect(!h.engine.leases.isActive("g", now: h.clock.now))
        _ = h.engine.run(.tokens(1), source: source("g")) {}
        #expect(h.engine.wallet.balance == 8)
    }

    @Test func leases_survive_relaunch() async throws {
        let h = try await Harness.free(tokens: 10)
        _ = h.engine.run(.tokens(2), source: source("g")) {}
        let engine = try await h.relaunch()
        #expect(engine.canPass(.tokens(2), gateID: "g"))
        _ = engine.run(.tokens(2), source: source("g")) {}
        #expect(engine.wallet.balance == 8)
    }

    @Test func tokens_never_expire() async throws {
        let h = try await Harness.free(tokens: 10)
        _ = h.engine.run(.tokens(2), source: source("g")) {}
        h.clock.advance(by: 10 * 365 * 86_400)
        let engine = try await h.relaunch()
        #expect(engine.wallet.balance == 8)
        #expect(!engine.leases.isActive("g", now: h.clock.now))
    }

    @Test func evaluate_never_draws() async throws {
        let h = try await Harness.free(tokens: 5)
        #expect(h.engine.evaluate(.tokens(3), source: source("e")).value != nil)
        #expect(h.engine.evaluate(.tokens(9), source: source("e")).failure?.reason == .insufficientTokens(needed: 9, available: 5))
        #expect(h.engine.evaluate(.paid, source: source("e")).failure?.reason == .requiresPaid)
        #expect(h.engine.wallet.balance == 5)
        #expect(h.engine.canPass(.tokens(5)))
        #expect(!h.engine.canPass(.tokens(6)))
    }

    // MARK: Sessions

    @Test func reserve_holds_on_appear_and_releases_on_disappear() async throws {
        let h = try await Harness.free(tokens: 5)
        let view = UUID()
        let state = h.engine.openSession(holder: view, level: .tokens(3), policy: .reserve, source: source("tool"))
        #expect(state.decision == .open(.reserved(3)))
        #expect(h.engine.wallet == Wallet(balance: 5, reserved: 3))
        h.engine.closeSession(holder: view)
        #expect(h.engine.wallet == Wallet(balance: 5, reserved: 0))
        #expect(h.events.contains(.reservedWithoutCommit(source: source("tool"), holder: view)))
    }

    @Test func commit_turns_the_hold_into_a_debit_and_pins_the_lease() async throws {
        let h = try await Harness.free(tokens: 5)
        let view = UUID()
        h.engine.openSession(holder: view, level: .tokens(3), policy: .reserve, source: source("tool"))
        let outcome = h.engine.run(.tokens(3), source: source("tool"), holder: view) { "done" }
        #expect(outcome.value == "done")
        #expect(h.engine.wallet == Wallet(balance: 2, reserved: 0))
        #expect(h.engine.leases.holders(of: "tool") == [view])
        h.clock.advance(by: 10_000)
        // Pinned: still open, no second draw.
        #expect(h.engine.run(.tokens(3), source: source("tool"), holder: view) { 1 }.value == 1)
        #expect(h.engine.wallet.balance == 2)
        h.engine.closeSession(holder: view)
        #expect(!h.engine.leases.isActive("tool", now: h.clock.now))
        #expect(!h.events.contains(.reservedWithoutCommit(source: source("tool"), holder: view)))
    }

    @Test func plain_withPaywall_consumes_a_view_reservation_with_the_same_id() async throws {
        let h = try await Harness.free(tokens: 3)
        let view = UUID()
        h.engine.openSession(holder: view, level: .tokens(3), policy: .reserve, source: source("tool"))
        #expect(h.engine.run(.tokens(3), source: source("tool")) { 1 }.value == 1)
        #expect(h.engine.wallet == Wallet(balance: 0, reserved: 0))
        #expect(h.engine.leases.holders(of: "tool") == [view])
    }

    @Test func two_instances_hold_separately_and_the_first_commit_releases_the_other() async throws {
        let h = try await Harness.free(tokens: 6)
        let a = UUID(), b = UUID()
        var bStates: [GateSessionState] = []
        h.engine.openSession(holder: a, level: .tokens(3), policy: .reserve, source: source("tool"))
        h.engine.openSession(holder: b, level: .tokens(3), policy: .reserve, source: source("tool")) { bStates.append($0) }
        #expect(h.engine.wallet.reserved == 6)
        _ = h.engine.run(.tokens(3), source: source("tool"), holder: a) {}
        #expect(h.engine.wallet == Wallet(balance: 3, reserved: 0))
        #expect(h.engine.sessionState(b)?.decision == .open(.leased))
        #expect(bStates.last?.decision == .open(.leased))
    }

    @Test func deductNow_draws_on_appear_and_pins() async throws {
        let h = try await Harness.free(tokens: 5)
        let view = UUID()
        let state = h.engine.openSession(holder: view, level: .tokens(2), policy: .deductNow, source: source("chart"))
        #expect(state.decision == .open(.drawn(2)))
        #expect(h.engine.wallet.balance == 3)
        h.engine.closeSession(holder: view)
        h.clock.advance(by: 100)
        // Back within S: free.
        #expect(h.engine.openSession(holder: UUID(), level: .tokens(2), policy: .deductNow, source: source("chart")).decision == .open(.leased))
        #expect(h.engine.wallet.balance == 3)
    }

    @Test func reserve_denied_when_wallet_is_short() async throws {
        let h = try await Harness.free(tokens: 1)
        let state = h.engine.openSession(holder: UUID(), level: .tokens(3), policy: .reserve, source: source("tool"))
        #expect(state.failure?.reason == .insufficientTokens(needed: 3, available: 1))
        #expect(!state.isOpen)
    }

    @Test func refund_while_on_screen_flips_the_view_to_denied() async throws {
        let h = try Harness()
        await h.store.setEntitlements([.subscription(id: 9, productID: "pro.weekly", purchased: h.clock.now, expires: h.clock.now.addingTimeInterval(7 * 86_400))])
        await h.start()
        var states: [GateSessionState] = []
        let view = UUID()
        let first = h.engine.openSession(holder: view, level: .paid, policy: .reserve, source: source("heatmap")) { states.append($0) }
        #expect(first.decision == .open(.paying))
        await h.store.refund(9, at: h.clock.now)
        #expect(await eventually { h.engine.entitlement == .free && states.last?.isOpen == false })
        #expect(h.events.contains { if case .entitlementChanged(_, .free, .revoked) = $0 { return true } else { return false } })
        #expect(await eventually { await h.store.finished.contains(9) })
    }

    @Test func subscription_expiring_on_screen_flips_the_view() async throws {
        let h = try Harness()
        let expiry = h.clock.now.addingTimeInterval(60)
        await h.store.setEntitlements([.subscription(id: 1, productID: "pro.weekly", purchased: h.clock.now, expires: expiry)])
        await h.start()
        var states: [GateSessionState] = []
        h.engine.openSession(holder: UUID(), level: .paid, policy: .reserve, source: source("p")) { states.append($0) }
        #expect(await eventually { h.clock.pendingSleepers > 0 })
        h.clock.advance(by: 61)
        #expect(await eventually { states.last?.failure?.reason == .requiresPaid })
        #expect(h.events.contains { if case .entitlementChanged(_, .free, .expiryTimer) = $0 { return true } else { return false } })
    }

    @Test func refund_during_a_token_lease_keeps_the_lease() async throws {
        let h = try await Harness.free(tokens: 0)
        await h.store.addToHistory(.tokenPack(id: 50, productID: "tokens.10", purchased: h.clock.now))
        await h.engine.handle(.tokenPack(id: 50, productID: "tokens.10", purchased: h.clock.now))
        _ = h.engine.run(.tokens(8), source: source("g")) {}
        await h.store.refund(50, at: h.clock.now)
        #expect(await eventually { h.engine.wallet.balance == -8 })
        #expect(h.engine.leases.isActive("g", now: h.clock.now))
        #expect(h.engine.wallet.available == 0)
        #expect(h.engine.run(.tokens(1), source: source("other")) { 1 }.failure?.reason == .insufficientTokens(needed: 1, available: 0))
    }

    // MARK: Store

    @Test func credit_is_idempotent_across_relaunch_before_finish() async throws {
        let h = try await Harness.free()
        let tx = StoreTransaction.tokenPack(id: 77, productID: "tokens.50", purchased: h.clock.now)
        await h.engine.handle(tx)
        let engine = try await h.relaunch()
        // StoreKit re-delivers the unfinished transaction at launch.
        await engine.handle(tx)
        #expect(engine.wallet.balance == 50)
        #expect(engine.ledger.events.filter { $0.id == "credit:77" }.count == 1)
    }

    @Test func purchase_of_a_pack_credits_before_finish() async throws {
        let h = try await Harness.free()
        await h.store.setProducts(products)
        let outcome = try await h.engine.purchase(productID: "tokens.10", source: source("paywall"))
        guard case .purchased(let id) = outcome else {
            Issue.record("expected purchase")
            return
        }
        #expect(h.engine.wallet.balance == 10)
        #expect(await h.store.finished == [id])
        #expect(h.events.contains(.purchase(stage: .completed, productID: "tokens.10", source: source("paywall"), transactionID: id)))
    }

    @Test func purchase_of_lifetime_unlocks() async throws {
        let h = try await Harness.free()
        _ = try await h.engine.purchase(productID: "pro.lifetime", source: nil)
        #expect(h.engine.entitlement.isPaying)
    }

    @Test func pending_purchase_credits_on_arrival() async throws {
        let h = try await Harness.free()
        await h.store.setNextPurchase(.pending)
        #expect(try await h.engine.purchase(productID: "tokens.10", source: nil) == .pending)
        #expect(h.engine.wallet.balance == 0)
        await h.store.deliver(.tokenPack(id: 5, productID: "tokens.10", purchased: h.clock.now))
        #expect(await eventually { h.engine.wallet.balance == 10 })
    }

    @Test func cancelled_and_failed_purchases_change_nothing() async throws {
        let h = try await Harness.free()
        await h.store.setNextPurchase(.cancel)
        #expect(try await h.engine.purchase(productID: "tokens.10", source: nil) == .cancelled)
        await h.store.setNextPurchase(.fail)
        await #expect(throws: FakeStore.Failure.self) { _ = try await h.engine.purchase(productID: "tokens.10", source: nil) }
        #expect(h.engine.wallet.balance == 0)
        #expect(h.events.contains { if case .purchase(.failed, _, _, _) = $0 { return true } else { return false } })
    }

    @Test func revoked_packs_found_by_launch_reconciliation() async throws {
        let h = try await Harness.free()
        await h.store.addToHistory(.tokenPack(id: 3, productID: "tokens.10", purchased: h.clock.now))
        await h.engine.handle(.tokenPack(id: 3, productID: "tokens.10", purchased: h.clock.now))
        // Refunded while the app was closed: not re-emitted, only visible in Transaction.all.
        await h.store.refund(3, at: h.clock.now, deliver: false)
        let engine = try await h.relaunch()
        #expect(engine.wallet.balance == 0)
        #expect(engine.ledger.contains("revocation:3"))
    }

    @Test func refund_while_closed_is_found_at_launch() async throws {
        let h = try Harness()
        await h.store.setEntitlements([.lifetime(id: 4, productID: "pro.lifetime", purchased: h.clock.now)])
        await h.start()
        #expect(h.engine.entitlement.isPaying)
        await h.store.refund(4, at: h.clock.now, deliver: false)
        let engine = try await h.relaunch()
        #expect(engine.entitlement == .free)
    }

    @Test func restore_recovers_lifetime_and_subscription() async throws {
        let h = try await Harness.free()
        await h.store.setEntitlements([.lifetime(id: 1, productID: "pro.lifetime", purchased: h.clock.now)])
        try await h.engine.restore()
        #expect(h.engine.entitlement == .lifetime(.purchase(transactionID: 1)))
        #expect(await h.store.syncCalls == 1)
        await h.store.setNetwork(false)
        await #expect(throws: FakeStore.Failure.self) { try await h.engine.restore() }
    }

    @Test func launch_and_foreground_make_no_store_prompts() async throws {
        let h = try await Harness.free()
        await h.engine.didBecomeActive()
        _ = try await h.relaunch()
        #expect(await h.store.syncCalls == 0)
        #expect(await h.store.purchaseCalls == 0)
    }

    @Test func cached_prices_carry_as_of_label() async throws {
        let h = try await Harness.free()
        let online = try await h.engine.products()
        #expect(online.count == 6)
        #expect(online.allSatisfy { $0.isPurchasable && $0.priceAsOf == nil })
        await h.store.setNetwork(false)
        let offline = try await h.engine.products()
        #expect(offline.map(\.displayPrice) == online.map(\.displayPrice))
        #expect(offline.allSatisfy { !$0.isPurchasable && $0.priceAsOf != nil })

        // Nothing was ever fetched, the launch fetch included: no cache to fall back on.
        let fresh = try Harness()
        await fresh.store.setNetwork(false)
        await fresh.start()
        #expect(fresh.engine.storefront == nil)
        await #expect(throws: FakeStore.Failure.self) { _ = try await fresh.engine.products() }
    }

    @Test func grandfather_survives_offline_launch() async throws {
        let now = FakeClock().now
        let policy = GrandfatheringPolicy(lastPaidBuild: "116", paidWindow: DateInterval(start: now.addingTimeInterval(-1e7), end: now))
        let h = try Harness(grandfathering: policy)
        await h.store.setApp(AppTransactionSnapshot(
            bundleID: "b", originalAppVersion: "90", originalPurchaseDate: now.addingTimeInterval(-1e6), environment: .production,
            origin: .appTransaction))
        await h.start()
        #expect(h.engine.entitlement == .lifetime(.grandfathered(originalAppVersion: "90")))
        #expect(h.events.contains { if case .grandfathered(originalAppVersion: "90", _, .production) = $0 { return true } else { return false } })
        // Offline: no AppTransaction, the cached snapshot answers.
        await h.store.setApp(nil)
        let engine = try await h.relaunch()
        #expect(engine.entitlement == .lifetime(.grandfathered(originalAppVersion: "90")))
        #expect(!h.events.contains { if case .grandfathered = $0 { return true } else { return false } })
        #expect(engine.canPass(.paid) && engine.canPass(.tokens(99)))
    }

    /// B1: the caches next to the journal are authenticated. A planted `app-transaction.json`, plain or enveloped
    /// with another key's tag, grants nothing offline, as a lifetime or as tokens.
    @Test func forged_app_transaction_cache_grants_nothing_offline() async throws {
        let now = FakeClock().now
        let policy = GrandfatheringPolicy(lastPaidBuild: "116", paidWindow: DateInterval(start: now.addingTimeInterval(-1e7), end: now))
        let forged = AppTransactionSnapshot(
            bundleID: "b", originalAppVersion: "90", originalPurchaseDate: now.addingTimeInterval(-1e6), environment: .production,
            origin: .appTransaction)
        let payload = try CanonicalJSON.encoder().encode(forged)
        for grant in [GrandfatheringPolicy.Grant.lifetime, .tokens(20)] {
            var granting = policy
            granting.grant = grant
            // Plain JSON, as an attacker (or an older build) writes it.
            let plain = try Harness(grandfathering: granting)
            try payload.write(to: plain.directory.appendingPathComponent("app-transaction.json"))
            await plain.start()
            #expect(plain.engine.entitlement == .free && plain.engine.wallet.balance == 0, "\(grant)")
            #expect(plain.engine.appTransaction == nil && plain.engine.accountKey == unboundAccountKey)
            #expect(!plain.events.contains { if case .grandfathered = $0 { true } else { false } })
            // The right shape, tagged with another key.
            let enveloped = try Harness(grandfathering: granting)
            let tagged = PaywallFiles.Envelope(mac: PaywallFiles.tag(payload, key: InMemoryFileKeyStore.randomKey()), payload: payload)
            try CanonicalJSON.encoder().encode(tagged).write(to: enveloped.directory.appendingPathComponent("app-transaction.json"))
            await enveloped.start()
            #expect(enveloped.engine.entitlement == .free && enveloped.engine.wallet.balance == 0, "\(grant)")
            #expect(enveloped.engine.appTransaction == nil)
        }
    }

    /// B1: a planted `entitlement.json` is no snapshot: before the store answers the launch fails closed (`.unknown`),
    /// where a trusted lifetime snapshot would have opened every gate. The engine's own file reads back.
    @Test func forged_entitlement_snapshot_is_unknown_not_lifetime() async throws {
        let h = try Harness()
        let snapshot = PaywallFiles.EntitlementSnapshot(entitlement: .lifetime(.purchase(transactionID: 1)), resolvedAt: h.clock.now)
        try CanonicalJSON.encoder().encode(snapshot).write(to: h.directory.appendingPathComponent("entitlement.json"))
        let forged = try await h.relaunch(start: false)
        #expect(forged.entitlement == .unknown)
        #expect(!forged.canPass(.paid))
        await h.store.setEntitlements([.lifetime(id: 1, productID: "pro.lifetime", purchased: h.clock.now)])
        await forged.start()
        #expect(forged.entitlement.isPaying)
        let genuine = try await h.relaunch(start: false)
        #expect(genuine.entitlement == .lifetime(.purchase(transactionID: 1)))
    }

    /// B1: a launch with no key at hand (the Keychain before first unlock) writes and trusts nothing, and leaves the
    /// authenticated cache as it was, so the next launch with the key reads it again.
    @Test func a_launch_without_the_file_key_keeps_the_cached_grandfather_for_the_next_one() async throws {
        let now = FakeClock().now
        let policy = GrandfatheringPolicy(lastPaidBuild: "116", paidWindow: DateInterval(start: now.addingTimeInterval(-1e7), end: now))
        let h = try Harness(grandfathering: policy)
        let app = AppTransactionSnapshot(
            bundleID: "b", originalAppVersion: "90", originalPurchaseDate: now.addingTimeInterval(-1e6), environment: .production,
            origin: .appTransaction)
        await h.store.setApp(app)
        await h.start()
        #expect(h.engine.entitlement == .lifetime(.grandfathered(originalAppVersion: "90")))
        let cache = h.directory.appendingPathComponent("app-transaction.json")
        let written = try Data(contentsOf: cache)
        // No key, the store still answering: the resolution comes from the store and the file is left alone.
        let withKey = h.fileKeyStore
        h.fileKeyStore = InMemoryFileKeyStore(key: nil)
        let keyless = try await h.relaunch()
        #expect(keyless.entitlement == .lifetime(.grandfathered(originalAppVersion: "90")), "the store answered")
        #expect(try Data(contentsOf: cache) == written, "nothing is written without a key")
        // No key and no store answer: nothing is trusted either.
        await h.store.setApp(nil)
        let keylessOffline = try await h.relaunch()
        #expect(keylessOffline.entitlement == .free)
        #expect(try Data(contentsOf: cache) == written)
        // The key is back: the cache written at the first launch still authenticates.
        h.fileKeyStore = withKey
        let recovered = try await h.relaunch()
        #expect(recovered.entitlement == .lifetime(.grandfathered(originalAppVersion: "90")))
    }

    /// B1: a cache an earlier build wrote in the clear is dropped, not laundered: the engine never wraps it in an
    /// envelope of its own, and the old `account.key` file goes with it.
    @Test func a_legacy_plain_cache_is_dropped_and_never_tagged() async throws {
        let now = FakeClock().now
        let policy = GrandfatheringPolicy(lastPaidBuild: "116", paidWindow: DateInterval(start: now.addingTimeInterval(-1e7), end: now))
        let h = try Harness(grandfathering: policy)
        let legacy = AppTransactionSnapshot(
            bundleID: "b", originalAppVersion: "90", originalPurchaseDate: now.addingTimeInterval(-1e6), environment: .production,
            origin: .appTransaction)
        let cache = h.directory.appendingPathComponent("app-transaction.json")
        try CanonicalJSON.encoder().encode(legacy).write(to: cache)
        try Data("k".utf8).write(to: h.directory.appendingPathComponent("account.key"))
        let launched = try await h.relaunch()  // the store has no app transaction: offline
        #expect(launched.entitlement == .free)
        #expect(!FileManager.default.fileExists(atPath: h.directory.appendingPathComponent("account.key").path))
        let files = PaywallFiles(directory: h.directory, keyStore: h.fileKeyStore)
        #expect(files.appTransaction() == nil)
        #expect((try? CanonicalJSON.decoder().decode(PaywallFiles.Envelope.self, from: Data(contentsOf: cache))) == nil, "still the plain file")
        // Once the store answers, the file is rewritten with a tag of its own and read back.
        await h.store.setApp(legacy)
        await launched.refresh(cause: .foreground)
        #expect(launched.entitlement == .lifetime(.grandfathered(originalAppVersion: "90")))
        #expect(files.appTransaction() == legacy)
    }

    @Test func grandfather_token_grant_is_once_per_account() async throws {
        let now = FakeClock().now
        let policy = GrandfatheringPolicy(
            lastPaidBuild: "116", paidWindow: DateInterval(start: now.addingTimeInterval(-1e7), end: now), grant: .tokens(20))
        let h = try Harness(grandfathering: policy)
        await h.store.setApp(AppTransactionSnapshot(
            bundleID: "b", originalAppVersion: "90", originalPurchaseDate: now.addingTimeInterval(-1e6), environment: .production,
            origin: .receipt))
        await h.start()
        await h.engine.refresh(cause: .foreground)
        #expect(h.engine.entitlement == .free)
        #expect(h.engine.wallet.balance == 20)
    }

    @Test func welcome_grant_with_a_fixed_id_is_once() async throws {
        let h = try await Harness.free()
        #expect(h.engine.grant(tokens: 5, reason: "welcome", id: "grant:welcome"))
        #expect(!h.engine.grant(tokens: 5, reason: "welcome", id: "grant:welcome"))
        #expect(!h.engine.grant(tokens: 0, reason: "nothing"))
        #expect(h.engine.wallet.balance == 5)
    }

    /// A3: a lapsed subscription in its billing grace period keeps the paid gate open until the grace ends, with one
    /// sleeper for the grace end and no `.free` through the expiry timer before it; at the end it lapses for real.
    @Test func a_subscription_in_billing_grace_stays_paid_until_the_grace_ends() async throws {
        let h = try Harness()
        let now = h.clock.now
        let graceEnd = now.addingTimeInterval(16 * 86_400)
        let lapsed = StoreTransaction.subscription(
            id: 5, productID: "pro.monthly", purchased: now.addingTimeInterval(-30 * 86_400), expires: now.addingTimeInterval(-3_600))
        await h.store.setEntitlements([lapsed])
        await h.store.setGraceEnd(graceEnd)
        await h.start()
        guard case .subscribed(let subscription) = h.engine.entitlement else {
            Issue.record("expected a subscription in grace, got \(h.engine.entitlement)")
            return
        }
        #expect(subscription.phase == .inGracePeriod && subscription.gracePeriodEndsAt == graceEnd)
        #expect(h.engine.canPass(.paid) && h.engine.canPass(.tokens(5)))
        #expect(h.clock.pendingSleepers == 1, "one expiry timer, for the grace end")
        h.clock.advance(by: 15 * 86_400)
        await Task.yield()
        #expect(h.engine.entitlement.isPaying)
        #expect(!h.events.contains { if case .entitlementChanged(_, .free, .expiryTimer) = $0 { true } else { false } })
        // Billing never recovered: at the grace end the subscription lapses, through the timer.
        h.clock.advance(by: 86_400)
        #expect(await eventually { h.engine.entitlement == .free })
        #expect(h.events.contains { if case .entitlementChanged(.subscribed, .free, .expiryTimer) = $0 { true } else { false } })
        #expect(!h.engine.canPass(.paid))
        // The grace read fails offline: the lapsed row is free, as before grace was modelled; online it counts again.
        await h.store.setGraceEnd(h.clock.now.addingTimeInterval(20 * 86_400))
        await h.store.setNetwork(false)
        await h.engine.refresh(cause: .foreground)
        #expect(h.engine.entitlement == .free)
        await h.store.setNetwork(true)
        await h.engine.refresh(cause: .foreground)
        #expect(h.engine.entitlement.isPaying, "back online, the grace the store reports counts again")
    }

    // MARK: Sync

    @Test func two_devices_converge_on_one_balance() async throws {
        let cloud = InMemoryCloud()
        let a = try await Harness.free(sync: InMemoryLedgerSync(cloud: cloud))
        let b = try await Harness.free(sync: InMemoryLedgerSync(cloud: cloud))
        await a.engine.handle(.tokenPack(id: 1, productID: "tokens.10", purchased: a.clock.now))
        _ = a.engine.run(.tokens(2), source: source("x")) {}
        _ = b.engine.run(.tokens(1), source: source("y")) {}  // denied: b has nothing yet
        await a.engine.syncNow()
        await b.engine.syncNow()
        _ = b.engine.run(.tokens(3), source: source("y")) {}
        await b.engine.syncNow()
        await a.engine.syncNow()
        #expect(a.engine.wallet.balance == 5)
        #expect(b.engine.wallet.balance == 5)
        #expect(a.engine.ledger.firstBrokenLink() == nil)
        #expect(b.events.contains { if case .syncMerged = $0 { return true } else { return false } })
    }

    @Test func outbox_ack_lost_does_not_double_upload() async throws {
        let cloud = InMemoryCloud()
        let sync = InMemoryLedgerSync(cloud: cloud)
        let h = try await Harness.free(tokens: 10, sync: sync)
        await h.engine.syncNow()
        #expect(h.engine.journal.pendingUpload.isEmpty)
        _ = h.engine.run(.tokens(2), source: source("x")) {}
        // The carrier saved the record but the app died before writing the uploaded marker.
        _ = try await sync.push(h.engine.journal.pendingUpload)
        let engine = try await h.relaunch(start: false)
        await engine.syncNow()
        #expect(await cloud.events.count == 2)
        #expect(engine.journal.pendingUpload.isEmpty)
        #expect(engine.wallet.balance == 8)
    }

    @Test func offline_outbox_stays_queued() async throws {
        let cloud = InMemoryCloud()
        let h = try await Harness.free(tokens: 10, sync: InMemoryLedgerSync(cloud: cloud))
        await cloud.setReachable(false)
        await h.engine.syncNow()
        #expect(h.engine.journal.pendingUpload.count == 1)
        await cloud.setReachable(true)
        await h.engine.syncNow()
        #expect(h.engine.journal.pendingUpload.isEmpty)
    }

    @Test func reinstall_keeps_the_balance_through_the_keychain_snapshot() async throws {
        let sync = InMemoryLedgerSync(cloud: InMemoryCloud())
        let h = try await Harness.free(tokens: 10, sync: sync)
        _ = h.engine.run(.tokens(4), source: source("x")) {}
        #expect(await eventually { await sync.snapshot?.balance == 6 })
        await sync.cloud.setReachable(false)  // iCloud off: only the Keychain survives.
        let reinstalled = try Harness(sync: sync)
        await reinstalled.start()
        #expect(reinstalled.engine.wallet.balance == 6)
        // A1: the balance holds across launches, not only the first one after the reinstall.
        for _ in 0..<2 {
            try await reinstalled.relaunch()
            await reinstalled.engine.syncNow()
            #expect(reinstalled.engine.wallet.balance == 6)
        }
        _ = reinstalled.engine.run(.tokens(1), source: source("y")) {}
        try await reinstalled.relaunch()
        #expect(reinstalled.engine.wallet.balance == 5)
        #expect(reinstalled.engine.canPass(.tokens(5)))
    }

    // MARK: Audit

    @Test func audit_records_chain_and_carry_state() async throws {
        let h = try await Harness.free(tokens: 10)
        _ = h.engine.run(.tokens(2), source: source("x")) {}
        await h.engine.flushAudit()
        let records = await h.audit.records
        #expect(AuditRecord.firstBrokenLink(in: records) == nil)
        let consumed = try #require(records.first { if case .tokensConsumed = $0.event { return true } else { return false } })
        #expect(consumed.balanceBefore == 10 && consumed.balanceAfter == 8)
        #expect(consumed.appVersion == "2.0" && consumed.build == "200")
        #expect(consumed.deviceID == h.engine.deviceID)
        var tampered = records
        tampered.remove(at: 1)
        #expect(AuditRecord.firstBrokenLink(in: tampered) != nil)
    }

    @Test func journal_sink_rotates_and_reports_debits() async throws {
        let dir = makeTemporaryPaywallDirectory()
        let sink = JournalSink(directory: dir, maxBytes: 2_000, maxFiles: 3)
        let h = try Harness(directory: dir, audit: InMemoryAuditSink())
        let engine = try GateEngine(
            directory: dir, catalog: catalog, settings: .init(), clock: h.clock, store: h.store, audit: [sink])
        await engine.start()
        engine.grant(tokens: 50, reason: "t")
        for i in 0..<20 { _ = engine.run(.tokens(1), source: source("g\(i)")) {} }
        await engine.flushAudit()
        let records = await sink.records()
        #expect(!records.isEmpty)
        let files = await sink.fileURLs().map(\.lastPathComponent)
        #expect(files.filter { $0.hasSuffix(".jsonl") }.count == 3)
        #expect(files.contains(JournalSink.anchorFileName))
        #expect(await sink.recordedDebitIDs().count >= 1)
        #expect(await sink.lastRecordHash() == records.last?.hash)
    }

    @Test func closure_sink_forwards() async throws {
        let box = InMemoryAuditSink()
        let sink = ClosureSink { await box.write($0) }
        let h = try Harness()
        let engine = try GateEngine(directory: makeTemporaryPaywallDirectory(), catalog: catalog, clock: h.clock, store: h.store, audit: [sink])
        _ = engine.evaluate(.paid, source: source("p"))
        await engine.flushAudit()
        #expect(await box.records.count >= 1)
    }

    @Test func timeline_plays_subscription_states() async throws {
        let h = try await Harness.free()
        let t = h.clock.now
        let timeline = EntitlementTimeline([
            .init(after: 0, transactions: [.subscription(id: 1, productID: "pro.weekly", purchased: t, expires: t.addingTimeInterval(100), trial: true)]),
            .init(after: 50, transactions: [.subscription(id: 2, productID: "pro.yearly", purchased: t, expires: t.addingTimeInterval(1_000))]),
            .init(after: 2_000, transactions: []),
        ])
        let seen = await timeline.play(on: h.store, clock: h.clock, engine: h.engine)
        #expect(seen == [
            .subscription(.weekly, isTrial: true, expiresAt: t.addingTimeInterval(100)),
            .subscription(.yearly, expiresAt: t.addingTimeInterval(1_000)),
            .free,
        ])
    }
}
