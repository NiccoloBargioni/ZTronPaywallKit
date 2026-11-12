public import Foundation
public import Logging

/// The live state of one gated view, as its modifier renders it.
public struct GateSessionState: Hashable, Sendable {
    public let holder: UUID
    public let level: GateLevel
    public let source: PaywallSource
    public let scope: String?
    public let decision: GateDecision

    public init(holder: UUID, level: GateLevel, source: PaywallSource, scope: String?, decision: GateDecision) {
        self.holder = holder
        self.level = level
        self.source = source
        self.scope = scope
        self.decision = decision
    }

    public var isOpen: Bool {
        if case .open = decision { return true }
        return false
    }

    public var failure: PaywallFailure? {
        guard case .closed(let reason) = decision else { return nil }
        return PaywallFailure(reason: reason, level: level, source: source, at: Date(), scope: scope)
    }
}

/// What `purchase` reports to the paywall screen.
public enum PurchaseOutcome: Hashable, Sendable {
    case purchased(transactionID: UInt64)
    /// Ask to Buy: credited or unlocked when the transaction arrives on `Transaction.updates`.
    case pending
    case cancelled
}

/// The one engine every entry point ends in. It reads the entitlement and the wallet, writes the journal and the
/// audit log, and publishes every decision once. Main-actor state, like `ZNavigator`, because the synchronous
/// `withPaywall` and SwiftUI read it synchronously.
@MainActor
public final class GateEngine {
    public struct Settings: Sendable {
        /// `S`: the lease window after a token draw.
        public var tolerance: TimeInterval
        public var leasePolicy: LeasePolicy
        /// Overrides the environment written to audit records (`"simulated"` from the simulator).
        public var environmentLabel: String?
        public var appVersion: String
        public var build: String
        /// `F_FULLFSYNC` on the draw path (default) or `fsync` only.
        public var fullSync: Bool
        public var compactionThreshold: Int
        /// The outbox drains at most once per interval.
        public var syncCoalescing: TimeInterval
        #if DEBUG
            /// Debug builds only: what the resolver sees as the original purchase. See `GrandfatherOverride`.
            public var grandfatherOverride: GrandfatherOverride?

            public func with(grandfatherOverride: GrandfatherOverride?) -> Settings {
                var copy = self
                copy.grandfatherOverride = grandfatherOverride
                return copy
            }
        #endif

        public init(
            tolerance: TimeInterval = 300,
            leasePolicy: LeasePolicy = .fixedFromDraw,
            environmentLabel: String? = nil,
            appVersion: String = "0",
            build: String = "0",
            fullSync: Bool = true,
            compactionThreshold: Int = 4096,
            syncCoalescing: TimeInterval = 30
        ) {
            self.tolerance = tolerance
            self.leasePolicy = leasePolicy
            self.environmentLabel = environmentLabel
            self.appVersion = appVersion
            self.build = build
            self.fullSync = fullSync
            self.compactionThreshold = compactionThreshold
            self.syncCoalescing = syncCoalescing
        }
    }

    struct Session {
        var level: GateLevel
        var policy: TokenPolicy
        var source: PaywallSource
        var scope: String?
        var committed = false
        var state: GateSessionState?
        var onChange: ((GateSessionState) -> Void)?
    }

    // MARK: Configuration

    public let directory: URL
    public let catalog: ProductCatalog
    public let grandfathering: GrandfatheringPolicy?
    public var settings: Settings
    public let clock: any PaywallClock
    public let store: any StoreClient
    public let sync: (any LedgerSync)?
    public let deviceID: String
    public let sessionID = UUID()
    let logger: Logger

    // MARK: State

    public private(set) var entitlement: Entitlement
    public private(set) var wallet: Wallet = .empty
    public internal(set) var accountKey: String
    public internal(set) var ledger: Ledger
    public internal(set) var appTransaction: AppTransactionSnapshot?
    public internal(set) var lastResolution: Date?
    public let leases = LeaseTable()
    public let reservations = ReservationTable()
    var sessions: [UUID: Session] = [:]
    var baseline: WalletSnapshot?
    let journal: Journal
    let audit: AuditTrail
    let resolver: EntitlementResolver
    private var reevaluating = false
    private let debitsAtLaunch: Set<String>
    private let repairingSinks: [any PaywallAuditRepairing]

