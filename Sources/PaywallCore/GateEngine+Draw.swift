public import Foundation
import Logging

/// The draw path, step by step. A step added here without a matching crash test fails to compile in the
/// observer's exhaustive switch and leaves a row missing from the parameterised proof.
public enum DrawStep: String, CaseIterable, Hashable, Sendable {
    /// Entitlement, lease and balance decided in memory.
    case decided
    /// The debit is one `write(2)` in the kernel's page cache.
    case debitAppended
    /// `F_FULLFSYNC` returned.
    case debitSynced
    /// The body ran or the `.deductNow` content rendered.
    case valueDelivered
    /// The audit record was enqueued.
    case auditWritten
}

public enum DrawObservation: Sendable {
    case proceed
    /// Simulated termination: the engine stops at this step as if the process died.
    case terminate
}

/// Sees every step of every draw. Production passes `nil`.
@MainActor
public protocol DrawObserver: AnyObject {
    func engine(_ engine: GateEngine, reached step: DrawStep) -> DrawObservation
}

/// An open gate between its decision and the end of the gated body. Sendable, so the async `withPaywall` can
/// carry it from the main actor to the caller's actor and back.
public struct GateTicket: Hashable, Sendable {
    public let level: GateLevel
    public let source: PaywallSource
    public let mode: GateOpenMode
    /// Set when this ticket wrote a debit.
    public let debitID: String?
    public let tokens: Int
    public let leaseUntil: Date?
    /// The view that pins the new lease, if a reservation was consumed.
    public let holder: UUID?

    public init(
        level: GateLevel, source: PaywallSource, mode: GateOpenMode, debitID: String?, tokens: Int, leaseUntil: Date?,
        holder: UUID?
    ) {
        self.level = level
        self.source = source
        self.mode = mode
        self.debitID = debitID
        self.tokens = tokens
        self.leaseUntil = leaseUntil
        self.holder = holder
    }
}

public enum GateBegin: Sendable {
    case open(GateTicket)
    case blocked(PaywallFailure)
}

extension GateEngine {
    /// Decide, and for `.tokens(N)` without a lease, draw write-ahead. The caller runs the body next and then
    /// calls `complete` or `abort`. `holder` is the committing view's session, if any.
    public func begin(_ level: GateLevel, source: PaywallSource, scope: String? = nil, holder: UUID? = nil) -> GateBegin {
        let gateID = source.id
        reportExpiredLease(gateID)
        if let holder, var session = sessions[holder] {
            session.committed = true
            sessions[holder] = session
        }
        // A view-held reservation for this gate is what a commit spends, so it does not count against itself.
        let consumed = reservations.reservation(forGate: gateID, preferring: holder)
        switch decide(level, gateID: gateID, excluding: consumed?.holder ?? holder) {
        case .closed(let reason):
            let failure = makeFailure(reason, level: level, source: source, scope: scope)
            emit(.gateEvaluated(source: source, level: level, decision: .closed(reason)))
            emit(.gateDenied(failure))
            return .blocked(failure)
        case .open(.affordable(let n)):
            switch draw(n, source: source, consuming: consumed, pinning: consumed?.holder ?? holder) {
            case .success(let ticket):
                emit(.gateEvaluated(source: source, level: level, decision: .open(.drawn(n))))
                emit(.gateOpened(source: source, level: level, mode: .drawn(n)))
                return .open(ticket)
            case .failure(let failure):
                emit(.gateEvaluated(source: source, level: level, decision: .closed(failure.reason)))
                emit(.gateDenied(failure))
                return .blocked(failure)
            }
        case .open(let mode):
            if mode == .leased {
                if let holder { pin(gateID, holder: holder) }
                if settings.leasePolicy == .refreshOnReentry { extendLease(gateID) }
            }
            emit(.gateEvaluated(source: source, level: level, decision: .open(mode)))
            emit(.gateOpened(source: source, level: level, mode: mode))
            return .open(
                GateTicket(level: level, source: source, mode: mode, debitID: nil, tokens: 0, leaseUntil: nil, holder: holder))
        }
    }

