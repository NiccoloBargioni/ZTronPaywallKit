public import Foundation

/// A view's hold on `tokens` for one gate. In memory only: it can vanish with the process without consequence,
/// because nothing of value is delivered until it becomes a debit.
public struct Reservation: Hashable, Sendable {
    public let holder: UUID
    public let gateID: String
    public let tokens: Int
    public let source: PaywallSource
}

/// Device-local reservations, one per modifier instance.
@MainActor
public final class ReservationTable {
    public private(set) var byHolder: [UUID: Reservation] = [:]

    public init() {}

    public var total: Int { byHolder.values.reduce(0) { $0 + $1.tokens } }

    public func reservation(of holder: UUID) -> Reservation? { byHolder[holder] }

    /// Any hold on `gateID`, preferring `holder`'s own. Deterministic: the smallest holder id otherwise.
    public func reservation(forGate gateID: String, preferring holder: UUID?) -> Reservation? {
        if let holder, let own = byHolder[holder], own.gateID == gateID { return own }
        return byHolder.values.filter { $0.gateID == gateID }.min { $0.holder.uuidString < $1.holder.uuidString }
    }

    public func hold(_ reservation: Reservation) {
        byHolder[reservation.holder] = reservation
    }

    @discardableResult
    public func release(_ holder: UUID) -> Reservation? {
        byHolder.removeValue(forKey: holder)
    }
}