    // MARK: Tasks (stored, cancelled by `shutdown`)

    var updatesTask: Task<Void, Never>?
    var expiryTask: Task<Void, Never>?
    var syncTask: Task<Void, Never>?
    var snapshotTask: Task<Void, Never>?
    var lastSyncAt: Date?
    var runningSync: Task<Void, Never>?
    var connectivityTask: Task<Void, Never>?
    let connectivity: (any PaywallConnectivity)?
    /// False while the connectivity source reports no network path: the outbox waits, and drains on return.
    public internal(set) var hasNetworkPath = true

    // MARK: Observation

    /// Every event, synchronously, in order. The facade fans it out to Combine, `AsyncStream` and handlers.
    public var onEvent: ((PaywallEvent) -> Void)?
    /// The entitlement or the wallet changed.
    public var onStateChange: (() -> Void)?
    /// Test hook for the crash-safety proof. `nil` in production.
    public var drawObserver: (any DrawObserver)?
    /// Set once a `DrawObserver` terminated a draw: the engine behaves like a dead process from then on.
    public private(set) var isTerminated = false

    /// Opens the journal in `directory` (synchronously, so the wallet is known before the first frame) and loads
    /// the last entitlement snapshot. Call `start()` to resolve against the store and begin listening.
    public init(
        directory: URL,
        catalog: ProductCatalog,
        grandfathering: GrandfatheringPolicy? = nil,
        settings: Settings = Settings(),
        clock: any PaywallClock,
        store: any StoreClient,
        sync: (any LedgerSync)? = nil,
        connectivity: (any PaywallConnectivity)? = nil,
        audit sinks: [any PaywallAuditSink] = [],
        logger: Logger = Logger(label: "ztron.paywall")
    ) throws(JournalError) {
        self.connectivity = connectivity
        self.directory = directory
        self.catalog = catalog
        self.grandfathering = grandfathering
        self.settings = settings
        self.clock = clock
        self.store = store
        self.sync = sync
        self.logger = logger
        self.resolver = EntitlementResolver(catalog: catalog, grandfathering: grandfathering)
        let journal = try Journal(
            directory: directory, compactionThreshold: settings.compactionThreshold, fullSync: settings.fullSync)
        self.journal = journal
        self.ledger = Ledger(events: journal.ledgerEvents)
        let files = PaywallFiles(directory: directory)
        self.deviceID = files.deviceID()
        self.accountKey = files.accountKey() ?? unboundAccountKey
        let cachedApp = files.appTransaction()
        self.appTransaction = cachedApp
        self.entitlement = files.entitlementSnapshot(now: clock.now) ?? .unknown
        self.repairingSinks = sinks.compactMap { $0 as? any PaywallAuditRepairing }
        self.audit = AuditTrail(sinks: sinks, ready: repairingSinks.isEmpty)
        let ownDevice = deviceID
        self.debitsAtLaunch = Set(
            journal.ledgerEvents.compactMap { event in
                if case .debit = event.kind, event.deviceID == ownDevice { return event.id }
                return nil
            })
        recomputeLeasesAndWallet(notify: false)
        if journal.droppedTailBytes > 0 {
            logger.warning("journal: dropped a torn tail", metadata: ["bytes": "\(journal.droppedTailBytes)"])
        }
    }

    /// Resolves against the store, starts the `Transaction.updates` listener, repairs the audit log, and drains
    /// the outbox. Never prompts: no receipt refresh, no `AppStore.sync()`.
    public func start() async {
        guard !isTerminated else { return }
        await repairAudit()
        if let sync { baseline = await sync.loadSnapshot() }
        recomputeLeasesAndWallet(notify: true)
        await startUpdatesListener()
        await startConnectivityListener()
        await refresh(cause: .launch)
        scheduleSync(immediately: true)
    }

