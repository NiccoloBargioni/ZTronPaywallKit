import SwiftUI

/// The minimal iOS app the StoreKit integration tests and the UIKit boundary matrix are hosted in. StoreKit
/// refuses purchases, `AppTransaction` and simulated external purchases in a process without an app bundle and a
/// window scene, and a UIKit modal presentation never completes there either, so both need a host; this is the
/// smallest one. It links nothing from the package (a product linked by the app and its test bundle becomes a
/// shared framework whose folded-in PaywallCore duplicates the bundle's copy, two `Paywall.shared`s included) and
/// configures nothing: every test configures `Paywall.shared` itself.
@main
struct TestHostApp: App {
    var body: some Scene {
        WindowGroup {
            Text("ztron-paywall-kit test host")
                .padding()
        }
    }
}
