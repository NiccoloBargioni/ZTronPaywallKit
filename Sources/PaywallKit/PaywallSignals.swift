public import Combine
public import Foundation
public import PaywallCore
public import SwiftUI
#if canImport(UIKit) && !os(watchOS)
    import UIKit
#endif

extension View {
    /// Presents `content` for every denial nobody claimed. Install it on the outermost root and on any root that is
    /// itself presented modally (a `.sheet`, a UIKit `present`); nested roots inside one presentation pass
    /// `presentsPaywall: false`. The deepest installed presenter that can present right now consumes
    /// `pendingFailure`, so two installed sheets never show the same denial: a root already presenting leaves it
    /// to the presenter inside its presentation, and when there is none the denial waits for the root until that
    /// presentation ends. Also re-resolves the entitlement on every `scenePhase == .active`.
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

    /// Calls `perform` with the product id of a promoted in-app purchase the user tapped on the App Store, once
    /// per intent, including one that arrived before this view existed. Open the paywall on that product; the
    /// purchase itself still goes through `Paywall.purchase`.
    public func onPurchaseIntent(perform: @escaping (String) -> Void) -> some View {
        modifier(PurchaseIntentHandler(perform: perform))
    }

    /// Re-resolves the entitlement on every `scenePhase == .active` and puts `\.paywallEntitlement` in the
    /// environment, for apps without a `.paywallSheet` (which does both as well).
    public func paywallLifecycle() -> some View {
        modifier(PaywallLifecycleModifier())
    }
}

struct PaywallSheetModifier<Sheet: View>: ViewModifier {
    let presents: Bool
    let sheet: (PaywallFailure) -> Sheet
    @ObservedObject private var paywall = Paywall.active
    /// The failure this presenter took. Local, so a second `.paywallSheet` finds `pendingFailure` empty.
    @State private var presented: PaywallFailure?
    /// Where this presenter sits in UIKit terms: whether it can present right now.
    @StateObject private var anchor = PaywallPresenterAnchor()
    /// How many `.paywallSheet`s are above this one; presenters below it read one more.
    @Environment(\.paywallPresenterDepth) private var depth

    func body(content: Content) -> some View {
        content
            .environment(\.paywallPresenterDepth, depth + 1)
            .environment(\.paywallEntitlement, paywall.entitlement.resolved)
            .background(PaywallPresenterProbe(anchor: anchor))
            .sheet(item: $presented) { failure in
                sheet(failure).environment(\.paywallPresenterDepth, depth + 1)
            }
            .onAppear {
                anchor.depth = depth
                if presents { paywall.register(anchor) }
                take()
            }
            .onDisappear {
                anchor.pendingTake?.cancel()
                anchor.pendingTake = nil
                paywall.unregister(anchor)
            }
            .onChange(of: paywall.pendingFailure) { _ in take() }
            .onChange(of: presented) { if $0 == nil { take() } }
            .onChange(of: anchor.inWindow) { _ in
                paywall.presentersChanged()
                take()
            }
            .onReceive(paywall.presenterChanges) { take() }
            .modifier(PaywallLifecycleModifier(paywall: paywall))
    }

    /// Takes the pending denial when this is the presenter to show it (`Paywall.shouldPresent`), confirmed a beat
    /// later: the content of a sheet renders, and can be denied, before UIKit knows the sheet is being presented,
    /// so a root that looks free the moment the denial lands may not be.
    private func take() {
        guard presents, paywall.pendingFailure != nil, presented == nil, paywall.shouldPresent(anchor) else { return }
        guard anchor.pendingTake == nil else { return }
        anchor.pendingTake = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            anchor.pendingTake = nil
            guard !Task.isCancelled, presents, paywall.pendingFailure != nil, presented == nil, paywall.shouldPresent(anchor) else { return }
            presented = paywall.consumePendingFailure()
        }
    }
}

private struct PaywallPresenterDepthKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    /// The number of `.paywallSheet`s above a view. A new SwiftUI root (a hosting controller) starts at zero.
    var paywallPresenterDepth: Int {
        get { self[PaywallPresenterDepthKey.self] }
        set { self[PaywallPresenterDepthKey.self] = newValue }
    }
}

/// Where a `.paywallSheet` sits, for the one-presenter rule: how deep in the presenter tree, and in UIKit terms
/// whether it is in a window and free to present.
@MainActor
final class PaywallPresenterAnchor: ObservableObject {
    /// Whether the presenter's view is in a window; changes re-run every presenter's `take()`.
    @Published var inWindow = false
    var depth = 0
    /// The confirmation a beat after this presenter decided to take the denial.
    var pendingTake: Task<Void, Never>?

