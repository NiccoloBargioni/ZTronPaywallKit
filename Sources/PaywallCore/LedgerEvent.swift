public import Foundation

public enum RefundReason: Hashable, Codable, Sendable {
    /// The gated body threw after the draw, so the feature did not run.
    case bodyThrew(String)
}

/// One immutable entry of the token ledger. The balance is derived from these, never stored.
public struct LedgerEvent: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: Codable, Hashable, Sendable {
        case credit(tokens: Int, productID: String, transactionID: UInt64)
        /// A refunded token pack: reverses the credit with the same transaction id.
        case revocation(transactionID: UInt64)
        /// One draw. The lease is this field and nothing else.
        case debit(tokens: Int, leaseUntil: Date)
        /// `.refreshOnReentry` only.
        case leaseExtended(debitID: String, until: Date)
        /// The gated body threw: gives the debit's tokens back and cancels its lease.
        case refund(debitID: String, reason: RefundReason)
        /// Welcome tokens, support credit.
        case grant(tokens: Int, reason: String)
    }

    /// Credits `"credit:<transactionID>"`, revocations `"revocation:<transactionID>"`, refunds `"refund:<debitID>"`,
    /// so a StoreKit re-delivery or a replayed sync is a no-op. Debits and grants carry a UUID.
    public let id: String
    public let at: Date
    /// Which device wrote it.
    public let deviceID: String
    /// The Apple Account partition. The wallet sums the current account's events only.
    public let accountKey: String
    /// The gate, for debits and refunds.
    public let source: PaywallSource?
    /// SHA-256 of the previous event written by the same device: a hash chain per device stream, which detects
    /// corruption and edits that do not rewrite the events after them. Not tamper-proof against whoever controls the
    /// device: the chain is unkeyed and its head is not anchored anywhere else.
    public let previousHash: String
    public let kind: Kind

    public init(
        id: String,
        at: Date,
        deviceID: String,
        accountKey: String,
        source: PaywallSource?,
        previousHash: String,
        kind: Kind
    ) {
        self.id = id
        self.at = at
        self.deviceID = deviceID
        self.accountKey = accountKey
        self.source = source
        self.previousHash = previousHash
        self.kind = kind
    }

    /// SHA-256 over the canonical JSON encoding. The next event from the same device links to it.
    public var hash: String {
        // Encoding a value made only of strings, numbers and dates cannot fail.
        let data = (try? CanonicalJSON.encoder().encode(self)) ?? Data()
        return SHA256Digest.hex(data)
    }

    /// The canonical JSON every carrier stores: sorted keys, dates as seconds since 1970.
    public func canonicalData() throws -> Data { try CanonicalJSON.encoder().encode(self) }

    public init(canonicalData: Data) throws {
        self = try CanonicalJSON.decoder().decode(LedgerEvent.self, from: canonicalData)
    }

    public static func creditID(_ transactionID: UInt64) -> String { "credit:\(transactionID)" }
    public static func revocationID(_ transactionID: UInt64) -> String { "revocation:\(transactionID)" }
    public static func refundID(_ debitID: String) -> String { "refund:\(debitID)" }
}
