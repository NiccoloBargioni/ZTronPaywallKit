public import Combine
public import Foundation
public import PaywallCore
public import SwiftUI

/// What gated content finds in `\.paywallGate`: the gate it lives behind, so a button inside commits with
/// `gate.withPaywall { export() }` without repeating the level or the id.
public struct GateSession: Hashable, Sendable {
    public let level: GateLevel
    public let source: PaywallSource
    public var isOpen: Bool
    let holder: UUID
    let scope: String?

    public init(level: GateLevel, source: PaywallSource, isOpen: Bool, holder: UUID = UUID(), scope: String? = nil) {
        self.level = level
        self.source = source
        self.isOpen = isOpen
        self.holder = holder
        self.scope = scope
    }

    /// Commits the view's reservation (or draws) and runs `body`. Inherits the level and the id.
    @MainActor
    @discardableResult
    public func withPaywall<R>(_ body: () throws -> R) rethrows -> PaywallOutcome<R> {
        try Paywall.active.run(level, source: source, scope: scope, holder: holder, body)
    }

    @discardableResult
    public func withPaywall<R>(
        isolation: isolated (any Actor)? = #isolation, _ body: () async throws -> R
    ) async rethrows -> PaywallOutcome<R> {
        try await gatedAsync(level, source: source, scope: scope, holder: holder, body)
    }
}

private struct PaywallGateKey: EnvironmentKey {
    static let defaultValue: GateSession? = nil
}

private struct PaywallScopeKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

private struct PaywallPresenceKey: EnvironmentKey {
    static var defaultValue: AnyPublisher<Bool, Never>? { nil }
}

private struct PaywallEntitlementKey: EnvironmentKey {
    static let defaultValue: Entitlement? = nil
}

extension EnvironmentValues {
    /// The gate of the enclosing `.paywallGated` content. A convenience: correctness never rests on it, because
    /// environment values stop at UIKit boundaries.
    public var paywallGate: GateSession? {
        get { self[PaywallGateKey.self] }
        set { self[PaywallGateKey.self] = newValue }
    }

    /// The scope set by `.paywallScope(_:)`, stamped on failures so `.onPaywallFailure(in:)` can filter.
    public var paywallScope: String? {
        get { self[PaywallScopeKey.self] }
        set { self[PaywallScopeKey.self] = newValue }
    }

    /// A container-provided presence signal (`PaywallHostingController` sets it). Used when a gate passes none.
    public var paywallPresence: AnyPublisher<Bool, Never>? {
        get { self[PaywallPresenceKey.self] }
        set { self[PaywallPresenceKey.self] = newValue }
    }

    /// The resolved entitlement, `nil` until the first resolution has answered (`Entitlement.unknown`). Set by
    /// `.paywallSheet`, `.paywallLifecycle()` and `PaywallHostingController`, and kept current from
    /// `Paywall.entitlement`. For display: gates and `withPaywall` are the only authority on access.
    public var paywallEntitlement: Entitlement? {
        get { self[PaywallEntitlementKey.self] }
        set { self[PaywallEntitlementKey.self] = newValue }
    }
}

extension Entitlement {
    /// `nil` while unresolved, so the environment can say "not yet" instead of "free".
    var resolved: Entitlement? { self == .unknown ? nil : self }
}

/// The latest failure of a `.paywallGated` view, for ancestors that use `.onPreferenceChange`. Flows only while
/// the gated view is in the tree; the coordinator (`pendingFailure`) covers the same cases without that gap.
public struct PaywallFailureKey: PreferenceKey {
    public static let defaultValue: PaywallFailure? = nil
    public static func reduce(value: inout PaywallFailure?, nextValue: () -> PaywallFailure?) {
        value = nextValue() ?? value
    }
}

