public import Combine
public import Foundation
public import PaywallCore
import Logging

/// The facade: configured once at launch, then the one thing views, `withPaywall`, the routing gate and UIKit
/// code talk to. Main-actor state, like `ZNavigator`.
@MainActor
public final class Paywall: ObservableObject {
    public static let shared = Paywall()

    /// Lets a test run `withPaywall` against its own facade without touching `shared`.
    @TaskLocal static var override: Paywall?

    /// The facade the free functions and sessions talk to: `shared`, unless a test overrode it.
    static var active: Paywall { override ?? shared }

    @MainActor
    public struct Configuration {
        /// Group id, weekly/monthly/yearly/lifetime ids, token packs.
        public var catalog: ProductCatalog
        /// `S`: the lease window after a token draw.
        public var tolerance: TimeInterval = 300
        public var leasePolicy: LeasePolicy = .fixedFromDraw
        /// Tokens a new account gets once to try the app, as the ledger grant `grant:welcome`, at the value of the
        /// build that writes it: a later build with another value leaves existing users with what their first build
        /// granted, less what they spent. Written at the first launch, or once the carrier has answered when `sync`
        /// is set, so a new device of an existing account takes the account's grant. `0` grants nothing.
        public var welcomeTokens = 100
        /// Prices and offers are fetched again at launch and foreground when the last fetch is older than this; a
        /// purchase or a restore fetches at once.
        public var storefrontRefreshInterval: TimeInterval = 3_600
        /// Last paid build, paid window, sentinel, grant.
        public var grandfathering: GrandfatheringPolicy?
        /// What another family member's subscription or lifetime purchase is worth on this account. Applied at
        /// every resolution and to the cached snapshot, so a build that changes it takes effect at its first launch.
        /// Tokens never cross family members whatever the value: the account key is per Apple Account.
        public var familySharing: FamilySharingPolicy = .sharedEntitlements
        /// Extra sinks (analytics). The local journal and OSLog are added unless `includesDefaultAudit` is false.
        public var audit: [any PaywallAuditSink] = []
        public var includesDefaultAudit = true
        /// CloudKit, your server, or nil.
        public var sync: (any LedgerSync)?
        /// The outbox drains only while a network path exists, and at once when one returns.
        public var connectivity: (any PaywallConnectivity)? = NetworkPathConnectivity()
        /// Injectable for tests and the simulator.
        public var clock: any PaywallClock = SystemClock()
        public var store: any StoreClient = StoreKit2Client()
        /// Signs promotional offers on your server, where the In-App Purchase key lives: a `RemotePromotionalOfferSigner`
        /// pointed at the worker in `Workers/PromotionalOfferSigner`. With `nil`, the default, `purchase(_:promotionalOffer:)`
        /// fails with `PromotionalOfferError.signerNotConfigured`; plain purchases are unaffected.
        public var promotionalOfferSigner: (any PromotionalOfferSigner)?
        /// Where the journal lives. Default: Application Support/ztron.paywall.
        public var storageDirectory: URL?
        /// Authenticates the caches next to the journal (`app-transaction.json`, `entitlement.json`) with a key that
        /// never leaves this install, so an edited container or a restored backup cannot plant a paying entitlement.
        /// The default keeps the key in the Keychain (this device only, after first unlock); tests pass
        /// `InMemoryFileKeyStore`. `nil` leaves the files plain and trusted, which no shipping app should want.
        public var fileKeyStore: (any PaywallFileKeyStore)? = KeychainFileKeyStore()
        /// Written into every audit record instead of the store environment (`"simulated"`).
        public var environmentLabel: String?
        /// `F_FULLFSYNC` on the draw path (default) or `fsync` only.
        public var fullSync = true
        /// Progressive adoption: `true` switches the whole mechanism off. Nothing starts (no engine, journal,
        /// store call, sync or audit), every gate passes as `.free`, `purchase(_:)` answers
        /// `.purchased(transactionID: 0)` without a payment, `products()` is empty and nothing is published.
        /// `false`, the default, is the product. Flip it by calling `configure` again.
        public var passthrough = false
        /// Posts every event to this center for the facade's lifetime (see `bridgeToNotificationCenter`), so
        /// `NotificationCenter` code can observe `.paywallDenied`, `.paywallPurchaseCompleted` and the other names.
        public var notificationCenter: NotificationCenter?
        /// Runs once the launch resolution finished (the simulator seeds its switches here).
        public var onStart: (@MainActor (GateEngine) async -> Void)?
        #if DEBUG
            /// Debug builds only: the debug-menu override for testing grandfathering on a device.
            public var grandfatherOverride: GrandfatherOverride?
        #endif

