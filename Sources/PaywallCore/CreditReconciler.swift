import Foundation

/// Turns token-pack transactions into the ledger events they imply, idempotently: credits keyed
/// `credit:<transactionID>`, revocations keyed `revocation:<transactionID>`. Pure.
public enum CreditReconciler {
    public struct Planned: Hashable, Sendable {
        public let id: String
        public let kind: LedgerEvent.Kind
    }

    /// The events `transaction` still needs. Non-pack products need none.
    public static func plan(for transaction: StoreTransaction, catalog: ProductCatalog, ledger: Ledger) -> [Planned] {
        guard let pack = catalog.tokenPack(for: transaction.productID) else { return [] }
        var planned: [Planned] = []
        let creditID = LedgerEvent.creditID(transaction.id)
        let revocationID = LedgerEvent.revocationID(transaction.id)
        if transaction.revocationDate == nil {
            if !ledger.contains(creditID) {
                planned.append(
                    Planned(
                        id: creditID,
                        kind: .credit(tokens: pack.tokens, productID: pack.productID, transactionID: transaction.id)))
            }
        } else if !ledger.contains(revocationID) {
            // A pack refunded before its credit was ever written still records the revocation, so the credit,
            // if it ever arrives (re-delivery, sync), nets to zero.
            if !ledger.contains(creditID) {
                planned.append(
                    Planned(
                        id: creditID,
                        kind: .credit(tokens: pack.tokens, productID: pack.productID, transactionID: transaction.id)))
            }
            planned.append(Planned(id: revocationID, kind: .revocation(transactionID: transaction.id)))
        }
        return planned
    }

    /// The events a scan of `Transaction.all` implies: revocations for refunded packs only. Unrevoked finished
    /// consumables are already credited (or synced) and are not replayed from here.
    public static func planRevocations(in transactions: [StoreTransaction], catalog: ProductCatalog, ledger: Ledger) -> [Planned] {
        var seen = ledger
        var planned: [Planned] = []
        for transaction in transactions where transaction.revocationDate != nil {
            for item in plan(for: transaction, catalog: catalog, ledger: seen) {
                planned.append(item)
                seen.append(
                    LedgerEvent(
                        id: item.id, at: .distantPast, deviceID: "", accountKey: "", source: nil,
                        previousHash: paywallGenesisHash, kind: item.kind))
            }
        }
        return planned
    }
}
