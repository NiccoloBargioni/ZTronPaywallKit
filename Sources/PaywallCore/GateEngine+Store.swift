import Foundation
import Logging

extension GateEngine {
    // MARK: Resolution

    /// Re-derives the entitlement from `currentEntitlements` (StoreKit's on-device cache) and the app transaction,
    /// reconciles revoked token packs, and re-arms the expiry timer. Never waits for the network.
    public func refresh(cause: EntitlementChangeCause) async {
        guard !isTerminated else { return }
        let transactions: [StoreTransaction]
        do {
            transactions = try await store.currentEntitlements()
        } catch {
            let age = PaywallFiles(directory: directory).entitlementSnapshotDate().map { clock.now.timeIntervalSince($0) }
            emit(.storeUnavailable(error: String(describing: error), snapshotAge: age))
            return
        }
        // A fresh install offline has no AppTransaction; the cached snapshot (or the receipt behind the store
        // client) answers, and the grant is re-checked on the next online resolution.
        if let fresh = try? await store.appTransaction() {
            bind(fresh)
        }
        guard !isTerminated else { return }
        let resolution = resolver.resolve(transactions: transactions, appTransaction: resolverInput, now: clock.now)
        lastResolution = clock.now
        if let grandfathered = resolution.grandfathered { recordGrandfather(grandfathered) }
        setEntitlement(resolution.entitlement, cause: cause)
        // Saved on every successful resolution: `resolvedAt` is the snapshot age `storeUnavailable` reports.
        PaywallFiles(directory: directory).saveEntitlementSnapshot(resolution.entitlement, at: clock.now)
        armExpiryTimer(resolution.expiresAt)

        if let all = try? await store.allTransactions() {
            for planned in CreditReconciler.planRevocations(in: all, catalog: catalog, ledger: ledger) {
                applyPlanned(planned)
            }
        }
        reevaluateSessions()
    }

    /// The app transaction the resolver sees: the bound one, unless a debug build overrides it.
    var resolverInput: AppTransactionSnapshot? {
        #if DEBUG
            if let override = settings.grandfatherOverride {
                return override.apply(to: appTransaction, bundleID: appTransaction?.bundleID ?? "debug.override")
            }
        #endif
        return appTransaction
    }

    func bind(_ snapshot: AppTransactionSnapshot) {
        appTransaction = snapshot
        let files = PaywallFiles(directory: directory)
        files.saveAppTransaction(snapshot)
        let key = snapshot.accountKey
        if key != accountKey {
            accountKey = key
            files.saveAccountKey(key)
            recomputeLeasesAndWallet(notify: true)
        }
    }

    private func recordGrandfather(_ snapshot: AppTransactionSnapshot) {
        let files = PaywallFiles(directory: directory)
        if !files.grandfatherLogged() {
            files.markGrandfatherLogged()
            emit(.grandfathered(
                originalAppVersion: snapshot.originalAppVersion, originalPurchaseDate: snapshot.originalPurchaseDate,
                environment: snapshot.environment))
        }
        if case .tokens(let n) = grandfathering?.grant {
            grant(tokens: n, reason: "grandfathered", id: "grant:grandfathered:\(accountKey)")
        }
    }

    private func armExpiryTimer(_ expiresAt: Date?) {
        expiryTask?.cancel()
        expiryTask = nil
        guard let expiresAt, !isShutDown else { return }
        let clock = clock
        expiryTask = Task { [weak self] in
            do {
                try await clock.sleep(until: expiresAt)
            } catch {
                return
            }
            await self?.refresh(cause: .expiryTimer)
        }
    }

