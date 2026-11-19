public import Foundation
public import Logging

/// The live state of one gated view, as its modifier renders it.
public struct GateSessionState: Hashable, Sendable {
    public let holder: UUID
    public let level: GateLevel
    public let source: PaywallSource
    public let scope: String?
    public let decision: GateDecision
    /// The failure the engine published for a closed decision: the same value, so `claim()` from the denied
    /// view refers to the failure the sheet and the handlers saw. `nil` while open.
    public let failure: PaywallFailure?

    public init(holder: UUID, level: GateLevel, source: PaywallSource, scope: String?, decision: GateDecision, failure: PaywallFailure? = nil) {
        self.holder = holder
        self.level = level
        self.source = source
        self.scope = scope
        self.decision = decision
        self.failure = failure
    }

    public var isOpen: Bool {
        if case .open = decision { return true }
        return false
    }
}

/// What `purchase` reports to the paywall screen.
public enum PurchaseOutcome: Hashable, Sendable {
    case purchased(transactionID: UInt64)
    /// Ask to Buy: credited or unlocked when the transaction arrives on `Transaction.updates`.
    case pending
    case cancelled
}

/// Pipeline-style handling, the twin of `PaywallOutcome.onExecuted` and `onBlocked`: each call runs its closure
/// when the outcome matches and returns the outcome unchanged, so the calls chain off `purchase` directly. A store
/// error is thrown by `purchase` itself and never reaches the chain, so the `try` stays.
///
///     try await Paywall.shared.purchase(product, source: failure.source)
///         .onPurchaseCompleted { transactionID in dismiss() }
///         .onPurchasePending { dismiss() }
///         .onPurchaseCancelled { }
extension PurchaseOutcome {
    /// Calls `body` with the transaction id when the purchase went through. The ledger and the entitlement are
    /// already updated by then.
    @discardableResult
    public func onPurchaseCompleted(_ body: (UInt64) throws -> Void) rethrows -> Self {
        if case .purchased(let transactionID) = self { try body(transactionID) }
        return self
    }

    /// Calls `body` when the purchase waits on Ask to Buy or a bank confirmation; the transaction arrives later on
    /// `Transaction.updates`.
    @discardableResult
    public func onPurchasePending(_ body: () throws -> Void) rethrows -> Self {
        if case .pending = self { try body() }
        return self
    }