    /// Cancels every task the engine owns.
    public func shutdown() {
        updatesTask?.cancel()
        expiryTask?.cancel()
        syncTask?.cancel()
        runningSync?.cancel()
        snapshotTask?.cancel()
        connectivityTask?.cancel()
        connectivityTask = nil
        updatesTask = nil
        expiryTask = nil
        syncTask = nil
    }

    /// Waits until every audit record so far reached every sink.
    public func flushAudit() async { await audit.flush() }

    // MARK: Decisions

    enum Decision {
        case open(GateOpenMode)
        case closed(PaywallFailure.Reason)
    }

    /// The pure decision. `excluding` leaves one holder's own reservation out of `reserved`.
    func decide(_ level: GateLevel, gateID: String, excluding holder: UUID? = nil) -> Decision {
        if isTerminated { return .closed(.storageUnavailable) }
        let cost: Int
        switch level {
        case .free:
            return .open(.free)
        case .paid:
            cost = 0
        case .tokens(let n):
            cost = n
        }
        if entitlement.isPaying { return .open(.paying) }
        if entitlement == .unknown { return .closed(.entitlementUnavailable) }
        // `.tokens(0)` is rejected at configuration time; at run time it fails closed like `.paid`.
        guard cost > 0 else { return .closed(.requiresPaid) }
        if leases.isActive(gateID, now: clock.now) { return .open(.leased) }
        let own = holder.flatMap { reservations.reservation(of: $0) }.map(\.tokens) ?? 0
        let available = max(0, wallet.balance - (reservations.total - own))
        return available >= cost ? .open(.affordable(cost)) : .closed(.insufficientTokens(needed: cost, available: available))
    }

    /// Pure read: no draw, no lease, no log.
    public func canPass(_ level: GateLevel, gateID: String? = nil) -> Bool {
        switch decide(level, gateID: gateID ?? "") {
        case .open: return true
        case .closed: return false
        }
    }

    /// Logs and publishes, never draws or holds. The routing gate's pre-navigation check.
    public func evaluate(_ level: GateLevel, source: PaywallSource, scope: String? = nil) -> PaywallOutcome<Void> {
        reportExpiredLease(source.id)
        switch decide(level, gateID: source.id) {
        case .open(let mode):
            emit(.gateEvaluated(source: source, level: level, decision: .open(mode)))
            return .executed(())
        case .closed(let reason):
            let failure = makeFailure(reason, level: level, source: source, scope: scope)
            emit(.gateEvaluated(source: source, level: level, decision: .closed(reason)))
            emit(.gateDenied(failure))
            return .blocked(failure)
        }
    }

    func makeFailure(_ reason: PaywallFailure.Reason, level: GateLevel, source: PaywallSource, scope: String?) -> PaywallFailure {
        PaywallFailure(reason: reason, level: level, source: source, at: clock.now, scope: scope)
    }

    func reportExpiredLease(_ gateID: String) {
        if let lapsed = leases.takeNewlyExpired(gateID, now: clock.now) {
            emit(.leaseExpired(gateID: gateID, expiresAt: lapsed.expiresAt))
        }
    }

    // MARK: Sessions (`.paywallGated`)

    /// A gated view appeared (or its presence turned true). Returns its first state; later states arrive on
    /// `onChange` whenever the entitlement, the wallet or the leases change.
    @discardableResult
    public func openSession(
        holder: UUID,
        level: GateLevel,
        policy: TokenPolicy,
        source: PaywallSource,
        scope: String? = nil,
        onChange: ((GateSessionState) -> Void)? = nil
    ) -> GateSessionState {
        sessions[holder] = Session(level: level, policy: policy, source: source, scope: scope, onChange: onChange)
        let state = evaluateSession(holder)
        reevaluateSessions(except: holder)
        return state
    }

    public func sessionState(_ holder: UUID) -> GateSessionState? { sessions[holder]?.state }

    /// A gated view disappeared (or its presence turned false): release an uncommitted hold, unpin the lease.
    public func closeSession(holder: UUID) {
        guard let session = sessions.removeValue(forKey: holder) else { return }
        if let reservation = reservations.release(holder) {
            emit(.tokensReleased(n: reservation.tokens, source: reservation.source, holder: holder))
            if session.policy == .reserve, !session.committed {
                emit(.reservedWithoutCommit(source: session.source, holder: holder))
            }
            recomputeLeasesAndWallet(notify: true)
        }
        unpin(session.source.id, holder: holder)
        reevaluateSessions()
    }

