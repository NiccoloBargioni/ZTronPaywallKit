import Foundation
import PaywallTesting
import Testing

@testable import PaywallCore

/// Terminates the draw at one step, as a process death would.
@MainActor
private final class Terminator: DrawObserver {
    let step: DrawStep
    private(set) var reached: [DrawStep] = []

    init(at step: DrawStep) { self.step = step }

    func engine(_ engine: GateEngine, reached step: DrawStep) -> DrawObservation {
        reached.append(step)
        // Exhaustive on purpose: a new step fails to compile here until the proof covers it.
        switch step {
        case .decided, .debitAppended, .debitSynced, .valueDelivered, .auditWritten:
            return step == self.step ? .terminate : .proceed
        }
    }
}

@Suite("Crash safety", .serialized)
@MainActor
struct CrashSafetyTests {
    /// The invariant: delivered(g) ⇒ durableDebit(g), and a durable debit whose value was not delivered leaves
    /// its lease behind, so the user re-enters free within S.
    @Test(arguments: DrawStep.allCases)
    func crash_at_every_draw_step_never_leaks(step: DrawStep) async throws {
        let h = try await Harness.free(tokens: 10)
        let terminator = Terminator(at: step)
        h.engine.drawObserver = terminator
        var delivered = false
        _ = h.engine.run(.tokens(3), source: source("solver")) { delivered = true }
        #expect(h.engine.isTerminated)
        await h.engine.flushAudit()

        // The process is dead: discard everything in memory and relaunch on the same directory.
        let engine = try await h.relaunch()
        await engine.flushAudit()
        let durableDebit = engine.ledger.events.contains { if case .debit = $0.kind { return true } else { return false } }
        #expect(!delivered || durableDebit, "leak: value delivered without a durable debit")

        switch step {
        case .decided:
            #expect(!delivered)
            #expect(!durableDebit)
            #expect(engine.wallet.balance == 10)
            #expect(!engine.leases.isActive("solver", now: h.clock.now))
        case .debitAppended, .debitSynced:
            #expect(!delivered)
            #expect(durableDebit)
            #expect(engine.wallet.balance == 7)
            // Loss bounded by S: the gate opens free until the lease expires.
            #expect(engine.run(.tokens(3), source: source("solver")) { true }.value == true)
            #expect(engine.wallet.balance == 7)
        case .valueDelivered:
            #expect(delivered)
            #expect(durableDebit)
            #expect(engine.wallet.balance == 7)
            // The audit record was rebuilt from the journal entry.
            #expect(await h.audit.events.contains { if case .auditRepaired = $0 { return true } else { return false } })
        case .auditWritten:
            #expect(delivered)
            #expect(engine.wallet.balance == 7)
            #expect(!(await h.audit.events.contains { if case .auditRepaired = $0 { return true } else { return false } }))
        }
        #expect(terminator.reached.last == step)
        #expect(engine.ledger.firstBrokenLink() == nil)
    }

    @Test func a_terminated_engine_does_nothing_more() async throws {
        let h = try await Harness.free(tokens: 10)
        h.engine.drawObserver = Terminator(at: .decided)
        _ = h.engine.run(.tokens(1), source: source("a")) {}
        #expect(h.engine.run(.free, source: source("f")) { 1 }.failure?.reason == .storageUnavailable)
        #expect(h.engine.run(.tokens(1), source: source("b")) { 1 }.failure?.reason == .storageUnavailable)
        #expect(!h.engine.grant(tokens: 1, reason: "x"))
        await h.engine.refresh(cause: .foreground)
        await h.engine.handle(.tokenPack(id: 1, productID: "tokens.10", purchased: h.clock.now))
        #expect(h.engine.wallet.balance == 10)
    }

    @Test func deductNow_crash_after_draw_leaves_a_lease() async throws {
        let h = try await Harness.free(tokens: 5)
        h.engine.drawObserver = Terminator(at: .debitSynced)
        let state = h.engine.openSession(holder: UUID(), level: .tokens(2), policy: .deductNow, source: source("chart"))
        #expect(!state.isOpen)
        let engine = try await h.relaunch()
        #expect(engine.openSession(holder: UUID(), level: .tokens(2), policy: .deductNow, source: source("chart")).decision == .open(.leased))
        #expect(engine.wallet.balance == 3)
    }

    @Test func reservation_lost_on_relaunch_changes_nothing() async throws {
        let h = try await Harness.free(tokens: 5)
        h.engine.openSession(holder: UUID(), level: .tokens(3), policy: .reserve, source: source("tool"))
        #expect(h.engine.wallet.reserved == 3)
        let engine = try await h.relaunch()
        #expect(engine.wallet == Wallet(balance: 5, reserved: 0))
    }

    @Test func credit_append_before_finish_is_idempotent_across_relaunch() async throws {
        let h = try await Harness.free()
        let tx = StoreTransaction.tokenPack(id: 11, productID: "tokens.10", purchased: h.clock.now)
        // Credit written, process dies before finish(): StoreKit re-delivers at launch.
        for planned in CreditReconciler.plan(for: tx, catalog: catalog, ledger: h.engine.ledger) { h.engine.applyPlanned(planned) }
        #expect(await h.store.finished.isEmpty)
        let engine = try await h.relaunch()
        await h.store.deliver(tx)
        #expect(await eventually { await h.store.finished == [11] })
        #expect(engine.wallet.balance == 10)
    }

    /// Seeded property test over the lease state machine: random appear, disappear, draw, crash and clock events.
    @Test(arguments: [1, 2, 3, 42, 1234])
    func lease_state_machine_invariants(seed: UInt64) async throws {
        var rng = SplitMix(seed: seed)
        let h = try await Harness.free(tokens: 40)
        var engine = h.engine
        var views: [UUID] = []
        var drawsInWindow: [Date] = []
        let tolerance = h.settings.tolerance
        for _ in 0..<200 {
            switch rng.next() % 6 {
            case 0:
                let view = UUID()
                views.append(view)
                engine.openSession(holder: view, level: .tokens(1), policy: .reserve, source: source("g"))
            case 1:
                if let view = views.popLast() { engine.closeSession(holder: view) }
            case 2:
                let before = engine.wallet.balance
                let pinned = !engine.leases.holders(of: "g").isEmpty
                _ = engine.run(.tokens(1), source: source("g"), holder: views.last) {}
                if engine.wallet.balance < before {
                    // Never two draws for one gate inside S while pinned.
                    #expect(!pinned)
                    drawsInWindow.append(h.clock.now)
                }
            case 3:
                h.clock.advance(by: Double(rng.next() % 400))
            case 4:
                engine = try await h.relaunch()
                views = []
            default:
                // Never an open gate past S once unpinned.
                if engine.leases.holders(of: "g").isEmpty, let lease = engine.leases.records["g"],
                    h.clock.now >= lease.grantedAt.addingTimeInterval(tolerance)
                {
                    #expect(!engine.leases.isActive("g", now: h.clock.now))
                }
            }
            // Reserved never exceeds balance.
            #expect(engine.wallet.reserved <= max(0, engine.wallet.balance))
        }
        #expect(engine.ledger.firstBrokenLink() == nil)
    }
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