    #if canImport(UIKit) && !os(watchOS)
        weak var view: UIView?
        /// Set once the view has been in a window: a presenter whose view then left every window is gone (a
        /// torn-down screen, a background tab), one whose view was never attached is still coming.
        var attachedOnce = false

        var isGone: Bool { attachedOnce && !inWindow }

        /// In a window, and neither the controller this presenter's view belongs to nor one of its ancestors is
        /// presenting something already. A presenter without a view yet counts as free.
        var canPresent: Bool {
            guard let view else { return true }
            guard view.window != nil else { return false }
            var responder: UIResponder? = view
            while let current = responder, !(current is UIViewController) { responder = current.next }
            guard let controller = responder as? UIViewController else { return true }
            return controller.presentedViewController == nil
        }
    #else
        var isGone: Bool { false }
        var canPresent: Bool { true }
    #endif
}

#if canImport(UIKit) && !os(watchOS)
    /// A hidden view that tells the anchor where the presenter lives and when it lands in a window.
    private struct PaywallPresenterProbe: UIViewRepresentable {
        let anchor: PaywallPresenterAnchor

        final class ProbeView: UIView {
            var moved: ((Bool) -> Void)?
            override func didMoveToWindow() {
                super.didMoveToWindow()
                moved?(window != nil)
            }
        }

        func makeUIView(context: Context) -> ProbeView {
            let view = ProbeView()
            view.isHidden = true
            view.isUserInteractionEnabled = false
            let anchor = anchor
            view.moved = { inWindow in
                if inWindow { anchor.attachedOnce = true }
                if anchor.inWindow != inWindow { anchor.inWindow = inWindow }
            }
            anchor.view = view
            return view
        }
        func updateUIView(_ view: ProbeView, context: Context) { anchor.view = view }
    }
#else
    private struct PaywallPresenterProbe: View {
        let anchor: PaywallPresenterAnchor
        var body: some View { EmptyView() }
    }
#endif

extension Paywall {
    func register(_ anchor: PaywallPresenterAnchor) {
        sheetPresenters.add(anchor)
        presenterChanges.send()
    }

    func unregister(_ anchor: PaywallPresenterAnchor) {
        sheetPresenters.remove(anchor)
        presenterChanges.send()
    }

    func presentersChanged() { presenterChanges.send() }

    /// The one-presenter rule: the deepest presenter still around takes the denial (the one inside the sheet or
    /// the modal that is up, not the root under it), and only when it can present now (in a window, presenting
    /// nothing). A presenter that is showing a plain sheet leaves the denial pending and takes it on the next
    /// nudge after that sheet has gone; SwiftUI's own "next sheet" queue is not relied on, it drops sheets.
    func shouldPresent(_ anchor: PaywallPresenterAnchor) -> Bool {
        let alive = sheetPresenters.allObjects.filter { !$0.isGone }
        if alive.contains(where: { $0.depth > anchor.depth }) { return false }
        return anchor.canPresent
    }
}

