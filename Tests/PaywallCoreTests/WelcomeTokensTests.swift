import Foundation
import PaywallTesting
import Testing

@testable import PaywallCore

/// The once-per-account welcome grant: this build's amount, written when the account is known to be new, never
/// touched by a later build with another amount.
@Suite("Welcome tokens", .serialized)
@MainActor
struct WelcomeTokensTests {
    private func settings(welcome: Int, version: String = "1.0") -> GateEngine.Settings {
        GateEngine.Settings(tolerance: 300, appVersion: version, build: "100", welcomeTokens: welcome)
    }

    private func welcomeGrants(_ engine: GateEngine) -> Int {
        engine.ledger.events.filter { if case .grant(_, "welcome") = $0.kind { true } else { false } }.count
    }

    @Test func a_fresh_install_without_a_carrier_is_granted_at_launch_and_keeps_its_amount() async throws {
        let h = try await Harness.free(settings: settings(welcome: 100))
        #expect(h.engine.wallet.balance == 100)
        #expect(h.engine.ledger.contains("grant:welcome"))
        #expect(h.events.contains(.tokensGranted(n: 100, reason: "welcome")))
        #expect(h.engine.tier == .tokens)
        _ = h.engine.run(.tokens(30), source: source("x")) {}
        // The next release grants 40 to its new users: this one keeps 100, less what they spent.
        h.settings = settings(welcome: 40, version: "1.1")
        try await h.relaunch()
        #expect(h.engine.wallet.balance == 70)
        #expect(welcomeGrants(h.engine) == 1)
        try await h.relaunch()
        #expect(h.engine.wallet.balance == 70)
    }

    @Test func zero_grants_nothing() async throws {
        let h = try await Harness.free(settings: settings(welcome: 0))
        #expect(h.engine.wallet.balance == 0)
        #expect(!h.engine.ledger.contains("grant:welcome"))
    }

    /// A store client whose launch read fails (a host-written one; StoreKit's never throws) still gets the grant, and
    /// the gates wait for a resolution.
    @Test func a_first_launch_with_the_store_unreachable_still_grants_and_the_gates_wait_for_the_resolution() async throws {
        let h = try Harness(settings: settings(welcome: 100))
        await h.store.setPassiveReadFailure(.unreachable)
        await h.start()
        #expect(h.engine.entitlement == .unknown)
        #expect(h.engine.wallet.balance == 100)
        #expect(h.engine.tier == nil)
        #expect(h.engine.run(.tokens(1), source: source("t")) { 1 }.failure?.reason == .entitlementUnavailable)
        await h.store.setPassiveReadFailure(nil)
        await h.engine.refresh(cause: .foreground)
        #expect(h.engine.tier == .tokens)
        #expect(h.engine.run(.tokens(1), source: source("t")) { 1 }.value == 1)
    }

    @Test func with_a_carrier_the_grant_waits_for_the_first_pull() async throws {
        let cloud = InMemoryCloud()
        await cloud.setReachable(false)
        let h = try await Harness.free(sync: InMemoryLedgerSync(cloud: cloud), settings: settings(welcome: 100))
        await h.engine.syncNow()
        #expect(h.engine.wallet.balance == 0)  // offline at the first launch: nothing yet
        await cloud.setReachable(true)
        await h.engine.syncNow()
        #expect(h.engine.wallet.balance == 100)  // the carrier answered with nothing for this account
        await h.engine.syncNow()
        #expect(h.engine.wallet.balance == 100)
        #expect(welcomeGrants(h.engine) == 1)
        #expect(await eventually { await cloud.events["grant:welcome"] != nil })
    }

    @Test func a_new_device_takes_the_accounts_grant_whatever_its_own_build_would_give() async throws {
        let cloud = InMemoryCloud()
        let a = try await Harness.free(sync: InMemoryLedgerSync(cloud: cloud), settings: settings(welcome: 100, version: "1.0"))
        await a.engine.syncNow()
        _ = a.engine.run(.tokens(10), source: source("x")) {}
        await a.engine.syncNow()
        let b = try await Harness.free(sync: InMemoryLedgerSync(cloud: cloud), settings: settings(welcome: 40, version: "2.0"))
        await b.engine.syncNow()
        #expect(b.engine.wallet.balance == 90)
        #expect(welcomeGrants(b.engine) == 1)
        #expect(!b.events.contains { if case .tokensGranted = $0 { true } else { false } })
        await a.engine.syncNow()
        #expect(a.engine.wallet.balance == 90)
    }

    @Test func an_account_with_history_but_no_welcome_grant_gets_none() async throws {
        let cloud = InMemoryCloud()
        // A build before welcome tokens existed, with a pack bought.
        let before = try await Harness.free(sync: InMemoryLedgerSync(cloud: cloud), settings: settings(welcome: 0))
        await before.engine.handle(.tokenPack(id: 1, productID: "tokens.10", purchased: before.clock.now))
        await before.engine.syncNow()
        // A new device on the build that has them: the account has history, so nothing is granted.
        let updated = try await Harness.free(sync: InMemoryLedgerSync(cloud: cloud), settings: settings(welcome: 100, version: "2.0"))
        await updated.engine.syncNow()
        #expect(updated.engine.wallet.balance == 10)
        #expect(welcomeGrants(updated.engine) == 0)
        // The same device updated in place: the same.
        before.settings = settings(welcome: 100, version: "2.0")
        try await before.relaunch()
        await before.engine.syncNow()
        #expect(before.engine.wallet.balance == 10)
        #expect(welcomeGrants(before.engine) == 0)
    }

    @Test func a_reinstall_with_a_keychain_snapshot_is_not_a_new_account() async throws {
        let sync = InMemoryLedgerSync(cloud: InMemoryCloud())
        let h = try await Harness.free(sync: sync, settings: settings(welcome: 100))
        await h.engine.syncNow()
        _ = h.engine.run(.tokens(4), source: source("x")) {}
        await h.engine.syncNow()  // the debit reaches the carrier before the old install dies
        #expect(await eventually { await sync.snapshot?.balance == 96 })
        await sync.cloud.setReachable(false)  // iCloud off: only the Keychain survives
        let reinstalled = try Harness(sync: sync, settings: settings(welcome: 100))
        await reinstalled.start()
        await reinstalled.engine.syncNow()
        #expect(reinstalled.engine.wallet.balance == 96)
        await sync.cloud.setReachable(true)
        await reinstalled.engine.syncNow()
        #expect(reinstalled.engine.wallet.balance == 96)
        #expect(welcomeGrants(reinstalled.engine) == 1)
    }
}