extension View {
    /// Gates this view. On appear (or while `presence` says true) the engine opens a session: open renders the
    /// content with a `GateSession` in `\.paywallGate`; closed renders nothing and publishes the failure. On
    /// disappear (or `presence` false) an unused reservation is released and the lease unpinned. A refund or an
    /// expiry while on screen flips the view live.
    ///
    /// - `.reserve` (default) holds `N` and spends only when something inside commits through
    ///   `gate.withPaywall`. The content is a shell; the paid value must be what the commit runs.
    /// - `.deductNow` draws on appear: use it when the content itself is the value.
    /// - `id` defaults to `"<fileID>:<line>"`; pass a stable one when the lease must survive a rebuild.
    public func paywallGated(
        _ level: GateLevel = .free,
        policy: TokenPolicy = .reserve,
        id: String? = nil,
        presence: AnyPublisher<Bool, Never>? = nil,
        fileID: String = #fileID,
        function: String = #function,
        line: Int = #line
    ) -> some View {
        modifier(
            PaywallGateModifier(
                level: level, policy: policy,
                source: PaywallSource(id: id, fileID: fileID, function: function, line: line),
                presence: presence, denied: { _ in EmptyView() }))
    }

    /// Gates this view and renders `denied` with the failure when closed.
    public func paywallGated<Denied: View>(
        _ level: GateLevel = .free,
        policy: TokenPolicy = .reserve,
        id: String? = nil,
        presence: AnyPublisher<Bool, Never>? = nil,
        fileID: String = #fileID,
        function: String = #function,
        line: Int = #line,
        @ViewBuilder denied: @escaping (PaywallFailure) -> Denied
    ) -> some View {
        modifier(
            PaywallGateModifier(
                level: level, policy: policy,
                source: PaywallSource(id: id, fileID: fileID, function: function, line: line),
                presence: presence, denied: denied))
    }
}

/// Owns one session (one holder id) for the lifetime of the modifier instance.
@MainActor
final class GateSessionModel: ObservableObject {
    let holder = UUID()
    @Published private(set) var state: GateSessionState?
    private var isOpen = false
    private weak var paywall: Paywall?

    func open(on paywall: Paywall, level: GateLevel, policy: TokenPolicy, source: PaywallSource, scope: String?) {
        guard !isOpen else { return }
        isOpen = true
        self.paywall = paywall
        state = paywall.openSession(
            holder: holder, level: level, policy: policy, source: source, scope: scope
        ) { [weak self] next in
            self?.state = next
        }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        paywall?.closeSession(holder: holder)
    }

    var session: GateSession? {
        guard let state else { return nil }
        return GateSession(level: state.level, source: state.source, isOpen: state.isOpen, holder: holder, scope: state.scope)
    }
}

struct PaywallGateModifier<Denied: View>: ViewModifier {
    let level: GateLevel
    let policy: TokenPolicy
    let source: PaywallSource
    let presence: AnyPublisher<Bool, Never>?
    let denied: (PaywallFailure) -> Denied
    /// The facade in effect where the view was built (`Paywall.shared` outside tests and previews).
    var paywall = Paywall.active

    @StateObject private var model = GateSessionModel()
    @Environment(\.paywallScope) private var scope
    @Environment(\.paywallPresence) private var hostedPresence

    private var effectivePresence: AnyPublisher<Bool, Never>? { presence ?? hostedPresence }

    func body(content: Content) -> some View {
        Group {
            if let state = model.state {
                if state.isOpen {
                    content.environment(\.paywallGate, model.session)
                } else if let failure = state.failure {
                    denied(failure)
                }
            } else {
                Color.clear
            }
        }
        .preference(key: PaywallFailureKey.self, value: model.state?.failure)
        .onAppear {
            if effectivePresence == nil { open() }
        }
        .onDisappear {
            if effectivePresence == nil { model.close() }
        }
        .onReceive(effectivePresence ?? Empty<Bool, Never>().eraseToAnyPublisher()) { present in
            if present { open() } else { model.close() }
        }
    }

    private func open() {
        model.open(on: paywall, level: level, policy: policy, source: source, scope: scope)
    }
}
