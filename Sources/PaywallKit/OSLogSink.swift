import Foundation
public import PaywallCore
import os

/// Audit records to the unified log: subsystem `ztron.paywall`, categories `gate`, `wallet`, `store`. The event
/// kind is public; ids and amounts are private (redacted unless a profile is installed).
public struct OSLogSink: PaywallAuditSink {
    private let gate = os.Logger(subsystem: "ztron.paywall", category: "gate")
    private let wallet = os.Logger(subsystem: "ztron.paywall", category: "wallet")
    private let store = os.Logger(subsystem: "ztron.paywall", category: "store")

    public init() {}

    public func write(_ record: AuditRecord) async {
        let detail = String(describing: record.event)
        let kind = String(detail.prefix { $0 != "(" })
        switch OSLogSink.category(of: record.event) {
        case .gate:
            gate.info("\(kind, privacy: .public) \(detail, privacy: .private) balance \(record.balanceAfter, privacy: .private)")
        case .wallet:
            wallet.info("\(kind, privacy: .public) \(detail, privacy: .private) balance \(record.balanceAfter, privacy: .private)")
        case .store:
            store.info("\(kind, privacy: .public) \(detail, privacy: .private)")
        }
    }

    enum Category: Hashable { case gate, wallet, store }

    static func category(of event: PaywallEvent) -> Category {
        switch event {
        case .gateEvaluated, .gateOpened, .gateDenied, .leaseGranted, .leasePinned, .leaseUnpinned, .leaseExtended,
            .leaseExpired, .reservedWithoutCommit:
            return .gate
        case .tokensReserved, .tokensReleased, .tokensConsumed, .tokensRefunded, .tokensCredited, .tokensRevoked,
            .tokensGranted, .syncMerged, .auditRepaired:
            return .wallet
        case .entitlementChanged, .purchase, .purchaseIntent, .promotionalOfferSigned, .restore, .grandfathered, .storeUnavailable,
            .storefrontChanged:
            return .store
        }
    }
}
