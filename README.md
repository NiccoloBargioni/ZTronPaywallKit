# ztron-paywall-kit

A freemium paywall package for an iOS app moving from paid up front to freemium.
StoreKit 2 is the only authority. Entitlements live in memory and are re-resolved on launch, foreground and
`Transaction.updates`. Tokens live in an append-only, hash-chained, crash-safe ledger. Every gate decision is
audited.

Swift 6 language mode, tools 6.0, iOS 15 / macOS 12. Nothing in the package uses `@unchecked Sendable`,
`nonisolated(unsafe)`, `@preconcurrency`, Dispatch or locks.

## Products

| Product | Target | Platforms | What it is |
|---|---|---|---|
| `ZTronPaywallCore` | `PaywallCore` | Darwin + Linux | Gate engine, ledger, journal, resolver, reconciler, audit. No UI and no StoreKit. |
| `ZTronPaywallKit` | `PaywallKit` | Darwin | `Paywall` facade, `withPaywall`, `.paywallGated`, signals, StoreKit 2 / receipt clients. |
| `ZTronPaywallCloudSync` | `PaywallCloudSync` | Darwin | CloudKit ledger carrier and Keychain wallet snapshot. |
| `ZTronPaywallSimulator` | `PaywallSimulator` | Darwin, `DEBUG` only | Presets, launch arguments, preview modifier. |
| `ZTronPaywallTesting` | `PaywallTesting` | Darwin + Linux | `FakeStore`, `FakeClock`, in-memory sinks and carriers. |

## Setup

```swift
import ZTronPaywallKit

let catalog = ProductCatalog(
    subscriptionGroupID: "pro",
    weekly: "pro.weekly", monthly: "pro.monthly", yearly: "pro.yearly",
    lifetime: "pro.lifetime",
    tokenPacks: [TokenPack(productID: "tokens.10", tokens: 10)])

var configuration = Paywall.Configuration(catalog: catalog)
configuration.grandfathering = GrandfatheringPolicy(
    lastPaidBuild: "116", paidWindow: DateInterval(start: launch, end: freemiumDay))
configuration.sync = PaywallCloudSync()          // optional: ZTronPaywallCloudSync
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
```

Each `.tokens(n)` draw grants a lease of `tolerance` seconds (300 by default) on that gate id. Re-opening
the same gate inside the lease costs nothing.

## Signals

A denial is offered to handlers first (claim), then falls back to the coordinator:

```swift
RootView()
    .paywallSheet { failure in PaywallScreen(failure) }      // unclaimed failures, end of turn
    .onPaywallFailure(in: "maps") { failure in               // scoped handler; claim() to stop the fallback
        failure.claim(); showInlineUpsell()
    }
```

Also available: `PaywallFailureKey` (preference), `Paywall.shared.events` (Combine) and `eventStream`
(`AsyncStream`), `bridgeToNotificationCenter()`, and `.paywallLifecycle()` for scenes without a sheet. On
iOS, `PaywallHostingController` provides presence and `paywallFailures` / `presentPaywall` to UIKit.

## Store

`products()`, `purchase(_:)`, `restorePurchases()`, `refresh()`, `subscriptionPhase()` and
`isEligibleForIntroOffer()` go through the engine. Pack credits are written to the ledger before
`finish()`. Refunds become revocation events. Prices are cached for offline display, but cached products are
marked not purchasable. The package never calls `AppStore.sync()` or refreshes the receipt on its own; only
`restorePurchases()` does.

## Crash safety

The proof obligation: delivered(g) ⇒ durableDebit(g). The draw runs in this order:

1. `decided`
2. `debitAppended`: `write(2)` of a CRC-framed, canonical-JSON ledger event
3. `debitSynced`: `F_FULLFSYNC`, falling back to `fsync`
4. `valueDelivered`
5. `auditWritten`

