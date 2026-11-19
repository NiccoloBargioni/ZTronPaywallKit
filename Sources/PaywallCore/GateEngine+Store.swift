public import Foundation
import Logging

extension GateEngine {
    // MARK: Resolution

    /// Re-derives the entitlement from `currentEntitlements` and the app transaction, reconciles revoked token packs,
    /// retries the pack credits the journal could not write, and re-arms the expiry timer.
    ///
    /// `currentEntitlements` and `Transaction.all` come from StoreKit's on-device cache. The app transaction comes from
    /// `AppTransaction.shared`, which asks the App Store when none is cached for this app version (typically the first
    /// launch), so this resolution can wait on the network; offline it fails and the cached snapshot, or the receipt
    /// behind the store client, answers. A lapsed subscription StoreKit still lists costs one more App Store read, for
    /// the end of its billing grace period. Never prompts.
    ///
    /// Resolutions overlap (a launch resolution stalled on the App Store while a purchase resolves). Each is stamped
    /// when it starts and applied only when no newer one was applied first, so a stale read never undoes a purchase
    /// or a refund resolved meanwhile.
    public func refresh(cause: EntitlementChangeCause) async {
        guard !isTerminated, !isShutDown else { return }
        resolutionGeneration += 1
        let generation = resolutionGeneration
        let transactions: [StoreTransaction]
        do {
            transactions = try await store.currentEntitlements()
        } catch {
            guard !isTerminated, !isShutDown else { return }
            // StoreKit's own reads never throw; a host-written store client's may, and the cached snapshot stands.
            let age = PaywallFiles(directory: directory, keyStore: fileKeyStore).entitlementSnapshotDate().map { clock.now.timeIntervalSince($0) }
            emit(.storeUnavailable(error: String(describing: error), snapshotAge: age))
            return
        }
        guard !isTerminated, !isShutDown else { return }
        // A fresh install offline has no AppTransaction; the cached snapshot (or the receipt behind the store
        // client) answers, and the grant is re-checked on the next online resolution.
        let fresh = try? await store.appTransaction()
        guard !isTerminated, !isShutDown else { return }
        let rebound = fresh.map { bind($0) } ?? false
        var graceEnd: Date?
        if resolver.needsGraceEnd(transactions: transactions, now: clock.now) {
            graceEnd = try? await store.renewalGraceEnd(groupID: catalog.subscriptionGroupID)
            guard !isTerminated, !isShutDown else { return }
        }
        if generation > lastAppliedGeneration {
            // Synchronous from here to the timer: nothing may run between the check and the apply.
            lastAppliedGeneration = generation
            let resolution = resolver.resolve(transactions: transactions, appTransaction: resolverInput, now: clock.now, graceEnd: graceEnd)
            lastResolution = clock.now
            if let grandfathered = resolution.grandfathered { recordGrandfather(grandfathered, storeAnswered: fresh != nil) }
            setEntitlement(resolution.entitlement, cause: cause)
            // Saved on every applied resolution: `resolvedAt` is the snapshot age `storeUnavailable` reports.
            PaywallFiles(directory: directory, keyStore: fileKeyStore).saveEntitlementSnapshot(resolution.entitlement, at: clock.now)
            armExpiryTimer(resolution.expiresAt)
        } else if rebound {
            // A newer resolution was applied while this one waited, and this one bound another app transaction, which
            // the grandfather rule reads: resolve once more, with a stamp of its own.
            Task { [weak self] in await self?.refresh(cause: cause) }
        }

        if let all = try? await store.allTransactions() {
            guard !isTerminated, !isShutDown else { return }
            for planned in CreditReconciler.planRevocations(in: all, catalog: catalog, ledger: ledger) {
                applyPlanned(planned)
            }
        }
        await retryUnfinishedPacks()
        guard !isTerminated, !isShutDown else { return }
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

    /// Binds the store's answer: the snapshot the resolver and the offer signing read, and the account partition the
    /// wallet counts. Returns whether anything changed.
    @discardableResult
    func bind(_ snapshot: AppTransactionSnapshot) -> Bool {
        let changed = snapshot != appTransaction
        appTransaction = snapshot
        let files = PaywallFiles(directory: directory, keyStore: fileKeyStore)
        files.saveAppTransaction(snapshot)
        let key = snapshot.accountKey
        if key != accountKey {
            accountKey = key
            recomputeLeasesAndWallet(notify: true)
            // The Keychain item is per account: a rebind writes this account's snapshot even when the balance stayed.
            persistSnapshot()
        }
        return changed
    }

    /// `storeAnswered`: the admitting snapshot came from the store in this very resolution. The token grant is minted
    /// only then, never from a cached snapshot alone, so a planted cache can mint nothing offline.
    private func recordGrandfather(_ snapshot: AppTransactionSnapshot, storeAnswered: Bool) {
        let files = PaywallFiles(directory: directory, keyStore: fileKeyStore)
        if !files.grandfatherLogged() {
            files.markGrandfatherLogged()
            emit(.grandfathered(
                originalAppVersion: snapshot.originalAppVersion, originalPurchaseDate: snapshot.originalPurchaseDate,
                environment: snapshot.environment))
        }
        if storeAnswered, case .tokens(let n) = grandfathering?.grant {
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

    /// Whether every event `transaction` implies is in the ledger: what must hold before it is finished, because a
    /// finished transaction is never delivered again.
    func landed(_ transaction: StoreTransaction) -> Bool {
        CreditReconciler.plan(for: transaction, catalog: catalog, ledger: ledger).isEmpty
    }

    func rememberUnfinished(_ transaction: StoreTransaction) {
        logger.warning("store: transaction left unfinished, its credit is not in the ledger", metadata: ["id": "\(transaction.id)"])
        guard !unfinishedPacks.contains(where: { $0.id == transaction.id }) else { return }
        unfinishedPacks.append(transaction)
    }

    /// Credits the packs whose write failed earlier, and finishes each one once its events landed.
    func retryUnfinishedPacks() async {
        guard !unfinishedPacks.isEmpty, !retryingUnfinished, !isTerminated, !isShutDown else { return }
        retryingUnfinished = true
        defer { retryingUnfinished = false }
        for transaction in unfinishedPacks {
            for planned in CreditReconciler.plan(for: transaction, catalog: catalog, ledger: ledger) {
                applyPlanned(planned)
            }
            guard landed(transaction) else { continue }
            unfinishedPacks.removeAll { $0.id == transaction.id }
            await store.finish(transactionID: transaction.id)
            guard !isTerminated, !isShutDown else { return }
        }
    }

    // MARK: Transaction.updates

    func startUpdatesListener() async {
        updatesTask?.cancel()
        let updates = await store.updates()
        guard !isShutDown else { return }
        updatesTask = Task { [weak self] in
            for await transaction in updates {
                guard let self, !Task.isCancelled else { return }
                await self.handle(transaction)
            }
        }
    }

    /// Credit or revoke, re-resolve, publish, log, and only then `finish()`: the transaction is finished once every
    /// event it implies is in the ledger, and not before. A credit the journal could not write leaves it unfinished,
    /// so StoreKit delivers it again at the next launch and the deterministic `credit:<id>` credits it once.
    /// Returns whether it was finished.
    @discardableResult
    public func handle(_ transaction: StoreTransaction) async -> Bool {
        guard !isTerminated, !isShutDown else { return false }
        for planned in CreditReconciler.plan(for: transaction, catalog: catalog, ledger: ledger) {
            applyPlanned(planned)
        }
        await refresh(cause: transaction.revocationDate != nil ? .revoked : .update)
        guard !isTerminated, !isShutDown else { return false }
        guard landed(transaction) else {
            rememberUnfinished(transaction)
            return false
        }
        await store.finish(transactionID: transaction.id)
        return true
    }

    /// A purchase that completed on an engine the facade had already shut down (a reconfigure during the payment
    /// sheet) lands here, on the current engine: credited, finished once the credit is in the ledger, and published as
    /// completed. Returns whether it was finished.
    @discardableResult
    public func adoptPurchase(_ transaction: StoreTransaction, source: PaywallSource?) async -> Bool {
        guard await handle(transaction) else { return false }
        emit(.purchase(stage: .completed, productID: transaction.productID, source: source, transactionID: transaction.id))
        await sync?.requestPull()
        scheduleSync(immediately: true)
        scheduleStorefrontRefresh()
        return true
    }

    // MARK: Promoted in-app purchases

    /// `PurchaseIntent.intents`: the user tapped a promoted product on the App Store. The engine publishes the
    /// intent and nothing more; the host's paywall opens on that product and the purchase goes through `purchase`.
    func startPurchaseIntentsListener() async {
        intentsTask?.cancel()
        let intents = await store.purchaseIntents()
        guard !isShutDown else { return }
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
        PaywallFiles(directory: directory, keyStore: fileKeyStore).saveStorefront(next)
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

    /// The credit is written before `finish()`, and `finish()` runs only once the credit is in the ledger: if the app
    /// dies in between, or the journal could not take the credit, `Transaction.updates` delivers the transaction again
    /// and the deterministic credit id makes the second write a no-op. A credit the journal refused answers `.pending`,
    /// like Ask to Buy: the tokens arrive when the transaction is delivered again (at the next resolution of this
    /// launch, or at the next launch). With `offer`, a promotional offer of the product, the signer is asked for this
    /// install's signature first and the store buys with it; a signing failure fails the purchase before the payment
    /// sheet, like a store error.
    public func purchase(productID: String, offer: PaywallProduct.Offer? = nil, source: PaywallSource?) async throws -> PurchaseOutcome {
        emit(.purchase(stage: .started, productID: productID, source: source, transactionID: nil))
        let result: StorePurchaseResult
        do {
            var signed: SignedPromotionalOffer?
            if let offer { signed = try await signPromotionalOffer(offer, productID: productID) }
            result = try await store.purchase(productID: productID, offer: signed)
        } catch {
            emit(.purchase(stage: .failed(String(describing: error)), productID: productID, source: source, transactionID: nil))
            throw error
        }
        switch result {
        case .success(let transaction):
            guard !isTerminated, !isShutDown else { return await handOff(transaction, source: source) }
            for planned in CreditReconciler.plan(for: transaction, catalog: catalog, ledger: ledger) {
                applyPlanned(planned)
            }
            await refresh(cause: .purchase)
            guard !isTerminated, !isShutDown else { return await handOff(transaction, source: source) }
            guard landed(transaction) else {
                rememberUnfinished(transaction)
                emit(.purchase(stage: .pending, productID: productID, source: source, transactionID: transaction.id))
                return .pending
            }
            await store.finish(transactionID: transaction.id)
            guard !isTerminated, !isShutDown else { return .purchased(transactionID: transaction.id) }
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

    /// Paid for after `shutdown()`: nothing durable happens on this engine. The facade's current engine takes the
    /// transaction (`onOrphanedPurchase`); with none, it stays unfinished for the next launch's `Transaction.updates`.
    private func handOff(_ transaction: StoreTransaction, source: PaywallSource?) async -> PurchaseOutcome {
        if let onOrphanedPurchase, await onOrphanedPurchase(transaction, source) { return .purchased(transactionID: transaction.id) }
        return .pending
    }

    /// Asks the signer for this install's signature of `offer` on `productID`: the one-time JWS the store takes. The
    /// request names the app (the settings' bundle id, else the app transaction's), the product, the offer and the
    /// app transaction id when the store reported one (iOS 16 and later), so the App Store can bind the offer to this
    /// customer. An empty id is no id: a third-party store client may hand one over.
    func signPromotionalOffer(_ offer: PaywallProduct.Offer, productID: String) async throws -> SignedPromotionalOffer {
        guard offer.kind == .promotional, let offerID = offer.id else { throw PromotionalOfferError.notPromotional }
        guard let signer = promotionalOfferSigner else { throw PromotionalOfferError.signerNotConfigured }
        guard let bundleID = settings.bundleID ?? appTransaction?.bundleID else { throw PromotionalOfferError.bundleIDUnknown }
        let transactionID = appTransaction?.appTransactionID.flatMap { $0.isEmpty ? nil : $0 }
        let request = PromotionalOfferSigningRequest(bundleID: bundleID, productID: productID, offerID: offerID, transactionID: transactionID)
        let signed = try await signer.sign(request)
        guard signed.productID == productID, signed.offerID == offerID else {
            // The answer's ids only: the token itself is single-use, and nothing of it belongs in a log.
            throw PromotionalOfferError.signatureMismatch(productID: signed.productID, offerID: signed.offerID)
        }
        emit(.promotionalOfferSigned(productID: productID, offerID: offerID))
        return signed
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
        guard !isTerminated, !isShutDown else { return }
        await refresh(cause: .restore)
        guard !isTerminated, !isShutDown else { return }
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
        guard !isShutDown else { return }
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
        if carrierHasAccount { await push(to: sync) }
        guard !isTerminated, !isShutDown else { return }
        // The engine owns the cursor: the carrier fetches from the journal's, and the cursor it hands back is written
        // with the merged events, in one write. A failed merge leaves it where it was, so the next fetch brings the
        // same events again; a shutdown meanwhile drops the answer for the successor to fetch.
        let pulled: LedgerPull?
        do {
            pulled = try await sync.pull(since: journal.cursor)
        } catch {
            return
        }
        guard let pulled, !isTerminated, !isShutDown else { return }
        let regained = !carrierHasAccount && pulled.accountAvailable
        carrierHasAccount = pulled.accountAvailable
        guard merge(pulled.events, cursor: pulled.cursor) else {
            await sync.requestPull()
            return
        }
        // The carrier has answered and the answer is durable: an account with no history anywhere is new.
        grantWelcomeIfNew()
        if regained { await push(to: sync) }
    }

    /// Uploads the outbox and acknowledges what the carrier took. Skipped while the last pull said the device has no
    /// account for the carrier: nothing would be taken, and encoding the outbox at every sync is what it would cost.
    private func push(to sync: any LedgerSync) async {
        let pending = journal.pendingUpload
        guard !pending.isEmpty else { return }
        // A push that fails is retried at the next sync; whether the device has an account is the pull's to say.
        guard let acknowledged = try? await sync.push(pending) else { return }
        guard !isTerminated, !isShutDown else { return }
        let ids = pending.map(\.id).filter(acknowledged.contains)
        if !ids.isEmpty {
            do {
                try journal.acknowledge(ids)
            } catch {
                logger.error("journal: acknowledgement failed", metadata: ["error": "\(error)"])
            }
        }
    }

    /// Union merge by id, with the carrier's `cursor` written in the same `write(2)` as the events it covers. Carriers
    /// only add events, so a merge can never remove a debit. Settles the Keychain baseline when the batch holds
    /// history for its account (events new to this ledger, so never this install's own echoed pushes), or its named
    /// last event. Returns whether everything landed: `true` with nothing fresh, `false` when the journal refused the
    /// write, in which case the ledger, the baseline and the cursor are as they were.
    @discardableResult
    public func merge(_ remote: [LedgerEvent], cursor: Data? = nil) -> Bool {
        guard !isTerminated, !isShutDown else { return false }
        var seen = Set<String>()
        let fresh = remote
            .filter { !ledger.contains($0.id) && seen.insert($0.id).inserted }
            .sorted { ($0.deviceID, $0.at) < ($1.deviceID, $1.at) }
        var entries: [JournalEntry] = fresh.map { .event($0, uploaded: true) }
        let settles = baseline.map { baseline in
            fresh.contains { $0.accountKey == baseline.accountKey || $0.accountKey == unboundAccountKey }
                || baseline.lastEventID.map { id in fresh.contains { $0.id == id } } ?? false
        } ?? false
        if settles { entries.append(.baselineSettled) }
        // The cursor is stored whenever the carrier moved it, with the events it covers (which may all be echoes of
        // this install's own pushes: the position still advances, so a device that only pushes never re-fetches its
        // history). An unchanged cursor writes nothing, so a quiet account costs no frame per pull.
        if let cursor, cursor != journal.cursor { entries.append(.cursor(cursor)) }
        guard !entries.isEmpty else { return true }
        let balanceBefore = wallet.balance
        do {
            try journal.append(contentsOf: entries)
        } catch {
            logger.error("journal: merge failed", metadata: ["error": "\(error)"])
            return false
        }
        for event in fresh { ledger.append(event) }
        if settles { baseline = nil }
        guard !fresh.isEmpty || settles else { return true }
        recomputeLeasesAndWallet(notify: true)
        if !fresh.isEmpty {
            let devices = Array(Set(fresh.map(\.deviceID))).sorted()
            emit(.syncMerged(count: fresh.count, fromDeviceIDs: devices), balanceBefore: balanceBefore)
        }
        reevaluateSessions()
        return true
    }

    /// The Keychain item: this account's balance, and while a baseline stands, the baseline's provenance (its last
    /// event, with the balance as baseline plus what this install wrote since), so a second reinstall, or a dropped
    /// log, adopts the same history again. Nothing is written while the engine is unbound and a baseline for a bound
    /// account stands (the item is that account's), and `{0, nil}` is never written (it says nothing and would replace
    /// another account's item).
    func persistSnapshot() {
        guard let sync, !isShutDown else { return }
        if accountKey == unboundAccountKey, let baseline, baseline.accountKey != unboundAccountKey { return }
        let lastEventID = baseline?.lastEventID ?? ledger.lastEventID
        let balance = ledger.balance(for: accountKey, baseline: baseline)
        guard balance != 0 || lastEventID != nil else { return }
        let snapshot = WalletSnapshot(accountKey: accountKey, balance: balance, lastEventID: lastEventID, headHash: ledger.head(for: deviceID))
        snapshotTask?.cancel()
        snapshotTask = Task { await sync.saveSnapshot(snapshot) }
    }
}
