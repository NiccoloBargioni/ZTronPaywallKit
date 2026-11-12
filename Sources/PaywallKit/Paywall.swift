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
        /// Last paid build, paid window, sentinel, grant.
        public var grandfathering: GrandfatheringPolicy?
        /// Extra sinks (analytics). The local journal and OSLog are added unless `includesDefaultAudit` is false.
        public var audit: [any PaywallAuditSink] = []
        public var includesDefaultAudit = true
        /// CloudKit, your server, or nil.
        public var sync: (any LedgerSync)?
        /// Injectable for tests and the simulator.
        public var clock: any PaywallClock = SystemClock()
        public var store: any StoreClient = StoreKit2Client()
        /// Where the journal lives. Default: Application Support/ztron.paywall.
        public var storageDirectory: URL?
        /// Written into every audit record instead of the store environment (`"simulated"`).
        public var environmentLabel: String?
        /// `F_FULLFSYNC` on the draw path (default) or `fsync` only.
        public var fullSync = true
        /// Runs once the launch resolution finished (the simulator seeds its switches here).
        public var onStart: (@MainActor (GateEngine) async -> Void)?

        public init(catalog: ProductCatalog) {
            self.catalog = catalog
        }

        public static var defaultStorageDirectory: URL {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            return base.appendingPathComponent("ztron.paywall", isDirectory: true)
        }
    }

    public enum ConfigurationError: Error, Hashable, Sendable {
        case invalidCatalog([ProductCatalog.Problem])
        case journalUnavailable(JournalError)
    }

    // MARK: Published state

    @Published public private(set) var entitlement: Entitlement = .unknown
    @Published public private(set) var wallet: Wallet = .empty
    /// Drives `.paywallSheet`. Set at the end of the run-loop turn for a denial nobody claimed.
    @Published public var pendingFailure: PaywallFailure?
    /// The last configuration problem; the facade fails closed meanwhile.
    @Published public private(set) var configurationError: ConfigurationError?

    public private(set) var engine: GateEngine?
    public private(set) var configuration: Configuration?
    private let subject = PassthroughSubject<PaywallEvent, Never>()
    private var streams: [UUID: AsyncStream<PaywallEvent>.Continuation] = [:]
    private var startTask: Task<Void, Never>?
    private var fallbackTasks: [UUID: Task<Void, Never>] = [:]
    private let logger = Logger(label: "ztron.paywall.facade")

    /// Internal so tests can build isolated facades; apps use `shared`.
    init() {}

    // MARK: Configuration

    /// Call once from `App.init`. Opens the journal synchronously (the wallet is known before the first frame),
    /// then resolves the entitlement and starts the `Transaction.updates` listener. Calling it again tears the
    /// previous engine down first.
    public func configure(_ configuration: Configuration) {
        teardown()
        let problems = configuration.catalog.validate()
        guard problems.isEmpty else {
            logger.error("paywall: invalid catalog", metadata: ["problems": "\(problems)"])
            configurationError = .invalidCatalog(problems)
            return
        }
        let directory = configuration.storageDirectory ?? Configuration.defaultStorageDirectory
        var sinks = configuration.audit
        if configuration.includesDefaultAudit {
            sinks.insert(JournalSink(directory: directory), at: 0)
            sinks.append(OSLogSink())
        }
        let info = Bundle.main.infoDictionary
        let settings = GateEngine.Settings(
            tolerance: configuration.tolerance,
            leasePolicy: configuration.leasePolicy,
            environmentLabel: configuration.environmentLabel,
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "0",
            build: info?["CFBundleVersion"] as? String ?? "0",
            fullSync: configuration.fullSync
        )
        let engine: GateEngine
        do {
            engine = try GateEngine(
                directory: directory, catalog: configuration.catalog, grandfathering: configuration.grandfathering,
                settings: settings, clock: configuration.clock, store: configuration.store, sync: configuration.sync,
                audit: sinks)
        } catch {
            logger.error("paywall: journal unavailable", metadata: ["error": "\(error)"])
            configurationError = .journalUnavailable(error)
            return
        }
        configurationError = nil
        self.configuration = configuration
        self.engine = engine
        engine.onEvent = { [weak self] event in self?.publish(event) }
        engine.onStateChange = { [weak self] in self?.mirror() }
        mirror()
        let onStart = configuration.onStart
        startTask = Task {
            await engine.start()
            await onStart?(engine)
        }
    }

    /// Waits until the launch resolution finished. Useful in tests and UI tests.
    public func waitUntilStarted() async {
        await startTask?.value
    }

    private func teardown() {
        startTask?.cancel()
        startTask = nil
        engine?.shutdown()
        engine?.onEvent = nil
        engine?.onStateChange = nil
        engine = nil
        for task in fallbackTasks.values { task.cancel() }
        fallbackTasks = [:]
        pendingFailure = nil
        mirror()
    }

    private func mirror() {
        guard let engine else {
            if entitlement != .unknown { entitlement = .unknown }
            if wallet != .empty { wallet = .empty }
            return
        }
        if entitlement != engine.entitlement { entitlement = engine.entitlement }
        if wallet != engine.wallet { wallet = engine.wallet }
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
            if !failure.isClaimed, self.pendingFailure == nil { self.pendingFailure = failure }
            failure.forgetClaim()
            self.fallbackTasks[id] = nil
        }
    }

    /// Lets the first presenter take the pending failure, so two installed sheets cannot both show it.
    public func consumePendingFailure() -> PaywallFailure? {
        defer { pendingFailure = nil }
        return pendingFailure
    }

    // MARK: Gates

    private func unconfiguredFailure(_ level: GateLevel, source: PaywallSource, scope: String?) -> PaywallFailure {
        PaywallFailure(reason: .entitlementUnavailable, level: level, source: source, at: Date(), scope: scope)
    }

    /// Pure read: no draw, no lease, no log.
    public func canPass(_ level: GateLevel, id: String? = nil) -> Bool {
        guard let engine else { return level == .free }
        return engine.canPass(level, gateID: id)
    }

    /// Logs and publishes, never draws. The routing gate's pre-navigation check.
    public func evaluate(
        _ level: GateLevel, id: String, fileID: String = #fileID, function: String = #function, line: Int = #line
    ) -> PaywallOutcome<Void> {
        let source = PaywallSource(id: id, fileID: fileID, function: function, line: line)
        guard let engine else {
            if level == .free { return .executed(()) }
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
            if level == .free { return .executed(try body()) }
            let failure = unconfiguredFailure(level, source: source, scope: scope)
            publish(.gateDenied(failure))
            return .blocked(failure)
        }
        return try engine.run(level, source: source, scope: scope, holder: holder, body)
    }

    static func begin(_ level: GateLevel, source: PaywallSource, scope: String?, holder: UUID?) -> GateBegin {
        let paywall = Paywall.active
        guard let engine = paywall.engine else {
            if level == .free {
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
        guard let engine else {
            let decision: GateDecision = level == .free ? .open(.free) : .closed(.entitlementUnavailable)
            if case .closed = decision { publish(.gateDenied(unconfiguredFailure(level, source: source, scope: scope))) }
            return GateSessionState(holder: holder, level: level, source: source, scope: scope, decision: decision)
        }
        return engine.openSession(holder: holder, level: level, policy: policy, source: source, scope: scope, onChange: onChange)
    }

    func closeSession(holder: UUID) { engine?.closeSession(holder: holder) }

    // MARK: Store

    public func products() async throws -> [PaywallProduct] {
        guard let engine else { throw StoreClientError.notConfigured }
        return try await engine.products()
    }

    public func purchase(_ product: PaywallProduct, source: PaywallSource? = nil) async throws -> PurchaseOutcome {
        guard let engine else { throw StoreClientError.notConfigured }
        return try await engine.purchase(productID: product.id, source: source)
    }

    /// `AppStore.sync()`: can prompt for sign-in, so wire it to the Restore button only.
    public func restorePurchases() async throws {
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
