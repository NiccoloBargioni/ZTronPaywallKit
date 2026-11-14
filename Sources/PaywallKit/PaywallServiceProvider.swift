public import Combine
public import SwiftUI

/// The root object of an app that runs the paywall on one of two implementations: production (StoreKit and the
/// real journal) or a fake (the same engine on a scripted store: the simulator's switches, or a `FakeStore` in a
/// test). Hold one as a `@StateObject` on the main page and install `.paywallProvider(_:)` there: every child then
/// finds the provider and the facade in the environment, and `PaywallHostingController` re-injects both under
/// UIKit layers.
///
/// It drives `Paywall.shared`, never a second facade: the free functions, `.paywallGated` and the UIKit bridge all
/// talk to the shared one, and two facades is how a claim gets lost. The `use` methods switch at runtime by
/// configuring the facade again, which tears the previous engine down first; they return the provider, so they chain.
@MainActor
public final class PaywallServiceProvider: ObservableObject {
    /// One implementation to run on. The fake is the production engine on a stand-in store (only the store, the
    /// clock, the sync carrier and the storage location differ), which is why both are a `Paywall.Configuration`.
    /// Debug builds get `.simulated(...)` and `.fromLaunchArguments(production:)` from `ZTronPaywallSimulator`.
    @MainActor
    public enum Service {
        case production(Paywall.Configuration)
        case fake(Paywall.Configuration)

        public var configuration: Paywall.Configuration {
            switch self {
            case .production(let configuration), .fake(let configuration): return configuration
            }
        }

        public var isFake: Bool {
            if case .fake = self { return true }
            return false
        }

        /// `"production"` or `"fake"`, for a badge or a log line.
        public var name: String { isFake ? "fake" : "production" }
    }

    /// The implementation in effect; the `use` methods change it.
    @Published public private(set) var service: Service
    /// The production configuration this provider saw last, from `init` or `useProduction(_:)`: what
    /// `useProduction()` returns to, and where the simulator's `useSimulated` takes the catalog and the grandfathering
    /// policy from. `nil` for a provider that only ever ran a fake.
    public private(set) var productionConfiguration: Paywall.Configuration?
    /// The facade this provider configures: `Paywall.shared` in an app.
    public let paywall: Paywall
    private var forwarding: AnyCancellable?

    /// Configures `Paywall.shared` with `service` at once, so the journal is open and the wallet known before the
    /// first frame, as `configure` from `App.init` would.
    public convenience init(_ service: Service) {
        self.init(service, paywall: .shared)
    }

    /// Internal so tests can build a provider on an isolated facade.
    init(_ service: Service, paywall: Paywall) {
        self.service = service
        self.paywall = paywall
        if case .production(let configuration) = service { productionConfiguration = configuration }
        paywall.provider = self
        paywall.configure(service.configuration)
        // A view that observes the provider alone still re-renders when the entitlement or the wallet changes.
        forwarding = paywall.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// Switches implementation: configures the facade again (the previous engine is torn down first) and publishes.
    @discardableResult
    public func use(_ service: Service) -> Self {
        if case .production(let configuration) = service { productionConfiguration = configuration }
        self.service = service
        paywall.configure(service.configuration)
        return self
    }

    /// `use(.production(configuration))`, and remembers the configuration for `useProduction()`.
    @discardableResult
    public func useProduction(_ configuration: Paywall.Configuration) -> Self {
        use(.production(configuration))
    }

    /// Back to the last production configuration this provider saw. A provider that never had one (built on a fake
    /// alone) has nothing to return to and stays as it is.
    @discardableResult
    public func useProduction() -> Self {
        guard let productionConfiguration else { return self }
        return use(.production(productionConfiguration))
    }

    /// `use(.fake(configuration))`.
    @discardableResult
    public func useFake(_ configuration: Paywall.Configuration) -> Self {
        use(.fake(configuration))
    }

    /// Whether the implementation in effect is the fake.
    public var isFake: Bool { service.isFake }
}

extension View {
    /// Installs `provider` on a root: the provider and its facade as environment objects, `\.paywallEntitlement`
    /// kept current, and the entitlement re-resolved whenever the scene becomes active (what `.paywallLifecycle()`
    /// does). `.paywallSheet` goes on the root as before, in either order.
    ///
    ///     @EnvironmentObject var paywall: Paywall                   // entitlement, wallet, purchase
    ///     @EnvironmentObject var provider: PaywallServiceProvider   // which implementation; the use methods switch
    public func paywallProvider(_ provider: PaywallServiceProvider) -> some View {
        modifier(PaywallProviderModifier(provider: provider))
    }
}

struct PaywallProviderModifier: ViewModifier {
    @ObservedObject var provider: PaywallServiceProvider

    func body(content: Content) -> some View {
        content
            .environmentObject(provider)
            .environmentObject(provider.paywall)
            .modifier(PaywallLifecycleModifier(paywall: provider.paywall))
    }
}
