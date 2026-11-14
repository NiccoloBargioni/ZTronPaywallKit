#if canImport(UIKit) && !os(watchOS)
    import Combine
    import Foundation
    import PaywallCore
    import PaywallKit
    import PaywallTesting
    import SwiftUI
    import Testing
    import UIKit

    /// The design's boundary matrix: a gated probe behind every kind of UIKit layer, alone and in every ordered pair
    /// (plus sampled triples), in a `UIWindow` of the test host on the iOS Simulator. It runs in the host because a
    /// modal presentation never completes in the package's unhosted test process (`isBeingPresented` stays true;
    /// SwiftUI sheets there only pretend to appear), and the matrix has a UIKit `present` in it. For each stack it
    /// checks the signal rows:
    ///
    /// - `\.paywallGate` and `Paywall` as environment object reach through SwiftUI-managed layers and through
    ///   `PaywallHostingController`, which re-injects them; what a plain hosting controller the SwiftUI tree creates
    ///   keeps is recorded (iOS 18 bridges it), and a hosting controller UIKit creates outside the tree gets nothing;
    /// - `PaywallFailureKey` reaches within one hosting tree and never out of a `.sheet`; the rest is recorded;
    /// - `pendingFailure`, `.onPaywallFailure` and `events` reach through anything;
    /// - a reservation held behind a layer is released when the layer goes, through the hosting controller's
    ///   presence signal, which does not depend on `onDisappear`.
    ///
    /// What a missing environment object does is a SwiftUI trap, so that row is asserted only in the direction that
    /// can run: with the hosting controller the object is there and is `Paywall.shared`.
    enum Boundary: String, CaseIterable, Sendable {
        /// Pure SwiftUI, same hosting tree: the control row.
        case overlay
        /// SwiftUI-managed presentation. The environment flows in; preferences do not flow out (UIKit presents it).
        case sheet
        case representableController
        case representableView
        case present
        case push
        case cell

        var isUIKit: Bool { self != .overlay && self != .sheet }
        /// The layer presents modally: a root above it cannot present a sheet of its own while it is up.
        var isPresentation: Bool { self == .sheet || self == .present }
    }

    @MainActor
    final class BoundaryLog: ObservableObject {
        var contentAppeared = 0
        var gateReached: Bool?
        var environmentObjectIsShared: Bool?
        var entitlementResolved: Bool?
        var preferenceAboveBoundary: [String] = []
        var preferenceInsideHost: [String] = []
        var handled: [String] = []
        var events: [PaywallEvent] = []
        var sheetPresented: [String] = []
    }

    /// Reads the environment where the probe lives and reports it.
    private struct ProbeContent: View {
        @ObservedObject var log: BoundaryLog
        let checkEnvironmentObject: Bool
        @Environment(\.paywallGate) private var gate
        @Environment(\.paywallEntitlement) private var entitlement

        var body: some View {
            Group {
                if checkEnvironmentObject {
                    EnvironmentObjectProbe(log: log)
                } else {
                    Color.green
                }
            }
            .frame(width: 40, height: 40)
            .onAppear {
                log.contentAppeared += 1
                log.gateReached = gate != nil
                log.entitlementResolved = entitlement != nil
                BoundaryDiagnostics.note("probe: appeared, gate=\(gate != nil)")
            }
        }
    }

    private struct EnvironmentObjectProbe: View {
        @ObservedObject var log: BoundaryLog
        @EnvironmentObject private var paywall: Paywall
        var body: some View {
            Color.blue.onAppear { log.environmentObjectIsShared = paywall === Paywall.shared }
        }
    }

    /// Makes the hosting controller a layer uses: the package's bridge, or a plain one.
    @MainActor
    private func host<V: View>(_ view: V, hosted: Bool, session: GateSession?) -> UIViewController {
        hosted ? PaywallHostingController(rootView: view, session: session) : UIHostingController(rootView: view)
    }

    private struct ControllerLayer<Inner: View>: UIViewControllerRepresentable {
        let hosted: Bool
        let inner: Inner
        @Environment(\.paywallGate) private var gate
        func makeUIViewController(context: Context) -> UIViewController {
            BoundaryDiagnostics.note("controller layer: made, hosted=\(hosted) gate=\(gate != nil)")
            return host(inner, hosted: hosted, session: gate)
        }
        func updateUIViewController(_ controller: UIViewController, context: Context) {
            BoundaryDiagnostics.note("controller layer: update, window=\(controller.view.window != nil) bounds=\(controller.view.bounds) parent=\(controller.parent.map { String(describing: type(of: $0)) } ?? "nil")")
        }
    }

    private struct ViewLayer<Inner: View>: UIViewRepresentable {
        let hosted: Bool
        let inner: Inner
        @Environment(\.paywallGate) private var gate

        final class Container: UIView {
            var child: UIViewController?
        }

        func makeUIView(context: Context) -> Container {
            let container = Container()
            let child = host(inner, hosted: hosted, session: gate)
            container.child = child
            child.view.frame = CGRect(x: 0, y: 0, width: 60, height: 60)
            container.addSubview(child.view)
            return container
        }

        /// The view is in the hierarchy by now: parent the child controller to the nearest controller above the
        /// view, as a container view would, so UIKit drives its appearance and lets it present.
        func updateUIView(_ view: Container, context: Context) {
            guard let child = view.child, child.parent == nil else { return }
            var responder: UIResponder? = view.next
            while let current = responder, !(current is UIViewController) { responder = current.next }
            if let parent = responder as? UIViewController {
                parent.addChild(child)
                child.didMove(toParent: parent)
            } else {
                child.beginAppearanceTransition(true, animated: false)
                child.endAppearanceTransition()
            }
        }
    }

    /// A UIKit controller that presents, pushes or shows in a cell the hosting controller for `inner`.
    private struct ContainerLayer<Inner: View>: UIViewControllerRepresentable {
        let boundary: Boundary
        let hosted: Bool
        let inner: Inner
        let registry: LayerRegistry
        @Environment(\.paywallGate) private var gate

        func makeUIViewController(context: Context) -> UIViewController {
            let child = host(inner, hosted: hosted, session: gate)
            let controller: UIViewController
            switch boundary {
            case .present:
                controller = PresentingController(child: child)
            case .push:
                controller = PushingNavigationController(child: child)
            case .cell:
                controller = CellTableController(child: child)
            case .overlay, .sheet, .representableController, .representableView:
                controller = child
            }
            registry.add(controller)
            return controller
        }

        func updateUIViewController(_ controller: UIViewController, context: Context) {}
    }

    @MainActor
    final class LayerRegistry {
        var controllers: [UIViewController] = []
        /// The `.sheet` layers' binding: tearing down flips it, because a sheet left on a constant `true` re-presents
        /// itself after a UIKit dismissal and its probe then publishes a stale denial into the next case.
        let sheets = SheetFlag()
        func add(_ controller: UIViewController) { controllers.append(controller) }

        /// Tears every layer down the way its container would: dismiss, pop, remove the cell's controller.
        func tearDown() {
            sheets.shown = false
            for controller in controllers {
                switch controller {
                case let presenting as PresentingController: presenting.child.dismiss(animated: false)
                case let navigation as PushingNavigationController: navigation.popToRootViewController(animated: false)
                case let table as CellTableController: table.evictCell()
                default: break
                }
            }
        }
    }

    final class PresentingController: UIViewController {
        let child: UIViewController
        private var presentedOnce = false
        init(child: UIViewController) {
            self.child = child
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !presentedOnce else { return }
            presentedOnce = true
            child.modalPresentationStyle = .overFullScreen
            // Present from whatever is on top, as an app's coordinator would (a representable's own controller is a
            // child of a hosting view and cannot present), on the next turn: a presentation started while the
            // presenter's own appearance transition is still running never completes.
            Task { @MainActor [self] in
                try? await Task.sleep(nanoseconds: 50_000_000)
                var presenter = view.window?.rootViewController ?? self
                while let above = presenter.presentedViewController { presenter = above }
                BoundaryDiagnostics.note("present: window=\(view.window != nil) presenter=\(type(of: presenter)) parent=\(parent.map { String(describing: type(of: $0)) } ?? "nil")")
                presenter.present(child, animated: false) {
                    BoundaryDiagnostics.note("present: completed, child in window=\(self.child.view.window != nil) bounds=\(self.child.view.bounds)")
                }
            }
        }
    }

    /// Prints go to the xcodebuild log; `TEST_RUNNER_BOUNDARY_STACKS="present;sheet>representableController"` runs a
    /// subset of the matrix.
    enum BoundaryDiagnostics {
        static let enabled = ProcessInfo.processInfo.environment["BOUNDARY_STACKS"] != nil
        static func note(_ message: String) {
            if enabled { print("BOUNDARY \(message)") }
        }
    }

    final class PushingNavigationController: UINavigationController {
        let child: UIViewController
        private var pushedOnce = false
        init(child: UIViewController) {
            self.child = child
            super.init(rootViewController: UIViewController())
        }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !pushedOnce else { return }
            pushedOnce = true
            pushViewController(child, animated: false)
        }
    }

    /// One cell whose content view hosts the child controller's view, as a list of gated rows would.
    final class CellTableController: UITableViewController {
        let child: UIViewController
        private var evicted = false
        init(child: UIViewController) {
            self.child = child
            super.init(style: .plain)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidLoad() {
            super.viewDidLoad()
            tableView.register(UITableViewCell.self, forCellReuseIdentifier: "gated")
            tableView.rowHeight = 80
        }
        override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { evicted ? 0 : 1 }
        override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            let cell = tableView.dequeueReusableCell(withIdentifier: "gated", for: indexPath)
            if child.parent !== self {
                addChild(child)
                child.view.frame = cell.contentView.bounds
                child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                cell.contentView.addSubview(child.view)
                child.didMove(toParent: self)
            }
            return cell
        }
        /// Cell reuse or deletion: UIKit drops the hosted controller without any SwiftUI disappearance.
        func evictCell() {
            evicted = true
            child.willMove(toParent: nil)
            child.view.removeFromSuperview()
            child.removeFromParent()
            tableView.reloadData()
        }
    }

    /// Wraps `inner` in one boundary layer.
    private struct Layer<Inner: View>: View {
        let boundary: Boundary
        let hosted: Bool
        let registry: LayerRegistry
        @ObservedObject var sheets: SheetFlag
        let inner: Inner

        var body: some View {
            switch boundary {
            case .overlay:
                Color.clear.frame(width: 60, height: 60).overlay(inner)
            case .sheet:
                Color.clear.frame(width: 10, height: 10).sheet(isPresented: $sheets.shown) {
                    inner.onAppear { BoundaryDiagnostics.note("sheet: content appeared") }
                }
            case .representableController:
                ControllerLayer(hosted: hosted, inner: inner)
            case .representableView:
                ViewLayer(hosted: hosted, inner: inner)
            case .present, .push, .cell:
                ContainerLayer(boundary: boundary, hosted: hosted, inner: inner, registry: registry)
            }
        }
    }

    /// `layers.first` is outermost. The probe sits behind every layer; the preference listener inside the innermost
    /// host wraps the probe, the one above the boundaries wraps the whole stack.
    private struct Stack: View {
        let layers: [Boundary]
        let hosted: Bool
        let level: GateLevel
        let gateAbove: Bool
        let log: BoundaryLog
        let registry: LayerRegistry
        let probeID: String

        var body: some View {
            let probe = ProbeContent(log: log, checkEnvironmentObject: hosted && gateAbove && layers.contains { $0.isUIKit })
            // With the gate above the stack the probe stands bare behind the layers and reads what reaches it. A gate
            // of its own would hand it a session (`.paywallGated` sets `\.paywallGate` for its content) and hide the
            // crossing.
            let innermost: AnyView =
                gateAbove
                ? AnyView(probe)
                : AnyView(
                    probe.paywallGated(level, id: probeID) { failure in
                        Color.red.frame(width: 40, height: 40).onAppear { log.handled.append("denied:\(failure.source.id)") }
                    })
            let gatedProbe = AnyView(
                innermost.onPreferenceChange(PaywallFailureKey.self) { failure in
                    if let failure { log.preferenceInsideHost.append(failure.source.id) }
                })
            let behind = layers.reversed().reduce(gatedProbe) { inner, boundary in
                AnyView(Layer(boundary: boundary, hosted: hosted, registry: registry, sheets: registry.sheets, inner: inner))
            }
            let gated = gateAbove ? AnyView(behind.paywallGated(level, id: probeID)) : behind
            gated
                .onPreferenceChange(PaywallFailureKey.self) { failure in
                    if let failure { log.preferenceAboveBoundary.append(failure.source.id) }
                }
                .onPaywallFailure { failure in log.handled.append("handler:\(failure.source.id)") }
                .frame(width: 300, height: 500)
        }
    }

    @MainActor
    final class SheetFlag: ObservableObject {
        @Published var shown = true
    }

    /// A root with a `.sheet` whose gated probe has its own `.paywallSheet`, and another on the root.
    private struct PresentingSheetRoot: View {
        @ObservedObject var flag: SheetFlag
        let probeID: String
        let log: BoundaryLog

        var body: some View {
            Color.clear.frame(width: 10, height: 10)
                .sheet(isPresented: $flag.shown) {
                    Color.green.frame(width: 40, height: 40)
                        .paywallGated(.paid, id: probeID) { failure in
                            Color.red.onAppear { log.handled.append("denied:\(failure.source.id)") }
                        }
                        .paywallSheet { failure in Color.yellow.onAppear { log.sheetPresented.append("inner:\(failure.source.id)") } }
                }
                .paywallSheet { failure in Color.orange.onAppear { log.sheetPresented.append("outer:\(failure.source.id)") } }
        }
    }

    /// A root with a plain `.sheet` over a gated probe and the paywall sheet on the root only.
    private struct PlainSheetRoot: View {
        @ObservedObject var flag: SheetFlag
        let probeID: String
        let log: BoundaryLog

        var body: some View {
            Color.clear.frame(width: 10, height: 10)
                .sheet(isPresented: $flag.shown) {
                    Color.green.frame(width: 40, height: 40)
                        .paywallGated(.paid, id: probeID) { failure in
                            Color.red.onAppear { log.handled.append("denied:\(failure.source.id)") }
                        }
                }
                .paywallSheet { failure in Color.orange.onAppear { log.sheetPresented.append("outer:\(failure.source.id)") } }
        }
    }

    private let boundaryProducts: [PaywallProduct] = [
        PaywallProduct(id: "pro.weekly", kind: .subscription(.weekly), displayName: "Weekly", displayPrice: "€1.99", introOffer: .init(trialDays: 7)),
        PaywallProduct(id: "pro.monthly", kind: .subscription(.monthly), displayName: "Monthly", displayPrice: "€4.99"),
        PaywallProduct(id: "pro.yearly", kind: .subscription(.yearly), displayName: "Yearly", displayPrice: "€29.99"),
        PaywallProduct(id: "pro.lifetime", kind: .lifetime, displayName: "Lifetime", displayPrice: "€59.99"),
        PaywallProduct(id: "tokens.10", kind: .tokens(0), displayName: "10 tokens", displayPrice: "€0.99"),
        PaywallProduct(id: "tokens.50", kind: .tokens(0), displayName: "50 tokens", displayPrice: "€3.99"),
    ]

    @MainActor
    private func configureShared(tokens: Int) async -> FakeStore {
        let store = FakeStore(products: boundaryProducts)
        var configuration = Paywall.Configuration(catalog: hostCatalog)
        configuration.welcomeTokens = 0
        configuration.store = store
        configuration.clock = FakeClock()
        configuration.storageDirectory = makeTemporaryPaywallDirectory()
        configuration.includesDefaultAudit = false
        configuration.connectivity = nil
        Paywall.shared.configure(configuration)
        await Paywall.shared.waitUntilStarted()
        if tokens > 0 { Paywall.shared.grant(tokens: tokens, reason: "test") }
        // Views of the previous case's window may still be finishing their UIKit transitions and re-open sessions
        // on the fresh engine; let them, then drop the denial they leave so it cannot shadow this case's.
        try? await Task.sleep(nanoseconds: 150_000_000)
        _ = Paywall.shared.consumePendingFailure()
        return store
    }

    @MainActor
    private func pump(_ window: UIWindow, rounds: Int = 12) async {
        for _ in 0..<rounds {
            window.layoutIfNeeded()
            await Task.yield()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @MainActor
    private func until(_ window: UIWindow, rounds: Int = 150, _ condition: () -> Bool) async -> Bool {
        for _ in 0..<rounds where !condition() { await pump(window, rounds: 1) }
        return condition()
    }

    /// A window on the host's scene (a window without one is never shown and cannot finish a presentation).
    @MainActor
    private func makeWindow() -> UIWindow {
        if let scene = UIApplication.shared.connectedScenes.first(where: { $0 is UIWindowScene }) as? UIWindowScene {
            return UIWindow(windowScene: scene)
        }
        return UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 568))
    }

    /// Hosts the stack in a key window under `.paywallLifecycle()`, as an app root without a sheet carries it, so
    /// `\.paywallEntitlement` starts above every layer the way `\.paywallGate` does.
    @MainActor
    private func show(_ stack: Stack) -> UIWindow {
        let window = makeWindow()
        window.rootViewController = UIHostingController(rootView: stack.paywallLifecycle())
        window.makeKeyAndVisible()
        return window
    }

    @MainActor
    private func dismissEverything(_ window: UIWindow) async {
        // Let SwiftUI finish dismissing what the teardown flipped before UIKit drops the rest: a dismissal started
        // mid-transition leaves a presentation controller the next case trips over.
        _ = await until(window, rounds: 50) { window.rootViewController?.presentedViewController == nil }
        window.rootViewController?.dismiss(animated: false)
        window.rootViewController = nil
        window.isHidden = true
        await pump(window, rounds: 5)
    }

    enum BoundaryMatrix {
        static let depth1: [[Boundary]] = Boundary.allCases.map { [$0] }
        static let depth2: [[Boundary]] = Boundary.allCases.flatMap { outer in Boundary.allCases.map { [outer, $0] } }
        /// Twelve triples, sampled deterministically.
        static let depth3: [[Boundary]] = {
            let all = Boundary.allCases
            var triples: [[Boundary]] = []
            var seed: UInt64 = 7
            while triples.count < 12 {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let a = all[Int(seed >> 33) % all.count], b = all[Int(seed >> 40) % all.count], c = all[Int(seed >> 47) % all.count]
                if !triples.contains([a, b, c]) { triples.append([a, b, c]) }
            }
            return triples
        }()
        static let stacks: [[Boundary]] = {
            if let subset = ProcessInfo.processInfo.environment["BOUNDARY_STACKS"] {
                return subset.split(separator: ";").map { $0.split(separator: ">").compactMap { Boundary(rawValue: String($0)) } }
            }
            return depth1 + depth2 + depth3
        }()
    }

    /// What the preference row can promise for a stack.
    enum PreferenceExpectation { case reaches, blocked, unspecified }

    extension Array where Element == Boundary {
        /// Preferences climb within one hosting tree. A `.sheet` is presented by UIKit and never hands them up. Across
        /// nested `UIHostingController`s iOS 18 bridges them and the design assumed it would not; the row records
        /// the observed value for those stacks rather than promising either.
        var preferenceExpectation: PreferenceExpectation {
            if allSatisfy({ $0 == .overlay }) { return .reaches }
            if allSatisfy({ !$0.isUIKit }) { return contains(.sheet) ? .blocked : .reaches }
            return .unspecified
        }
    }

    extension HostLane {
    @Suite("UIKit boundaries", .serialized)
    @MainActor
    struct UIKitBoundaryTests {
        /// A free user behind the stack: the denial is published; the handler, the event stream and the coordinator
        /// see it whatever the layers; the preference key reaches within a hosting tree and never out of a sheet.
        @Test(arguments: BoundaryMatrix.stacks)
        func denial_signals_cross_every_boundary(layers: [Boundary]) async {
            _ = await configureShared(tokens: 0)
            let log = BoundaryLog()
            let registry = LayerRegistry()
            let probeID = "probe.\(layers.map(\.rawValue).joined(separator: "."))"
            var seen: [PaywallEvent] = []
            let cancellable = Paywall.shared.events.sink { seen.append($0) }
            defer { cancellable.cancel() }
            let window = show(Stack(layers: layers, hosted: false, level: .paid, gateAbove: false, log: log, registry: registry, probeID: probeID))
            let denied = await until(window) { log.handled.contains("denied:\(probeID)") }
            #expect(denied, "denied view never rendered behind \(layers)")
            #expect(log.handled.contains("handler:\(probeID)"), ".onPaywallFailure above the boundary: \(layers)")
            #expect(seen.contains { $0.failure?.source.id == probeID }, "events: \(layers)")
            #expect(await until(window) { Paywall.shared.pendingFailure?.source.id == probeID }, "coordinator: \(layers), pending: \(Paywall.shared.pendingFailure?.source.id ?? "nil")")
            #expect(log.preferenceInsideHost.contains(probeID), "preference inside the host: \(layers)")
            switch layers.preferenceExpectation {
            case .reaches: #expect(log.preferenceAboveBoundary.contains(probeID), "preference lost inside one tree: \(layers)")
            case .blocked: #expect(log.preferenceAboveBoundary.isEmpty, "preference climbed out of a sheet: \(layers)")
            case .unspecified: print("preference across \(layers): \(log.preferenceAboveBoundary.isEmpty ? "stopped" : "bridged")")
            }
            _ = Paywall.shared.consumePendingFailure()
            registry.tearDown()
            await dismissEverything(window)
        }

        /// A gate above the stack and, below it, content that reads the gate's session from the environment, as a
        /// commit point does. SwiftUI-managed layers keep the environment. Across a UIKit layer the design counted on
        /// losing it, and the package never relies on keeping it; the row records what the runtime does (iOS 17.5 and
        /// 18.0 carry the environment down the view-controller containment hierarchy, to representables, a pushed or
        /// a cell-hosted controller, not to one UIKit presents), while the contract is asserted whatever the layer:
        /// `PaywallHostingController` re-injects the gate session it is given and `Paywall.shared`. The root's
        /// `.paywallLifecycle()` puts `\.paywallEntitlement` above the stack too; it travels exactly as far as the
        /// gate value in every row, and the bridge re-injects it as well.
        @Test(arguments: BoundaryMatrix.stacks)
        func gate_environment_crosses_uikit_through_the_hosting_controller(layers: [Boundary]) async {
            _ = await configureShared(tokens: 5)
            for hosted in [false, true] {
                let log = BoundaryLog()
                let registry = LayerRegistry()
                let probeID = "gate.\(hosted).\(layers.map(\.rawValue).joined(separator: "."))"
                let window = show(Stack(layers: layers, hosted: hosted, level: .tokens(1), gateAbove: true, log: log, registry: registry, probeID: probeID))
                #expect(await until(window) { log.gateReached != nil }, "content never appeared behind \(layers) hosted=\(hosted)")
                if !layers.contains(where: \.isUIKit) {
                    #expect(log.gateReached == true, "SwiftUI-managed layers keep the environment: \(layers)")
                } else if hosted {
                    #expect(log.gateReached == true, "PaywallHostingController re-injects the gate: \(layers)")
                    #expect(await until(window) { log.environmentObjectIsShared == true }, "Paywall.shared re-injected: \(layers)")
                } else {
                    print("root environment across \(layers): \(log.gateReached == true ? "bridged" : "lost")")
                }
                #expect(
                    log.entitlementResolved == log.gateReached,
                    "\\.paywallEntitlement travels exactly as far as \\.paywallGate: \(layers) hosted=\(hosted)")
                registry.tearDown()
                await dismissEverything(window)
            }
        }

        /// A reservation held behind a UIKit layer is released when the layer goes, through presence. Plain hosting
        /// relies on `onDisappear`, which the design documents as unreliable; the bridge does not.
        @Test(arguments: Boundary.allCases.filter(\.isUIKit))
        func reservation_behind_a_rehosted_layer_is_released_when_the_layer_goes(boundary: Boundary) async {
            _ = await configureShared(tokens: 5)
            let log = BoundaryLog()
            let registry = LayerRegistry()
            let probeID = "reserve.\(boundary.rawValue)"
            let window = show(Stack(layers: [boundary], hosted: true, level: .tokens(2), gateAbove: false, log: log, registry: registry, probeID: probeID))
            #expect(await until(window) { Paywall.shared.wallet.reserved == 2 }, "no hold behind \(boundary)")
            #expect(log.contentAppeared == 1)
            registry.tearDown()
            if boundary == .representableController || boundary == .representableView {
                // Representables go when their SwiftUI parent does.
                window.rootViewController = UIHostingController(rootView: Color.clear)
            }
            #expect(await until(window) { Paywall.shared.wallet.reserved == 0 }, "hold not released after \(boundary) went")
            #expect(Paywall.shared.wallet.balance == 5)
            await dismissEverything(window)
        }

        /// The sheet installed on the outermost root presents for a denial behind each layer that leaves the root
        /// able to present, once.
        @Test(arguments: Boundary.allCases.filter { !$0.isPresentation })
        func root_sheet_presents_for_a_denial_behind_a_layer(boundary: Boundary) async {
            _ = await configureShared(tokens: 0)
            let log = BoundaryLog()
            let registry = LayerRegistry()
            let probeID = "sheet.\(boundary.rawValue)"
            let stack = Stack(layers: [boundary], hosted: false, level: .paid, gateAbove: false, log: log, registry: registry, probeID: probeID)
                .paywallSheet { failure in Color.yellow.onAppear { log.sheetPresented.append(failure.source.id) } }
            let window = makeWindow()
            window.rootViewController = UIHostingController(rootView: stack)
            window.makeKeyAndVisible()
            #expect(await until(window) { log.handled.contains("denied:\(probeID)") }, "no denial behind \(boundary)")
            #expect(await until(window, rounds: 300) { log.sheetPresented == [probeID] }, "the root sheet did not present for \(boundary): \(log.sheetPresented)")
            #expect(Paywall.shared.pendingFailure == nil)
            registry.tearDown()
            await dismissEverything(window)
        }

        /// A root that is already presenting (a sheet, a modal) cannot present the paywall: the sheet modifier
        /// belongs on the presented root too. The first presenter that can take it does; the other stays quiet.
        @Test func a_denial_inside_a_sheet_needs_the_sheets_own_presenter() async {
            _ = await configureShared(tokens: 0)
            let log = BoundaryLog()
            let flag = SheetFlag()
            let probeID = "sheet.inner"
            let window = makeWindow()
            window.rootViewController = UIHostingController(rootView: PresentingSheetRoot(flag: flag, probeID: probeID, log: log))
            window.makeKeyAndVisible()
            #expect(await until(window) { log.handled.contains("denied:\(probeID)") })
            #expect(await until(window, rounds: 300) { !log.sheetPresented.isEmpty }, "nobody presented")
            await pump(window, rounds: 20)
            #expect(log.sheetPresented == ["inner:\(probeID)"], "\(log.sheetPresented)")
            #expect(Paywall.shared.pendingFailure == nil)
            flag.shown = false
            await dismissEverything(window)
        }

        /// A denial inside a plain `.sheet` with no presenter of its own: it stays pending while the root cannot
        /// present, and the root takes it once the sheet goes (SwiftUI's own "next sheet" queue drops sheets).
        @Test func a_denial_inside_a_plain_sheet_waits_for_the_root_until_the_sheet_goes() async {
            _ = await configureShared(tokens: 0)
            let log = BoundaryLog()
            let flag = SheetFlag()
            let probeID = "sheet.plain"
            let window = makeWindow()
            window.rootViewController = UIHostingController(rootView: PlainSheetRoot(flag: flag, probeID: probeID, log: log))
            window.makeKeyAndVisible()
            #expect(await until(window) { log.handled.contains("denied:\(probeID)") })
            #expect(await until(window) { Paywall.shared.pendingFailure?.source.id == probeID }, "the denial is not pending")
            await pump(window, rounds: 30)
            #expect(Paywall.shared.pendingFailure != nil, "a root that is presenting took the denial")
            #expect(log.sheetPresented.isEmpty, "the paywall showed over the sheet: \(log.sheetPresented)")
            flag.shown = false
            #expect(await until(window, rounds: 300) { log.sheetPresented == ["outer:\(probeID)"] }, "after the sheet went: \(log.sheetPresented)")
            #expect(Paywall.shared.pendingFailure == nil)
            _ = Paywall.shared.consumePendingFailure()
            await dismissEverything(window)
        }

        /// The row the design wrote for "any UIKit layer" holds for a hosting controller UIKit code creates outside
        /// the SwiftUI tree, a UIKit-first screen: nothing above it to inherit from, so `\.paywallGate` is nil and
        /// `Paywall` as an environment object is absent, unless `PaywallHostingController` is given the session.
        @Test func a_uikit_created_root_gets_the_gate_only_through_the_hosting_controller() async {
            _ = await configureShared(tokens: 5)
            let session = GateSession(
                level: .tokens(1), source: PaywallSource(id: "coordinator", fileID: #fileID, function: #function, line: #line),
                isOpen: true)
            for hosted in [false, true] {
                let log = BoundaryLog()
                let controller = host(ProbeContent(log: log, checkEnvironmentObject: hosted), hosted: hosted, session: session)
                let window = makeWindow()
                window.rootViewController = controller
                window.makeKeyAndVisible()
                #expect(await until(window) { log.gateReached != nil }, "content never appeared hosted=\(hosted)")
                #expect(log.gateReached == hosted, "a plain hosting controller has no gate above it; the bridge re-injects the session")
                #expect(log.entitlementResolved == hosted, "the bridge puts the resolved entitlement in the environment; a plain root has none")
                if hosted {
                    #expect(await until(window) { log.environmentObjectIsShared == true }, "Paywall.shared re-injected")
                }
                await dismissEverything(window)
            }
        }

        @Test func uikit_helpers_filter_and_present() async {
            _ = await configureShared(tokens: 0)
            let controller = UIViewController()
            let window = makeWindow()
            window.rootViewController = controller
            window.makeKeyAndVisible()
            await pump(window, rounds: 2)
            var received: [String] = []
            let cancellable = controller.paywallFailures(scope: "home") { received.append($0.source.id) }
            Paywall.shared.engine?.openSession(holder: UUID(), level: .paid, policy: .reserve, source: PaywallSource(id: "a", fileID: "f", function: "g", line: 1), scope: "home")
            Paywall.shared.engine?.openSession(holder: UUID(), level: .paid, policy: .reserve, source: PaywallSource(id: "b", fileID: "f", function: "g", line: 1), scope: "maps")
            #expect(received == ["a"])
            let failure = PaywallFailure(reason: .requiresPaid, level: .paid, source: PaywallSource(id: "a", fileID: "f", function: "g", line: 1), at: Date())
            controller.presentPaywall(for: failure) { _ in Color.orange }
            #expect(failure.isClaimed)
            BoundaryDiagnostics.note("helper: presented=\(controller.presentedViewController.map { String(describing: type(of: $0)) } ?? "nil") rootInWindow=\(controller.view.window != nil)")
            #expect(await until(window) { (controller.presentedViewController as? PaywallHostingController<Color>)?.isPresent == true })
            let hosting = controller.presentedViewController as? PaywallHostingController<Color>
            hosting?.setPresent(false)
            #expect(hosting?.isPresent == false)
            cancellable.cancel()
            failure.forgetClaim()
            await dismissEverything(window)
        }
    }
    }
#endif