    /// Calls `body` when the user dismissed the payment sheet.
    @discardableResult
    public func onPurchaseCancelled(_ body: () throws -> Void) rethrows -> Self {
        if case .cancelled = self { try body() }
        return self
    }
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
        /// What another family member's purchase is worth here. Applied at every resolution and to the cached
        /// snapshot, so a build that changes it takes effect at its first launch.
        public var familySharing: FamilySharingPolicy
        /// Overrides the environment written to audit records (`"simulated"` from the simulator).
        public var environmentLabel: String?
        public var appVersion: String
        public var build: String
        /// `F_FULLFSYNC` on the draw path (default) or `fsync` only.
        public var fullSync: Bool
        /// Compaction at open folds the upload markers once the log holds more of them than this; `start()` writes a
        /// checkpoint and drops the events it covers once more events than this follow the last one (HANDBOOK.md,
        /// "Retention").
        public var compactionThreshold: Int
        /// The outbox drains at most once per interval.
        public var syncCoalescing: TimeInterval
        /// Tokens a new account gets once to try the app, as the ledger grant `grant:welcome`, at this build's value:
        /// a later build with another value leaves existing users with what their first build granted, less what
        /// they spent. `0` here; `Paywall.Configuration` sets 100.
        public var welcomeTokens: Int
        /// Launch and foreground fetch the storefront again when the last fetch is older than this.
        public var storefrontRefreshInterval: TimeInterval
        /// The app's bundle id, what a promotional offer signature is bound to (`Bundle.main.bundleIdentifier` from the
        /// facade). `nil` falls back to the app transaction's.
        public var bundleID: String?
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
            familySharing: FamilySharingPolicy = .sharedEntitlements,
            environmentLabel: String? = nil,
            appVersion: String = "0",
            build: String = "0",
            fullSync: Bool = true,
            compactionThreshold: Int = 4096,
            syncCoalescing: TimeInterval = 30,
            welcomeTokens: Int = 0,
            storefrontRefreshInterval: TimeInterval = 3_600,
            bundleID: String? = nil
        ) {
            self.tolerance = tolerance
            self.leasePolicy = leasePolicy
            self.familySharing = familySharing
            self.environmentLabel = environmentLabel
            self.appVersion = appVersion
            self.build = build
            self.fullSync = fullSync
            self.compactionThreshold = compactionThreshold
            self.syncCoalescing = syncCoalescing
            self.welcomeTokens = welcomeTokens
            self.storefrontRefreshInterval = storefrontRefreshInterval
            self.bundleID = bundleID
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
    /// Signs promotional offers for `purchase(productID:offer:source:)`. `nil`: an offer purchase fails before the store.
    public let promotionalOfferSigner: (any PromotionalOfferSigner)?
    public let sync: (any LedgerSync)?
    /// Authenticates the caches next to the journal (`app-transaction.json`, `entitlement.json`); `nil` leaves them
    /// plain and trusted, as a core-only host may choose. The facade installs the Keychain store.
    public let fileKeyStore: (any PaywallFileKeyStore)?
    public let deviceID: String
    public let sessionID = UUID()
    let logger: Logger

    // MARK: State

    public private(set) var entitlement: Entitlement
    public private(set) var wallet: Wallet = .empty
    /// Where the user stands, from the entitlement and the wallet: `nil` while the entitlement is unknown.
    public var tier: AccessTier? { entitlement.tier(wallet: wallet) }
    public internal(set) var accountKey: String
    public internal(set) var ledger: Ledger
    public internal(set) var appTransaction: AppTransactionSnapshot?
    public internal(set) var lastResolution: Date?
    /// The last storefront fetch, from this launch or from disk; `nil` until the first one ever answers.
    public internal(set) var storefront: PaywallStorefront?
    public let leases = LeaseTable()
    public let reservations = ReservationTable()
    var sessions: [UUID: Session] = [:]
    /// The Keychain snapshot standing in for history this install has not seen: adopted in `start()` over a ledger
    /// with no events for its account, written to the journal so it outlives the launch, and settled by `merge` once
    /// the carrier delivers history for its account (see HANDBOOK.md, "Reinstall and the Keychain snapshot").
    var baseline: WalletSnapshot?
    let journal: Journal
    let audit: AuditTrail
    let resolver: EntitlementResolver
    private var reevaluating = false
    /// Stamps resolutions in the order they start; only a resolution newer than the last applied one is applied, so
    /// a read that stalled on the App Store cannot undo a purchase or a refund resolved meanwhile.
    var resolutionGeneration = 0
    var lastAppliedGeneration = 0
    /// Token packs the store delivered whose credit the journal could not write: left unfinished, retried at every
    /// resolution and finished once the credit lands. StoreKit delivers them again at the next launch either way.
    var unfinishedPacks: [StoreTransaction] = []
    var retryingUnfinished = false
    /// Whether the last pull said the carrier has an account to upload to. `false` stops the outbox from being
    /// encoded and pushed at every sync while a device has no iCloud account; the next pull that finds one pushes.
    var carrierHasAccount = true
    /// This device's debits in the journal at open, with their dates: the candidates for the audit repair.
    private let debitsAtLaunch: [String: Date]
    private let repairingSinks: [any PaywallAuditRepairing]
    /// The ledger as the journal held it at open, kept only while the events since the last checkpoint exceed the
    /// threshold: `start()` writes its checkpoint once the audit repair has settled every debit it covers.
    private var checkpointCandidate: Ledger?

    // MARK: Tasks (stored, cancelled by `shutdown`)

    var updatesTask: Task<Void, Never>?
    var intentsTask: Task<Void, Never>?
    var expiryTask: Task<Void, Never>?
    var syncTask: Task<Void, Never>?
    var snapshotTask: Task<Void, Never>?
    var storefrontTask: Task<Void, Never>?
    var lastSyncAt: Date?
    var runningSync: Task<Void, Never>?
    var connectivityTask: Task<Void, Never>?
    let connectivity: (any PaywallConnectivity)?
    /// False while the connectivity source reports no network path: the outbox waits, and drains on return.
    public internal(set) var hasNetworkPath = true
    /// Set by `shutdown()`: no task started afterwards touches the journal or the carrier, so an engine the
    /// facade replaced cannot write next to its successor.
    public private(set) var isShutDown = false

    // MARK: Observation

    /// Every event, synchronously, in order. The facade fans it out to Combine, `AsyncStream` and handlers.
    public var onEvent: ((PaywallEvent) -> Void)?
    /// The entitlement or the wallet changed.
    public var onStateChange: (() -> Void)?
    /// A purchase that completed after `shutdown()` (the facade reconfigured while the payment sheet was up). This
    /// engine credits and finishes nothing after shutdown; the facade hands the transaction to its current engine's
    /// `adoptPurchase(_:source:)` and answers whether that engine finished it. `nil` leaves it unfinished for the next
    /// launch's `Transaction.updates`.
    public var onOrphanedPurchase: ((StoreTransaction, PaywallSource?) async -> Bool)?
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
        promotionalOfferSigner: (any PromotionalOfferSigner)? = nil,
        sync: (any LedgerSync)? = nil,
        connectivity: (any PaywallConnectivity)? = nil,
        audit sinks: [any PaywallAuditSink] = [],
        fileKeyStore: (any PaywallFileKeyStore)? = nil,
        logger: Logger = Logger(label: "ztron.paywall")
    ) throws(JournalError) {
        self.connectivity = connectivity
        self.directory = directory
        self.catalog = catalog
        self.grandfathering = grandfathering
        self.settings = settings
        self.clock = clock
        self.store = store
        self.promotionalOfferSigner = promotionalOfferSigner
        self.sync = sync
        self.fileKeyStore = fileKeyStore
        self.logger = logger
        self.resolver = EntitlementResolver(catalog: catalog, grandfathering: grandfathering, familySharing: settings.familySharing)
        let journal = try Journal(
            directory: directory, compactionThreshold: settings.compactionThreshold, fullSync: settings.fullSync)
        self.journal = journal
        self.ledger = Ledger(checkpoint: journal.checkpoint, events: journal.ledgerEvents)
        let files = PaywallFiles(directory: directory, keyStore: fileKeyStore)
        // A corrupt frame took events the carrier may bring back: a new device stream, so nothing written meanwhile
        // forks the old one when they do.
        self.deviceID = journal.droppedCorruptFrame ? files.rotateDeviceID() : files.deviceID()
        let cachedApp = files.appTransaction()
        self.appTransaction = cachedApp
        // The account partition comes from the authenticated snapshot, not from a file of its own.
        self.accountKey = cachedApp?.accountKey ?? unboundAccountKey
        files.removeLegacyAccountKey()
        self.storefront = files.storefront()
        self.entitlement = files.entitlementSnapshot(now: clock.now, familySharing: settings.familySharing) ?? .unknown
        self.repairingSinks = sinks.compactMap { $0 as? any PaywallAuditRepairing }
        self.audit = AuditTrail(sinks: sinks, ready: repairingSinks.isEmpty)
        var debits: [String: Date] = [:]
        for event in ledger.events where event.deviceID == deviceID {
            if case .debit = event.kind { debits[event.id] = event.at }
        }
        self.debitsAtLaunch = debits
        if ledger.events.count > settings.compactionThreshold { checkpointCandidate = ledger }
        // Before the recompute: the balance it persists must count the baseline the journal still holds.
        self.baseline = journal.baseline
        recomputeLeasesAndWallet(notify: false)
        if journal.droppedTailBytes > 0 {
            logger.warning(
                journal.droppedCorruptFrame ? "journal: dropped a corrupt frame and what followed it" : "journal: dropped a torn tail",
                metadata: ["bytes": "\(journal.droppedTailBytes)"])
        }
        if journal.compactedOnOpen {
            logger.info("journal: compacted at open", metadata: ["entries": "\(journal.entries.count)"])
        }
    }

    /// Resolves against the store, starts the `Transaction.updates` and `PurchaseIntent` listeners, repairs the
    /// audit log, drains the outbox, writes the welcome grant when no carrier could know better, and fetches the
    /// storefront when the last one is stale. Never prompts: no receipt refresh, no `AppStore.sync()`.
    public func start() async {
        guard !isTerminated, !isShutDown else { return }
        // Each engine's first pull is a real look: a carrier inherited from a predecessor may still be inside its
        // pull interval, and an answer it did not fetch must not settle this engine's baseline or welcome grant.
        await sync?.requestPull()
        guard !isShutDown else { return }
        await repairAudit()
        guard !isShutDown else { return }
        await writeCheckpointIfDue()
        guard !isShutDown else { return }
        if baseline == nil, let sync {
            let snapshot = await sync.loadSnapshot()
            guard !isShutDown else { return }
            if let snapshot, Self.standsForHistory(snapshot), !ledger.hasEvents(for: snapshot.accountKey) {
                // Adopted over a ledger with no history for its account only (a reinstall, a new device). A ledger
                // with history cannot tell which part of it the snapshot already counts: another device's snapshot
                // from iCloud Keychain, or this device's own written ahead of a torn journal, would add that history
                // twice. Written to the journal, so it stands at the next launch too.
                adoptBaseline(snapshot)
            }
        }
        recomputeLeasesAndWallet(notify: true)
        await startUpdatesListener()
        guard !isShutDown else { return }
        await startPurchaseIntentsListener()
        guard !isShutDown else { return }
        await startConnectivityListener()
        guard !isShutDown else { return }
        await refresh(cause: .launch)
        guard !isShutDown else { return }
        // Without a carrier nothing else can know this account: the welcome grant is written now. With one it
        // waits for the first pull (`performSync`), so a new device of an existing account takes the account's grant.
        if sync == nil { grantWelcomeIfNew() }
        scheduleSync(immediately: true)
        await refreshStorefrontIfStale()
    }

    /// A snapshot that says something: a balance, or a last event. `{0, nil}` is what an install with no history
    /// writes and is adopted as nothing, so the welcome grant still fires.
    static func standsForHistory(_ snapshot: WalletSnapshot) -> Bool {
        snapshot.balance != 0 || snapshot.lastEventID != nil
    }

    func adoptBaseline(_ snapshot: WalletSnapshot) {
        do {
            try journal.append(.baseline(snapshot))
        } catch {
            logger.error("journal: baseline write failed", metadata: ["error": "\(error)"])
        }
        // Adopted in memory even when the write failed: the balance is right for this launch, and the next launch
        // adopts the Keychain item again.
        baseline = snapshot
    }

    /// Stops the engine for good: every task it owns is cancelled, the journal is closed, the view sessions are
    /// dropped, and nothing durable happens afterwards (no journal or file write, no audit record, no `finish()`, no
    /// listener): a successor engine may own the directory by then. Work already in flight returns without effect.
    public func shutdown() {
        isShutDown = true
        updatesTask?.cancel()
        intentsTask?.cancel()
        expiryTask?.cancel()
        syncTask?.cancel()
        runningSync?.cancel()
        snapshotTask?.cancel()
        storefrontTask?.cancel()
        connectivityTask?.cancel()
        connectivityTask = nil
        storefrontTask = nil
        updatesTask = nil
        intentsTask = nil
        expiryTask = nil
        syncTask = nil
        sessions.removeAll()
        journal.close()
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
        // A dead engine (terminated by the crash proof, or shut down and replaced) can make nothing durable.
        if isTerminated || isShutDown { return .closed(.storageUnavailable) }
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
        // Nothing rejects `.tokens(n)` with n <= 0 up front (gate levels are call-site arguments): at run time it fails
        // closed like `.paid`, and a debug build logs the call site once (`warnIfInvalid`).
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

    #if DEBUG
        private var warnedInvalidGates: Set<String> = []
    #endif

    /// Debug builds: a `.tokens(n)` gate with n <= 0 is a caller error that fails closed like `.paid`, logged once per
    /// gate so the developer learns of it before a free user does.
    func warnIfInvalid(_ level: GateLevel, _ source: PaywallSource) {
        #if DEBUG
            guard !level.isValid, warnedInvalidGates.insert(source.id).inserted else { return }
            logger.warning(
                "gate: a token cost of \(level.tokenCost) is not a free gate, it fails closed like .paid", metadata: ["gate": "\(source.id)"])
        #endif
    }

    /// Logs and publishes, never draws or holds. The routing gate's pre-navigation check.
    public func evaluate(_ level: GateLevel, source: PaywallSource, scope: String? = nil) -> PaywallOutcome<Void> {
        warnIfInvalid(level, source)
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
        warnIfInvalid(level, source)
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
        var decision: GateDecision
        var drawn: GateTicket?
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
                    session.committed = true
                    drawn = ticket
                    decision = .open(.drawn(n))
                case .failure(let failure):
                    decision = .closed(failure.reason)
                }
            }
        case .open(let mode):
            releaseHold(of: holder)
            decision = .open(mode)
        }
        let previous = session.state
        // A view that drew stays `.drawn`: its own lease is what keeps it open on every later evaluation.
        if let previous, case .open(.drawn) = previous.decision, decision == .open(.leased) { decision = previous.decision }
        var failure: PaywallFailure?
        if case .closed(let reason) = decision {
            // One failure per closed spell, so the denied view, the preference key and the published event agree.
            if previous?.decision == decision, let same = previous?.failure {
                failure = same
            } else {
                failure = makeFailure(reason, level: session.level, source: session.source, scope: session.scope)
            }
        }
        let state = GateSessionState(
            holder: holder, level: session.level, source: session.source, scope: session.scope, decision: decision,
            failure: failure)
        session.state = state
        sessions[holder] = session
        if previous?.decision != decision {
            emit(.gateEvaluated(source: session.source, level: session.level, decision: decision))
            switch decision {
            case .open(let mode):
                emit(.gateOpened(source: session.source, level: session.level, mode: mode))
            case .closed:
                if let failure { emit(.gateDenied(failure)) }
            }
            if previous != nil { session.onChange?(state) }
        }
        // Steps 4–5 run after the state is stored, so the re-evaluation `complete` triggers sees this session open.
        if let drawn { complete(drawn) }
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
        let balanceChanged = next.balance != wallet.balance
        wallet = next
        // Holds are device-local and never reach the carrier: only a balance change is worth a Keychain write.
        if balanceChanged { persistSnapshot() }
        if notify { onStateChange?() }
    }

    func setEntitlement(_ next: Entitlement, cause: EntitlementChangeCause) {
        guard next != entitlement else { return }
        let before = entitlement
        entitlement = next
        emit(.entitlementChanged(from: before, to: next, cause: cause), entitlementBefore: before)
        onStateChange?()
        reevaluateSessions()
    }

    /// Appends one ledger event write-ahead. Used outside the draw path (credits, refunds, grants, extensions).
    /// `nil` when the event is already there, the engine is dead, or the write failed; a failed sync after a
    /// successful write is a landed event, as on the draw path (the frame is in the file).
    @discardableResult
    func appendLedger(id: String, kind: LedgerEvent.Kind, source: PaywallSource? = nil) -> LedgerEvent? {
        guard !isTerminated, !isShutDown, !ledger.contains(id) else { return nil }
        let event = LedgerEvent(
            id: id, at: clock.now, deviceID: deviceID, accountKey: accountKey, source: source,
            previousHash: ledger.head(for: deviceID), kind: kind)
        do {
            try journal.write(.event(event, uploaded: false))
        } catch {
            logger.error("journal: append failed", metadata: ["id": "\(id)", "error": "\(error)"])
            return nil
        }
        do {
            try journal.sync()
        } catch {
            logger.warning("journal: sync failed after an append", metadata: ["id": "\(id)", "error": "\(error)"])
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

    /// The once-per-account welcome grant, `grant:welcome`, at this build's `settings.welcomeTokens`. A later build
    /// with another value finds the id taken and changes nothing: the user keeps what their first build granted,
    /// less what they spent. Only an account with no history gets one, and a Keychain snapshot standing in for
    /// history counts as history.
    func grantWelcomeIfNew() {
        guard settings.welcomeTokens > 0, baseline == nil, !ledger.hasEvents(for: accountKey) else { return }
        grant(tokens: settings.welcomeTokens, reason: "welcome", id: "grant:welcome")
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
        // After `shutdown()` the audit files belong to the successor: a late record would break its chain.
        guard !isTerminated, !isShutDown else { return }
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

    /// Rebuilds `tokensConsumed` records the audit log lost to a crash between delivery and the audit write. A
    /// debit older than what every sink still retains is left alone: its record may simply have been rotated out,
    /// and repairing it at every launch would fill the log with repairs of repairs. The sinks are asked only about
    /// the debits that remain candidates after that floor, and not at all when none does, so a launch with nothing to
    /// check never decodes the retained audit files.
    private func repairAudit() async {
        guard !repairingSinks.isEmpty else { return }
        var lastHash: String?
        var retainedSince: Date?
        var someSinkRetainsEverything = false
        for sink in repairingSinks {
            if lastHash == nil { lastHash = await sink.lastRecordHash() }
            if let since = await sink.retainedSince() {
                retainedSince = min(retainedSince ?? since, since)
            } else {
                someSinkRetainsEverything = true
            }
        }
        audit.resume(after: lastHash ?? paywallGenesisHash)
        let floor = someSinkRetainsEverything ? nil : retainedSince
        // At the floor itself the debit's own records may straddle the dropped file: leave it alone too.
        let candidates = Set(debitsAtLaunch.filter { debit in floor.map { debit.value > $0 } ?? true }.keys)
        guard !candidates.isEmpty, !isShutDown else { return }
        var recorded: Set<String> = []
        for sink in repairingSinks {
            recorded.formUnion(await sink.recordedDebitIDs(among: candidates))
        }
        guard !isShutDown else { return }
        for debitID in candidates.subtracting(recorded).sorted() {
            emit(.auditRepaired(debitID: debitID))
        }
    }

    /// Retention (HANDBOOK.md): once more events than `compactionThreshold` followed the last checkpoint at open, the
    /// ledger as it stood at open becomes the new checkpoint and the journal drops the events it covers; the ones the
    /// carrier has not acknowledged move to the outbox file. Only what an earlier process wrote is covered, and only
    /// after this launch's audit repair saw it in the journal and the flush put every repaired record in the sinks'
    /// hands: a debit written since open stays in the log for the next launch's repair. Nothing is written to the
    /// journal after `shutdown()`, since a successor engine may own the file by then. A log in the shape earlier builds
    /// wrote, with covered unacknowledged events behind its checkpoint, is compacted once to move them out.
    private func writeCheckpointIfDue() async {
        guard let candidate = checkpointCandidate else {
            guard sync != nil, journal.hasCoveredOutboxInLog, !isTerminated, !isShutDown else { return }
            do {
                try journal.compact()
                logger.info("journal: moved the covered outbox out of the log", metadata: ["entries": "\(journal.entries.count)"])
            } catch {
                logger.error("journal: outbox migration failed", metadata: ["error": "\(error)"])
            }
            return
        }
        checkpointCandidate = nil
        await flushAudit()
        guard !isTerminated, !isShutDown else { return }
        do {
            // Without a carrier nothing will ever acknowledge the outbox: the checkpoint covers it too.
            try journal.compact(checkpoint: candidate.checkpoint(), keepingOutbox: sync != nil)
            logger.info(
                "journal: checkpointed",
                metadata: ["covered": "\(candidate.events.count)", "entries": "\(journal.entries.count)"])
        } catch {
            logger.error("journal: checkpoint failed", metadata: ["error": "\(error)"])
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

/// Small files next to the journal: the device id, the storefront cache, and the two caches resolution falls back
/// on offline, `app-transaction.json` and `entitlement.json`, which can open paid gates on their own.
///
/// With a key store those two are authenticated: each is written as `{"mac": <hex>, "payload": <base64 JSON>}`, the
/// tag an HMAC-SHA256 over the payload bytes under a key that never leaves the install, and a file whose tag is
/// missing or wrong is dropped on read (never re-tagged: a file written before the key existed, or planted, is not
/// laundered), so an edited container or a restored backup plants nothing. With no key at hand (the Keychain before
/// first unlock) nothing is written or trusted. Without a key store the files are plain JSON and trusted as written,
/// the shape every build before this one wrote.
struct PaywallFiles {
    let directory: URL
    let keyStore: (any PaywallFileKeyStore)?

    init(directory: URL, keyStore: (any PaywallFileKeyStore)? = nil) {
        self.directory = directory
        self.keyStore = keyStore
    }

    private func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    func deviceID() -> String {
        if let data = FileManager.default.contents(atPath: url("device.id").path), let id = String(data: data, encoding: .utf8),
            !id.isEmpty
        {
            return id
        }
        return rotateDeviceID()
    }

    /// A new device id, written over the old one: a new stream for the chain.
    func rotateDeviceID() -> String {
        let id = UUID().uuidString
        try? Data(id.utf8).write(to: url("device.id"), options: .atomic)
        return id
    }

    /// Builds before this one cached the account key in a file of its own; it is derived from the app transaction now.
    func removeLegacyAccountKey() {
        try? FileManager.default.removeItem(at: url("account.key"))
    }

    /// The authenticated shape of a cache.
    struct Envelope: Codable {
        var mac: String
        var payload: Data
    }

    private func load<T: Decodable>(_ type: T.Type, _ name: String, authenticated: Bool) -> T? {
        guard let data = FileManager.default.contents(atPath: url(name).path) else { return nil }
        let decoder = CanonicalJSON.decoder()
        guard authenticated, let keyStore else { return try? decoder.decode(type, from: data) }
        guard let key = keyStore.fileKey(), let envelope = try? decoder.decode(Envelope.self, from: data),
            envelope.mac == Self.tag(envelope.payload, key: key)
        else { return nil }
        return try? decoder.decode(type, from: envelope.payload)
    }

    private func save<T: Encodable>(_ value: T, _ name: String, authenticated: Bool) {
        guard let payload = try? CanonicalJSON.encoder().encode(value) else { return }
        var data = payload
        if authenticated, let keyStore {
            guard let key = keyStore.fileKey(), let enveloped = try? CanonicalJSON.encoder().encode(Envelope(mac: Self.tag(payload, key: key), payload: payload))
            else { return }
            data = enveloped
        }
        try? data.write(to: url(name), options: .atomic)
    }

    static func tag(_ payload: Data, key: Data) -> String {
        HMACSHA256.tag(key: key, message: payload).map { byte in
            let s = String(byte, radix: 16)
            return s.count == 1 ? "0" + s : s
        }.joined()
    }

    func appTransaction() -> AppTransactionSnapshot? { load(AppTransactionSnapshot.self, "app-transaction.json", authenticated: true) }
    func saveAppTransaction(_ snapshot: AppTransactionSnapshot) { save(snapshot, "app-transaction.json", authenticated: true) }

    struct EntitlementSnapshot: Codable {
        var entitlement: Entitlement
        var resolvedAt: Date
    }

    /// The last successful resolution, with lapsed subscriptions downgraded to free (a subscription in its billing
    /// grace period lapses at the grace end), and family-shared entitlements downgraded when the policy no longer
    /// admits them.
    func entitlementSnapshot(now: Date, familySharing: FamilySharingPolicy = .sharedEntitlements) -> Entitlement? {
        guard let snapshot = load(EntitlementSnapshot.self, "entitlement.json", authenticated: true) else { return nil }
        if case .subscribed(let subscription) = snapshot.entitlement, let endsAt = subscription.accessEndsAt, endsAt <= now {
            return .free
        }
        if familySharing == .purchaserOnly, snapshot.entitlement.isFamilyShared { return .free }
        return snapshot.entitlement == .unknown ? nil : snapshot.entitlement
    }

    func entitlementSnapshotDate() -> Date? { load(EntitlementSnapshot.self, "entitlement.json", authenticated: true)?.resolvedAt }

    func saveEntitlementSnapshot(_ entitlement: Entitlement, at date: Date = Date()) {
        guard entitlement != .unknown else { return }
        save(EntitlementSnapshot(entitlement: entitlement, resolvedAt: date), "entitlement.json", authenticated: true)
    }

    func grandfatherLogged() -> Bool { FileManager.default.fileExists(atPath: url("grandfathered.logged").path) }
    func markGrandfatherLogged() { _ = FileManager.default.createFile(atPath: url("grandfathered.logged").path, contents: Data()) }

    func storefront() -> PaywallStorefront? { load(PaywallStorefront.self, "storefront.json", authenticated: false) }
    func saveStorefront(_ storefront: PaywallStorefront) { save(storefront, "storefront.json", authenticated: false) }
}