struct PaywallLifecycleModifier: ViewModifier {
    @ObservedObject var paywall = Paywall.active
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .environment(\.paywallEntitlement, paywall.entitlement.resolved)
            .onChange(of: scenePhase) { phase in
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

struct PurchaseIntentHandler: ViewModifier {
    let perform: (String) -> Void
    @ObservedObject private var paywall = Paywall.active

    func body(content: Content) -> some View {
        content
            .onAppear { take() }
            .onChange(of: paywall.pendingPurchaseIntent) { _ in take() }
    }

    private func take() {
        if let productID = paywall.pendingPurchaseIntent, paywall.consumePendingPurchaseIntent() == productID {
            perform(productID)
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

    /// Promoted in-app purchases the user tapped on the App Store, as product ids.
    public var purchaseIntents: AnyPublisher<String, Never> {
        events
            .compactMap { event -> String? in
                if case .purchaseIntent(let productID) = event { return productID }
                return nil
            }
            .eraseToAnyPublisher()
    }

    /// The untyped surface for `NotificationCenter` code: posts every event as `Notification.Name.paywallEvent` with
    /// the event under `PaywallNotificationKey.event`, and the paywall and purchase events under their own names as
    /// well (`.paywallDenied`, `.paywallPurchaseCompleted`, …) with the payload unpacked into `userInfo`. Keep the
    /// cancellable alive, or set `Configuration.notificationCenter` and the facade keeps it for its lifetime.
    public func bridgeToNotificationCenter(_ center: NotificationCenter = .default) -> AnyCancellable {
        events.sink { event in
            center.post(name: .paywallEvent, object: nil, userInfo: [PaywallNotificationKey.event: event])
            if let name = event.notificationName {
                center.post(name: name, object: nil, userInfo: event.notificationUserInfo)
            }
        }
    }
}

extension Notification.Name {
    /// Every event, with the `PaywallEvent` under `PaywallNotificationKey.event`.
    public static let paywallEvent = Notification.Name("ztron.paywall.event")
    /// A gate closed and the paywall should show: `PaywallNotificationKey.failure` holds the `PaywallFailure`.
    public static let paywallDenied = Notification.Name("ztron.paywall.denied")
    /// `PaywallNotificationKey.entitlement` (the new value), `.previousEntitlement` and `.cause`.
    public static let paywallEntitlementChanged = Notification.Name("ztron.paywall.entitlementChanged")
    /// The purchase stages: `PaywallNotificationKey.productID` and `.source` on each, `.transactionID` on completed,
    /// `.error` on failed.
    public static let paywallPurchaseStarted = Notification.Name("ztron.paywall.purchase.started")
    public static let paywallPurchaseCompleted = Notification.Name("ztron.paywall.purchase.completed")
    public static let paywallPurchasePending = Notification.Name("ztron.paywall.purchase.pending")
    public static let paywallPurchaseCancelled = Notification.Name("ztron.paywall.purchase.cancelled")
    public static let paywallPurchaseFailed = Notification.Name("ztron.paywall.purchase.failed")
    /// The restore stages: `PaywallNotificationKey.error` on failed.
    public static let paywallRestoreRequested = Notification.Name("ztron.paywall.restore.requested")
    public static let paywallRestoreCompleted = Notification.Name("ztron.paywall.restore.completed")
    public static let paywallRestoreFailed = Notification.Name("ztron.paywall.restore.failed")
    /// A promoted in-app purchase tapped on the App Store: `PaywallNotificationKey.productID`. Open the paywall on it.
    public static let paywallPurchaseIntent = Notification.Name("ztron.paywall.purchaseIntent")
}

/// `userInfo` keys. Every notification carries `event`; the dedicated names add their payload under the rest.
public enum PaywallNotificationKey {
    public static let event = "event"
    public static let failure = "failure"
    public static let entitlement = "entitlement"
    public static let previousEntitlement = "previousEntitlement"
    public static let cause = "cause"
    public static let productID = "productID"
    public static let transactionID = "transactionID"
    public static let source = "source"
    public static let error = "error"
}

extension PaywallEvent {
    /// The dedicated notification for a paywall or purchase event; `nil` for the rest (tokens, leases, sync).
    var notificationName: Notification.Name? {
        switch self {
        case .gateDenied: return .paywallDenied
        case .entitlementChanged: return .paywallEntitlementChanged
        case .purchase(let stage, _, _, _):
            switch stage {
            case .started: return .paywallPurchaseStarted
            case .completed: return .paywallPurchaseCompleted
            case .pending: return .paywallPurchasePending
            case .cancelled: return .paywallPurchaseCancelled
            case .failed: return .paywallPurchaseFailed
            }
        case .restore(let stage):
            switch stage {
            case .requested: return .paywallRestoreRequested
            case .completed: return .paywallRestoreCompleted
            case .failed: return .paywallRestoreFailed
            }
        case .purchaseIntent: return .paywallPurchaseIntent
        default: return nil
        }
    }

    /// The payload of a dedicated notification, with the event itself under `PaywallNotificationKey.event`.
    var notificationUserInfo: [String: Any] {
        var info: [String: Any] = [PaywallNotificationKey.event: self]
        switch self {
        case .gateDenied(let failure):
            info[PaywallNotificationKey.failure] = failure
        case .entitlementChanged(let from, let to, let cause):
            info[PaywallNotificationKey.previousEntitlement] = from
            info[PaywallNotificationKey.entitlement] = to
            info[PaywallNotificationKey.cause] = cause
        case .purchase(let stage, let productID, let source, let transactionID):
            info[PaywallNotificationKey.productID] = productID
            if let source { info[PaywallNotificationKey.source] = source }
            if let transactionID { info[PaywallNotificationKey.transactionID] = transactionID }
            if case .failed(let error) = stage { info[PaywallNotificationKey.error] = error }
        case .restore(.failed(let error)):
            info[PaywallNotificationKey.error] = error
        case .purchaseIntent(let productID):
            info[PaywallNotificationKey.productID] = productID
        default:
            break
        }
        return info
    }
}