    @discardableResult
    func evaluateSession(_ holder: UUID) -> GateSessionState {
        // Callers only pass holders they just looked up or inserted.
        var session = sessions[holder]!
        let gateID = session.source.id
        reportExpiredLease(gateID)
        let decision: GateDecision
        switch decide(session.level, gateID: gateID, excluding: holder) {
        case .closed(let reason):
            releaseHold(of: holder)
            unpin(gateID, holder: holder)
            decision = .closed(reason)
        case .open(.leased):
            // Another instance committed, or a lease survived from an earlier visit: drop the hold, pin the lease.
            releaseHold(of: holder)
            pin(gateID, holder: holder)
            if settings.leasePolicy == .refreshOnReentry, session.state?.isOpen != true { extendLease(gateID) }
            decision = .open(.leased)
        case .open(.affordable(let n)):
            if reservations.reservation(of: holder) != nil {
                decision = .open(.reserved(n))
            } else if session.policy == .reserve {
                reservations.hold(Reservation(holder: holder, gateID: gateID, tokens: n, source: session.source))
                emit(.tokensReserved(n: n, source: session.source, holder: holder))
                recomputeLeasesAndWallet(notify: true)
                decision = .open(.reserved(n))
            } else {
                // `.deductNow`: the content is the value, so the draw is write-ahead before it renders.
                switch draw(n, source: session.source, consuming: nil, pinning: holder) {
                case .success(let ticket):
                    complete(ticket)
                    session.committed = true
                    decision = .open(.drawn(n))
                case .failure(let failure):
                    decision = .closed(failure.reason)
                }
            }
        case .open(let mode):
            releaseHold(of: holder)
            decision = .open(mode)
        }
        let state = GateSessionState(
            holder: holder, level: session.level, source: session.source, scope: session.scope, decision: decision)
        let previous = session.state
        session.state = state
        sessions[holder] = session
        if previous?.decision != decision {
            emit(.gateEvaluated(source: session.source, level: session.level, decision: decision))
            switch decision {
            case .open(let mode):
                emit(.gateOpened(source: session.source, level: session.level, mode: mode))
            case .closed(let reason):
                emit(.gateDenied(makeFailure(reason, level: session.level, source: session.source, scope: session.scope)))
            }
            if previous != nil { session.onChange?(state) }
        }
        return state
    }

    /// Re-evaluates every live session until nothing changes (a hold released by one can open another).
    func reevaluateSessions(except skipped: UUID? = nil) {
        guard !reevaluating else { return }
        reevaluating = true
        defer { reevaluating = false }
        for _ in 0..<4 {
            let before = sessions.mapValues { $0.state?.decision }
            for holder in sessions.keys.sorted(by: { $0.uuidString < $1.uuidString }) where holder != skipped {
                if sessions[holder] != nil { evaluateSession(holder) }
            }
            if sessions.mapValues({ $0.state?.decision }) == before { break }
        }
    }

    private func releaseHold(of holder: UUID) {
        guard let reservation = reservations.release(holder) else { return }
        emit(.tokensReleased(n: reservation.tokens, source: reservation.source, holder: holder))
        recomputeLeasesAndWallet(notify: true)
    }

    func pin(_ gateID: String, holder: UUID) {
        guard leases.pin(gateID, holder: holder), let record = leases.records[gateID] else { return }
        emit(.leasePinned(gateID: gateID, expiresAt: record.expiresAt, holders: leases.holders(of: gateID).count))
    }

    func unpin(_ gateID: String, holder: UUID) {
        guard leases.unpin(gateID, holder: holder), let record = leases.records[gateID] else { return }
        emit(.leaseUnpinned(gateID: gateID, expiresAt: record.expiresAt, holders: leases.holders(of: gateID).count))
    }

    // MARK: Derived state

