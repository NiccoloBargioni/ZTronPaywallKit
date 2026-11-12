public import Foundation

/// Where a gate lives: the lease key, the log key, and the call site that produced it.
public struct PaywallSource: Hashable, Codable, Sendable {
    /// The lease and log key. Defaults to `"<fileID>:<line>"`; pass an explicit id for any gate
    /// whose lease must survive a rebuild, because line numbers move.
    public let id: String
    public let fileID: String
    public let function: String
    public let line: Int

    public init(id: String? = nil, fileID: String, function: String, line: Int) {
        self.id = id ?? "\(fileID):\(line)"
        self.fileID = fileID
        self.function = function
        self.line = line
    }
}

/// A closed gate. `Identifiable`, so it can drive `.sheet(item:)` directly.
public struct PaywallFailure: Error, Identifiable, Hashable, Codable, Sendable {
    public enum Reason: Hashable, Codable, Sendable {
        case requiresPaid
        case insufficientTokens(needed: Int, available: Int)
        /// The store is unreachable and no snapshot exists (fresh install, offline).
        case entitlementUnavailable
        /// The journal could not be written, so no draw can be made durable. Fails closed.
        case storageUnavailable
    }

    public let id: UUID
    public let reason: Reason
    public let level: GateLevel
    public let source: PaywallSource
    public let at: Date
    /// The `.paywallScope` the gate was evaluated in, if any. `.onPaywallFailure(in:)` filters on it.
    public let scope: String?

    public init(
        id: UUID = UUID(),
        reason: Reason,
        level: GateLevel,
        source: PaywallSource,
        at: Date,
        scope: String? = nil
    ) {
        self.id = id
        self.reason = reason
        self.level = level
        self.source = source
        self.at = at
        self.scope = scope
    }

    /// Marks the failure as handled, so it does not fall through to `Paywall.pendingFailure`.
    /// Call it from an `.onPaywallFailure` handler after routing somewhere.
    @MainActor public func claim() {
        PaywallFailureClaims.shared.claim(id)
    }

    @MainActor public var isClaimed: Bool {
        PaywallFailureClaims.shared.isClaimed(id)
    }

    /// Drops the claim record once the fallback window for this failure has closed.
    @MainActor public func forgetClaim() {
        PaywallFailureClaims.shared.forget(id)
    }
}

/// The claim registry. Main-actor state, cleared when the fallback window for a failure closes.
@MainActor
final class PaywallFailureClaims {
    static let shared = PaywallFailureClaims()
    private var claimed: Set<UUID> = []

    func claim(_ id: UUID) { claimed.insert(id) }
    func isClaimed(_ id: UUID) -> Bool { claimed.contains(id) }
    func forget(_ id: UUID) { claimed.remove(id) }
}

/// What a gated call returns. `.blocked` is a value, never a thrown error.
public enum PaywallOutcome<Success> {
    case executed(Success)
    case blocked(PaywallFailure)

    public var value: Success? {
        if case .executed(let value) = self { return value }
        return nil
    }

    public var failure: PaywallFailure? {
        if case .blocked(let failure) = self { return failure }
        return nil
    }

    /// The throwing style: returns the value or throws the `PaywallFailure`.
    public func get() throws(PaywallFailure) -> Success {
        switch self {
        case .executed(let value): return value
        case .blocked(let failure): throw failure
        }
    }
}

extension PaywallOutcome: Sendable where Success: Sendable {}
extension PaywallOutcome: Equatable where Success: Equatable {}
