# ZTronPaywallKit

A freemium paywall for iOS apps, as a Swift package: gates in code and in SwiftUI, a token wallet, subscriptions and a
lifetime purchase through StoreKit 2, grandfathering for the installs that paid up front, promotional offers signed by
a server you deploy, optional cross-device sync, a simulator for debug builds and fakes for tests. This page is the
outside view: what the package promises, how to adopt it, what it exposes, what can go wrong. How it works inside is
in [HANDBOOK.md](HANDBOOK.md).

## Intent

An app that was paid up front and is going freemium needs four things at once: a way to keep paying customers whole
(App Review 3.1.2(a)), gates that cannot leak value (a feature delivered without a payment, or a token spent twice),
a store layer that treats StoreKit 2 as the only authority on who paid, and enough evidence to settle a dispute.
ZTronPaywallKit is that, and only that. It draws no paywall screen, holds no product copy and makes no routing
decision; those stay in the app, which calls one facade.

What it guarantees:

- **StoreKit 2 decides entitlements.** They are re-resolved on launch, on foreground and on every transaction update,
  from verified transactions. Nothing in the package can grant a subscription or a lifetime unlock on its own.
- **Value is never delivered without a durable debit.** A token gate writes the debit to disk before the gated code
  runs; a crash at any step leaves the ledger consistent at the next launch, and a gated body that throws gets its
  draw reversed. The guarantee is one device's: with a sync carrier each device spends against the balance it last
  pulled, so the devices of one account can spend the same tokens offline or between pulls; the merge keeps every
  debit and the balance goes negative until repaid (see Known defects and limitations).
- **Every decision is on the record.** Each gate decision, purchase, restore and entitlement change is published once
  as an event and written to a hash-chained audit log that can be checked for corruption and exported. It is evidence
  for a support case, not proof against whoever controls the device (see HANDBOOK.md, "Audit").