        public init(catalog: ProductCatalog) {
            self.catalog = catalog
        }

        public static var defaultStorageDirectory: URL { let base: URL; if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first { base = support } else { base = FileManager.default.temporaryDirectory }; return base.appendingPathComponent("ztron.paywall", isDirectory: true) }
    }

    public enum ConfigurationError: Error, Hashable, Sendable {
        case invalidCatalog([ProductCatalog.Problem])
        case journalUnavailable(JournalError)
    }

    // MARK: Published state

    @Published public private(set) var entitlement: Entitlement = .unknown
    @Published public private(set) var wallet: Wallet = .empty
    /// What the App Store sells right now, with prices and offers: the last fetch, from this launch or from disk,
    /// `nil` until the first one ever answers. `refreshStorefront()` fetches now.
    @Published public private(set) var storefront: PaywallStorefront?
    /// Where the user stands, from `entitlement` and `wallet`; `nil` while the entitlement is unknown.
    @Published public private(set) var tier: AccessTier?
    /// Drives `.paywallSheet`. Set at the end of the run-loop turn for a denial nobody claimed.
    @Published public var pendingFailure: PaywallFailure?
    /// The `.paywallSheet` presenters installed right now, weakly, for the one-presenter rule.
    var sheetPresenters = NSHashTable<PaywallPresenterAnchor>.weakObjects()
    /// Fires when a presenter arrives, goes, or enters or leaves a window, so the others re-decide.
    let presenterChanges = PassthroughSubject<Void, Never>()
    /// While a denial is pending and no presenter could take it (a plain sheet is up), nudges them regularly.
    private var nudgeTask: Task<Void, Never>?
    /// The product id of a promoted in-app purchase the user tapped on the App Store (`PurchaseIntent`), until the
    /// host consumes it or starts buying it. The paywall screen opens on this product.
    @Published public private(set) var pendingPurchaseIntent: String?
    /// The last configuration problem; the facade fails closed meanwhile.
    @Published public private(set) var configurationError: ConfigurationError?
    /// `true` while `Configuration.passthrough` keeps the mechanism off: no engine, every gate passes, every
    /// purchase succeeds without a payment, nothing is published. `entitlement` stays `.unknown` and `wallet`
    /// `.empty` meanwhile, so an account screen branches on this rather than on them.
    @Published public private(set) var isPassthrough = false

    public private(set) var engine: GateEngine?
    public private(set) var configuration: Configuration?
    /// The `.paywallGated` views on screen, as the facade knows them: a reconfigure reopens each on the new engine
    /// (or in the new mode) and delivers its new decision, so no view keeps a dead engine's decision.
    struct LiveSession {
        var level: GateLevel
        var policy: TokenPolicy
        var source: PaywallSource
        var scope: String?
        var onChange: (GateSessionState) -> Void
        var state: GateSessionState
    }
    var liveSessions: [UUID: LiveSession] = [:]
    /// The `PaywallServiceProvider` that configured this facade, when the app installed one at its root; `nil` for a
    /// facade configured directly. `PaywallHostingController` re-injects it under UIKit layers.
    public internal(set) weak var provider: PaywallServiceProvider?
    private let subject = PassthroughSubject<PaywallEvent, Never>()
    private var streams: [UUID: AsyncStream<PaywallEvent>.Continuation] = [:]
    private var startTask: Task<Void, Never>?
    private var fallbackTasks: [UUID: Task<Void, Never>] = [:]
    private var notificationBridge: AnyCancellable?
    private let logger = Logger(label: "ztron.paywall.facade")

