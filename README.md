# ztron-paywall-kit

A freemium paywall package for an iOS app moving from paid up front to freemium.
StoreKit 2 is the only authority. Entitlements live in memory and are re-resolved on launch, foreground and
`Transaction.updates`. Tokens live in an append-only, hash-chained, crash-safe ledger. Every gate decision is
audited.

Swift 6 language mode, tools 6.0, iOS 15. macOS is not supported: the `.macOS(.v12)` entry in `Package.swift`
only lets the Mac build and run `swift test` as the development host, and the AppKit hosting in four test files
exists for that lane alone; nothing ships for or is measured on macOS. Nothing in the package uses
`@unchecked Sendable`, `nonisolated(unsafe)`, `@preconcurrency`, Dispatch or locks.

## Products

Products are what a `Package.swift` depends on; the module you `import` is the target name.

| Product | Module | Platforms | What it is |
|---|---|---|---|
| `ZTronPaywallCore` | `PaywallCore` | Darwin + Linux | Gate engine, ledger, journal, resolver, reconciler, audit. No UI and no StoreKit. |
| `ZTronPaywallKit` | `PaywallKit` | Darwin | `Paywall` facade, `withPaywall`, `.paywallGated`, signals, StoreKit 2 client, receipt verifier. |
| `ZTronPaywallCloudSync` | `PaywallCloudSync` | Darwin | CloudKit ledger carrier and Keychain wallet snapshot. |
| `ZTronPaywallSimulator` | `PaywallSimulator` | Darwin, `DEBUG` only | Presets, launch arguments, preview modifier. |
| `ZTronPaywallTesting` | `PaywallTesting` | Darwin + Linux | `FakeStore`, `FakeClock`, `FakeConnectivity`, in-memory sinks and carriers. |

## Setup

```swift
import PaywallKit

let catalog = ProductCatalog(
    subscriptionGroupID: "21000000",                 // App Store Connect's numeric group id, as StoreKit reports it
    weekly: "pro.weekly", monthly: "pro.monthly", yearly: "pro.yearly",
    lifetime: "pro.lifetime",
    tokenPacks: [TokenPack(productID: "tokens.10", tokens: 10), TokenPack(productID: "tokens.50", tokens: 50)])

var configuration = Paywall.Configuration(catalog: catalog)
configuration.grandfathering = GrandfatheringPolicy(
    lastPaidBuild: "116", paidWindow: DateInterval(start: launch, end: freemiumDay))
configuration.familySharing = .sharedEntitlements   // or .purchaserOnly; see Family Sharing
configuration.welcomeTokens = 100                    // the default: once per account; see Welcome tokens
configuration.sync = PaywallCloudSync()              // optional: ZTronPaywallCloudSync
Paywall.shared.configure(configuration)
```

`configure` validates the catalog and opens the journal synchronously, so the wallet is known before the
first frame. If the catalog is invalid or the journal can't be opened, `configurationError` is set and every
gate except `.free` fails closed.

`configuration.connectivity` defaults to `NetworkPathConnectivity` (NWPathMonitor). The outbox drains only
while a network path exists, and immediately when one returns. On iOS 15–16 and macOS 12–13 the monitor can
only report on a dispatch queue, which the package doesn't use, so there the outbox relies on its other
triggers: launch, foreground, purchase and the 30-second timer.