    /// Steps 1–3 of the write-ahead order. On success the debit is durable and the lease exists (it *is* the
    /// debit's `leaseUntil`); nothing of value has been delivered yet.
    func draw(_ n: Int, source: PaywallSource, consuming reservation: Reservation?, pinning holder: UUID?) -> Result<GateTicket, PaywallFailure> {
        let level = GateLevel.tokens(n)
        let storageFailure = makeFailure(.storageUnavailable, level: level, source: source, scope: nil)
        guard observe(.decided) else { return .failure(storageFailure) }

        let now = clock.now
        let leaseUntil = now.addingTimeInterval(settings.tolerance)
        let event = LedgerEvent(
            id: "debit:\(UUID().uuidString)", at: now, deviceID: deviceID, accountKey: accountKey, source: source,
            previousHash: ledger.head(for: deviceID), kind: .debit(tokens: n, leaseUntil: leaseUntil))
        do {
            try journal.write(.event(event, uploaded: false))
        } catch {
            logger.error("journal: debit write failed", metadata: ["error": "\(error)"])
            return .failure(storageFailure)
        }
        guard observe(.debitAppended) else { return .failure(storageFailure) }
        do {
            try journal.sync()
        } catch {
            // The bytes are in the page cache and survive a process death; only power loss can still take them.
            logger.warning("journal: sync failed after a debit", metadata: ["error": "\(error)"])
        }
        guard observe(.debitSynced) else { return .failure(storageFailure) }

        ledger.append(event)
        if let reservation { reservations.release(reservation.holder) }
        recomputeLeasesAndWallet(notify: true)
        if let holder { _ = leases.pin(source.id, holder: holder) }
        return .success(
            GateTicket(
                level: level, source: source, mode: .drawn(n), debitID: event.id, tokens: n, leaseUntil: leaseUntil,
                holder: holder))
    }

    /// Steps 4–5: the value was delivered; write the audit evidence. No-op for tickets without a draw.
    public func complete(_ ticket: GateTicket) {
        guard let debitID = ticket.debitID, let leaseUntil = ticket.leaseUntil else { return }
        guard observe(.valueDelivered) else { return }
        emit(.tokensConsumed(n: ticket.tokens, source: ticket.source, debitID: debitID, leaseUntil: leaseUntil),
             balanceBefore: wallet.balance + ticket.tokens)
        let holders = leases.holders(of: ticket.source.id).count
        emit(.leaseGranted(gateID: ticket.source.id, expiresAt: leaseUntil, holders: holders))
        if holders > 0 { emit(.leasePinned(gateID: ticket.source.id, expiresAt: leaseUntil, holders: holders)) }
        guard observe(.auditWritten) else { return }
        reevaluateSessions()
        scheduleSync(immediately: false)
    }

    /// The body threw after a draw: the feature did not run, so the draw is reversed and no lease remains.
    public func abort(_ ticket: GateTicket, error: any Error) {
        guard !isTerminated, let debitID = ticket.debitID else { return }
        if let holder = ticket.holder { _ = leases.unpin(ticket.source.id, holder: holder) }
        let reason = RefundReason.bodyThrew(String(describing: error))
        if appendLedger(id: LedgerEvent.refundID(debitID), kind: .refund(debitID: debitID, reason: reason), source: ticket.source) != nil {
            emit(.tokensRefunded(debitID: debitID, reason: reason))
        }
    }

    /// Decide, draw, run `body`, and audit, synchronously. A view-held reservation with the same gate id is
    /// consumed instead of a fresh draw.
    public func run<R>(
        _ level: GateLevel,
        source: PaywallSource,
        scope: String? = nil,
        holder: UUID? = nil,
        _ body: () throws -> R
    ) rethrows -> PaywallOutcome<R> {
        switch begin(level, source: source, scope: scope, holder: holder) {
        case .blocked(let failure):
            return .blocked(failure)
        case .open(let ticket):
            do {
                let value = try body()
                complete(ticket)
                return .executed(value)
            } catch {
                abort(ticket, error: error)
                throw error
            }
        }
    }

    /// `false` when the observer terminated the run here.
    private func observe(_ step: DrawStep) -> Bool {
        guard !isTerminated else { return false }
        guard let drawObserver else { return true }
        switch drawObserver.engine(self, reached: step) {
        case .proceed:
            return true
        case .terminate:
            terminate()
            return false
        }
    }
}