    func recomputeLeasesAndWallet(notify: Bool) {
        leases.refresh(from: ledger.leases(for: accountKey))
        let next = Wallet(balance: ledger.balance(for: accountKey, baseline: baseline), reserved: reservations.total)
        guard next != wallet else { return }
        wallet = next
        persistSnapshot()
        if notify { onStateChange?() }
    }

    func setEntitlement(_ next: Entitlement, cause: EntitlementChangeCause) {
        guard next != entitlement else { return }
        let before = entitlement
        entitlement = next
        emit(.entitlementChanged(from: before, to: next, cause: cause), entitlementBefore: before)
        PaywallFiles(directory: directory).saveEntitlementSnapshot(next)
        onStateChange?()
        reevaluateSessions()
    }

    /// Appends one ledger event write-ahead. Used outside the draw path (credits, refunds, grants, extensions).
    @discardableResult
    func appendLedger(id: String, kind: LedgerEvent.Kind, source: PaywallSource? = nil) -> LedgerEvent? {
        guard !isTerminated, !ledger.contains(id) else { return nil }
        let event = LedgerEvent(
            id: id, at: clock.now, deviceID: deviceID, accountKey: accountKey, source: source,
            previousHash: ledger.head(for: deviceID), kind: kind)
        do {
            try journal.append(.event(event, uploaded: false))
        } catch {
            logger.error("journal: append failed", metadata: ["id": "\(id)", "error": "\(error)"])
            return nil
        }
        ledger.append(event)
        recomputeLeasesAndWallet(notify: true)
        reevaluateSessions()
        scheduleSync(immediately: false)
        return event
    }

    /// Welcome tokens or a support credit. Pass a deterministic `id` to make the grant once per account.
    @discardableResult
    public func grant(tokens: Int, reason: String, id: String? = nil) -> Bool {
        guard tokens > 0, appendLedger(id: id ?? "grant:\(UUID().uuidString)", kind: .grant(tokens: tokens, reason: reason)) != nil
        else { return false }
        emit(.tokensGranted(n: tokens, reason: reason))
        return true
    }

    func extendLease(_ gateID: String) {
        guard let record = leases.records[gateID] else { return }
        let until = clock.now.addingTimeInterval(settings.tolerance)
        guard until > record.expiresAt else { return }
        if appendLedger(id: "extend:\(UUID().uuidString)", kind: .leaseExtended(debitID: record.debitID, until: until)) != nil {
            emit(.leaseExtended(gateID: gateID, expiresAt: until))
        }
    }

    // MARK: Events and audit

    func emit(_ event: PaywallEvent, entitlementBefore: Entitlement? = nil, balanceBefore: Int? = nil) {
        guard !isTerminated else { return }
        let now = clock.now
        let uptime = clock.uptime
        let environment = settings.environmentLabel ?? appTransaction?.environment.rawValue ?? "unknown"
        let entitlementAfter = entitlement
        let balanceAfter = wallet.balance
        let deviceID = deviceID
        let sessionID = sessionID
        let settings = settings
        audit.record { previous in
            AuditRecord(
                at: now, uptime: uptime, sessionID: sessionID, deviceID: deviceID, appVersion: settings.appVersion,
                build: settings.build, environment: environment, event: event,
                entitlementBefore: entitlementBefore ?? entitlementAfter, entitlementAfter: entitlementAfter,
                balanceBefore: balanceBefore ?? balanceAfter, balanceAfter: balanceAfter, previousHash: previous)
        }
        onEvent?(event)
    }

    /// Rebuilds `tokensConsumed` records the audit log lost to a crash between delivery and the audit write.
    private func repairAudit() async {
        guard !repairingSinks.isEmpty else { return }
        var recorded: Set<String> = []
        var lastHash: String?
        for sink in repairingSinks {
            recorded.formUnion(await sink.recordedDebitIDs())
            if lastHash == nil { lastHash = await sink.lastRecordHash() }
        }
        audit.resume(after: lastHash ?? paywallGenesisHash)
        for debitID in debitsAtLaunch.sorted() where !recorded.contains(debitID) {
            emit(.auditRepaired(debitID: debitID))
        }
    }