    func applyPlanned(_ planned: CreditReconciler.Planned) {
        let balanceBefore = wallet.balance
        guard appendLedger(id: planned.id, kind: planned.kind) != nil else { return }
        // The reconciler only plans credits and revocations.
        if case .credit(let tokens, let productID, let transactionID) = planned.kind {
            emit(.tokensCredited(n: tokens, productID: productID, transactionID: transactionID), balanceBefore: balanceBefore)
        } else if case .revocation(let transactionID) = planned.kind {
            emit(.tokensRevoked(transactionID: transactionID, n: ledger.creditTokens(transactionID: transactionID) ?? 0),
                 balanceBefore: balanceBefore)
        }
    }

    // MARK: Transaction.updates

    func startUpdatesListener() async {
        updatesTask?.cancel()
        let updates = await store.updates()
        updatesTask = Task { [weak self] in
            for await transaction in updates {
                guard let self, !Task.isCancelled else { return }
                await self.handle(transaction)
            }
        }
    }

    /// Credit or revoke, re-resolve, publish, log, and only then `finish()`.
    public func handle(_ transaction: StoreTransaction) async {
        guard !isTerminated else { return }
        for planned in CreditReconciler.plan(for: transaction, catalog: catalog, ledger: ledger) {
            applyPlanned(planned)
        }
        await refresh(cause: transaction.revocationDate != nil ? .revoked : .update)
        guard !isTerminated else { return }
        await store.finish(transactionID: transaction.id)
    }

    // MARK: Promoted in-app purchases

    /// `PurchaseIntent.intents`: the user tapped a promoted product on the App Store. The engine publishes the
    /// intent and nothing more; the host's paywall opens on that product and the purchase goes through `purchase`.
    func startPurchaseIntentsListener() async {
        intentsTask?.cancel()
        let intents = await store.purchaseIntents()
        intentsTask = Task { [weak self] in
            for await productID in intents {
                guard let self, !Task.isCancelled else { return }
                self.emit(.purchaseIntent(productID: productID))
            }
        }
    }

    // MARK: Storefront

    /// What the paywall screen shows: the storefront fetched now, or offline the last one with its prices marked
    /// `priceAsOf` and the buy button disabled. Throws when nothing was ever fetched.
    public func products() async throws -> [PaywallProduct] {
        do {
            return try await refreshStorefront().products
        } catch {
            guard let cached = storefront else { throw error }
            return cached.products.map { product in
                var offline = product
                offline.priceAsOf = cached.fetchedAt
                offline.isPurchasable = false
                return offline
            }
        }
    }

    /// Fetches the catalog's products from the store: what it sells right now, with prices and offers, in catalog
    /// order. The result replaces `storefront`, is saved next to the journal, and is published as
    /// `.storefrontChanged` when the listing differs from the last one. Throws offline; `storefront` then still holds
    /// the last fetch, from this launch or from disk.
    public func refreshStorefront() async throws -> PaywallStorefront {
        let fetched = try await store.products(for: catalog.allProductIDs)
        let countryCode = await store.storefrontCountryCode()
        guard !isTerminated, !isShutDown else { throw CancellationError() }
        var listed: [PaywallProduct] = []
        var unavailable: [String] = []
        for entry in catalog.entries where !entry.isRetired {
            if var product = fetched.first(where: { $0.id == entry.productID }) {
                // The catalog is the authority on what a product is (StoreKit does not know a pack's size).
                product.kind = entry.kind
                listed.append(product)
            } else {
                unavailable.append(entry.productID)
            }
        }
        let next = PaywallStorefront(products: listed, unavailableProductIDs: unavailable, countryCode: countryCode, fetchedAt: clock.now)
        let changed = storefront.map { !$0.hasSameListing(as: next) } ?? true
        storefront = next
        PaywallFiles(directory: directory).saveStorefront(next)
        if changed { emit(.storefrontChanged(productIDs: listed.map(\.id), countryCode: countryCode)) }
        onStateChange?()
        return next
    }

    /// Launch and foreground: a fetch when the storefront was never fetched or is older than
    /// `settings.storefrontRefreshInterval`. Offline, the last one stands.
    func refreshStorefrontIfStale() async {
        if let storefront, clock.now.timeIntervalSince(storefront.fetchedAt) < settings.storefrontRefreshInterval { return }
        _ = try? await refreshStorefront()
    }

