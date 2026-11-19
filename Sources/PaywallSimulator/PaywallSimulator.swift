#if DEBUG
    public import Combine
    public import Foundation
    @_spi(PaywallSimulation) public import PaywallCore
    public import PaywallKit
    public import PaywallTesting
    public import SwiftUI

    /// The simulated store: the scriptable fake, driven by the simulator's switches.
    public typealias SimulatedStore = FakeStore
    /// The simulated clock: leases and subscriptions expire on `advance(by:)`, not on the wall clock.
    public typealias SimulatedClock = FakeClock

    /// Drives the production gates, ledger, leases and audit log from switches. Only the store, the clock, the
    /// sync carrier and the storage location are replaced; every audit record says `environment: "simulated"`, and
    /// the journal lives in a temporary directory, never next to the real one.
    @MainActor
    public final class PaywallSimulator: ObservableObject {
        public static let shared = PaywallSimulator()

        /// Every change re-resolves the engine at once.
        @Published public var simulation = PaywallSimulation() {
            didSet { if simulation != oldValue { schedule(from: oldValue) } }
        }

        public private(set) var store = SimulatedStore()
        public private(set) var clock = SimulatedClock(now: Date())
        public private(set) var sync = InMemoryLedgerSync()
        /// Follows the `network` switch.
        public private(set) var connectivity = FakeConnectivity()
        public private(set) var directory = PaywallSimulator.freshDirectory()
        public private(set) var catalog: ProductCatalog?
        public private(set) var grandfathering: GrandfatheringPolicy?
        private var applyTask: Task<Void, Never>?
        private var nextTransactionID: UInt64 = 10_000
        private var lastPackTransaction: StoreTransaction?

        init() {}

        static func freshDirectory() -> URL {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("ztron.paywall.simulated", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        }

        /// A policy that admits the simulated grandfathered install when the host configured none.
        static let simulatedPolicy = GrandfatheringPolicy(
            environments: [.xcode], lastPaidBuild: "1000000",
            paidWindow: DateInterval(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 4_000_000_000)))

        private var engine: GateEngine? { Paywall.shared.engine }

        // MARK: Configuration

        func makeConfiguration(_ simulation: PaywallSimulation, catalog: ProductCatalog, grandfathering: GrandfatheringPolicy?)
            -> Paywall.Configuration
        {
            applyTask?.cancel()
            store = SimulatedStore()
            clock = SimulatedClock(now: Date())
            sync = InMemoryLedgerSync()
            connectivity = FakeConnectivity(hasPath: simulation.network)
            directory = Self.freshDirectory()
            self.catalog = catalog
            self.grandfathering = grandfathering ?? Self.simulatedPolicy
            self.lastPackTransaction = nil
            self.simulation = simulation

            var configuration = Paywall.Configuration(catalog: catalog)
            configuration.store = store
            configuration.clock = clock
            configuration.sync = sync
            configuration.connectivity = connectivity
            configuration.storageDirectory = directory
            configuration.environmentLabel = "simulated"
            // A debug build takes a promotional offer without a server: the fake answers with a JWS-shaped token.
            configuration.promotionalOfferSigner = FakePromotionalOfferSigner()
            configuration.grandfathering = self.grandfathering
            configuration.tolerance = simulation.tolerance ?? configuration.tolerance
            configuration.includesDefaultAudit = true
            // A fresh key per simulated journal: nothing of the simulation touches the Keychain.
            configuration.fileKeyStore = InMemoryFileKeyStore()
            // The `tokens` switch is the balance: no welcome grant on top of it.
            configuration.welcomeTokens = 0
            let store = store
            let connectivity = connectivity
            let snapshot = storeState(for: simulation)
            configuration.onStart = { [weak self] engine in
                await self?.seed(engine)
            }
            // The store must hold the simulated state before the first resolution reads it.
            applyTask = Task { [weak self] in
                await Self.push(snapshot, to: store, connectivity: connectivity)
                // A store that never answers never lets `start()` finish, so `onStart` cannot seed: seed here.
                guard !simulation.storeReachable, let self, let engine = self.engine else { return }
                engine.simulateBalance(simulation.tokens)
                if let tolerance = simulation.tolerance { engine.settings.tolerance = tolerance }
                engine.simulateEntitlement(.unknown)
            }
            return configuration
        }

        /// Seeds the balance and the tolerance once the engine has started. A store that never answers never lets it
        /// start, so `applyTask` seeds that case itself (see `makeConfiguration`).
        private func seed(_ engine: GateEngine) async {
            await applyTask?.value
            engine.simulateBalance(simulation.tokens)
            if let tolerance = simulation.tolerance { engine.settings.tolerance = tolerance }
            await engine.refresh(cause: .simulation)
        }

        // MARK: Switches

        public func apply(_ preset: PaywallPreset) { simulation = preset.simulation }

        /// A revoked transaction arrives on the simulated `Transaction.updates`, as a real refund would.
        public func refund(_ what: SimulatedRefund) {
            let store = store
            let now = clock.now
            switch what {
            case .subscription:
                guard case .subscribed = simulation.entitlement else { return }
                setQuietly(\.entitlement, .free)
                Task { await store.refund(Self.subscriptionTransactionID, at: now) }
            case .lifetime:
                let id: UInt64
                switch simulation.entitlement {
                case .lifetime(.purchase(let purchased)), .lifetime(.familyShared(let purchased)): id = purchased
                default: return
                }
                setQuietly(\.entitlement, .free)
                Task { await store.refund(id, at: now) }
            case .lastTokenPack:
                guard let pack = lastPackTransaction else { return }
                lastPackTransaction = nil
                Task { await store.refund(pack.id, at: now) }
            }
        }

        /// Renews the current subscription for one more period (billing recovered, if it was in grace).
        public func renew() {
            guard case .subscribed(var subscription) = simulation.entitlement else { return }
            let base = max(subscription.expiresAt ?? clock.now, clock.now)
            subscription.expiresAt = base.addingTimeInterval(TimeInterval(subscription.tier.periodInDays) * 86_400)
            subscription.isTrial = false
            subscription.phase = .active
            subscription.gracePeriodEndsAt = nil
            simulation.entitlement = .subscribed(subscription)
        }

        /// The subscription lapses now: the expiry timer flips visible views.
        public func expire() {
            guard case .subscribed = simulation.entitlement else { return }
            simulation.entitlement = .free
        }

        /// Billing failed at the renewal and the App Store grants a grace period: the store keeps listing the lapsed
        /// transaction (its expiration has passed) and reports the grace end, 16 days out, and access stays.
        public func enterGracePeriod() {
            guard case .subscribed(var subscription) = simulation.entitlement else { return }
            subscription.phase = .inGracePeriod
            subscription.expiresAt = clock.now.addingTimeInterval(-60)
            subscription.gracePeriodEndsAt = clock.now.addingTimeInterval(16 * 86_400)
            simulation.entitlement = .subscribed(subscription)
        }

        /// Billing retry without grace does not keep access (`currentEntitlements` drops it).
        public func enterBillingRetry() {
            guard case .subscribed = simulation.entitlement else { return }
            let store = store
            setQuietly(\.entitlement, .free)
            Task {
                await store.setPhase(.inBillingRetryPeriod)
                await store.setEntitlements([])
                await Paywall.shared.refresh()
            }
        }

        /// Buys a token pack in the simulated store, so `refund(.lastTokenPack)` has something to revoke.
        public func purchaseTokenPack(_ productID: String? = nil) {
            guard let pack = productID.flatMap({ catalog?.tokenPack(for: $0) }) ?? catalog?.tokenPacks.first else { return }
            nextTransactionID += 1
            let transaction = StoreTransaction.tokenPack(id: nextTransactionID, productID: pack.productID, purchased: clock.now)
            lastPackTransaction = transaction
            let store = store
            Task { await store.deliver(transaction) }
        }

        public func grantTokens(_ n: Int) { simulation.tokens += n }

        /// Moves the simulated clock: leases and subscriptions expire without waiting.
        public func advance(by seconds: TimeInterval) {
            clock.advance(by: seconds)
            Task { await Paywall.shared.refresh() }
        }

        /// Wipes the simulated journal and audit log and starts over with the current switches.
        public func reset() {
            guard let catalog else { return }
            Paywall.shared.configure(makeConfiguration(simulation, catalog: catalog, grandfathering: grandfathering))
        }

        // MARK: Applying

        private var quiet = false

        private func setQuietly<Value>(_ keyPath: WritableKeyPath<PaywallSimulation, Value>, _ value: Value) {
            quiet = true
            simulation[keyPath: keyPath] = value
            quiet = false
        }

        private func schedule(from old: PaywallSimulation) {
            guard !quiet else { return }
            let next = simulation
            let snapshot = storeState(for: next)
            let store = store
            let connectivity = connectivity
            let previous = applyTask
            applyTask = Task { [weak self] in
                await previous?.value
                await Self.push(snapshot, to: store, connectivity: connectivity)
                guard let self, let engine = self.engine else { return }
                if next.tokens != old.tokens || next.tokens != engine.wallet.balance { engine.simulateBalance(next.tokens) }
                if let tolerance = next.tolerance { engine.settings.tolerance = tolerance }
                if !next.storeReachable {
                    engine.simulateEntitlement(.unknown)
                } else {
                    await engine.refresh(cause: .simulation)
                }
            }
        }

        /// Waits until every switch flipped so far reached the engine.
        public func settle() async {
            await applyTask?.value
        }

        struct StoreState: Sendable {
            var entitlements: [StoreTransaction]
            var app: AppTransactionSnapshot?
            var reachable: Bool
            var network: Bool
            var next: FakeStore.NextPurchase
            var introEligible: Bool
            var phase: SubscriptionPhase?
            var graceEnd: Date?
            var products: [PaywallProduct]
        }

        static let subscriptionTransactionID: UInt64 = 2

        func storeState(for simulation: PaywallSimulation) -> StoreState {
            let now = clock.now
            var entitlements: [StoreTransaction] = []
            var app: AppTransactionSnapshot?
            var phase: SubscriptionPhase?
            var graceEnd: Date?
            switch simulation.entitlement {
            case .unknown, .free:
                break
            case .subscribed(let subscription):
                let productID = catalog?.subscriptions[subscription.tier] ?? subscription.productID
                var expires = subscription.expiresAt ?? now.addingTimeInterval(TimeInterval(subscription.tier.periodInDays) * 86_400)
                if subscription.phase == .inGracePeriod {
                    // What StoreKit shows during grace: the lapsed transaction stays listed, the grace end is in the
                    // renewal info.
                    expires = min(expires, now.addingTimeInterval(-60))
                    graceEnd = subscription.gracePeriodEndsAt ?? now.addingTimeInterval(16 * 86_400)
                }
                entitlements = [
                    .subscription(
                        id: Self.subscriptionTransactionID, productID: productID, purchased: now.addingTimeInterval(-60),
                        expires: expires, trial: subscription.isTrial)
                ]
                phase = subscription.phase
            case .lifetime(.purchase(let id)):
                entitlements = [.lifetime(id: id, productID: catalog?.lifetimeProductID ?? "pro.lifetime", purchased: now)]
            case .lifetime(.familyShared(let id)):
                entitlements = [.lifetime(id: id, productID: catalog?.lifetimeProductID ?? "pro.lifetime", purchased: now).familyShared()]
            case .lifetime(.grandfathered):
                let policy = grandfathering ?? Self.simulatedPolicy
                app = AppTransactionSnapshot(
                    bundleID: Bundle.main.bundleIdentifier ?? "simulated",
                    originalAppVersion: policy.lastPaidBuild,
                    originalPurchaseDate: policy.paidWindow.start.addingTimeInterval(policy.paidWindow.duration / 2),
                    environment: policy.environments.sorted { $0.rawValue < $1.rawValue }.first ?? .production,
                    origin: .simulated)
            }
            let next: FakeStore.NextPurchase
            switch simulation.purchaseOutcome {
            case .success: next = .succeed
            case .cancelled: next = .cancel
            case .pending: next = .pending
            case .failed: next = .fail
            }
            return StoreState(
                entitlements: entitlements, app: app, reachable: simulation.storeReachable, network: simulation.network,
                next: next, introEligible: simulation.introOfferEligible, phase: phase, graceEnd: graceEnd,
                products: Self.products(for: catalog, introEligible: simulation.introOfferEligible))
        }

        static func push(_ state: StoreState, to store: SimulatedStore, connectivity: FakeConnectivity) async {
            await connectivity.set(state.network)
            await store.setEntitlements(state.entitlements)
            await store.setApp(state.app)
            await store.setNetwork(state.network)
            await store.setNextPurchase(state.next)
            await store.setIntroEligible(state.introEligible)
            await store.setPhase(state.phase)
            await store.setGraceEnd(state.graceEnd)
            await store.setProducts(state.products)
            // Last: `true` releases the reads a store that was down held, and they read the state above.
            await store.setReachable(state.reachable)
        }

        /// Euro prices in cents: the display string and the exact figure behind it.
        static func money(_ cents: Int) -> (display: String, price: Decimal) {
            ("€\(cents / 100).\(String(format: "%02d", cents % 100))", Decimal(cents) / 100)
        }

        static func cents(for tier: SubscriptionTier) -> Int {
            switch tier {
            case .weekly: return 199
            case .monthly: return 499
            case .yearly: return 2_999
            }
        }

        /// The simulated storefront: every catalog product, priced in euros, each plan with a seven-day free trial
        /// the `introOfferEligible` switch decides the eligibility of.
        static func products(for catalog: ProductCatalog?, introEligible: Bool) -> [PaywallProduct] {
            guard let catalog else { return [] }
            var products: [PaywallProduct] = []
            for tier in SubscriptionTier.allCases {
                guard let id = catalog.subscriptions[tier] else { continue }
                let (display, price) = money(cents(for: tier))
                let trial = PaywallProduct.Offer(
                    kind: .introductory, paymentMode: .freeTrial, displayPrice: "€0.00", price: 0, periodDays: 7, isEligible: introEligible)
                products.append(
                    PaywallProduct(
                        id: id, kind: .subscription(tier), displayName: "Pro \(tier.rawValue.capitalized)", displayPrice: display,
                        price: price, currencyCode: "EUR", introOffer: introEligible ? .init(trialDays: 7) : nil, offers: [trial]))
            }
            if let lifetime = catalog.lifetimeProductID {
                let (display, price) = money(5_999)
                products.append(
                    PaywallProduct(id: lifetime, kind: .lifetime, displayName: "Pro Lifetime", displayPrice: display, price: price, currencyCode: "EUR"))
            }
            for pack in catalog.tokenPacks {
                let (display, price) = money(pack.tokens / 10 * 100 + 99)
                products.append(
                    PaywallProduct(
                        id: pack.productID, kind: .tokens(pack.tokens), displayName: "\(pack.tokens) tokens", displayPrice: display,
                        price: price, currencyCode: "EUR"))
            }
            return products
        }
    }

    extension Paywall.Configuration {
        /// A drop-in configuration driven by `PaywallSimulator.shared`. Debug builds only: in a release build this
        /// module and the fakes it drives (`ZTronPaywallTesting`) compile to nothing, and
        /// `Scripts/check-release-symbols.sh` checks that they did.
        public static func simulated(
            _ simulation: PaywallSimulation = PaywallSimulation(),
            catalog: ProductCatalog,
            grandfathering: GrandfatheringPolicy? = nil
        ) -> Paywall.Configuration {
            PaywallSimulator.shared.makeConfiguration(simulation, catalog: catalog, grandfathering: grandfathering)
        }

        /// The same, from launch arguments (UI tests). Problems are logged, never fatal.
        public static func simulated(
            _ arguments: PaywallLaunchArguments,
            catalog: ProductCatalog,
            grandfathering: GrandfatheringPolicy? = nil
        ) -> Paywall.Configuration {
            for problem in arguments.problems { print("ZTronPaywallSimulator: launch argument problem: \(problem)") }
            return simulated(arguments.simulation, catalog: catalog, grandfathering: grandfathering)
        }
    }

    extension ProductCatalog {
        /// A catalog for previews and the simulator when the host passes none.
        public static let simulatorDefault = ProductCatalog(
            subscriptionGroupID: "pro", weekly: "pro.weekly", monthly: "pro.monthly", yearly: "pro.yearly",
            lifetime: "pro.lifetime",
            tokenPacks: [TokenPack(productID: "tokens.10", tokens: 10), TokenPack(productID: "tokens.50", tokens: 50)])
    }

    extension View {
        /// For `#Preview`: configures `Paywall.shared` with `simulation` before the content first appears, through a
        /// `PaywallServiceProvider` the content finds in its environment as it would under the app's root, so
        /// `PaywallSimulation(.free)` renders the denied state and `PaywallSimulation(.lifetime)` the open one.
        public func paywallSimulation(_ simulation: PaywallSimulation, catalog: ProductCatalog = .simulatorDefault) -> some View {
            modifier(PaywallSimulationModifier(simulation: simulation, catalog: catalog))
        }
    }

    @MainActor
    final class PaywallPreviewHost: ObservableObject {
        /// The fake on the shared facade, installed on the preview as an app's root would.
        let provider: PaywallServiceProvider

        init(simulation: PaywallSimulation, catalog: ProductCatalog) {
            provider = PaywallServiceProvider(.simulated(simulation, catalog: catalog))
            // Seed synchronously so the first frame is right; the store resolution confirms it.
            if let engine = provider.paywall.engine {
                engine.simulateBalance(simulation.tokens)
                engine.simulateEntitlement(simulation.storeReachable ? simulation.entitlement : .unknown)
            }
        }
    }

    struct PaywallSimulationModifier: ViewModifier {
        @StateObject private var host: PaywallPreviewHost

        init(simulation: PaywallSimulation, catalog: ProductCatalog) {
            _host = StateObject(wrappedValue: PaywallPreviewHost(simulation: simulation, catalog: catalog))
        }

        func body(content: Content) -> some View {
            content.paywallProvider(host.provider)
        }
    }
#endif