    // MARK: Simulation (ZTronPaywallSimulator only)

    // Compiled out of release builds with the simulator (Scripts/check-release-symbols.sh).
    #if DEBUG
        /// Moves the balance to `target` with one grant of the difference (negative allowed). Simulator only: the
        /// production paths for tokens are StoreKit credits and explicit grants.
        @_spi(PaywallSimulation)
        public func simulateBalance(_ target: Int) {
            let delta = target - wallet.balance
            guard delta != 0 else { return }
            if appendLedger(id: "grant:simulated:\(UUID().uuidString)", kind: .grant(tokens: delta, reason: "simulated")) != nil {
                emit(.tokensGranted(n: delta, reason: "simulated"))
            }
        }

        /// Sets the entitlement ahead of the store resolution that will confirm it, so a preview renders the right
        /// state on its first frame. Simulator only.
        @_spi(PaywallSimulation)
        public func simulateEntitlement(_ entitlement: Entitlement) {
            setEntitlement(entitlement, cause: .simulation)
        }
    #endif

    // MARK: Termination (crash-safety proof)

    func terminate() {
        isTerminated = true
        audit.discardPending()
        shutdown()
    }
}

/// Small files next to the journal: device id, account key, and the caches resolution falls back on offline.
struct PaywallFiles {
    let directory: URL

    private func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    func deviceID() -> String {
        if let data = FileManager.default.contents(atPath: url("device.id").path), let id = String(data: data, encoding: .utf8),
            !id.isEmpty
        {
            return id
        }
        let id = UUID().uuidString
        try? Data(id.utf8).write(to: url("device.id"), options: .atomic)
        return id
    }

    func accountKey() -> String? {
        FileManager.default.contents(atPath: url("account.key").path).flatMap { String(data: $0, encoding: .utf8) }
    }

    func saveAccountKey(_ key: String) {
        try? Data(key.utf8).write(to: url("account.key"), options: .atomic)
    }

    private func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        FileManager.default.contents(atPath: url(name).path).flatMap { try? CanonicalJSON.decoder().decode(type, from: $0) }
    }

    private func save<T: Encodable>(_ value: T, _ name: String) {
        guard let data = try? CanonicalJSON.encoder().encode(value) else { return }
        try? data.write(to: url(name), options: .atomic)
    }

    func appTransaction() -> AppTransactionSnapshot? { load(AppTransactionSnapshot.self, "app-transaction.json") }
    func saveAppTransaction(_ snapshot: AppTransactionSnapshot) { save(snapshot, "app-transaction.json") }

    struct EntitlementSnapshot: Codable {
        var entitlement: Entitlement
        var resolvedAt: Date
    }

    /// The last successful resolution, with lapsed subscriptions already downgraded to free.
    func entitlementSnapshot(now: Date) -> Entitlement? {
        guard let snapshot = load(EntitlementSnapshot.self, "entitlement.json") else { return nil }
        if case .subscribed(let subscription) = snapshot.entitlement, let expiresAt = subscription.expiresAt, expiresAt <= now {
            return .free
        }
        return snapshot.entitlement == .unknown ? nil : snapshot.entitlement
    }

    func entitlementSnapshotDate() -> Date? { load(EntitlementSnapshot.self, "entitlement.json")?.resolvedAt }

    func saveEntitlementSnapshot(_ entitlement: Entitlement, at date: Date = Date()) {
        guard entitlement != .unknown else { return }
        save(EntitlementSnapshot(entitlement: entitlement, resolvedAt: date), "entitlement.json")
    }

    func grandfatherLogged() -> Bool { FileManager.default.fileExists(atPath: url("grandfathered.logged").path) }
    func markGrandfatherLogged() { _ = FileManager.default.createFile(atPath: url("grandfathered.logged").path, contents: Data()) }

    struct PriceCache: Codable {
        var products: [PaywallProduct]
        var at: Date
    }

    func prices() -> PriceCache? { load(PriceCache.self, "prices.json") }
    func savePrices(_ products: [PaywallProduct], at date: Date) { save(PriceCache(products: products, at: date), "prices.json") }
}
