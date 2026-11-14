import Combine
import Foundation
import PaywallCore
import PaywallTesting
import SwiftUI
import Testing

@testable import PaywallKit

#if canImport(AppKit)
    import AppKit
    private typealias ProviderHostWindow = NSWindow
#else
    import UIKit
    private typealias ProviderHostWindow = UIWindow
#endif

/// A configuration on a scripted store and a fresh directory, for either service: the label is the provider's.
@MainActor
private func fakeBacked(store: FakeStore = FakeStore(products: products), welcomeTokens: Int = 0) -> Paywall.Configuration {
    var configuration = Paywall.Configuration(catalog: catalog)
    configuration.store = store
    configuration.clock = FakeClock()
    configuration.storageDirectory = makeTemporaryPaywallDirectory()
    configuration.includesDefaultAudit = false
    configuration.connectivity = nil
    configuration.welcomeTokens = welcomeTokens
    return configuration
}

/// Puts `view` on screen in a real window (AppKit or UIKit).
@MainActor
private func show<V: View>(_ view: V) -> ProviderHostWindow {
    #if canImport(AppKit)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: view)
        window.orderFront(nil)
    #else
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
    #endif
    return window
}

/// Pumps layout so appear and change callbacks run.
@MainActor
private func pump(_ window: ProviderHostWindow) async {
    for _ in 0..<20 {
        #if canImport(AppKit)
            window.contentView?.layoutSubtreeIfNeeded()
        #else
            window.layoutIfNeeded()
        #endif
        await Task.yield()
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

@MainActor
private func dismiss(_ window: ProviderHostWindow) {
    #if canImport(AppKit)
        window.close()
    #else
        window.rootViewController = nil
        window.isHidden = true
    #endif
}

@MainActor
private final class Recorder: ObservableObject {
    var names: [String] = []
    var entitlements: [Entitlement?] = []
    var facades: [ObjectIdentifier] = []
    @Published var phase: ScenePhase = .background
}

/// Feeds a controllable scene phase to `content`, as a scene would.
private struct PhaseHost<Content: View>: View {
    @ObservedObject var recorder: Recorder
    let content: Content
    var body: some View { content.environment(\.scenePhase, recorder.phase) }
}

/// Reads both environment objects and the entitlement where a child of the root would, and records every change.
@available(iOS 17, macOS 14, *)
private struct ProviderProbe: View {
    @ObservedObject var recorder: Recorder
    @EnvironmentObject private var provider: PaywallServiceProvider
    @EnvironmentObject private var paywall: Paywall
    @Environment(\.paywallEntitlement) private var entitlement

    var body: some View {
        Text(provider.service.name)
            .onAppear { record() }
            .onChange(of: provider.service.name) { _, _ in record() }
            .onChange(of: entitlement) { _, _ in record() }
    }

    private func record() {
        recorder.names.append(provider.service.name)
        recorder.entitlements.append(entitlement)
        recorder.facades.append(ObjectIdentifier(paywall))
    }
}

@Suite("Service provider", .serialized)
@MainActor
struct ServiceProviderTests {
    @Test func a_provider_configures_its_facade_before_the_first_frame() async {
        let paywall = Paywall()
        let lifetime = StoreTransaction.lifetime(id: 3, productID: "pro.lifetime", purchased: Date())
        let provider = PaywallServiceProvider(
            .fake(fakeBacked(store: FakeStore(entitlements: [lifetime], products: products))), paywall: paywall)
        #expect(paywall.engine != nil, "configured synchronously: the journal is open and the wallet known at once")
        #expect(paywall.provider === provider)
        #expect(provider.paywall === paywall)
        #expect(provider.isFake)
        #expect(provider.service.isFake)
        #expect(provider.service.name == "fake")
        await paywall.waitUntilStarted()
        #expect(paywall.entitlement == .lifetime(.purchase(transactionID: 3)))
    }

    @Test func production_is_the_other_implementation() async {
        let paywall = Paywall()
        let provider = PaywallServiceProvider(.production(fakeBacked()), paywall: paywall)
        #expect(!provider.isFake)
        #expect(!provider.service.isFake)
        #expect(provider.service.name == "production")
        #expect(provider.service.configuration.catalog == catalog)
        await paywall.waitUntilStarted()
        #expect(paywall.entitlement == .free)
    }

    @Test func use_switches_implementation_and_rebuilds_the_engine() async {
        let paywall = Paywall()
        let provider = PaywallServiceProvider(.production(fakeBacked()), paywall: paywall)
        await paywall.waitUntilStarted()
        let first = paywall.engine
        var changes = 0
        let subscription = provider.objectWillChange.sink { _ in changes += 1 }
        let lifetime = StoreTransaction.lifetime(id: 9, productID: "pro.lifetime", purchased: Date())
        provider.use(.fake(fakeBacked(store: FakeStore(entitlements: [lifetime], products: products))))
        #expect(provider.isFake)
        #expect(changes >= 1)
        #expect(paywall.engine != nil)
        #expect(paywall.engine !== first, "configure again: the previous engine is torn down")
        await paywall.waitUntilStarted()
        #expect(paywall.entitlement == .lifetime(.purchase(transactionID: 9)))
        subscription.cancel()
    }

    @Test func facade_changes_reach_observers_of_the_provider() async {
        let paywall = Paywall()
        let provider = PaywallServiceProvider(.fake(fakeBacked()), paywall: paywall)
        await paywall.waitUntilStarted()
        var changes = 0
        let subscription = provider.objectWillChange.sink { _ in changes += 1 }
        paywall.grant(tokens: 3, reason: "test")
        #expect(changes >= 1, "a view observing the provider alone re-renders on a wallet change")
        #expect(paywall.wallet.balance == 3)
        subscription.cancel()
    }

    @Test func the_facade_holds_its_provider_weakly() async {
        let paywall = Paywall()
        var provider: PaywallServiceProvider? = PaywallServiceProvider(.fake(fakeBacked()), paywall: paywall)
        await paywall.waitUntilStarted()
        #expect(paywall.provider === provider)
        provider = nil
        #expect(paywall.provider == nil)
    }

    // MARK: Use methods

    @Test func use_methods_chain_and_useProduction_returns_to_the_last_production_configuration() async {
        let paywall = Paywall()
        let production = fakeBacked(welcomeTokens: 7)
        let provider = PaywallServiceProvider(.production(production), paywall: paywall)
        await paywall.waitUntilStarted()
        #expect(provider.productionConfiguration?.welcomeTokens == 7)
        #expect(paywall.wallet.balance == 7)

        let lifetime = StoreTransaction.lifetime(id: 4, productID: "pro.lifetime", purchased: Date())
        let chained = provider.useFake(fakeBacked(store: FakeStore(entitlements: [lifetime], products: products)))
        #expect(chained === provider)
        #expect(provider.isFake)
        await paywall.waitUntilStarted()
        #expect(paywall.entitlement == .lifetime(.purchase(transactionID: 4)))
        #expect(paywall.wallet.balance == 0)
        #expect(provider.productionConfiguration?.welcomeTokens == 7, "a fake does not replace the remembered production configuration")

        #expect(provider.useProduction() === provider)
        #expect(!provider.isFake)
        await paywall.waitUntilStarted()
        #expect(paywall.configuration?.welcomeTokens == 7)
        #expect(paywall.wallet.balance == 7, "the same journal as before the fake")
        #expect(paywall.entitlement == .free)
    }

    @Test func useProduction_with_a_configuration_replaces_the_remembered_one() async {
        let paywall = Paywall()
        let provider = PaywallServiceProvider(.production(fakeBacked(welcomeTokens: 1)), paywall: paywall)
        await paywall.waitUntilStarted()
        #expect(provider.useProduction(fakeBacked(welcomeTokens: 2)) === provider)
        await paywall.waitUntilStarted()
        #expect(!provider.isFake)
        #expect(provider.productionConfiguration?.welcomeTokens == 2)
        #expect(paywall.configuration?.welcomeTokens == 2)
    }

    @Test func useProduction_without_a_production_configuration_keeps_the_fake() async {
        let paywall = Paywall()
        let provider = PaywallServiceProvider(.fake(fakeBacked()), paywall: paywall)
        await paywall.waitUntilStarted()
        let engine = paywall.engine
        #expect(provider.productionConfiguration == nil)
        #expect(provider.useProduction() === provider)
        #expect(provider.isFake)
        #expect(paywall.engine === engine, "nothing to return to: the facade is not configured again")
    }

    // MARK: Environment

    @available(iOS 17, macOS 14, *)
    @Test func paywall_provider_injects_the_provider_the_facade_and_the_entitlement() async {
        let paywall = Paywall()
        let lifetime = StoreTransaction.lifetime(id: 5, productID: "pro.lifetime", purchased: Date())
        let provider = PaywallServiceProvider(
            .fake(fakeBacked(store: FakeStore(entitlements: [lifetime], products: products))), paywall: paywall)
        let recorder = Recorder()
        let window = show(ProviderProbe(recorder: recorder).paywallProvider(provider))
        defer { dismiss(window) }
        await paywall.waitUntilStarted()
        await pump(window)
        #expect(recorder.names.first == "fake", "\(recorder.names)")
        #expect(!recorder.facades.isEmpty)
        #expect(recorder.facades.allSatisfy { $0 == ObjectIdentifier(paywall) })
        #expect(recorder.entitlements.last == .lifetime(.purchase(transactionID: 5)), "\(recorder.entitlements)")

        provider.use(.production(fakeBacked()))
        await paywall.waitUntilStarted()
        await pump(window)
        #expect(recorder.names.last == "production", "\(recorder.names)")
        #expect(recorder.entitlements.last == .free, "\(recorder.entitlements)")
    }

    @Test func paywall_provider_refreshes_the_entitlement_when_the_scene_becomes_active() async {
        let paywall = Paywall()
        let store = FakeStore(products: products)
        let provider = PaywallServiceProvider(.fake(fakeBacked(store: store)), paywall: paywall)
        let recorder = Recorder()
        let window = show(PhaseHost(recorder: recorder, content: Text("root").paywallProvider(provider)))
        defer { dismiss(window) }
        await paywall.waitUntilStarted()
        await pump(window)
        #expect(!paywall.entitlement.isPaying)
        await store.setEntitlements([.lifetime(id: 1, productID: "pro.lifetime", purchased: Date())])
        recorder.phase = .active
        for _ in 0..<50 where !paywall.entitlement.isPaying { await pump(window) }
        #expect(paywall.entitlement.isPaying)
    }

    #if canImport(UIKit) && !os(watchOS)
        /// The contract under UIKit layers: a `PaywallHostingController` puts the provider back, next to the facade
        /// and the entitlement it already re-injected.
        @available(iOS 17, *)
        @Test func a_hosting_controller_reinjects_the_provider() async {
            let paywall = Paywall()
            let provider = PaywallServiceProvider(.fake(fakeBacked()), paywall: paywall)
            await paywall.waitUntilStarted()
            let recorder = Recorder()
            let controller = Paywall.$override.withValue(paywall) {
                PaywallHostingController(rootView: ProviderProbe(recorder: recorder))
            }
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer { dismiss(window) }
            await pump(window)
            #expect(recorder.names.first == "fake", "\(recorder.names)")
            #expect(recorder.facades.first == ObjectIdentifier(paywall))
            #expect(recorder.entitlements.first == .free, "\(recorder.entitlements)")
        }

        /// A facade configured without a provider: the hosted root still gets the facade, and nothing to re-inject.
        @Test func a_hosting_controller_without_a_provider_still_injects_the_facade() async {
            let (paywall, _, _) = await makePaywall()
            let recorder = Recorder()
            struct FacadeProbe: View {
                @ObservedObject var recorder: Recorder
                @EnvironmentObject private var paywall: Paywall
                var body: some View {
                    Text("probe").onAppear { recorder.facades.append(ObjectIdentifier(paywall)) }
                }
            }
            let controller = Paywall.$override.withValue(paywall) {
                PaywallHostingController(rootView: FacadeProbe(recorder: recorder))
            }
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer { dismiss(window) }
            await pump(window)
            #expect(recorder.facades == [ObjectIdentifier(paywall)])
            #expect(paywall.provider == nil)
        }
    #endif
}
