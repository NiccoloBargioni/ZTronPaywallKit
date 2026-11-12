#if canImport(UIKit) && !os(watchOS)
    public import Combine
    public import PaywallCore
    public import SwiftUI
    public import UIKit

    /// The root a `PaywallHostingController` hosts: the content with the paywall re-injected, because a
    /// `UIHostingController` is a new SwiftUI root and nothing from the tree above a UIKit layer reaches it.
    public struct PaywallHostedRoot<Content: View>: View {
        let content: Content
        let session: GateSession?
        let presence: AnyPublisher<Bool, Never>
        let presentsPaywall: Bool
        let sheet: ((PaywallFailure) -> AnyView)?

        public var body: some View {
            let hosted = content
                .environment(\.paywallGate, session)
                .environment(\.paywallPresence, presence)
                .environmentObject(Paywall.shared)
            if presentsPaywall, let sheet {
                hosted.paywallSheet { failure in sheet(failure) }
            } else {
                hosted
            }
        }
    }

    /// The only UIKit bridge: re-injects `Paywall.shared` and the `GateSession` it is given, publishes presence
    /// from `willMove(toParent:)` and the appearance callbacks (so a reservation held by a hosted gated view is
    /// released when UIKit drops the controller, even on cell reuse where `onDisappear` may not fire), and
    /// installs its own `.paywallSheet` when `presentsPaywall` is true.
    public final class PaywallHostingController<Content: View>: UIHostingController<PaywallHostedRoot<Content>> {
        private let presenceSubject = CurrentValueSubject<Bool, Never>(false)

        public init(
            rootView: Content,
            session: GateSession? = nil,
            presentsPaywall: Bool = false,
            sheet: ((PaywallFailure) -> AnyView)? = nil
        ) {
            let subject = presenceSubject
            super.init(
                rootView: PaywallHostedRoot(
                    content: rootView, session: session, presence: subject.removeDuplicates().eraseToAnyPublisher(),
                    presentsPaywall: presentsPaywall, sheet: sheet))
        }

        @available(*, unavailable)
        @MainActor required dynamic init?(coder aDecoder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        /// `true` while UIKit shows this controller.
        public var isPresent: Bool { presenceSubject.value }

        /// For containers that know better (a cell being reused): flips presence explicitly.
        public func setPresent(_ present: Bool) { presenceSubject.send(present) }

        public override func willMove(toParent parent: UIViewController?) {
            super.willMove(toParent: parent)
            if parent == nil { presenceSubject.send(false) }
        }

        public override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            presenceSubject.send(true)
        }

        public override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            presenceSubject.send(false)
        }
    }

    extension UIViewController {
        /// Denials for UIKit screens, filtered like `.onPaywallFailure`. Keep the cancellable alive.
        @MainActor
        public func paywallFailures(
            scope: String? = nil, id: String? = nil, _ handler: @escaping (PaywallFailure) -> Void
        ) -> AnyCancellable {
            Paywall.shared.failures(scope: scope, id: id).sink(receiveValue: handler)
        }

        /// Presents the host's paywall screen for `failure` modally and claims the failure.
        @MainActor
        public func presentPaywall<Screen: View>(for failure: PaywallFailure, @ViewBuilder screen: (PaywallFailure) -> Screen) {
            failure.claim()
            present(PaywallHostingController(rootView: screen(failure)), animated: true)
        }
    }
#endif
