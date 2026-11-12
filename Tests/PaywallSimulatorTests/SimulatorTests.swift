#if DEBUG
    import AppKit
    import Combine
    import Foundation
    import PaywallCore
    import PaywallKit
    import PaywallTesting
    import SwiftUI
    import Testing

    @testable import PaywallSimulator

    private let catalog = ProductCatalog.simulatorDefault

    @MainActor
    private func configure(_ simulation: PaywallSimulation) async {
        Paywall.shared.configure(.simulated(simulation, catalog: catalog))
        await Paywall.shared.waitUntilStarted()
    }

    @MainActor
    private func outcome(_ level: GateLevel, _ id: String) -> PaywallFailure.Reason? {
        withPaywall(level, id: id) { () }.failure?.reason
    }

    /// Hosts a SwiftUI view in a real window long enough for appear callbacks to run.
    @MainActor
    private func host<V: View>(_ view: V) async -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: view)
        window.orderFront(nil)
        for _ in 0..<20 {
            window.contentView?.layoutSubtreeIfNeeded()
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return window
    }

    private struct Probe: View {
        let level: GateLevel
        let policy: TokenPolicy
        @Binding var log: [String]

        var body: some View {
            Text("content")
                .onAppear { log.append("content") }
                .paywallGated(level, policy: policy, id: "probe") { failure in
                    Text("denied").onAppear { log.append("denied:\(failure.reason)") }
                }
        }
    }

    @MainActor
    private final class Log: ObservableObject {
        @Published var entries: [String] = []
    }

    private struct ProbeHost: View {
        let level: GateLevel
        let policy: TokenPolicy
        let simulation: PaywallSimulation
        @ObservedObject var log: Log

        var body: some View {
            Probe(level: level, policy: policy, log: $log.entries).paywallSimulation(simulation)
        }
    }

    @Suite("Simulator", .serialized)
    @MainActor
    struct SimulatorTests {
        // MARK: Enumerations

        @Test(arguments: PaywallPreset.allCases)
        func every_preset_round_trips_its_raw_value(preset: PaywallPreset) {
            #expect(PaywallPreset(rawValue: preset.rawValue) == preset)
            #expect(PaywallSimulation(preset) == preset.simulation)
        }

        @Test(arguments: PaywallLaunchArgument.allCases)
        func every_launch_argument_parses(argument: PaywallLaunchArgument) {
            let value: String
            switch argument {
            case .preset: value = PaywallPreset.lifetime.rawValue
            case .tokens: value = "7"
            case .network: value = "off"
            case .store: value = "down"
            case .tolerance: value = "12"
            }
            let parsed = PaywallLaunchArguments(["App", argument.rawValue, value])
            #expect(parsed.problems.isEmpty)
            #expect(parsed.isPresent)
            switch argument {
            case .preset: #expect(parsed.simulation == PaywallSimulation(.lifetime))
            case .tokens: #expect(parsed.simulation.tokens == 7)
            case .network: #expect(!parsed.simulation.network)
            case .store: #expect(!parsed.simulation.storeReachable)
            case .tolerance: #expect(parsed.simulation.tolerance == 12)
            }
            let bad = PaywallLaunchArguments([argument.rawValue, "nonsense-\u{1F600}"])
            #expect(bad.problems == [.invalidValue(argument, "nonsense-\u{1F600}")])
            #expect(PaywallLaunchArguments([argument.rawValue]).problems == [.missingValue(argument)])
        }

        @Test func overrides_apply_after_the_preset_whatever_the_order() {
            let parsed = PaywallLaunchArguments(["-paywall.tokens", "3", "-paywall.preset", "tokens-5", "-other.flag", "x"])
            #expect(parsed.simulation.tokens == 3)
            #expect(parsed.problems.isEmpty)
            #expect(!PaywallLaunchArguments(["App", "-NSDebug", "YES"]).isPresent)
            #expect(PaywallLaunchArguments(["-paywall.preset", "-paywall.tokens", "2"]).problems == [.missingValue(.preset)])
        }

        // MARK: Presets against the real engine

        /// One case per preset: the outcome of each gate level.
        @Test(arguments: PaywallPreset.allCases)
        func preset_gate_outcomes(preset: PaywallPreset) async {
            await configure(PaywallSimulation(preset))
            let free = outcome(.free, "free")
            let paid = outcome(.paid, "paid")
            let tokens = outcome(.tokens(3), "tokens")
            #expect(free == nil)
            switch preset {
            case .trial, .weekly, .monthly, .yearly, .lifetime, .grandfathered:
                #expect(paid == nil)
                #expect(tokens == nil)
                #expect(Paywall.shared.wallet.balance == 0)
            case .tokens5:
                #expect(paid == .requiresPaid)
                #expect(tokens == nil)
                #expect(Paywall.shared.wallet.balance == 2)
            case .free, .broke, .offline:
                #expect(paid == .requiresPaid)
                #expect(tokens == .insufficientTokens(needed: 3, available: 0))
            case .storeDown:
                #expect(paid == .entitlementUnavailable)
                #expect(tokens == .entitlementUnavailable)
            }
            if preset == .trial, case .subscribed(let subscription) = Paywall.shared.entitlement {
                #expect(subscription.isTrial)
            }
        }

        @Test func audit_records_say_simulated() async throws {
            await configure(PaywallSimulation(.free))
            _ = outcome(.paid, "x")
            await Paywall.shared.engine?.flushAudit()
            let flushed = await JournalSink(directory: PaywallSimulator.shared.directory).records()
            #expect(!flushed.isEmpty)
            #expect(flushed.allSatisfy { $0.environment == "simulated" })
            #expect(PaywallSimulator.shared.directory.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        }

        // MARK: Switches

        @Test func switches_re_resolve_the_engine() async {
            await configure(PaywallSimulation(.free))
            let simulator = PaywallSimulator.shared
            simulator.simulation.tokens = 4
            await simulator.settle()
            #expect(Paywall.shared.wallet.balance == 4)
            simulator.grantTokens(1)
            await simulator.settle()
            #expect(Paywall.shared.wallet.balance == 5)
            simulator.apply(.monthly)
            await simulator.settle()
            #expect(Paywall.shared.entitlement.isPaying)
            simulator.simulation.storeReachable = false
            await simulator.settle()
            #expect(Paywall.shared.entitlement == .unknown)
            simulator.simulation.storeReachable = true
            await simulator.settle()
            #expect(Paywall.shared.entitlement.isPaying)
        }

        @Test func refund_subscription_flips_a_visible_view_live() async {
            await configure(PaywallSimulation(.weekly))
            let log = Log()
            let window = await host(Probe(level: .paid, policy: .reserve, log: Binding(get: { log.entries }, set: { log.entries = $0 })))
            #expect(log.entries.contains("content"))
            PaywallSimulator.shared.refund(.subscription)
            var flipped = false
            for _ in 0..<200 where !flipped {
                window.contentView?.layoutSubtreeIfNeeded()
                try? await Task.sleep(nanoseconds: 5_000_000)
                flipped = log.entries.contains { $0.hasPrefix("denied") }
            }
            #expect(flipped)
            #expect(Paywall.shared.entitlement == .free)
            window.close()
        }

        @Test func refund_lifetime_and_last_token_pack() async {
            await configure(PaywallSimulation(.lifetime))
            let simulator = PaywallSimulator.shared
            simulator.refund(.lifetime)
            var free = false
            for _ in 0..<200 where !free {
                try? await Task.sleep(nanoseconds: 5_000_000)
                free = Paywall.shared.entitlement == .free
            }
            #expect(free)

            simulator.purchaseTokenPack()
            var credited = false
            for _ in 0..<200 where !credited {
                try? await Task.sleep(nanoseconds: 5_000_000)
                credited = Paywall.shared.wallet.balance == 10
            }
            #expect(credited)
            simulator.refund(.lastTokenPack)
            var revoked = false
            for _ in 0..<200 where !revoked {
                try? await Task.sleep(nanoseconds: 5_000_000)
                revoked = Paywall.shared.wallet.balance == 0
            }
            #expect(revoked)
            simulator.refund(.lastTokenPack)  // nothing left: no-op
            simulator.refund(.subscription)  // not subscribed: no-op
        }

        @Test func renewal_expiry_grace_and_billing_retry() async {
            await configure(PaywallSimulation(.trial))
            let simulator = PaywallSimulator.shared
            simulator.renew()
            await simulator.settle()
            if case .subscribed(let s) = Paywall.shared.entitlement { #expect(!s.isTrial) } else { Issue.record("not subscribed") }
            simulator.enterGracePeriod()
            await simulator.settle()
            #expect(Paywall.shared.entitlement.isPaying)
            #expect(try! await Paywall.shared.subscriptionPhase() == .inGracePeriod)
            simulator.enterBillingRetry()
            var lapsed = false
            for _ in 0..<200 where !lapsed {
                try? await Task.sleep(nanoseconds: 5_000_000)
                lapsed = Paywall.shared.entitlement == .free
            }
            #expect(lapsed)
            simulator.apply(.weekly)
            await simulator.settle()
            simulator.expire()
            await simulator.settle()
            #expect(Paywall.shared.entitlement == .free)
            simulator.renew()  // not subscribed: no-op
            simulator.enterGracePeriod()
            simulator.enterBillingRetry()
            simulator.expire()
        }

        @Test func lease_window_with_simulated_clock() async {
            var simulation = PaywallSimulation(.tokens5)
            simulation.tolerance = 60
            await configure(simulation)
            #expect(outcome(.tokens(1), "solver") == nil)
            PaywallSimulator.shared.advance(by: 30)
            #expect(outcome(.tokens(1), "solver") == nil)
            #expect(Paywall.shared.wallet.balance == 4)
            PaywallSimulator.shared.advance(by: 31)
            #expect(outcome(.tokens(1), "solver") == nil)
            #expect(Paywall.shared.wallet.balance == 3)
        }

        @Test func purchase_outcomes_without_app_store_connect() async throws {
            for (outcomeCase, expected) in [(SimulatedPurchaseOutcome.success, "purchased"), (.cancelled, "cancelled"), (.pending, "pending"), (.failed, "failed")] {
                var simulation = PaywallSimulation()
                simulation.purchaseOutcome = outcomeCase
                await configure(simulation)
                let products = try await Paywall.shared.products()
                #expect(products.count == 6)
                let lifetime = try #require(products.first { $0.kind == .lifetime })
                do {
                    switch try await Paywall.shared.purchase(lifetime) {
                    case .purchased: #expect(expected == "purchased")
                    case .cancelled: #expect(expected == "cancelled")
                    case .pending: #expect(expected == "pending")
                    }
                } catch {
                    #expect(expected == "failed")
                }
            }
        }

        @Test func offline_products_show_cached_prices() async throws {
            await configure(PaywallSimulation(.free))
            _ = try await Paywall.shared.products()
            PaywallSimulator.shared.simulation.network = false
            await PaywallSimulator.shared.settle()
            let cached = try await Paywall.shared.products()
            #expect(cached.allSatisfy { !$0.isPurchasable && $0.priceAsOf != nil })
        }

        @Test func network_switch_drives_the_network_path() async {
            await configure(PaywallSimulation(.free))
            #expect(await PaywallSimulator.shared.connectivity.hasPath)
            PaywallSimulator.shared.simulation.network = false
            await PaywallSimulator.shared.settle()
            #expect(await !PaywallSimulator.shared.connectivity.hasPath)
            for _ in 0..<100 where Paywall.shared.engine?.hasNetworkPath != false { await Task.yield() }
            #expect(Paywall.shared.engine?.hasNetworkPath == false)
        }

        @Test func launch_arguments_configure_the_matching_gate() async {
            let arguments = PaywallLaunchArguments([PaywallLaunchArgument.preset.rawValue, PaywallPreset.lifetime.rawValue, "-paywall.tokens", "x"])
            Paywall.shared.configure(.simulated(arguments, catalog: catalog))
            await Paywall.shared.waitUntilStarted()
            #expect(arguments.problems == [.invalidValue(.tokens, "x")])
            #expect(outcome(.paid, "heatmap") == nil)
        }

        @Test func reset_wipes_the_journal() async {
            await configure(PaywallSimulation(.tokens5))
            let before = PaywallSimulator.shared.directory
            PaywallSimulator.shared.reset()
            await Paywall.shared.waitUntilStarted()
            #expect(PaywallSimulator.shared.directory != before)
            #expect(Paywall.shared.wallet.balance == 5)
        }

        // MARK: Previews

        @Test(arguments: [PaywallPreset.free, .lifetime, .tokens5, .storeDown])
        func preview_renders_the_state_of_the_preset(preset: PaywallPreset) async {
            let log = Log()
            let window = await host(ProbeHost(level: .paid, policy: .reserve, simulation: PaywallSimulation(preset), log: log))
            switch preset {
            case .lifetime:
                #expect(log.entries.first == "content")
            case .storeDown:
                #expect(log.entries.first == "denied:entitlementUnavailable")
            default:
                #expect(log.entries.first == "denied:requiresPaid")
            }
            window.close()
        }

        @Test func reserve_on_appear_commit_through_session_release_on_disappear() async {
            await configure(PaywallSimulation(.tokens5))
            struct Committer: View {
                @Environment(\.paywallGate) var gate
                let onCommit: (Bool) -> Void
                var body: some View {
                    Text("tool").onAppear { onCommit(gate?.withPaywall { true }.value ?? false) }
                }
            }
            var committed: Bool?
            let window = await host(Committer { committed = $0 }.paywallGated(.tokens(3), id: "tool"))
            #expect(committed == true)
            #expect(Paywall.shared.wallet == Wallet(balance: 2, reserved: 0))
            window.contentViewController = NSHostingController(rootView: Text("gone"))
            for _ in 0..<20 { await Task.yield() }
            #expect(Paywall.shared.wallet.reserved == 0)
            window.close()
        }
    }
#endif