    /// After a purchase or a restore, what this account may buy and at what price changed (the trial is used up, a
    /// win-back offer appeared): a fetch in the background, so the purchase answers without waiting for the store.
    /// One fetch at a time.
    func scheduleStorefrontRefresh() {
        guard storefrontTask == nil, !isTerminated, !isShutDown else { return }
        storefrontTask = Task { [weak self] in
            _ = try? await self?.refreshStorefront()
            self?.storefrontTask = nil
        }
    }

    // MARK: Purchases

    /// The credit is written before `finish()`: if the app dies in between, `Transaction.updates` re-delivers the
    /// transaction and the deterministic credit id makes the second write a no-op.
    public func purchase(productID: String, source: PaywallSource?) async throws -> PurchaseOutcome {
        emit(.purchase(stage: .started, productID: productID, source: source, transactionID: nil))
        let result: StorePurchaseResult
        do {
            result = try await store.purchase(productID: productID)
        } catch {
            emit(.purchase(stage: .failed(String(describing: error)), productID: productID, source: source, transactionID: nil))
            throw error
        }
        switch result {
        case .success(let transaction):
            for planned in CreditReconciler.plan(for: transaction, catalog: catalog, ledger: ledger) {
                applyPlanned(planned)
            }
            await refresh(cause: .purchase)
            await store.finish(transactionID: transaction.id)
            emit(.purchase(stage: .completed, productID: productID, source: source, transactionID: transaction.id))
            await sync?.requestPull()
            scheduleSync(immediately: true)
            scheduleStorefrontRefresh()
            return .purchased(transactionID: transaction.id)
        case .pending:
            emit(.purchase(stage: .pending, productID: productID, source: source, transactionID: nil))
            return .pending
        case .userCancelled:
            emit(.purchase(stage: .cancelled, productID: productID, source: source, transactionID: nil))
            return .cancelled
        }
    }

    /// `AppStore.sync()` then re-resolve, then pull the token history. Wire it to the Restore button only.
    public func restore() async throws {
        emit(.restore(stage: .requested))
        do {
            try await store.sync()
        } catch {
            emit(.restore(stage: .failed(String(describing: error))))
            throw error
        }
        await refresh(cause: .restore)
        emit(.restore(stage: .completed))
        await sync?.requestPull()
        await syncNow()
        scheduleStorefrontRefresh()
    }

    /// Return to foreground: re-resolve, drain the outbox, and fetch the storefront when the last one is stale.
    public func didBecomeActive() async {
        await refresh(cause: .foreground)
        scheduleSync(immediately: false)
        await refreshStorefrontIfStale()
    }

    // MARK: Connectivity

    func startConnectivityListener() async {
        connectivityTask?.cancel()
        guard let connectivity else { return }
        let paths = await connectivity.paths()
        connectivityTask = Task { [weak self] in
            for await hasPath in paths {
                guard let self, !Task.isCancelled else { return }
                self.networkPathChanged(hasPath)
            }
        }
    }

    /// A returning path drains the outbox at once (and pulls), instead of waiting for the next trigger.
    func networkPathChanged(_ hasPath: Bool) {
        let restored = hasPath && !hasNetworkPath
        hasNetworkPath = hasPath
        if restored { scheduleSync(immediately: true) }
    }

    // MARK: Sync

    /// Drains the outbox now, coalesced to one run per `syncCoalescing` seconds otherwise.
    func scheduleSync(immediately: Bool) {
        guard sync != nil, !isTerminated, !isShutDown else { return }
        if immediately {
            syncTask?.cancel()
            syncTask = nil
            Task { [weak self] in await self?.syncNow() }
            return
        }
        guard syncTask == nil else { return }
        let due = (lastSyncAt ?? .distantPast).addingTimeInterval(settings.syncCoalescing)
        let clock = clock
        syncTask = Task { [weak self] in
            do {
                try await clock.sleep(until: due)
            } catch {
                return
            }
            await self?.syncNow()
        }
    }