`CrashSafetyTests` terminates the engine at every `DrawStep` (`CaseIterable`, so a new step won't compile
until it's covered), relaunches on the same directory, and checks that tokens never leak and value is never
delivered without a debit. Torn tails are truncated at open. Compaction writes a side file and renames it
over the log. A seeded property test drives the lease state machine.

## Simulator (debug builds)

```swift
#Preview { HeatmapView().paywallSimulation(PaywallSimulation(.tokens5)) }

// UI tests: -paywall.preset broke -paywall.tokens 3 -paywall.network off -paywall.store down
Paywall.shared.configure(.simulated(PaywallLaunchArguments(), catalog: catalog))

PaywallSimulator.shared.apply(.lifetime)
PaywallSimulator.shared.refund(.lastTokenPack)
PaywallSimulator.shared.advance(by: 301)
```

## App Review

The design maps each App Review rejection cause to a named test. This package holds the package half:
`AppReviewTests`, `EdgeCaseTests` and `AuditTableTests` in `PaywallCoreTests`, plus the disclosure tests in
`PaywallKitTests`.

`ProductCatalog.mismatches(withStoreKitConfiguration:)` compares the catalog with a `.storekit` file. It reports
missing products, wrong types, wrong renewal periods and subscriptions split across groups. The host's
`catalog_matches_storekit_configuration` test calls it on its own file.

`Scripts/check-release-symbols.sh` builds release and fails if a shipping module contains simulator, preset,
launch-argument, fake, override or simulation-hook symbols, or if `PaywallSimulator` is not empty.

## Development

```bash
swift build --build-tests -Xswiftc -warnings-as-errors
```

```bash
swift test --enable-code-coverage
```

```bash
Scripts/coverage-gate.sh --baseline coverage-baseline.json
```

```bash
swift test --sanitize=thread
```

`Scripts/coverage-gate.sh` exports llvm-cov over every test bundle, optionally merges
`xccov --report --json` files from xcodebuild lanes (`--xccov`), and enforces two rules:

- 97% line coverage per target.
- 100% line and region coverage on the crash-critical files: `Journal`, `LedgerEvent`, `Ledger`,
  `LeaseTable`, `ReservationTable`, `GateEngine+Draw` and `CreditReconciler`.

With `--baseline`, neither number may drop for any target.

CI (`.github/workflows/test.yml`) runs:

- A forbidden-construct grep.
- macOS: build with warnings as errors, tests, the coverage gate, and a release build.
- TSan.
- An iOS Simulator build.
- Linux: the core targets, their coverage gate, and TSan.
- On macOS and Linux: the release-symbol check.

### Current coverage

| Target | Lines | Regions | Gate |
|---|---|---|---|
| PaywallCore | 99.7% | 97.6% | ok, all 7 crash-critical files at 100/100 |
| PaywallTesting | 98.3% | 93.9% | ok |
| PaywallSimulator | 97.9% | 90.9% | ok |
| PaywallKit | 80.3% | 75.9% | **fails**: `StoreKit2Client.swift` (163 lines) runs only under SKTestSession. The rest of the target is at about 98%. |
| PaywallCloudSync | 55.9% | 57.9% | **fails**: `CloudKitDatabase.swift` (73 lines) needs a CloudKit container. The rest is covered by the in-memory fake. |

The design allows no exclusions. StoreKit2Client is meant to be exercised by SKTestSession in an
Xcode-hosted test lane, and CloudKitDatabase by the live CloudKit test behind an environment flag. Neither
lane can run under plain `swift test`, so neither exists yet. When they land, pass their xccov reports to the
gate with `--xccov`.

## Not in this package

- **Routing**: the `ZRouteGate` hook belongs in `ztron-routing-kit`.
- **Adoption**: integrating the package into the host app.
- **Hosted lanes**: `StoreKitIntegrationTests` (SKTestSession: refunds, Ask to Buy, renewals at accelerated
  time), `UIKitBoundaryTests` for `PaywallHostingController` on the iOS 15 and iOS 17 simulators, the
  xcodebuild coverage lane, and the 25 ms draw performance test on a device. These need an app host and a
  `.storekit` configuration file.
- **The host half of the App Review table**: the paywall screen (restore button, links, disclosures, retry
  when products fail, hiding Buy for the current tier), the gated routes, the archive check over the `.ipa`,
  and `Scripts/presubmit.sh`.
- **Open design decisions**: promoted in-app purchases (a PurchaseIntent listener), Family Sharing for
  tokens, macOS scope, and a runtime refusal of the simulator in non-debug processes.
- **Receipt signature verification**: `ReceiptClient` fails closed (no grandfathering on iOS 15) until a
  `ReceiptVerifier` is supplied.