To test grandfathering on a device (TestFlight and the sandbox can't reach it), debug builds have
`configuration.grandfatherOverride = GrandfatherOverride(originalAppVersion:originalPurchaseDate:)`. It changes
only what the resolver sees; the account key, and with it the wallet, still come from the real AppTransaction.
It's compiled out of release builds.

### Production or fake, chosen at the root

`PaywallServiceProvider` is the one object the main page holds for the paywall: a `@StateObject` that runs the
production implementation or a fake one, installed on the root with `.paywallProvider(_:)` so every child finds it,
and the facade, in the environment. The fake is the production engine on a stand-in store (the simulator's switches,
or a `FakeStore` in a test); only the store, the clock, the sync carrier and the storage location differ, so both
implementations are a `Paywall.Configuration`: `.production(configuration)` or `.fake(configuration)`. Debug builds
add `.simulated(_:catalog:)` and `.fromLaunchArguments(production:)` from `ZTronPaywallSimulator`.

```swift
@main
struct ZTronApp: App {
    static var configuration: Paywall.Configuration { /* the configuration above */ }
    #if DEBUG
        // Production unless a `-paywall.*` launch argument is present (UI tests), then the simulated fake.
        @StateObject private var paywall = PaywallServiceProvider(.fromLaunchArguments(production: Self.configuration))
    #else
        @StateObject private var paywall = PaywallServiceProvider(.production(Self.configuration))
    #endif

    var body: some Scene {
        WindowGroup {
            RootView()
                .paywallSheet { failure in PaywallScreen(failure) }
                .paywallProvider(paywall)
        }
    }
}

struct AccountBadge: View {
    @EnvironmentObject private var paywall: Paywall                   // entitlement, wallet, purchase(_:)
    @EnvironmentObject private var provider: PaywallServiceProvider   // which implementation
    var body: some View {
        if provider.isFake { Text("SIMULATED") }
    }
}

// A debug menu: switch at runtime. The methods return the provider, so they chain.
provider.useSimulated(.lifetime)                 // on the production catalog and grandfathering policy, see below
provider.useSimulated(PaywallSimulation(.tokens5), catalog: catalog)
provider.useFake(configuration)                  // any configuration whose store is a stand-in
provider.useProduction()                         // back to the production configuration the provider saw last
provider.use(.fromLaunchArguments(production: configuration))
```

The provider drives `Paywall.shared`, never a second facade (two facades is how a claim gets lost): its initialiser
calls `configure` at once, so the journal is open and the wallet known before the first frame, and every `use` method
configures again, tearing the previous engine down first. `productionConfiguration` is the production configuration
it saw last (from `init` or `useProduction(_:)`): `useProduction()` returns to it, and `useSimulated` takes the catalog
and the grandfathering policy from it unless given others. `.paywallProvider` also does what `.paywallLifecycle()` does:
`\.paywallEntitlement` kept current and a re-resolution whenever the scene becomes active. `PaywallHostingController`
re-injects the provider under UIKit layers next to the facade (`Paywall.shared.provider` is the same object), and
`.paywallSimulation(_:)` installs one in previews, so a child declaring `@EnvironmentObject var provider` renders
there too.

### Progressive adoption

`configuration.passthrough = true` switches the whole mechanism off, for the builds that ship with the gates in
place before the freemium launch. Nothing starts: no engine, journal, store call, sync or audit. Every gate passes
as `.free` (`withPaywall`, `evaluate`, `canPass`, `.paywallGated`), `purchase(_:)` answers
`.purchased(transactionID: 0)` without a payment, `products()` is empty, `restorePurchases()` returns, and nothing
is published, so no sheet ever shows. `Paywall.isPassthrough` says so; `entitlement` stays `.unknown` and `wallet`
`.empty`, so an account screen branches on the flag rather than on them. The catalog is only logged, not enforced,
until the toggle flips. Default `false`; flip it by calling `configure` again.

## Catalog and storefront

`ProductCatalog` declares, in code, every product the app has ever sold: the subscription group id, the `weekly`,
`monthly` and `yearly` plans (each optional: leave `monthly` out to never offer one), the `lifetime` non-consumable
and the `tokenPacks` with their sizes. The catalog is the authority on what a product *is*: StoreKit does not know a
pack's size, nor which plan is which tier, and resolution looks every transaction up here, so a product sold once
stays declared for as long as a customer may hold a transaction for it. `mismatches(withStoreKitConfiguration:)`
keeps the catalog in step with the `.storekit` file and App Store Connect.

What the paywall *offers* is the storefront's subset of the catalog. `PaywallStorefront` is what the App Store
sells right now: every declared product the store returned, in catalog order, each with `displayPrice`, the `price`
and `currencyCode` behind it, and its `offers`: the introductory offer, the promotional offers and, on iOS 18, the
win-back offers this account is eligible for, each with its payment mode, period, price and, where StoreKit can say,
eligibility. `unavailableProductIDs` lists the declared products the store did not return (removed from sale, not
approved yet, not sold in this storefront) and `countryCode` the storefront the prices are for.

The engine keeps it current on its own. It is fetched at launch and on every return to the foreground when the last
fetch is older than `configuration.storefrontRefreshInterval` (an hour by default), at once after a purchase or a
restore (the trial is used up, a win-back offer may have appeared), and on demand with `refreshStorefront()`. The last
fetch is kept next to the journal, so `Paywall.storefront` is populated before a launch's first fetch answers, and a
fetch that changes the listing (a product, a price, an offer, the country) is published as `.storefrontChanged`.
`products()` is the screen-facing shortcut: a fetch, or offline the last storefront with `priceAsOf` set and
`isPurchasable` false.

Opting out of a plan has two forms. Without a release, remove it from sale in App Store Connect: the store stops
returning it, the storefront drops it, and existing subscribers keep renewing and keep resolving through the
catalog. In code, add it to `catalog.retired`: still declared, so its transactions resolve and credit, never listed.
Dropping a product from the catalog altogether is only right for one that was never sold, because a transaction the
catalog does not know resolves to nothing.

```swift
let catalog = ProductCatalog(
    subscriptionGroupID: "21000000", weekly: "pro.weekly", monthly: "pro.monthly", yearly: "pro.yearly",
    lifetime: "pro.lifetime", tokenPacks: packs,
    retired: ["pro.monthly"])                        // sold before, honoured, no longer offered

if let storefront = Paywall.shared.storefront {   // @Published, kept current by the engine
    let current = Paywall.shared.tier ?? .free
    for product in storefront.products where product.tier > current { show(product) }
    for offer in storefront.product("pro.yearly")?.offers ?? [] where offer.isEligible != false { show(offer) }
}
```

Redeeming an offer: the introductory offer applies by itself at purchase. A promotional offer needs a signature
from the app's server, and a win-back offer the purchase option StoreKit added in iOS 18; `purchase(_:)` passes
neither yet (see Not in this package). The storefront models both so the screen can show them.

## Tiers

`AccessTier` puts what the user has on one scale, lowest first:
`.free < .freeTrial < .tokens < .weekly < .monthly < .yearly < .lifetime < .grandfathered`. The declaration order is
the order (`Comparable`, `rank`). `Paywall.tier` and `GateEngine.tier` derive it from the entitlement and the wallet:
a free user with a positive balance is `.tokens`, a subscription in its free trial is `.freeTrial` whatever its
period, a lifetime purchase bought or family-shared is `.lifetime`, a grandfathered install `.grandfathered`, and
`nil` stands for an unknown entitlement. `PaywallProduct.tier` names the tier a product buys, so a screen offers
what ranks above the current one. `SubscriptionTier` (`.weekly < .monthly < .yearly`) is the billing period of a
plan, not the user's standing. Gates never read tiers: `GateEngine.decide` does, and a trial opens `.paid` gates
like any subscription.

## Welcome tokens

`configuration.welcomeTokens` (100 by default, `0` for none) is granted once per account to try the app, as the
ledger event `grant:welcome` carrying the amount of the build that wrote it. Being a ledger event, a later build
with another amount changes nothing for existing users: their balance stays what their first build granted, less
what they spent, and the deterministic id makes any second attempt a no-op on every device.

When it is written depends on what can know the account is new. Without a carrier, at the first launch, right after
the launch resolution. With `sync` set, after the carrier's first answer, so a new device of an existing account
takes the account's grant, whatever its own build would give, rather than writing its own, and an account with
history but no welcome grant (from before the feature) gets none. An offline first launch with a carrier shows the
tokens once the first pull answers. A device with no iCloud account is told so by the carrier
(`CloudDatabaseError.noAccount`) and grants on its own, as if it had none; signed in later, it uploads that grant
like any event, and should the account already hold another build's grant from another device, the ids collide and
each device keeps the one it wrote. A reinstall whose Keychain snapshot stands in for history is not a new account
either. Without any carrier the package has no memory of the account beyond StoreKit, so a delete-and-reinstall
grants again, as any local trial would.

## Gating

```swift
// Synchronous, main actor: decide, draw write-ahead, run, audit.
let outcome = withPaywall(.tokens(2), id: "export") { exportPDF() }

// Async, inherits the caller's isolation (SE-0420).
let value = await withPaywall(.paid, id: "heatmap") { await renderHeatmap() }

// Views: hold on appear, consume on commit, release on disappear (`.reserve`), or draw on appear (`.deductNow`).
MapView()
    .paywallGated(.tokens(1), id: "map") { failure in LockedMapView(failure) }

// Inside a gated view, commit the reservation:
@Environment(\.paywallGate) var gate
gate?.withPaywall { solve() }

// Or handle the outcome in place. Both handlers return the outcome, so they chain off any of the calls above.
withPaywall(.tokens(2), id: "export") { exportPDF() }
    .onExecuted { url in share(url) }
    .onBlocked { failure in failure.claim(); showUpsell(failure) }   // claim it, or the sheet shows it too
```

Each `.tokens(n)` draw grants a lease of `tolerance` seconds (300 by default) on that gate id. Re-opening
the same gate inside the lease costs nothing. A `.deductNow` view that drew stays `.drawn` for as long as it is
on screen; its own lease is what keeps it open on later evaluations, and nothing logs a second open for it.

The denied view receives the same `PaywallFailure` value the engine published, so `failure.claim()` from inside
it stops the global sheet, and `PaywallFailureKey` carries one value per closed spell rather than one per render.

## Signals

A denial is offered to handlers first (claim), then falls back to the coordinator:

```swift
RootView()
    .paywallSheet { failure in PaywallScreen(failure) }      // unclaimed failures, end of turn
    .onPaywallFailure(in: "maps") { failure in               // scoped handler; claim() to stop the fallback
        failure.claim(); showInlineUpsell()
    }
    .onPurchaseIntent { productID in                         // a promoted in-app purchase tapped on the App Store
        showPaywall(highlighting: productID)
    }
```

`.paywallSheet` consumes `pendingFailure` when it takes a denial, so two installed sheets never show one. Install
it on the outermost root and on any root that is itself presented modally (a `.sheet`, a UIKit `present`); nested
roots inside one presentation pass `presentsPaywall: false`. The deepest installed presenter that can present
takes the denial, so the sheet inside a presented sheet shows it rather than the root under it, which cannot
present a second sheet. Behind a plain sheet with no presenter inside, the denial stays pending and the root takes
it once that sheet goes (SwiftUI's own "next sheet" queue is not relied on; it drops sheets). Both cases are in
the boundary tests.

Also available: `PaywallFailureKey` (preference), `Paywall.shared.events` (Combine), `eventStream`
(`AsyncStream`), `purchaseIntents` (Combine), `bridgeToNotificationCenter()`, and `.paywallLifecycle()` for
scenes without a sheet. On iOS, `PaywallHostingController` provides presence and `paywallFailures` /
`presentPaywall` to UIKit.

For `NotificationCenter` code, `bridgeToNotificationCenter()` (or `configuration.notificationCenter = .default`, which
keeps the bridge for the facade's lifetime) posts every event as `.paywallEvent`, and the paywall and purchase events
under their own names with the payload in `userInfo`, keyed by `PaywallNotificationKey`: `.paywallDenied`
(`failure`), `.paywallEntitlementChanged` (`entitlement`, `previousEntitlement`, `cause`), `.paywallPurchaseStarted`
/ `Completed` / `Pending` / `Cancelled` / `Failed` (`productID`, `source`, `transactionID`, `error`),
`.paywallRestoreRequested` / `Completed` / `Failed` (`error`), and `.paywallPurchaseIntent` (`productID`).

For display, `.paywallSheet`, `.paywallLifecycle()` and `PaywallHostingController` also put the resolved
entitlement in the environment as `\.paywallEntitlement`: `nil` until the first resolution answers (so a view can
show a placeholder instead of the free state), then `.free`, `.subscribed` or `.lifetime`, kept current from
`Paywall.entitlement`. It is a convenience like `\.paywallGate`; access decisions stay with the gates and
`withPaywall`.

```swift
@Environment(\.paywallEntitlement) private var entitlement   // Entitlement?, nil while resolving
```

What crosses a UIKit boundary, measured by `UIKitBoundaryTests` in the test host on the iOS 18.0 and 17.5
Simulators, with identical rows (every layer kind alone, every ordered pair, twelve triples; the suite runs in the
host because a modal presentation never completes in the package's unhosted test process; iOS 15 runtimes no
longer run on current macOS): `pendingFailure`, `.onPaywallFailure`, `events` and
`purchaseIntents` reach through anything. Environment values set above the stack (`\.paywallGate` and
`\.paywallEntitlement`, which travel together in every row) reach through SwiftUI-managed layers, and SwiftUI also
carries them into a hosting controller that stays in the view-controller containment hierarchy under its tree: a
representable's, one pushed by a navigation controller, one in a table cell. They are lost as soon as a UIKit modal
presentation is anywhere in the stack, and a hosting controller that UIKit code creates outside the tree (a
UIKit-first screen) gets nothing. `PaywallFailureKey` climbs out of every UIKit layer, the modal included, and
never out of a `.sheet`. The suite records those rows rather than promising them: the design did not count on
them. The contract is `PaywallHostingController`: the gate session it is given, `Paywall.shared` as an environment
object (with the `PaywallServiceProvider` that configured it, when the app installed one) and the resolved
entitlement are in its environment whatever the layer. A reservation held behind any UIKit layer is released when
the layer goes, through the hosting controller's presence signal, without relying on `onDisappear`.

## Store

`products()`, `purchase(_:)`, `restorePurchases()`, `refresh()`, `subscriptionPhase()` and
`isEligibleForIntroOffer()` go through the engine. Pack credits are written to the ledger before
`finish()`. Refunds become revocation events: a refunded pack arrives on `Transaction.updates` and is also found
by every resolution in `Transaction.all`, which lists finished consumables only when the app's `Info.plist` sets
`SKIncludeConsumableInAppPurchaseHistory` (set it; the test host does). Prices and offers come with the storefront
(see Catalog and storefront); offline, `products()` returns the last storefront marked not purchasable. The package
never calls `AppStore.sync()` or refreshes the receipt on its own; only `restorePurchases()` does.

The outcome chains like a gate's. A store error is thrown by `purchase` itself, so the `try` stays and no handler
runs. A purchase does not re-run the `withPaywall` call it was bought for: open view gates re-evaluate on their own,
a call site runs the action again.

```swift
try await Paywall.shared.purchase(product, source: failure.source)
    .onPurchaseCompleted { transactionID in dismiss() }   // ledger and entitlement already updated
    .onPurchasePending { dismiss() }                      // Ask to Buy: the transaction arrives on `Transaction.updates`
    .onPurchaseCancelled { }
```

`StoreKit2Client` is `@concurrent`: StoreKit's work and the receipt parse run off the caller's actor, so the
main actor's only disk I/O stays the draw path. `Subscription.willAutoRenew` is `true` from a transaction
(StoreKit does not put the renewal preference on it); the account screen reads the renewal state through
`subscriptionPhase()`.

### Promoted in-app purchases

`PurchaseIntent.intents` (iOS 16.4+) is listened to from `start()`. An intent becomes a `.purchaseIntent`
event, `Paywall.pendingPurchaseIntent` and a call to `.onPurchaseIntent`; the engine buys nothing on its own.
Starting a purchase of that product, or `consumePendingPurchaseIntent()`, clears it. StoreKit Testing cannot
simulate an intent, so the review test `promoted_purchase_intent_opens_paywall` drives it through `FakeStore`.

### Family Sharing

`configuration.familySharing` is `.sharedEntitlements` (a family member's subscription or lifetime purchase
counts as paying here; the entitlement says `isFamilyShared`) or `.purchaserOnly` (a family-shared transaction
resolves as if absent). Tokens never cross members whatever the value: consumables cannot be shared and the
account key is per Apple Account. The policy is applied at every resolution and to the cached snapshot before
the first one, so a build that changes it takes effect at its first launch, and a removal from the family is a
revocation like a refund.

### Receipt verification (iOS 15 path)

`ReceiptClient` reads the App Store receipt, and `AppleReceiptVerifier` checks it before anything is parsed:

- PKCS#7 `SignedData` with Apple's layout (no signed attributes, RSA PKCS#1 v1.5 over the payload, SHA-256; SHA-1
  on receipts signed before 2023), signed attributes accepted with the `messageDigest` checked;
- the signer certificate found in the container chains to the **Apple Root CA** (embedded, SHA-256
  `b0b1730e…f024`) as the only anchor, evaluated **at the receipt's creation date** (field 12), because Apple
  rotates the signing certificate and a 2015 receipt stays valid after its certificate expired;
- the signer carries Apple's receipt-signing marker extension `1.2.840.113635.100.6.11.1`, so a certificate
  Apple issued for anything else cannot sign one;
- field 2 names this app's bundle id.

Not checked: the device GUID hash (field 5), which binds a receipt to one device. It needs
`identifierForVendor` and only matters against a user copying their own receipt between their own devices.

The Mac App Store receipts installed on the machine running the tests are verified as a bonus: purchase
receipts (`Production`) verify and parse; Apple's `ProductionStub` receipts for its bundled apps carry no
original version and fail closed, as they should.

## Crash safety

The proof obligation: delivered(g) ⇒ durableDebit(g). The draw runs in this order:

1. `decided`
2. `debitAppended`: `write(2)` of a CRC-framed, canonical-JSON ledger event
3. `debitSynced`: `F_FULLFSYNC`, falling back to `fsync`
4. `valueDelivered`
5. `auditWritten`

`CrashSafetyTests` terminates the engine at every `DrawStep` (`CaseIterable`, so a new step won't compile
until it's covered), relaunches on the same directory, and checks that tokens never leak and value is never
delivered without a debit. Torn tails are truncated at open. A short `write(2)` is rewound to the frame
boundary, and if even that fails the journal stops writing until the relaunch truncates the torn frame, so a
half-written frame can never hide the records after it. Compaction writes a side file and renames it over the
log. A seeded property test drives the lease state machine.

`DrawPerformanceTests` bounds the draw at 25 ms (median and p95 over 60 draws with `F_FULLFSYNC`), on macOS and
on the iOS Simulator, on an empty ledger and on one of 20,000 events; the design states the bound for a device,
where it has not been measured yet.

## Retention

What a long-lived install must not pay for its history, and what the package forgets:

- **The ledger's derivations are maintained, not replayed.** `Ledger` keeps the balance per account partition and
  the lease table per partition up to date as events are appended, in whatever order a sync delivers them (a refund
  or an extension may arrive before its debit), so a draw, a hold and a merge cost the same on a ten-year history as
  on a fresh install. `LedgerIncrementalTests` checks every append of random histories against a full replay.
- **The journal is checkpointed, and compaction drops what the checkpoint covers.** A compacted `ledger.log` starts
  with a `.checkpoint` record: the ledger's derived state, which is everything a later event may still refer to. The
  balances with their cross-account parts, the lease table of every account partition, the per-device heads the next
  events link to, the credits a revocation may reverse, every debit a refund may give back or a lease may fall back
  to (amount, account, date, lease, gate), the refunds and revocations that arrived before their counterpart, every
  event id (so a replay or a re-delivery of a forgotten event stays a no-op and the sync union merge and the outbox
  stay exact), and what the chain check needs to go on: per device the hashes no event links to yet, whether the
  first event was seen, the events whose predecessor the sync has not delivered, and a fork. The engine starts from
  the checkpoint and replays only the events after it. `LedgerIncrementalTests` proves that a replay from a
  checkpoint taken anywhere in a random, shuffled, two-device history observes exactly what the full replay does,
  the chain verdicts included: an event whose predecessor is missing is a broken link until it arrives, a fork stays
  one for good. The checkpoint grows with the ids and debits of the history, at a fraction of an event's size;
  nothing else of the history survives it.
- **The retention rule.** `start()` writes a checkpoint when more events than `compactionThreshold` (4096) followed
  the last one at open, and only after this launch's audit repair ran over those very debits and the audit trail
  flushed, so every debit a checkpoint covers has its audit record before the journal forgets it. Only what an
  earlier process wrote is covered: a debit drawn before `start()` got there stays in the log for the next launch's
  repair, and nothing is written after `shutdown()`. The rewrite goes to a side file that is synced and renamed over
  the log, as compaction always did; an interrupted one leaves the old log intact and the side file is deleted at the
  next open. What survives the rewrite: the checkpoint; the outbox, the events the carrier has not acknowledged, kept
  behind the checkpoint that already counts them (replays to the ledger, dropped by the next compaction once
  acknowledged); and every event appended since. Without a carrier nothing will ever acknowledge the outbox, so none
  is kept, and a carrier configured by a later build receives the events written since the last checkpoint only. The
  marker compaction at open stays: `ledger.log` is rewritten when it holds more `.uploaded` markers than the
  threshold, and with a checkpoint in front the acknowledged events it counts go too. A corrupt checkpoint, or one
  from a newer build's format, drops the log like any undecodable first frame; the Keychain snapshot and the carrier
  then restore the ledger as after a reinstall. On the 20,000-event history of `DrawPerformanceTests` (17,142 debits
  on 50 gates, 2,857 extensions) the iPhone 17 simulator opens the engine in 144 ms from the checkpoint against 500 ms
  for the full replay, and `ledger.log` shrinks from 6.1 MB to 2.2 MB; the test prints both pairs.
- **The audit log forgets by rotation, and the repair knows it.** `audit.jsonl` rotates at 5 MB and keeps 10 files.
  Dropping a file writes `audit.anchor`, the hash of the last record dropped: `verifyAuditChain` checks the retained
  chain from there, and the export carries the anchor. The launch repair (`auditRepaired`) only considers debits
  newer than the oldest retained record; older ones have simply been rotated out. A refunded debit counts as known
  to the audit. The chain's last hash is read from the tail of the newest file, not by decoding every file.

## Reinstall and the Keychain snapshot

After a reinstall the Keychain snapshot stands in for the history this install has not seen. Once the carrier
has answered with events for the account, the snapshot steps aside: if its last event is among them the ledger
is complete; if not, that event was never uploaded and died with the old install, and keeping the snapshot on
top of the remote history would count every uploaded credit twice. A carrier that answers with nothing (iCloud
off, empty container) leaves the snapshot standing.

The snapshot is adopted at `start()` only when the ledger holds no events for its account: a reinstall, or a
new device. A ledger with history never gets a snapshot added on top, because it cannot tell which part of that
history the snapshot already counts. The item is `synchronizable`, so another device's snapshot can arrive
through iCloud Keychain before that device's debits were pulled; adopted over the local history, it would count
every local credit twice (a 10-pack read as 19 at an offline relaunch). This device's own snapshot written ahead
of a journal that lost its tail would do the same. Neither is adopted.

## Simulator (debug builds)

```swift
#Preview { HeatmapView().paywallSimulation(PaywallSimulation(.tokens5)) }

// UI tests: -paywall.preset broke -paywall.tokens 3 -paywall.network off -paywall.store down
Paywall.shared.configure(.simulated(PaywallLaunchArguments(), catalog: catalog))
// or, through the root provider (see Setup): production unless a `-paywall.*` argument is present
@StateObject private var paywall = PaywallServiceProvider(.fromLaunchArguments(production: configuration))

PaywallSimulator.shared.apply(.lifetime)
PaywallSimulator.shared.refund(.lastTokenPack)
PaywallSimulator.shared.advance(by: 301)
```

## App Review

The design maps each App Review rejection cause to a named test. This package holds the package half:
`AppReviewTests`, `EdgeCaseTests` and `AuditTableTests` in `PaywallCoreTests`, the disclosure and receipt
tests in `PaywallKitTests`, and `StoreKitIntegrationTests` in the test host (refunds, Ask to Buy, renewals at
accelerated time, crossgrades, cancellation, restore, against the real `StoreKit2Client`).

`ProductCatalog.mismatches(withStoreKitConfiguration:)` compares the catalog with a `.storekit` file. It reports
missing products, wrong types, wrong renewal periods and subscriptions split across groups. The package's own
file, `Tests/PaywallKitTests/Fixtures/Paywall.storekit`, is the one the simulator and host lanes load, and
`the_storekit_configuration_matches_the_test_catalog` keeps it in step with the test catalog. The host app runs
the same check against its own file.

`Scripts/check-release-symbols.sh` builds release and fails if a shipping module contains simulator, preset,
launch-argument, fake, override or simulation-hook symbols, or if `PaywallSimulator` is not empty.

## Development

Four lanes, all run by `.github/workflows/test.yml`, and a fifth that only runs locally (below):

```bash
swift build --build-tests -Xswiftc -warnings-as-errors && swift test --enable-code-coverage
```

```bash
xcodebuild test -scheme ztron-paywall-kit-Package -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -skipPackagePluginValidation -enableCodeCoverage YES -resultBundlePath /tmp/package.xcresult
```

```bash
xcodebuild test -project TestHost/TestHost.xcodeproj -scheme TestHost -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -skipPackagePluginValidation -enableCodeCoverage YES -resultBundlePath /tmp/host.xcresult CODE_SIGNING_ALLOWED=NO
```

```bash
docker run --rm -v "$PWD":/pkg -w /pkg swift:6.3-noble bash -c 'swift test --enable-code-coverage && Scripts/coverage-gate.sh --targets "PaywallCore PaywallTesting"'
```

Then the gate, which merges `llvm-cov` from `swift test` with the `xccov` reports of the two simulator lanes:

```bash
xcrun xccov view --report --json /tmp/package.xcresult > /tmp/package-xccov.json && xcrun xccov view --report --json /tmp/host.xcresult > /tmp/host-xccov.json && Scripts/coverage-gate.sh --baseline coverage-baseline.json --xccov /tmp/package-xccov.json --xccov /tmp/host-xccov.json
```

```bash
swift test --sanitize=thread
```

### Live CloudKit lane (local)

`LiveCloudKitTests` runs the production `CloudKitDatabase` and `PaywallCloudSync` against the real container
`iCloud.com.ztron.paywall.testhost` from the test host: zone setup and the save and change-fetch round trips
through the `CKDatabase` forwarders; two devices (two engines on their own directories) on one iCloud account
converging on one ledger after interleaved draws; delete-and-reinstall keeping the balance through the Keychain
snapshot before the first sync and through the container after it (the pack is bought through the engine's
purchase path); and an iCloud data reset, where the ledger zone is deleted under a running adapter and comes back
on the next save and the next fetch while a change token from the old zone restarts the fetch from the beginning.
Each test deletes the ledger zone first, so the container is empty and the balances it asserts are absolute.

The first live run found a bug the fake had hidden: CloudKit reports a save into a deleted zone per record
(`zoneNotFound` on each, the call itself succeeding, as `modifyRecords` is not atomic here), not as a thrown error,
so `CloudKitDatabase.save` never recreated the zone and the outbox stayed unacknowledged until a relaunch. It now
recreates the zone and retries the batch once in either shape, and `FakeCloudKit` reports a missing zone the way
the server does.

It needs what CI cannot have: a simulator signed into an iCloud account and a signed host, so the suite is gated on
`PAYWALL_CLOUDKIT_CONTAINER` (skipped when unset; `TestHost.entitlements` carries the container; the signing team comes
from `DEVELOPMENT_TEAM` on the command line, and `CODE_SIGNING_ALLOWED=NO` in the default lane needs none). Sign a simulator into iCloud in Settings, then:

```bash
TEST_RUNNER_PAYWALL_CLOUDKIT_CONTAINER=iCloud.com.ztron.paywall.testhost xcodebuild test -project TestHost/TestHost.xcodeproj -scheme TestHost -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation -enableCodeCoverage YES -resultBundlePath /tmp/live.xcresult DEVELOPMENT_TEAM=<your team id>
```

`xcodebuild` hands `TEST_RUNNER_`-prefixed variables to the test process; the `TestHost` scheme also carries the
variable, switched off, for running the suite from Xcode. The run is the TestHost lane with four more tests, so its
`xccov` report takes the host lane's place in the gate (or joins it: the merge keeps the best report per file):

```bash
xcrun xccov view --report --json /tmp/live.xcresult > /tmp/live-xccov.json && Scripts/coverage-gate.sh --baseline coverage-baseline.json --xccov /tmp/package-xccov.json --xccov /tmp/live-xccov.json
```

With it PaywallCloudSync measures 99.08% of lines: the live lane's `CloudKitDatabase.swift` includes the error paths
(deleted zone, expired token) because the suite provokes them against the server, so only the one-line fold of a
whole-call zone error is left to the fake. Do not write that run back with `--write-baseline`: `coverage-baseline.json`
ratchets what CI measures, the package lane and the unsigned host lane, where PaywallCloudSync is at 97.24%.

The test host (`TestHost/`) is the smallest iOS app that can host `SKTestSession` and a UIKit modal
presentation: StoreKit refuses purchases, `AppTransaction` and simulated external purchases in a process without
an app bundle and a window scene, a `present` started there never completes, and `swift test` on macOS is not
entitled for StoreKit at all. Its tests are `StoreKitIntegrationTests`, `UIKitBoundaryTests` and `LiveCloudKitTests`, in
one serialized lane because the first two configure `Paywall.shared`. Only the test bundle links the package: a product linked
by the app too becomes a shared framework whose folded-in `PaywallCore` duplicates the bundle's static copy, and
two `Paywall.shared`s is how a claim gets lost. It needs iOS 17 for the StoreKitTest Swift API, and its
`Info.plist` sets `SKIncludeConsumableInAppPurchaseHistory`, without which a refunded token pack vanishes from
`Transaction.all` instead of showing up revoked (the host test asserts the key is in effect before it refunds).

`Scripts/coverage-gate.sh` enforces two rules, per target, with no exclusions:

- 97% line coverage per target.
- 100% line and region coverage on the crash-critical files: `Journal`, `LedgerEvent`, `Ledger`,
  `LeaseTable`, `ReservationTable`, `GateEngine+Draw` and `CreditReconciler`.

With `--baseline`, neither number may drop for any target. `llvm-cov` counts lines per function, closures
included, so a never-run closure or `??` fallback on an executed line costs a line: the four CloudKit forwarders
and the two container initialisers in `PaywallCloudSync` are written as single statements for that reason, and
only the live CloudKit lane executes them (CloudKit traps outside an entitled host).

### Fixtures

`Scripts/make-receipt-fixtures.sh` regenerates `Tests/PaywallKitTests/Fixtures`: a throwaway root → intermediate
→ leaf chain shaped like Apple's (the leaf carries the receipt-signing marker) and receipts signed in every
layout the verifier accepts or refuses: SHA-256 without attributes (Apple's), SHA-1, signed attributes, an
expired signer with and without a creation date, a leaf without the marker, another app's bundle id. Keys are
discarded; only the root certificate and the receipts are kept. The verifier is pointed at that root in tests
and at the Apple Root CA in production.

A real **production receipt** of your app runs through the same checks, and then the grandfathering rule, when
`PAYWALL_PRODUCTION_RECEIPT` names it. `ProductionReceiptTests` verifies it against the embedded Apple Root CA,
parses it, derives a policy from its own build and purchase date, and checks that the rule, the resolver and a
configured facade admit it, that the rule refuses it once the paid window ends before the purchase, and that one
changed payload byte is refused. A receipt names its app, so none is committed and CI skips the suite:

```bash
PAYWALL_PRODUCTION_RECEIPT=/path/to/receipt swift test --filter ProductionReceiptTests
```

Such a receipt can only come from an App Store install of the paid app. The ways to get one, in order of
usefulness:

1. Install the app from the Mac App Store on an Apple silicon Mac: an iOS app keeps its receipt at
   `~/Library/Containers/<bundle id>/Data/StoreKit/receipt`, root-owned, so copy it with `sudo`. It carries your
   bundle id and the build that Apple Account first bought, at that account's purchase date: a fresh purchase
   proves the format and the rule, not an old customer's history.
2. Any Mac App Store app you own has an Apple-production-signed receipt at
   `/Applications/<App>.app/Contents/_MASReceipt/receipt`. It proves the signature chain and the parser against
   Apple's real output (the test suite does this on the machine it runs on) but carries that app's bundle id and
   marketing version, so it cannot stand in for your app's fixture.
3. Ship a support export in the freemium build: a hidden action that shares `Bundle.main.appStoreReceiptURL`'s
   contents and `AppTransaction.shared`'s `jwsRepresentation` through the share sheet. A paid-era user, or your
   own device that bought the paid version from the App Store, then sends both. A TestFlight build of the same gives a
   sandbox receipt (`original_application_version` `1.0`), which is the fixture for the sentinel cases.
4. Xcode's Devices window → Download Container works only for development-signed builds and yields the StoreKit
   Testing receipt, which `AppleReceiptVerifier` correctly rejects.

Apple does not publish downloadable receipts, and the App Store Server API has no endpoint for them.

### Current coverage

| Target | Lines | Regions | Gate |
|---|---|---|---|
| PaywallCloudSync | 97.44% | 86.81% | ok; the CloudKit forwarders and container initialisers run only in the live CloudKit lane |
| PaywallCore | 99.76% | 98.42% | ok, all 7 crash-critical files at 100/100 |
| PaywallKit | 98.13% | 83.80% | ok; `StoreKit2Client`, `PaywallHostingController` and the UIKit boundary matrix from the TestHost lane |
| PaywallSimulator | 98.11% | 91.71% | ok |
| PaywallTesting | 100.00% | 100.00% | ok |

Measured 2026-11-14 in CI's shape: `swift test` on macOS merged with the xccov reports of the package simulator
lane and the unsigned TestHost lane, `Scripts/coverage-gate.sh --baseline coverage-baseline.json --xccov … --xccov …`.
Regions come from `swift test` alone. `coverage-baseline.json` holds these numbers. The live CloudKit lane, which CI
cannot run, adds the CloudKit forwarders on top (PaywallCloudSync 99.08% when last measured, 2026-11-13); a live run
is checked against the same baseline. On Linux (`swift:6.3-noble`) the gate runs on PaywallCore and PaywallTesting alone and passes, with the
crash-critical files at 100/100.

## Not in this package

- **Routing**: the `ZRouteGate` hook belongs in `ztron-routing-kit`.
- **Adoption**: integrating the package into the host app.
- **The host half of the App Review table**: the paywall screen (restore button, links, disclosures, retry
  when products fail, hiding Buy for the current tier), the gated routes, the archive check over the `.ipa`,
  and `Scripts/presubmit.sh`.
- **Offer redemption**: `purchase(_:)` passes no `Product.PurchaseOption`. A promotional offer needs the app's
  server to sign it and a win-back offer the iOS 18 purchase option; the storefront models both for display.
- **Decided out**: macOS (the Mac is the build host for `swift test`, nothing more), a `UIHostingConfiguration`
  cell variant for iOS 16+, and a runtime refusal of the simulator in non-debug processes.
- **The 25 ms draw bound on a device**: measured on macOS and the iOS Simulator; a device lane needs a signed
  build of the test host.