    /// Push the outbox, pull and union-merge remote events. Waits for a sync already in flight, then runs once
    /// more, so a caller always sees its own events pushed. Nothing in the gate path waits for this.
    public func syncNow() async {
        while let running = runningSync { await running.value }
        guard sync != nil, !isTerminated, !isShutDown else { return }
        // The task clears itself before it completes, so a waiter that resumes never sees a finished task
        // (awaiting a finished task does not suspend, and the loop above would spin on the main actor).
        let task = Task {
            await self.performSync()
            self.runningSync = nil
        }
        runningSync = task
        await task.value
    }

    private func performSync() async {
        // The coalescing timer that led here is spent either way; a stale handle would block the next one.
        syncTask?.cancel()
        syncTask = nil
        guard let sync, !isTerminated, !isShutDown, hasNetworkPath else { return }
        lastSyncAt = clock.now
        let pending = journal.pendingUpload
        if !pending.isEmpty, let acknowledged = try? await sync.push(pending) {
            let ids = pending.map(\.id).filter(acknowledged.contains)
            if !ids.isEmpty, !isTerminated, !isShutDown { try? journal.append(.uploaded(ids)) }
        }
        guard let remote = try? await sync.pull(), !isTerminated, !isShutDown else { return }
        merge(remote)
        settleBaseline(afterPulling: remote)
        // The carrier has answered: an account with no history anywhere is new.
        grantWelcomeIfNew()
    }

    /// Union merge by id. Carriers only add events, so a merge can never remove a debit.
    public func merge(_ remote: [LedgerEvent]) {
        var seen = Set<String>()
        let fresh = remote
            .filter { !ledger.contains($0.id) && seen.insert($0.id).inserted }
            .sorted { ($0.deviceID, $0.at) < ($1.deviceID, $1.at) }
        guard !fresh.isEmpty else { return }
        let balanceBefore = wallet.balance
        do {
            try journal.append(contentsOf: fresh.map { .event($0, uploaded: true) })
        } catch {
            logger.error("journal: merge failed", metadata: ["error": "\(error)"])
            return
        }
        for event in fresh { ledger.append(event) }
        recomputeLeasesAndWallet(notify: true)
        let devices = Array(Set(fresh.map(\.deviceID))).sorted()
        emit(.syncMerged(count: fresh.count, fromDeviceIDs: devices), balanceBefore: balanceBefore)
        reevaluateSessions()
    }

    /// After a reinstall the Keychain snapshot stands in for the history this install has not seen. Once the
    /// carrier has answered with events for this account, the snapshot has done its job: if its last event is
    /// among them the ledger is complete; if not, that event was never uploaded and died with the old install, and
    /// keeping the snapshot on top of the remote history would count every uploaded credit twice. Either way the
    /// carrier is the truth from here. A carrier that answers with nothing (iCloud off, empty container) leaves the
    /// snapshot standing.
    func settleBaseline(afterPulling remote: [LedgerEvent]) {
        guard let baseline else { return }
        let seenLast = baseline.lastEventID.map(ledger.contains) ?? true
        let answered = remote.contains { $0.accountKey == accountKey || $0.accountKey == unboundAccountKey }
        guard seenLast || answered else { return }
        self.baseline = nil
        recomputeLeasesAndWallet(notify: true)
        reevaluateSessions()
    }

    func persistSnapshot() {
        guard let sync, !isShutDown else { return }
        let snapshot = WalletSnapshot(
            accountKey: accountKey, balance: ledger.balance(for: accountKey, baseline: baseline),
            lastEventID: ledger.lastEventID, headHash: ledger.head(for: deviceID))
        snapshotTask?.cancel()
        snapshotTask = Task { await sync.saveSnapshot(snapshot) }
    }
}