- **Nothing secret ships in the app.** Promotional offers are signed by a server (a Cloudflare Worker in this
  repository) that holds the In-App Purchase key; the app holds only its URL. See [Secrets](#secrets).
- **Debug tooling compiles to nothing in release.** Presets, launch arguments, overrides and the fakes live in two
  modules that are empty in release builds, and a script fails the release build if a shipping module's symbols name
  any of it, or if either module defines a Swift symbol.

Platforms: iOS 15 and later, Swift 6 language mode, SwiftUI first with one UIKit bridge. macOS only builds and runs the
unit tests; Linux builds the engine and the fakes. Products and the modules they import:

| Product | `import` | What it is |
|---|---|---|
| `ZTronPaywallKit` | `PaywallKit` (+ `PaywallCore`) | The app-facing package: facade, gates, signals, StoreKit 2, receipts. |
| `ZTronPaywallCore` | `PaywallCore` | The engine without UI or StoreKit, for apps that bring their own store client. |
| `ZTronPaywallCloudSync` | `PaywallCloudSync` | Token ledger sync through CloudKit, with a Keychain snapshot for reinstalls. |
| `ZTronPaywallSimulator` | `PaywallSimulator` | Debug builds only: presets, launch arguments, preview support. |
| `ZTronPaywallTesting` | `PaywallTesting` | Fakes for the store, the clock, the network, the signer and the cloud. |

## Adoption

```swift
// Package.swift
.package(url: "https://github.com/<owner>/ZTronPaywallKit.git", branch: "main"),   // pin a tag once released
// target dependencies
.product(name: "ZTronPaywallKit", package: "ZTronPaywallKit"),
.product(name: "ZTronPaywallCloudSync", package: "ZTronPaywallKit"),               // optional
```

```swift
import PaywallCore
import PaywallKit
import SwiftUI

@main
struct MyApp: App {
    static var configuration: Paywall.Configuration {
        let catalog = ProductCatalog(
            subscriptionGroupID: "21000000",                                  // the group id as App Store Connect shows it
            weekly: "pro.weekly", monthly: "pro.monthly", yearly: "pro.yearly",
            lifetime: "pro.lifetime",
            tokenPacks: [TokenPack(productID: "tokens.10", tokens: 10)])
        var configuration = Paywall.Configuration(catalog: catalog)
        configuration.grandfathering = GrandfatheringPolicy(                    // installs that paid up front keep access
            lastPaidBuild: "116", paidWindow: DateInterval(start: launchDate, end: freemiumDate))
        configuration.sync = PaywallCloudSync()                                 // optional: tokens follow the account
        configuration.promotionalOfferSigner = RemotePromotionalOfferSigner(   // optional: promotional offers
            endpoint: URL(string: "https://<your signer>/v1/promotional-offers/sign")!)
        return configuration
    }

    @StateObject private var paywall = PaywallServiceProvider(.production(Self.configuration))

    var body: some Scene {
        WindowGroup {
            RootView()
                .paywallSheet { failure in PaywallScreen(failure) }   // your screen, shown when a gate closes
                .paywallProvider(paywall)
        }
    }
}

// Gate code: `.blocked` is a value, not an error. Tokens are drawn before `export()` runs.
let outcome = withPaywall(.tokens(1), id: "export") { export() }

// Gate a view: shows nothing (or `denied`) until the user is entitled.
PremiumChart().paywallGated(.paid)

// Buy from the paywall screen; the entitlement and the wallet update on their own.
try await Paywall.shared.purchase(product, source: failure.source)
    .onPurchaseCompleted { _ in dismiss() }
    .onPurchasePending { dismiss() }
    .onPurchaseCancelled { }
```

Two things the app must do: set `SKIncludeConsumableInAppPurchaseHistory` in `Info.plist` (without it a refunded
token pack disappears from StoreKit's history instead of being revoked), and keep a `.storekit` configuration and the
App Store Connect products in step with the catalog; `ProductCatalog.mismatches(withStoreKitConfiguration:)` reports
drift in a test. Builds that ship before the freemium launch set `configuration.passthrough = true`: every gate
passes and nothing starts.

## Public API

Each row names the entry point, what it does, and what must come before or after it. Types without a module note
come with `ZTronPaywallKit`; the value types they take and return are declared in `PaywallCore`.

### Configuring

| API | What it does | Before / after |
|---|---|---|
| `ProductCatalog`, `TokenPack` | Declares the products: a subscription group with its weekly, monthly and yearly tiers, a lifetime purchase, token packs. The authority on what each product is. | First. `Paywall.Configuration` takes it; `mismatches(withStoreKitConfiguration:)` checks it against a `.storekit` file in a test. |
| `Paywall.Configuration` | Everything the paywall runs on: the catalog, `grandfathering`, `familySharing`, `welcomeTokens`, `tolerance`, `leasePolicy`, `audit` sinks, `sync`, `promotionalOfferSigner`, `connectivity`, `clock`, `store`, `storageDirectory`, `passthrough`, `onStart`. | Built from a catalog, then handed to `PaywallServiceProvider` or `Paywall.configure`. |
| `GrandfatheringPolicy` | Which installs keep what they paid for: the last paid build and the paid window, with sentinels for the odd cases. | Set on the configuration before configuring; applied at every resolution. |
| `FamilySharingPolicy` | `.sharedEntitlements` (a family member's purchase counts) or `.purchaserOnly`. Tokens never cross members. | Set on the configuration; a change takes effect at the next launch. |
| `PaywallServiceProvider` | The one object the app root holds. Runs the production implementation or a fake (`.production(_:)`, `.fake(_:)`), switches at runtime (`useProduction`, `useFake`, `use`), reports `isFake`. | Create as a `@StateObject` at the root; it configures `Paywall.shared` at once. Install with `.paywallProvider(_:)`. |
| `.paywallProvider(_:)` | View modifier: puts the provider and the facade in the environment, keeps `\.paywallEntitlement` current, re-resolves when the scene becomes active. | On the root view, after `.paywallSheet`. Replaces `.paywallLifecycle()`. |
| `Paywall.configure(_:)`, `waitUntilStarted()` | Manual setup without a provider. Validates the catalog and opens the ledger synchronously, so the wallet is known before the first frame. | Once at launch, before any gate. `waitUntilStarted` before reading store-derived state in tests. |
| `Paywall.Configuration.grandfatherOverride` | Debug builds only: pretend the install bought a given version on a given date, to test the grandfather branch on a device. | Compiled out of release. |

### Reading state

| API | What it does | Before / after |
|---|---|---|
| `Paywall.shared` | The facade, an `ObservableObject`: `entitlement`, `wallet`, `tier`, `storefront`, `pendingFailure`, `pendingPurchaseIntent`, `configurationError`, `isPassthrough`. | After configuring. Read from views as `@EnvironmentObject var paywall: Paywall`. |
| `Entitlement`, `Subscription`, `LifetimeSource` | What StoreKit says the account has: `.unknown`, `.free`, `.subscribed(…)`, `.lifetime(…)` with a `LifetimeSource` of `.purchase`, `.familyShared` or `.grandfathered`. | Published by the facade; never set by the app. |
| `AccessTier`, `SubscriptionTier` | One comparable scale, `.free < .freeTrial < .tokens < .weekly < .monthly < .yearly < .lifetime < .grandfathered`, for "what ranks above the current one". | Derived from the entitlement and the wallet. |
| `Wallet` | Tokens as views see them: `balance`, `reserved`, `available`. | Published by the facade. |
| `Paywall.canPass(_:id:)`, `evaluate(…)` | Answers whether a gate would open now, without drawing. | For disabled buttons and badges; a real draw still goes through `withPaywall`. |
| `Paywall.events`, `eventStream` | Every decision, once: a Combine publisher and an `AsyncStream` of `PaywallEvent`. | Subscribe after configuring. |
| `PaywallEvent`, `GateDecision`, `PurchaseStage`, `RestoreStage` | The event vocabulary: gate decisions, purchase and restore stages, entitlement changes, sync, storefront changes, promotional offer signatures. | What `events`, the audit log and the notifications carry. |
| `Paywall.subscriptionPhase()`, `isEligibleForIntroOffer()` | The renewal state (active, grace period, billing retry, expired) and introductory offer eligibility, from StoreKit. | For the account screen; `Subscription.willAutoRenew` alone is not the renewal preference. |

### Gating

| API | What it does | Before / after |
|---|---|---|
| `GateLevel` | What a gate asks: `.free`, `.paid`, `.tokens(n)`. | The first argument of every gate. |
| `withPaywall(_:id:_:)` (sync and async) | Runs a body behind a gate. Draws the tokens durably before the body, refunds them if the body throws, publishes a `PaywallFailure` when closed. Returns `PaywallOutcome`, whose `.blocked` is a value; `.get()` for the throwing style. | After configuring. Pair with `.paywallSheet` so a denial shows the screen. |
| `.paywallGated(_:policy:id:)`, `.paywallGated(_:denied:)` | Gates a view. `policy: .reserve` (default) holds the tokens and spends only when something inside commits; `.deductNow` draws on appear. A refund or expiry while on screen flips the view live. Once the view holds a lease (its first draw or commit, or a live lease found on appear) it pins it while on screen: commits and any `withPaywall` with that id, at any `n`, open `.leased` without drawing, and `tolerance` counts from when the view leaves. A view gate costs `n` per visit; per-use pricing needs a plain `withPaywall` with its own id. | Under `.paywallProvider`. Pass a stable `id` when the lease must survive a view rebuild. |
| `\.paywallGate`, `GateSession.withPaywall` | Inside gated content: the gate the view lives behind, so a button commits the reservation it holds. | Only inside `.paywallGated` content. |
| `TokenPolicy`, `LeasePolicy` | How a view gate spends, and whether a lease is fixed from the draw or refreshed on re-entry. | `LeasePolicy` is a configuration value; `TokenPolicy` a per-view argument. |
| `PaywallOutcome`, `PaywallFailure`, `PaywallSource` | What a gate returns, why it closed (`reason`, the level, the wallet at the time) and where it lives (`id`, file, function, line). | `PaywallFailure.source` goes back into `purchase(_:source:)` so the audit links the buy to the gate. |
| `Paywall.grant(tokens:reason:id:)` | Credits tokens outside a purchase (a promotion, a support gesture). Idempotent by `id`. | After configuring. Lands in the ledger and syncs like a purchase. |

### Showing the paywall

| API | What it does | Before / after |
|---|---|---|
| `.paywallSheet { failure in … }` | Presents your screen whenever a gate under it closes, with the `PaywallFailure`. The nearest sheet takes the denial. | On the root, and on any presented sheet that contains gates. |
| `.paywallScope(_:)`, `.onPaywallFailure(…)`, `Paywall.failures(scope:id:)` | Route denials: a scope names which sheet handles them; the handlers and the publisher deliver them to code. | Alternatives to the default sheet. |
| `.onPurchaseIntent(perform:)`, `Paywall.purchaseIntents`, `consumePendingPurchaseIntent()` | A promoted in-app purchase tapped in the App Store arrives as a product id; show its screen. | Starting the purchase clears the intent. |
| `PaywallDisclosure(product:whatYouGet:termsURL:privacyURL:)` | The pre-purchase disclosure guideline 3.1.2(c) requires, as one value: price, period, trial, renewal, cancellation, links; `isComplete` says it is. | Build it from the `PaywallProduct` the screen offers, before the Buy button renders. |
| `.paywallLifecycle()`, `consumePendingFailure()`, `Paywall.bridgeToNotificationCenter(_:)`, `Notification.Name.paywall…` | For apps not using the provider or SwiftUI: lifecycle hooks, one-shot reads and `NotificationCenter` posts (`paywallDenied`, `paywallEntitlementChanged`, `paywallPurchaseCompleted`, …) with `PaywallNotificationKey` payloads. | Optional. |
| `PaywallHostingController` | The UIKit bridge: hosts SwiftUI content with the facade and provider re-injected; `paywallFailures(…)` and `presentPaywall(for:screen:)` for UIKit-driven presentation. | For UIKit containers and navigation stacks. |

### Store

| API | What it does | Before / after |
|---|---|---|
| `Paywall.products()`, `refreshStorefront()`, `PaywallStorefront`, `PaywallProduct` | The catalog as the App Store sells it: prices, periods, offers and eligibility per product. Offline, the last storefront, marked not purchasable. | After configuring; refreshed hourly, on restore, and on demand. Feeds the screen. |
| `Paywall.purchase(_:source:)` → `PurchaseOutcome` | Buys a product. Pack credits land in the ledger before the transaction is finished; the entitlement updates itself. Handlers chain: `onPurchaseCompleted`, `onPurchasePending` (Ask to Buy, and a pack whose credit could not be written: the transaction stays unfinished and is credited when the write lands, later in the session or at the next launch), `onPurchaseCancelled`. Store errors are thrown. | From the screen, with the failure's `source`. A purchase does not re-run the gate it was bought for. |
| `Paywall.purchase(_:promotionalOffer:source:)`, `PaywallProduct.Offer` | Buys a subscription with a promotional offer: asks the configured signer for this install's signature, then buys with it. | Needs `configuration.promotionalOfferSigner` and a deployed signer. The offer comes from `PaywallProduct.offers` with kind `.promotional`; introductory offers need nothing. |
| `RemotePromotionalOfferSigner(endpoint:transport:timeout:)`, `HTTPTransport`, `URLSessionTransport` | The client of the signing worker: posts bundle, product, offer and app transaction id, returns the signed offer within a total deadline (`timeout`, 15 s by default). | Deploy `Workers/PromotionalOfferSigner` first; set the client on the configuration. |
| `Paywall.restorePurchases()` | The Restore button: syncs with the App Store and re-resolves. The only call that triggers `AppStore.sync()`. | From the screen's Restore button, never automatically. |
| `Paywall.refresh()`, `didBecomeActive()`, `syncNow()` | Re-resolve now; what the provider does on foreground; push and pull the ledger now. | Usually not needed with the provider installed. |
| `StoreKit2Client`, `NetworkPathConnectivity`, `ReceiptClient`, `AppleReceiptVerifier` | The production adapters behind the defaults: StoreKit 2, `NWPathMonitor`, and the on-device receipt path (iOS 15, and iOS 16 and later only when `AppTransaction.shared` throws), which admits a receipt only for the device it was issued to. | Replace through `configuration.store` and `.connectivity` only to substitute them. |

### Audit

| API | What it does | Before / after |
|---|---|---|
| `PaywallAuditSink`, `AuditRecord`, `ClosureSink`, `JournalSink`, `OSLogSink` | Where the audit goes: your closure (analytics), a rotating JSON-lines file in the paywall directory, the unified log (subsystem `ztron.paywall`). The file and the log are on by default. | Add sinks to `configuration.audit`; `includesDefaultAudit = false` drops the defaults. |
| `Paywall.verifyAuditChain()`, `exportAudit()` | Checks the hash chains of the audit log and the ledger, and writes an export for support or a dispute: hash-chained evidence, not proof against the device's owner. | Any time after configuring. |

### Cross-device sync (`ZTronPaywallCloudSync`)

| API | What it does | Before / after |
|---|---|---|
| `PaywallCloudSync(containerIdentifier:keychain:)` | The recommended carrier: ledger events in the CloudKit private database, merged as a set (the pull position lives in the engine's journal, written with the events it covers), plus a Keychain wallet snapshot so a reinstall shows the balance before the first sync and keeps it, launch after launch, until the account's history arrives. Each device spends against the balance it last pulled: hourly, or when a purchase, a restore or a forwarded silent push requests a pull. | Set as `configuration.sync` before configuring. Needs the iCloud capability with CloudKit and a container. |
| `KeychainWalletSnapshotStore(service:account:synchronizable:)` | The snapshot store on its own, if the Keychain item needs another name. Per device by default (`synchronizable: false`); an item an earlier build wrote as synchronizable is still read when no local one exists. | Passed to `PaywallCloudSync`. |
| `LedgerSync`, `CloudDatabase`, `CloudKitDatabase`, `InMemoryCloudDatabase` | The seams: write your own carrier, or run the real merge logic against an in-memory cloud in tests. | Optional. |

### Simulator (`ZTronPaywallSimulator`, debug builds only)

| API | What it does | Before / after |
|---|---|---|
| `PaywallServiceProvider.Service.simulated(_:catalog:)`, `.fromLaunchArguments(production:)`, `provider.useSimulated(…)` | Run the production engine on a simulated store, picked in code, from a debug menu, or by `-paywall.*` launch arguments in UI tests. | Instead of `.production`. Compiles to nothing in release. |
| `PaywallPreset`, `PaywallSimulation` | Named states (`free`, `trial`, `weekly`, `monthly`, `yearly`, `lifetime`, `grandfathered`, `tokens5`, `broke`, `offline`, `storeDown`) and every switch behind them. | Applied through the provider or `PaywallSimulator.shared.apply`. |
| `PaywallSimulator.shared` | Drives the fake live: `refund`, `renew`, `expire`, `enterGracePeriod`, `enterBillingRetry`, `purchaseTokenPack`, `grantTokens`, `advance(by:)`, `reset`, `settle`. | While a simulated service is in use. |
| `.paywallSimulation(_:catalog:)`, `PaywallLaunchArguments` | Previews on a simulated paywall; the parsed launch arguments with their problems. | Previews and UI tests. |

### Fakes (`ZTronPaywallTesting`)

| API | What it does | Before / after |
|---|---|---|
| `FakeStore`, `FakeClock`, `FakeConnectivity`, `FakePromotionalOfferSigner` | Scriptable stand-ins for the store (entitlements, purchase outcomes, refunds), the clock, the network path and the signer. | Plug into `Paywall.Configuration` (`store`, `clock`, `connectivity`, `promotionalOfferSigner`) in tests. |
| `InMemoryAuditSink`, `InMemoryCloud`, `InMemoryLedgerSync`, `EntitlementTimeline` | Collect audit records; several carriers on one in-memory cloud converge like devices on one account; a scripted entitlement over time. | `audit` and `sync` on the configuration. |

### Engine (`ZTronPaywallCore`, without UI or StoreKit)

| API | What it does | Before / after |
|---|---|---|
| `GateEngine`, `GateEngine.Settings` | The engine the facade drives: `begin`/`complete`/`abort` or `run` for a gate, `refresh`, `purchase`, `restore`, `handle(_:)` for a transaction, `merge(_:)` for synced events. | For apps that bring their own `StoreClient`. The facade is the supported path on iOS. |
| `StoreClient`, `StoreTransaction`, `AppTransactionSnapshot`, `PaywallClock`, `PaywallConnectivity`, `PromotionalOfferSigner` | The seams an engine runs on. `PromotionalOfferSigner` is also the hook for a client that attaches App Attest assertions. | Implement to substitute; the kit provides the production ones. |
| `Ledger`, `LedgerEvent`, `Journal`, `EntitlementResolver`, `CreditReconciler`, `LeaseTable`, `ReservationTable`, `SHA256Digest`, `CRC32`, … | Public so the package's own modules and tests can reach them. Not an integration surface; they can change between minor versions. | Avoid. |

### Companion: the signing worker

`Workers/PromotionalOfferSigner` is a Cloudflare Worker (TypeScript, wrangler). `POST /v1/promotional-offers/sign`
takes `{bundleId, productId, offerId, transactionId?}` and answers `{compactJWS, …}`; `GET /v1/keys` serves the
public key as a JWKS; `GET /v1/health` answers `{"ok": true}`. Its secrets are `APPLE_IAP_PRIVATE_KEY`,
`APPLE_IAP_KEY_ID`, `APPLE_IAP_ISSUER_ID`, `APPLE_BUNDLE_IDS` and the optional `ALLOWED_OFFERS`, set with
`wrangler secret put`. Deploy it, then point `RemotePromotionalOfferSigner` at its URL. Details in
[its README](Workers/PromotionalOfferSigner/README.md).

## Risks assessment

| Risk | What the package does | What stays with the app |
|---|---|---|
| **App Review 3.1.1: unlocking without an in-app purchase.** | StoreKit 2 is the only source of entitlements; no code path grants one. Debug overrides, the simulator and the fakes compile to nothing in release, and `Scripts/check-release-symbols.sh` fails the release build if a shipping module's demangled symbols name any of it, or if `PaywallSimulator` or `PaywallTesting` defines a Swift symbol; it checks every module the platform builds and fails by name on one it cannot. | Keep an archive check of your own in the pipeline (a stripped binary keeps few symbols, so this script's patterns do not transfer to an `.ipa`); never ship a build with `passthrough` on past the freemium launch. |
| **App Review 3.1.2: subscription disclosures, grandfathering, family sharing.** | `PaywallDisclosure` gathers what 3.1.2(c) requires; `GrandfatheringPolicy` and `FamilySharingPolicy` are applied at every resolution; tests map rejection causes to behaviour. | The screen: showing the disclosure, a Restore button, terms and privacy links, hiding Buy for the current tier. |
| **Value leaks or double spends around crashes.** | The debit is durable before the gated code runs; a crash at any step is recovered at the next launch; a throwing body refunds its draw. | Gate the paid value itself (`.reserve` content is a shell until something inside commits). |
| **The signing endpoint is public.** Anyone can obtain an offer signature for an allowed app. | The App Store applies its own eligibility rules on top; the worker signs only configured bundle ids and, with `ALLOWED_OFFERS`, only listed offers. Nothing bounds the volume by default: an optional `RATE_LIMITER` binding answers 429 per client IP, and a WAF rule on a custom domain stops excess before the Worker (worker README, "Security model"). On Workers Free a flood exhausts the account-wide daily quota. | Who is shown an offer is the app's decision. App Attest in front of the worker if that decision must hold against a tampered client. |
| **The signer is down or slow.** | The purchase with an offer fails before the payment sheet, with the signer's error, after the usual `.purchase(stage: .failed)` event; plain purchases are unaffected; the request has a 15-second total deadline (`RemotePromotionalOfferSigner.timeout`), not an idle timer. | Offer the regular price when the offer purchase fails. |
| **The In-App Purchase key is compromised or rotated.** | The key exists as a Worker secret, imported non-extractable, and in the `.p8` downloaded once from App Store Connect, which stays out of the repository (or is deleted after `wrangler secret put`); nothing in the app changes with the key. | Revoke in App Store Connect, `wrangler secret put` the new key and id. |
| **Device clock manipulation.** | Entitlements come from StoreKit's signed transactions, but whether they have expired is judged by the device clock: the resolver, the launch snapshot and the expiry timer. A clock set forward shows a subscriber as free; one set back keeps a lapsed cached subscription until the launch resolution. Audit records carry uptime to expose clock changes. Token leases outlive their draw by `tolerance` (300 s by default), bounding what a moved clock buys. | Choose `tolerance` and `leasePolicy` for your gates. |
| **Offline.** | Entitlements resolve from StoreKit's on-device cache; `products()` returns the last storefront, not purchasable; token gates keep working on the local ledger; synced events queue and drain when a path returns. | Nothing; show the storefront's `priceAsOf` when prices are stale. |
| **Reinstall and account changes.** | With `ZTronPaywallCloudSync`, the balance survives a delete-and-reinstall through the Keychain snapshot (per device, adopted into the journal and kept across launches until the account's history arrives) and the cloud; without a carrier the package has no memory beyond StoreKit, so a reinstall grants welcome tokens again. | Decide whether tokens are worth a CloudKit container. |
| **Refunds and revocations.** | A refunded pack is revoked and its credit reversed; a refunded subscription or a family removal ends the entitlement at the next resolution; the audit links each reversal to what it reverses. | `SKIncludeConsumableInAppPurchaseHistory` in `Info.plist`, or refunded packs vanish from history instead. |
| **StoreKit Testing is not the App Store.** | The test host runs the real StoreKit client against a `.storekit` configuration, including a promotional offer purchase. | Verify in the sandbox before release; eligibility and renewal timing differ. |
| **Platform scope.** | iOS 15+. macOS is a test host only; Linux builds the engine and fakes only. | Do not ship the package on macOS. |

## Known defects and limitations

The 2026-11-17 review (`Reviews/2026-11-17-skeptical-review.md`) confirmed 25 findings; every one was fixed, with a
regression test, in the cycle recorded in `Reviews/2026-11-19-fix-plan.md`. What is open or accepted:

- **Multi-device overspend** (accepted). Each device spends against the balance it last pulled; offline, or between
  pulls, the devices of one account can spend the same tokens. The merge keeps every debit, the balance goes
  negative and token gates stay closed until it is repaid. Show `available`, not `balance`.
- **Expiry is judged by the device clock** (accepted). StoreKit's transactions are the only source of entitlements,
  but a forward clock shows a subscriber as free and a backward clock keeps a lapsed cached subscription until the
  launch resolution.
- **The audit chain is evidence, not proof.** Unkeyed and anchored on the device, it detects corruption and partial
  edits, not a rewrite by whoever controls the container. Forward records to a server when evidence must hold against
  the user.
- **The outbox of a device with no iCloud account grows on disk.** `ledger.log` stays bounded (the covered events
  wait in `outbox.log`, which no launch decodes), but nothing acknowledges them until the user signs in.
- **The signer has no volume bound of its own.** The optional `RATE_LIMITER` binding and a WAF rule are the bounds;
  throttled requests still count toward a Workers Free quota.
- **Volume Purchase installs are not grandfathered.** The VPP receipts examined so far carry no original version or
  purchase date and fail closed; `AppTransaction` reportedly does not serve them either.
- **The receipt path needs a device identifier.** A receipt is admitted only for the device it was issued to
  (`identifierForVendor`); where there is none (macOS, iOS before first unlock) it answers nothing and the cached
  snapshot stands, so the receipt path never grandfathers a Mac.
- **Win-back offers** are modelled in the storefront for display, but no `purchase` call redeems one: the iOS 18
  purchase option is not passed yet.
- **The 25 ms draw bound** is measured on macOS and on the iOS Simulator, not on a device.
- **iOS 15 and 16**: `NWPathMonitor` can only report on a dispatch queue there, which the package does not use, so the
  sync outbox drains on launch, foreground, purchase and a 30-second timer rather than the moment a path returns.
- **`Subscription.willAutoRenew`** is `true` from a transaction, because StoreKit does not put the renewal preference on
  it; read `subscriptionPhase()` for the real state.
- **Live-only coverage**: the CloudKit forwarders and container initialisers, and the network path of
  `URLSessionTransport`, run only in the local live lanes, not in CI.
- **StoreKit Testing and promotional offers**: the local store server accepts an offer only when the `.storekit` file
  carries a `subscriptionOffersKeyPair` at its top level with a base64 PKCS#8 P-256 key; without it the purchase fails
  with `StoreKitError.unknown`. The package's fixture ships such a key.
- **iOS 27 simulator runtimes** (Xcode 27, November 2026): the test host's StoreKit lane can stall on an App Store
  sign-in sheet; it runs clean on an iOS 26 runtime.

## Secrets

Nothing identifying the publisher or its apps is in this repository, ever: no In-App Purchase key, key id or issuer id,
no App Store receipt, no team id, no production bundle id or app name. Where tests or tools need a secret, it is
simulated:

- The `.storekit` fixture's `subscriptionOffersKeyPair` is a throwaway P-256 key generated for StoreKit Testing.
- The worker's tests generate a fresh key per test, and `.dev.vars` for local runs (gitignored) is written from the
  fixture's key by `Scripts/worker-dev-vars.sh`.
- Receipt fixtures are signed by a throwaway certificate chain from `Scripts/make-receipt-fixtures.sh`; the lane that
  checks a real receipt reads it from a path outside the repository and is skipped without one.
- `*.p8` is gitignored at the root and in the worker.

The private key lives in the Worker's secrets and in the `.p8` downloaded once from App Store Connect; keep that file
out of the repository, or delete it after `wrangler secret put`. The key id and issuer id are not secret: every signature
carries them, the worker returns the key id and serves it at `/v1/keys`. They stay out of this repository because they
identify the publisher. The real receipt for the production-receipt lane stays outside the repository. CI runs entirely
on the simulated values, and its `forbidden-constructs` job fails on any tracked `.p8` or PEM key material.

## More

- [HANDBOOK.md](HANDBOOK.md): the full account of policies, signals, the store, crash safety, retention, sync, the
  simulator, App Review mapping, and how to run every test lane.
- [Workers/PromotionalOfferSigner/README.md](Workers/PromotionalOfferSigner/README.md): the signer's API, secrets,
  deployment and security model.
