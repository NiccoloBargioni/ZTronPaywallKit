import Foundation
public import PaywallCore

/// Runs `body` behind a gate. Evaluates the gate against the entitlement and the wallet, logs the decision, and
/// either returns `.blocked` (and publishes the failure) or, for `.tokens(N)` without an active lease, draws `N`
/// write-ahead, grants a lease for `tolerance` seconds, and runs `body`. A view-held reservation with the same id
/// is consumed instead of a fresh draw. If `body` throws after a draw, the draw is reversed.
///
/// `.blocked` is a value, never a thrown error: a non-throwing body needs no `try`. Use `.get()` for the throwing
/// style.
@MainActor
@discardableResult
public func withPaywall<Result>(
    _ level: GateLevel = .free,
    id: String? = nil,
    fileID: String = #fileID,
    function: String = #function,
    line: Int = #line,
    _ body: () throws -> Result
) rethrows -> PaywallOutcome<Result> {
    let source = PaywallSource(id: id, fileID: fileID, function: function, line: line)
    return try Paywall.active.run(level, source: source, scope: nil, holder: nil, body)
}

/// The async twin: the decision costs one hop to the main actor and back, and `body` runs on the caller's actor.
@discardableResult
public func withPaywall<Result>(
    _ level: GateLevel = .free,
    id: String? = nil,
    fileID: String = #fileID,
    function: String = #function,
    line: Int = #line,
    isolation: isolated (any Actor)? = #isolation,
    _ body: () async throws -> Result
) async rethrows -> PaywallOutcome<Result> {
    let source = PaywallSource(id: id, fileID: fileID, function: function, line: line)
    return try await gatedAsync(level, source: source, scope: nil, holder: nil, body)
}

/// Shared by the free function and `GateSession`.
func gatedAsync<Result>(
    _ level: GateLevel,
    source: PaywallSource,
    scope: String?,
    holder: UUID?,
    isolation: isolated (any Actor)? = #isolation,
    _ body: () async throws -> Result
) async rethrows -> PaywallOutcome<Result> {
    switch await Paywall.begin(level, source: source, scope: scope, holder: holder) {
    case .blocked(let failure):
        return .blocked(failure)
    case .open(let ticket):
        do {
            let value = try await body()
            await Paywall.complete(ticket)
            return .executed(value)
        } catch {
            await Paywall.abort(ticket, error: error)
            throw error
        }
    }
}