    /// Internal so tests can build isolated facades; apps use `shared`.
    init() {}

    // MARK: Configuration

    /// Call once from `App.init`. Opens the journal synchronously (the wallet is known before the first frame),
    /// then resolves the entitlement and starts the `Transaction.updates` listener. Calling it again tears the
    /// previous engine down first.
    public func configure(_ configuration: Configuration) {
        let previous = engine
        teardown()
        let problems = configuration.catalog.validate()
        if configuration.passthrough {
            // Progressive adoption: nothing starts and nothing fails closed. A catalog problem is only logged.
            if !problems.isEmpty {
                logger.warning("paywall: passthrough with an invalid catalog", metadata: ["problems": "\(problems)"])
            }
            logger.notice("paywall: passthrough, the mechanism is off")
            configurationError = nil
            self.configuration = configuration
            isPassthrough = true
            reopenLiveSessions()
            return
        }
        guard problems.isEmpty else {
            logger.error("paywall: invalid catalog", metadata: ["problems": "\(problems)"])
            configurationError = .invalidCatalog(problems)
            reopenLiveSessions()
            return
        }
        let directory = configuration.storageDirectory ?? Configuration.defaultStorageDirectory
        var sinks = configuration.audit
        if configuration.includesDefaultAudit {
            sinks.insert(JournalSink(directory: directory), at: 0)
            sinks.append(OSLogSink())
        }
        let info = Bundle.main.infoDictionary
        let base = GateEngine.Settings(
            tolerance: configuration.tolerance,
            leasePolicy: configuration.leasePolicy,
            familySharing: configuration.familySharing,
            environmentLabel: configuration.environmentLabel,
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "0",
            build: info?["CFBundleVersion"] as? String ?? "0",
            fullSync: configuration.fullSync,
            welcomeTokens: configuration.welcomeTokens,
            storefrontRefreshInterval: configuration.storefrontRefreshInterval,
            bundleID: Bundle.main.bundleIdentifier
        )
        #if DEBUG
            let settings = base.with(grandfatherOverride: configuration.grandfatherOverride)
        #else
            let settings = base
        #endif
        let engine: GateEngine
        do {
            engine = try GateEngine(
                directory: directory, catalog: configuration.catalog, grandfathering: configuration.grandfathering,
                settings: settings, clock: configuration.clock, store: configuration.store,
                promotionalOfferSigner: configuration.promotionalOfferSigner, sync: configuration.sync,
                connectivity: configuration.connectivity,
                audit: sinks, fileKeyStore: configuration.fileKeyStore)
        } catch {
            logger.error("paywall: journal unavailable", metadata: ["error": "\(error)"])
            configurationError = .journalUnavailable(error)
            reopenLiveSessions()
            return
        }
        configurationError = nil
        self.configuration = configuration
        self.engine = engine
        engine.onEvent = { [weak self] event in self?.publish(event) }
        engine.onStateChange = { [weak self] in self?.mirror() }
        // A purchase that completes on an engine this facade has since replaced goes to whichever engine is current.
        engine.onOrphanedPurchase = { [weak self] transaction, source in
            guard let self, let current = self.engine else { return false }
            return await current.adoptPurchase(transaction, source: source)
        }
        if let center = configuration.notificationCenter { notificationBridge = bridgeToNotificationCenter(center) }
        mirror()
        let onStart = configuration.onStart
        startTask = Task { [weak self] in
            // The predecessor's audit records land before the successor reads where the chain ends.
            await previous?.flushAudit()
            await engine.start()
            if let self, self.engine === engine { self.reopenLiveSessions() }
            await onStart?(engine)
        }
    }

