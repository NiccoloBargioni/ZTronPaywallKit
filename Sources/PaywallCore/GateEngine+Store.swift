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
        let resolution = resolver.resolve(transactions: transactions, appTransaction: appTransaction, now: clock.now)
        lastResolution = clock.now
        if let grandfathered = resolution.grandfathered { recordGrandfather(grandfathered) }
        setEntitlement(resolution.entitlement, cause: cause)
        PaywallFiles(directory: directory).saveEntitlementSnapshot(resolution.entitlement, at: clock.now)
        armExpiryTimer(resolution.expiresAt)

        if let all = try? await store.allTransactions() {
            for planned in CreditReconciler.planRevocations(in: all, catalog: catalog, ledger: ledger) {
                applyPlanned(planned)
            }
        }
        reevaluateSessions()
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
            grant(tokens: n, reason: "grandfathered", id: "grant:grandfathered:\(snapshot.accountKey)")
        }
    }

    private func armExpiryTimer(_ expiresAt: Date?) {
        expiryTask?.cancel()
        expiryTask = nil
        guard let expiresAt else { return }
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

    // MARK: Purchases

    public func products() async throws -> [PaywallProduct] {
        let files = PaywallFiles(directory: directory)
        do {
            // The catalog is the authority on what a product is (StoreKit does not know a pack's size).
            let products = try await store.products(for: catalog.allProductIDs).map { product in
                var mapped = product
                mapped.kind = catalog.kind(of: product.id) ?? product.kind
                return mapped
            }
            files.savePrices(products, at: clock.now)
            return products
        } catch {
            // Offline: last-known prices with an "as of" date, and the buy button disabled.
            guard let cache = files.prices() else { throw error }
            return cache.products.map { product in
                var cached = product
                cached.priceAsOf = cache.at
                cached.isPurchasable = false
                return cached
            }
        }
    }

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
    }

    /// Return to foreground: re-resolve and drain the outbox.
    public func didBecomeActive() async {
        await refresh(cause: .foreground)
        scheduleSync(immediately: false)
    }

    // MARK: Sync

    /// Drains the outbox now, coalesced to one run per `syncCoalescing` seconds otherwise.
    func scheduleSync(immediately: Bool) {
        guard sync != nil, !isTerminated else { return }
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
        guard sync != nil, !isTerminated else { return }
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
        guard let sync, !isTerminated else { return }
        syncTask?.cancel()
        syncTask = nil
        lastSyncAt = clock.now
        let pending = journal.pendingUpload
        if !pending.isEmpty, let acknowledged = try? await sync.push(pending) {
            let ids = pending.map(\.id).filter(acknowledged.contains)
            if !ids.isEmpty, !isTerminated { try? journal.append(.uploaded(ids)) }
        }
        guard let remote = try? await sync.pull(), !isTerminated else { return }
        merge(remote)
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

    func persistSnapshot() {
        guard let sync else { return }
        let snapshot = WalletSnapshot(
            accountKey: accountKey, balance: ledger.balance(for: accountKey, baseline: baseline),
            lastEventID: ledger.events.last?.id, headHash: ledger.head(for: deviceID))
        snapshotTask?.cancel()
        snapshotTask = Task { await sync.saveSnapshot(snapshot) }
    }
}
