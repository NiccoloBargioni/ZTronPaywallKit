#if canImport(AppKit)
    import AppKit
    import Combine
    import Foundation
    import PaywallCore
    import PaywallTesting
    import SwiftUI
    import Testing

    @testable import PaywallKit

    @MainActor
    private final class Opened {
        var count = 0
    }

    @Suite("Facade edges", .serialized)
    @MainActor
    struct FacadeEdgeTests {
        private let gate = PaywallSource(id: "gate", fileID: "f", function: "g", line: 1)

        @Test func default_storage_lives_in_application_support() {
            #expect(Paywall.Configuration.defaultStorageDirectory.lastPathComponent == "ztron.paywall")
        }

        @Test func a_failed_reconfigure_clears_the_mirrored_state() async {
            let (paywall, _, _) = await makePaywall(tokens: 4)
            #expect(paywall.wallet.balance == 4)
            #expect(paywall.entitlement == .free)
            paywall.configure(Paywall.Configuration(catalog: ProductCatalog(subscriptionGroupID: "g")))
            #expect(paywall.engine == nil)
            #expect(paywall.entitlement == .unknown)
            #expect(paywall.wallet == .empty)
        }

        @Test func can_pass_reads_the_engine() async {
            let (paywall, _, _) = await makePaywall(tokens: 1)
            #expect(paywall.canPass(.tokens(1), id: "g"))
            #expect(!paywall.canPass(.tokens(2), id: "g"))
            #expect(!paywall.canPass(.paid))
            #expect(Paywall().canPass(.free))
            #expect(!Paywall().canPass(.tokens(1)))
        }

        @Test func static_begin_on_an_unconfigured_facade_fails_closed_except_free() {
            let unconfigured = Paywall()
            Paywall.$override.withValue(unconfigured) {
                guard case .open(let ticket) = Paywall.begin(.free, source: gate, scope: nil, holder: nil) else {
                    Issue.record("free gate closed")
                    return
                }
                #expect(ticket.mode == .free)
                Paywall.complete(ticket)
                guard case .blocked(let failure) = Paywall.begin(.tokens(1), source: gate, scope: "s", holder: nil) else {
                    Issue.record("token gate opened without an engine")
                    return
                }
                #expect(failure.reason == .entitlementUnavailable)
                #expect(failure.scope == "s")
            }
        }

        @Test func reconfiguring_cancels_a_pending_fallback() async {
            let (paywall, _, _) = await makePaywall()
            _ = paywall.evaluate(.paid, id: "heatmap")  // fallback scheduled for the end of the turn
            let (_, store, clock) = await makePaywall()
            var configuration = Paywall.Configuration(catalog: catalog)
            configuration.store = store
            configuration.clock = clock
            configuration.connectivity = nil
            configuration.includesDefaultAudit = false
            configuration.storageDirectory = makeTemporaryPaywallDirectory()
            paywall.configure(configuration)
            await settle()
            #expect(paywall.pendingFailure == nil)  // the old engine's denial never surfaces on the new one
        }

        @Test func unconfigured_sessions_open_free_and_deny_the_rest() {
            let unconfigured = Paywall()
            let free = unconfigured.openSession(holder: UUID(), level: .free, policy: .reserve, source: gate, scope: nil) { _ in }
            #expect(free.isOpen)
            let paid = unconfigured.openSession(holder: UUID(), level: .paid, policy: .reserve, source: gate, scope: "s") { _ in }
            #expect(paid.failure?.reason == .entitlementUnavailable)
        }

        @Test func failure_preference_keeps_the_latest_non_nil_value() {
            let failure = PaywallFailure(reason: .requiresPaid, level: .paid, source: gate, at: Date())
            var value: PaywallFailure? = nil
            PaywallFailureKey.reduce(value: &value) { failure }
            #expect(value == failure)
            PaywallFailureKey.reduce(value: &value) { nil }
            #expect(value == failure)
        }

        @Test func container_presence_drives_a_gate_without_its_own() async {
            let (paywall, _, _) = await makePaywall(tokens: 3)
            let presence = PassthroughSubject<Bool, Never>()
            let opened = Opened()
            let window = await Paywall.$override.withValue(paywall) { () async -> NSWindow in
                let view = Text("content")
                    .onAppear { opened.count += 1 }
                    .paywallGated(.tokens(1), policy: .deductNow, id: "hosted")
                    .environment(\.paywallPresence, presence.eraseToAnyPublisher())
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered,
                    defer: false)
                window.isReleasedWhenClosed = false
                window.contentViewController = NSHostingController(rootView: view)
                window.orderFront(nil)
                return window
            }
            defer { window.close() }
            await pumpLayout(window)
            #expect(paywall.wallet.balance == 3)  // a presence signal exists: appearing alone opens nothing
            presence.send(true)
            await pumpLayout(window)
            #expect(paywall.wallet.balance == 2)
            #expect(opened.count == 1)
            presence.send(false)
            await pumpLayout(window)
            presence.send(true)
            await pumpLayout(window)
            #expect(paywall.wallet.balance == 2)  // re-shown within the lease: no second draw
        }

        private func pumpLayout(_ window: NSWindow) async {
            for _ in 0..<20 {
                window.contentView?.layoutSubtreeIfNeeded()
                await Task.yield()
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
    }
#endif