    /// Every `.paywallGated` view still on screen is decided again by the engine (or the mode) in effect now, and told.
    /// A view that was open through a lease it held on the old engine is pinned first: what the user paid for stays,
    /// and nothing draws a second time.
    private func reopenLiveSessions() {
        for (holder, live) in liveSessions {
            let state: GateSessionState
            if let engine {
                if case .open(let mode) = live.state.decision, Self.holdsLease(mode) { engine.leases.pin(live.source.id, holder: holder) }
                state = engine.openSession(
                    holder: holder, level: live.level, policy: live.policy, source: live.source, scope: live.scope,
                    onChange: tracking(holder, live.onChange))
            } else {
                state = fixedSessionState(holder: holder, level: live.level, source: live.source, scope: live.scope)
            }
            liveSessions[holder]?.state = state
            live.onChange(state)
        }
    }

    private static func holdsLease(_ mode: GateOpenMode) -> Bool {
        switch mode {
        case .leased, .drawn: return true
        case .free, .paying, .reserved, .affordable: return false
        }
    }

    /// Waits until the launch resolution finished. Useful in tests and UI tests.
    public func waitUntilStarted() async {
        await startTask?.value
    }

    private func teardown() {
        startTask?.cancel()
        startTask = nil
        // `shutdown()` drops the old engine's view sessions; the facade reopens the live ones on the successor.
        // `onOrphanedPurchase` stays: it reads the engine current at the time a late purchase lands.
        engine?.shutdown()
        engine?.onEvent = nil
        engine?.onStateChange = nil
        engine = nil
        for task in fallbackTasks.values { task.cancel() }
        fallbackTasks = [:]
        notificationBridge = nil
        if isPassthrough { isPassthrough = false }
        nudgeTask?.cancel()
        nudgeTask = nil
        pendingFailure = nil
        pendingPurchaseIntent = nil
        mirror()
    }

    private func mirror() {
        guard let engine else {
            if entitlement != .unknown { entitlement = .unknown }
            if wallet != .empty { wallet = .empty }
            if storefront != nil { storefront = nil }
            if tier != nil { tier = nil }
            return
        }
        if entitlement != engine.entitlement { entitlement = engine.entitlement }
        if wallet != engine.wallet { wallet = engine.wallet }
        if storefront != engine.storefront { storefront = engine.storefront }
        if tier != engine.tier { tier = engine.tier }
    }

    // MARK: Events

    /// Every decision, once. Combine subjects are not `Sendable`, so this stays on the main actor.
    public var events: AnyPublisher<PaywallEvent, Never> { subject.eraseToAnyPublisher() }

