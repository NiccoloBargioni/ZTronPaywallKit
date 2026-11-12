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

    @Suite("Signal modifiers", .serialized)
    @MainActor
    struct SignalViewTests {
        @Test func paywall_sheet_presents_unclaimed_failures() async {
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
            #expect(paywall.pendingFailure?.source.id == "heatmap")
            await pump(window)
            #expect(recorder.presented == ["heatmap"])
            window.attachedSheet.map { window.endSheet($0) }
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
