public import Combine
public import Foundation
public import PaywallCore
public import SwiftUI

extension View {
    /// Presents `content` for every denial nobody claimed. Install it once, on the outermost root that can
    /// present; nested roots pass `presentsPaywall: false`. Also re-resolves the entitlement on every
    /// `scenePhase == .active`.
    public func paywallSheet<Sheet: View>(
        presentsPaywall: Bool = true,
        @ViewBuilder content: @escaping (PaywallFailure) -> Sheet
    ) -> some View {
        modifier(PaywallSheetModifier(presents: presentsPaywall, sheet: content))
    }

    /// Stamps a scope on every failure produced inside, for `.onPaywallFailure(in:)`.
    public func paywallScope(_ scope: String) -> some View {
        environment(\.paywallScope, scope)
    }

    /// Calls `perform` synchronously for each matching denial. Call `failure.claim()` after routing somewhere so
    /// the global sheet does not also present it. `scope` and `id` filter; `nil` matches everything.
    public func onPaywallFailure(
        in scope: String? = nil,
        id: String? = nil,
        perform: @escaping (PaywallFailure) -> Void
    ) -> some View {
        modifier(PaywallFailureHandler(scope: scope, id: id, perform: perform))
    }

    /// Re-resolves the entitlement on every `scenePhase == .active`, for apps without a `.paywallSheet`.
    public func paywallLifecycle() -> some View {
        modifier(PaywallLifecycleModifier())
    }
}

struct PaywallSheetModifier<Sheet: View>: ViewModifier {
    let presents: Bool
    let sheet: (PaywallFailure) -> Sheet
    @ObservedObject private var paywall = Paywall.active

    func body(content: Content) -> some View {
        content
            .sheet(item: presents ? $paywall.pendingFailure : .constant(nil)) { failure in
                sheet(failure)
            }
            .modifier(PaywallLifecycleModifier(paywall: paywall))
    }
}

struct PaywallLifecycleModifier: ViewModifier {
    var paywall = Paywall.active
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.onChange(of: scenePhase) { phase in
            if phase == .active {
                Task { await paywall.didBecomeActive() }
            }
        }
    }
}

struct PaywallFailureHandler: ViewModifier {
    let scope: String?
    let id: String?
    let perform: (PaywallFailure) -> Void
    var paywall = Paywall.active

    func body(content: Content) -> some View {
        content.onReceive(paywall.failures(scope: scope, id: id)) { failure in
            perform(failure)
        }
    }
}

extension Paywall {
    /// Denials, filtered by scope and gate id (`nil` matches all).
    public func failures(scope: String? = nil, id: String? = nil) -> AnyPublisher<PaywallFailure, Never> {
        events
            .compactMap(\.failure)
            .filter { failure in
                (scope == nil || failure.scope == scope) && (id == nil || failure.source.id == id)
            }
            .eraseToAnyPublisher()
    }

    /// The one untyped surface: posts every event as `Notification.Name.paywallEvent` with the event under
    /// `PaywallNotificationKey.event`, for legacy UIKit code. Keep the cancellable alive.
    public func bridgeToNotificationCenter(_ center: NotificationCenter = .default) -> AnyCancellable {
        events.sink { event in
            center.post(name: .paywallEvent, object: nil, userInfo: [PaywallNotificationKey.event: event])
        }
    }
}

extension Notification.Name {
    public static let paywallEvent = Notification.Name("ztron.paywall.event")
}

public enum PaywallNotificationKey {
    public static let event = "event"
}