    /// Every decision, once, for any isolation. Each access returns a new stream.
    public var eventStream: AsyncStream<PaywallEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<PaywallEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.streams[id] = nil }
        }
        streams[id] = continuation
        return stream
    }

    func publish(_ event: PaywallEvent) {
        switch event {
        case .purchaseIntent(let productID):
            pendingPurchaseIntent = productID
        case .purchase(.started, let productID, _, _) where productID == pendingPurchaseIntent:
            // The paywall opened on the promoted product and the user is buying it: the intent is served.
            pendingPurchaseIntent = nil
        default:
            break
        }
        subject.send(event)
        for continuation in streams.values { continuation.yield(event) }
        if case .gateDenied(let failure) = event { scheduleFallback(failure) }
    }

    /// Claim-then-fallback: handlers run synchronously inside `publish`; whatever is still unclaimed when this
    /// main-actor task runs (the end of the current turn) becomes `pendingFailure`.
    private func scheduleFallback(_ failure: PaywallFailure) {
        let id = failure.id
        fallbackTasks[id] = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            if !failure.isClaimed, self.pendingFailure == nil {
                self.pendingFailure = failure
                self.nudgePresenters()
            }
            failure.forgetClaim()
            self.fallbackTasks[id] = nil
        }
    }

    /// Every quarter second while the denial stays pending, asks the presenters again: the one that could not
    /// present (its root was showing a plain sheet) takes it once that sheet is gone.
    private func nudgePresenters() {
        nudgeTask?.cancel()
        nudgeTask = Task { @MainActor [weak self] in
            while let self, self.pendingFailure != nil, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                self.presenterChanges.send()
            }
        }
    }

    /// Lets the presenter that can show the pending failure take it, so two installed sheets cannot both show it.
    public func consumePendingFailure() -> PaywallFailure? {
        defer {
            pendingFailure = nil
            nudgeTask?.cancel()
            nudgeTask = nil
        }
        return pendingFailure
    }

    /// Takes the promoted product the host is about to show, so nothing else presents it too.
    public func consumePendingPurchaseIntent() -> String? {
        defer { pendingPurchaseIntent = nil }
        return pendingPurchaseIntent
    }

    // MARK: Gates

    private func unconfiguredFailure(_ level: GateLevel, source: PaywallSource, scope: String?) -> PaywallFailure {
        PaywallFailure(reason: .entitlementUnavailable, level: level, source: source, at: Date(), scope: scope)
    }

    /// Pure read: no draw, no lease, no log.
    public func canPass(_ level: GateLevel, id: String? = nil) -> Bool {
        // No engine: unconfigured or failed, closed except `.free`; in passthrough, every level is `.free`.
        guard let engine else { return level == .free || isPassthrough }
        return engine.canPass(level, gateID: id)
    }

    /// Logs and publishes, never draws. The routing gate's pre-navigation check.
    public func evaluate(
        _ level: GateLevel, id: String, fileID: String = #fileID, function: String = #function, line: Int = #line
    ) -> PaywallOutcome<Void> {
        let source = PaywallSource(id: id, fileID: fileID, function: function, line: line)
        guard let engine else {
            if level == .free || isPassthrough { return .executed(()) }
            let failure = unconfiguredFailure(level, source: source, scope: nil)
            publish(.gateDenied(failure))
            return .blocked(failure)
        }
        return engine.evaluate(level, source: source)
    }

    func run<R>(
        _ level: GateLevel, source: PaywallSource, scope: String?, holder: UUID?, _ body: () throws -> R
    ) rethrows -> PaywallOutcome<R> {
        guard let engine else {
            if level == .free || isPassthrough { return .executed(try body()) }
            let failure = unconfiguredFailure(level, source: source, scope: scope)
            publish(.gateDenied(failure))
            return .blocked(failure)
        }
        return try engine.run(level, source: source, scope: scope, holder: holder, body)
    }

    static func begin(_ level: GateLevel, source: PaywallSource, scope: String?, holder: UUID?) -> GateBegin {
        let paywall = Paywall.active
        guard let engine = paywall.engine else {
            if level == .free || paywall.isPassthrough {
                return .open(GateTicket(level: level, source: source, mode: .free, debitID: nil, tokens: 0, leaseUntil: nil, holder: nil))
            }
            let failure = paywall.unconfiguredFailure(level, source: source, scope: scope)
            paywall.publish(.gateDenied(failure))
            return .blocked(failure)
        }
        return engine.begin(level, source: source, scope: scope, holder: holder)
    }

    static func complete(_ ticket: GateTicket) { Paywall.active.engine?.complete(ticket) }
    static func abort(_ ticket: GateTicket, error: any Error) { Paywall.active.engine?.abort(ticket, error: error) }

    // MARK: Sessions

    func openSession(
        holder: UUID, level: GateLevel, policy: TokenPolicy, source: PaywallSource, scope: String?,
        onChange: @escaping (GateSessionState) -> Void
    ) -> GateSessionState {
        let state: GateSessionState
        if let engine {
            state = engine.openSession(
                holder: holder, level: level, policy: policy, source: source, scope: scope, onChange: tracking(holder, onChange))
        } else {
            state = fixedSessionState(holder: holder, level: level, source: source, scope: scope)
        }
        liveSessions[holder] = LiveSession(level: level, policy: policy, source: source, scope: scope, onChange: onChange, state: state)
        return state
    }

    /// With no engine: open as `.free` in passthrough (and for `.free`), closed otherwise.
    private func fixedSessionState(holder: UUID, level: GateLevel, source: PaywallSource, scope: String?) -> GateSessionState {
        if level == .free || isPassthrough {
            return GateSessionState(holder: holder, level: level, source: source, scope: scope, decision: .open(.free))
        }
        let failure = unconfiguredFailure(level, source: source, scope: scope)
        publish(.gateDenied(failure))
        return GateSessionState(holder: holder, level: level, source: source, scope: scope, decision: .closed(failure.reason), failure: failure)
    }

    /// The engine's `onChange`, keeping the facade's copy of the view's state current on the way.
    private func tracking(_ holder: UUID, _ onChange: @escaping (GateSessionState) -> Void) -> (GateSessionState) -> Void {
        { [weak self] next in
            self?.liveSessions[holder]?.state = next
            onChange(next)
        }
    }

    func closeSession(holder: UUID) {
        liveSessions[holder] = nil
        engine?.closeSession(holder: holder)
    }

    // MARK: Store

    public func products() async throws -> [PaywallProduct] {
        if isPassthrough { return [] }
        guard let engine else { throw StoreClientError.notConfigured }
        return try await engine.products()
    }

    /// Fetches what the App Store sells right now, with prices and offers, publishes it as `storefront` and returns
    /// it. In passthrough, an empty storefront.
    public func refreshStorefront() async throws -> PaywallStorefront {
        if isPassthrough { return PaywallStorefront(products: [], fetchedAt: Date()) }
        guard let engine else { throw StoreClientError.notConfigured }
        return try await engine.refreshStorefront()
    }

    public func purchase(_ product: PaywallProduct, source: PaywallSource? = nil) async throws -> PurchaseOutcome {
        // Passthrough: "bought" without a payment, and 0 is no transaction.
        if isPassthrough { return .purchased(transactionID: 0) }
        guard let engine else { throw StoreClientError.notConfigured }
        return try await engine.purchase(productID: product.id, source: source)
    }

    /// Buys `product` with one of its promotional offers (`product.offers`, kind `.promotional`): asks
    /// `configuration.promotionalOfferSigner` for this install's signature, then purchases with it. Throws a
    /// `PromotionalOfferError` before the store is reached when no signer is configured, the offer is not a promotional
    /// one, or the signer answered for something else; `.purchase(stage: .failed)` is published either way. The outcome
    /// chains like a plain purchase's.
    public func purchase(_ product: PaywallProduct, promotionalOffer offer: PaywallProduct.Offer, source: PaywallSource? = nil)
        async throws -> PurchaseOutcome
    {
        if isPassthrough { return .purchased(transactionID: 0) }
        guard let engine else { throw StoreClientError.notConfigured }
        return try await engine.purchase(productID: product.id, offer: offer, source: source)
    }

    /// `AppStore.sync()`: can prompt for sign-in, so wire it to the Restore button only.
    public func restorePurchases() async throws {
        if isPassthrough { return }
        guard let engine else { throw StoreClientError.notConfigured }
        try await engine.restore()
    }

    /// Re-resolves the entitlement and reconciles the ledger.
    public func refresh() async {
        await engine?.refresh(cause: .foreground)
    }

    /// Call on every `scenePhase == .active` (`.paywallSheet` and `.paywallLifecycle()` do it for you).
    public func didBecomeActive() async {
        await engine?.didBecomeActive()
    }

    /// Renewal phase for the account screen. Goes to the App Store.
    public func subscriptionPhase() async throws -> SubscriptionPhase? {
        if isPassthrough { return nil }
        guard let engine else { throw StoreClientError.notConfigured }
        return try await engine.store.subscriptionPhase(groupID: engine.catalog.subscriptionGroupID)
    }

    public func isEligibleForIntroOffer() async -> Bool {
        guard let engine else { return false }
        return await engine.store.isEligibleForIntroOffer(groupID: engine.catalog.subscriptionGroupID)
    }

    /// Push the outbox and pull remote ledger events now. Call it from the CloudKit silent-push handler after
    /// `requestPull()` on the carrier.
    public func syncNow() async {
        await engine?.syncNow()
    }

    /// Welcome tokens or a support credit. A deterministic `id` makes it once per account.
    @discardableResult
    public func grant(tokens: Int, reason: String, id: String? = nil) -> Bool {
        engine?.grant(tokens: tokens, reason: reason, id: id) ?? false
    }
}
