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
    private final class Recorder: ObservableObject {
        var presented: [String] = []
        var handled: [String] = []
        var entitlements: [Entitlement?] = []
        @Published var phase: ScenePhase = .background
    }

    /// Feeds a controllable scene phase to `content`, as a scene would.
    private struct PhaseHost<Content: View>: View {
        @ObservedObject var recorder: Recorder
        let content: Content
        var body: some View { content.environment(\.scenePhase, recorder.phase) }
    }

    /// Hosts `view` in a real window and pumps layout so appear and change callbacks run.
    @MainActor
    private func host<V: View>(_ view: V) async -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: view)
        window.orderFront(nil)
        await pump(window)
        return window
    }

    @MainActor
    private func pump(_ window: NSWindow) async {
        for _ in 0..<20 {
            window.contentView?.layoutSubtreeIfNeeded()
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// Reads `\.paywallEntitlement` where it lives and records every value it sees.
    @available(macOS 14, *)
    private struct EntitlementProbe: View {
        @ObservedObject var recorder: Recorder
        @Environment(\.paywallEntitlement) private var entitlement
        var body: some View {
            Text("probe")
                .onAppear { recorder.entitlements.append(entitlement) }
                .onChange(of: entitlement) { _, new in recorder.entitlements.append(new) }
        }
    }

    @Suite("Signal modifiers", .serialized)
    @MainActor
    struct SignalViewTests {
        /// `\.paywallEntitlement` is nil until the first resolution answers, then follows `Paywall.entitlement`
        /// through every change, from the root the sheet is installed on.
        @available(macOS 14, *)
        @Test func paywall_entitlement_is_nil_until_resolved_then_follows_the_facade() async {
            let paywall = Paywall()
            let recorder = Recorder()
            let window = await Paywall.$override.withValue(paywall) {
                await host(EntitlementProbe(recorder: recorder).paywallSheet { _ in Text("paywall") })
            }
            defer { window.close() }
            #expect(paywall.entitlement == .unknown)
            #expect(recorder.entitlements == [nil], "\(recorder.entitlements)")

            let store = FakeStore(entitlements: [.lifetime(id: 7, productID: "pro.lifetime", purchased: Date())], products: products)
            var configuration = Paywall.Configuration(catalog: catalog)
            configuration.store = store
            configuration.clock = FakeClock()
            configuration.storageDirectory = makeTemporaryPaywallDirectory()
            configuration.includesDefaultAudit = false
            configuration.connectivity = nil
            paywall.configure(configuration)
            await paywall.waitUntilStarted()
            await pump(window)
            #expect(recorder.entitlements.last == .lifetime(.purchase(transactionID: 7)), "\(recorder.entitlements)")

            await store.refund(7, at: Date())
            await settle()
            await pump(window)
            #expect(recorder.entitlements.last == .free, "\(recorder.entitlements)")
            #expect(!recorder.entitlements.contains(.unknown), "unknown must read as nil, never as a value")
        }

        @available(macOS 14, *)
        @Test func paywall_lifecycle_injects_the_entitlement_too() async {
            let (paywall, _, _) = await makePaywall()
            let recorder = Recorder()
            let window = await Paywall.$override.withValue(paywall) {
                await host(EntitlementProbe(recorder: recorder).paywallLifecycle())
            }
            defer { window.close() }
            #expect(recorder.entitlements.last == .free, "\(recorder.entitlements)")
        }

        /// Without a root modifier nothing injects it: the default is nil whatever the facade knows.
        @available(macOS 14, *)
        @Test func without_a_root_modifier_the_entitlement_environment_is_nil() async {
            let (paywall, _, _) = await makePaywall()
            let recorder = Recorder()
            let window = await Paywall.$override.withValue(paywall) {
                await host(EntitlementProbe(recorder: recorder))
            }
            defer { window.close() }
            #expect(paywall.entitlement == .free)
            #expect(recorder.entitlements == [nil], "\(recorder.entitlements)")
        }

        @Test func paywall_sheet_presents_unclaimed_failures_and_consumes_them() async {
            let (paywall, _, _) = await makePaywall()
            let recorder = Recorder()
            let window = await Paywall.$override.withValue(paywall) {
                await host(
                    Text("root").paywallSheet { failure in
                        Text("paywall").onAppear { recorder.presented.append(failure.source.id) }
                    })
            }
            defer { window.close() }
            _ = paywall.evaluate(.paid, id: "heatmap")
            await settle()
            await pump(window)
            #expect(recorder.presented == ["heatmap"])
            // The presenter took it: nothing is left for a second presenter, and a later denial is a new sheet.
            #expect(paywall.pendingFailure == nil)
            window.attachedSheet.map { window.endSheet($0) }
        }

        /// The design's rule: `pendingFailure` is consumed by the first presenter, so two installed sheets cannot
        /// both show one denial.
        @Test func two_installed_sheets_present_a_denial_once() async {
            let (paywall, _, _) = await makePaywall()
            let recorder = Recorder()
            let window = await Paywall.$override.withValue(paywall) {
                await host(
                    Text("root")
                        .paywallSheet { failure in
                            Text("outer").onAppear { recorder.presented.append("outer:\(failure.source.id)") }
                        }
                        .paywallSheet { failure in
                            Text("inner").onAppear { recorder.presented.append("inner:\(failure.source.id)") }
                        })
            }
            defer { window.close() }
            _ = paywall.evaluate(.paid, id: "heatmap")
            await settle()
            await pump(window)
            await pump(window)
            #expect(recorder.presented.count == 1, "\(recorder.presented)")
            #expect(paywall.pendingFailure == nil)
            window.attachedSheet.map { window.endSheet($0) }
        }

        @Test func on_purchase_intent_opens_the_paywall_on_the_promoted_product() async {
            let (paywall, store, _) = await makePaywall()
            let recorder = Recorder()
            let window = await Paywall.$override.withValue(paywall) {
                await host(Text("root").onPurchaseIntent { recorder.handled.append($0) })
            }
            defer { window.close() }
            await store.deliverPurchaseIntent(productID: "pro.yearly")
            for _ in 0..<50 where recorder.handled.isEmpty { await pump(window) }
            #expect(recorder.handled == ["pro.yearly"])
            #expect(paywall.pendingPurchaseIntent == nil)  // taken by the handler
        }

        @Test func paywall_sheet_can_be_switched_off() async {
            let (paywall, _, _) = await makePaywall()
            let recorder = Recorder()
            let window = await Paywall.$override.withValue(paywall) {
                await host(
                    Text("root").paywallSheet(presentsPaywall: false) { failure in
                        Text("paywall").onAppear { recorder.presented.append(failure.source.id) }
                    })
            }
            defer { window.close() }
            _ = paywall.evaluate(.paid, id: "heatmap")
            await settle()
            await pump(window)
            #expect(recorder.presented.isEmpty)
            #expect(window.attachedSheet == nil)
        }

        @Test func on_paywall_failure_receives_scoped_denials() async {
            let (paywall, _, _) = await makePaywall()
            let recorder = Recorder()
            let window = await Paywall.$override.withValue(paywall) {
                await host(
                    Text("root")
                        .onPaywallFailure(in: "home") { failure in
                            recorder.handled.append(failure.source.id)
                            failure.claim()
                        }
                        .paywallScope("home"))
            }
            defer { window.close() }
            let source = PaywallSource(id: "map", fileID: "f", function: "g", line: 1)
            paywall.engine?.openSession(holder: UUID(), level: .paid, policy: .reserve, source: source, scope: "home")
            paywall.engine?.openSession(holder: UUID(), level: .paid, policy: .reserve, source: source, scope: "maps")
            await settle()
            #expect(recorder.handled == ["map"])
        }

        @Test func becoming_active_refreshes_the_entitlement() async {
            let (paywall, store, _) = await makePaywall()
            let recorder = Recorder()
            let window = await Paywall.$override.withValue(paywall) {
                await host(PhaseHost(recorder: recorder, content: Text("root").paywallLifecycle()))
            }
            defer { window.close() }
            #expect(!paywall.entitlement.isPaying)
            await store.setEntitlements([.lifetime(id: 1, productID: "pro.lifetime", purchased: Date())])
            recorder.phase = .inactive
            await pump(window)
            #expect(!paywall.entitlement.isPaying)  // only `.active` refreshes
            recorder.phase = .active
            await pump(window)
            for _ in 0..<50 where !paywall.entitlement.isPaying { await pump(window) }
            #expect(paywall.entitlement.isPaying)
        }
    }
#endif
