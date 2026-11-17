# Skeptical review 1: ZTronPaywallKit at `b5c20e4`

**Status.** Open. Written on 2026-11-17 as input for the next fix cycle; none of it is fixed yet.\
**Scope.** The whole repository at commit `b5c20e4` (`main`, clean tree): the Swift package, the TestHost project, the promotional-offer signing worker, the scripts, CI and the docs.\
**Result.** 25 verified findings (1 critical, 3 high, 10 medium, 11 low). 12 hold as reported; 13 hold in a narrower form than first reported. None was refuted. There are also ten docs-vs-code corrections (D1 to D10) and one operational item (O1).\
**Sensitivity.** Several findings describe weaknesses someone could exploit (A1's token reset, B1, A11+B6, B3, B4, B5). Keep this file out of the public repository until they are fixed or accepted.

## How to use this file

You are probably an agent starting a fix cycle. Read this section, the summary (§1) and the fix plan (§2). Then work through §3 one finding at a time.

- **Each entry stands alone.** It gives:
  - the code locations at `b5c20e4`
  - the defect and a concrete failure scenario
  - the evidence
  - a fix direction
  - the regression test that proves the fix
  - the findings it interacts with
  - what verification could and could not settle

  Line numbers are at `b5c20e4`, so re-locate them if the tree has moved since.
- **Reproduce before you fix.** Reviewer A's probes (Appendix A) and the verifiers' reproductions (Appendix B) fail today, and each probe's `#expect` states the correct behaviour. Copy one into its test target, watch it fail, then turn it into the regression test the entry names. Never commit the probes as they are.
- **Treat the fix direction as guidance, not a patch.** The verifiers corrected several of the reviewers' proposals, and each entry carries the corrected version. For example, A8's "close the old engine's sessions in teardown" is unsafe. Where an entry leaves a product decision to the owner (for example D4's per-visit pricing), ask the owner.
- **Follow the fix groups in §2.** Several findings share a root cause or edit the same lines, so fixing one alone can make another worse. For example, guarding `appendLedger` after shutdown (A5) without A2's finish gate turns a late credit into a purchase that is finished but never credited.
- **These repository rules apply to every fix:**
  - Nothing that identifies the host app or the publisher goes into code, tests, fixtures, docs or commit messages: no app name, bundle id, team id, key id, issuer id, workers.dev subdomain or real receipt. Write "the host app".
  - Tests that configure `Paywall.shared` belong in the serialized "Simulator" suite in `Tests/PaywallSimulatorTests/SimulatorTests.swift`. Other PaywallKitTests build isolated facades with `Paywall()` and `Paywall.$override`.
  - The test bundles compile for macOS 14 under `-warnings-as-errors`. In tests, use the macOS 14 API forms (for example the two-parameter `onChange`) and mark them `@available(macOS 14, *)`, not with a runtime `#available` check.
  - The coverage gate ratchets (`Scripts/coverage-gate.sh` against `coverage-baseline.json`), so every new branch needs a test. Before you call a group done, run the lanes described in HANDBOOK.md › Development. Never write the baseline from a partial or failed run.
  - Some entries end with facts that only a device, the sandbox or a service can settle (§7). Don't mark those parts done on the strength of a macOS run.
- **Keep this file current.** Update the Status column in §1 to `fixed in <commit>`, `accepted: <reason>` or `won't fix: <reason>`. When a fix changes what README's "Known defects and limitations" should say, update that list too (D10).

## 1. Summary

Sorted by verified severity. "Narrower" means the defect is real, but its trigger or impact is smaller than the reviewer first reported; the entry says exactly how. The Group column refers to §2.

| ID | Severity | Verdict | Area | Finding | Group | Status |
|---|---|---|---|---|---|---|
| [A1](#a1) | critical | confirmed | Sync, reinstall | After a delete-and-reinstall, the Keychain snapshot's balance lasts only one launch when the carrier lacks the old history. The next launch drops it and writes `grant:welcome` again | G1 | open |
| [A2](#a2) | high | confirmed | Store, credits | A pack credit whose journal write fails is still finished and reported as purchased, so the paid tokens are lost for good | G2 | open |
| [A3](#a3) | high | confirmed | Entitlements | Subscribers in a billing grace period resolve to .free, because the resolver drops the lapsed auto-renewable that currentEntitlements still lists | G3 | open |
| [A6](#a6) | high | confirmed | Sync | CloudKit change token is committed before pulled events are durable: a failed merge or a mid-pull shutdown loses them for that install, and the baseline and welcome grant still settle | G1 | open |
| [A4](#a4) | medium | narrower | Entitlements | Overlapping refreshes apply in the order they finish, so a stalled older resolution can undo a subscription just bought (or a refund) until the next resolution | G3 | open |
| [A5](#a5) | medium | narrower | Engine lifecycle | After a same-directory reconfigure, a shut-down engine still credits, journals and finishes work already in flight. The bought tokens stay hidden until relaunch, both chains fork, and the credit is lost if the successor compacted. | G2 | open |
| [A7](#a7) | medium | confirmed | Journal, sync | A dropped or truncated ledger.log is never refilled from CloudKit: PaywallCloudSync's change token outlives the drop, so the recovery HANDBOOK promises does not happen | G1 | open |
| [A8](#a8) | medium | confirmed | Facade, views | Reconfiguring the facade (provider use*, a passthrough flip, simulator reset) orphans .paywallGated views on screen: they keep their old decision until they disappear | G2 | open |
| [A9](#a9) | medium | confirmed | Journal, sync | With the CloudKit carrier set and no iCloud account, every checkpoint keeps the whole unacknowledged history, so ledger.log and the main-actor decode at launch grow without bound | G1 | open |
| [A11+B6](#a11b6) | medium | narrower | Receipts, grandfathering | ReceiptClient never checks the field-5 device hash, so a planted stranger's paid-era receipt grandfathers the install (lasting on iOS 15, temporary on iOS 16+); the reason HANDBOOK.md:396-397 gives for skipping the check is wrong | G4 | open |
| [B1](#b1) | medium | narrower | Grandfathering, caches | Unauthenticated app-transaction.json and entitlement.json are trusted as store answers: anyone who can write the container gets a grandfathered lifetime unlock while StoreKit yields no app transaction | G4 | open |
| [B3](#b3) | medium | narrower | Release hygiene | check-release-symbols.sh passes a non-empty release PaywallSimulator made of plain extension members, misses word-substituted Paywall* function names, and skips missing objects silently | G5 | open |
| [B4](#b4) | medium | confirmed | Release hygiene | ZTronPaywallSimulator links PaywallTesting's fakes into every Release app that uses it, and the release symbol gate never scans PaywallTesting | G5 | open |
| [B5](#b5) | medium | narrower | Signer worker | The signing worker has no volume limit on its documented workers.dev deployment, but README.md:225 and the worker README say Cloudflare rate limiting bounds it | G6 | open |
| [A10](#a10) | low | confirmed | Entitlements | Paid introductory offers (pay as you go, pay up front) resolve as a free trial: Subscription.isTrial is true and the tier is .freeTrial | G3 | open |
| [A12](#a12) | low | narrower | Launch cost | Every launch decodes the whole retained audit (up to 50 MB) before start() starts the StoreKit listeners and its own launch resolution | G2 | open |
| [B2](#b2) | low | narrower | Receipts, grandfathering | ProductionVPP receipts are labelled .xcode, but this is latent: the VPP receipts seen so far lack fields 18/19 and fail closed before the switch | G4 | open |
| [B7](#b7) | low | narrower | CI, coverage gate | Coverage gate fails open for a target with no coverage data when --targets is absent, and --write-baseline replaces the baseline with the measured subset | G8 | open |
| [B8](#b8) | low | narrower | Offers (app) | A promotional-offer signature mismatch writes the unredeemed JWS to audit.jsonl, the export zip and host-wired sinks (OSLog redacts it). Only a non-echoing custom signer can trigger it. | G7 | open |
| [B9](#b9) | low | confirmed | Receipts, parsing | ASN1.parseNode has no depth bound and copies every subtree, so a crafted ~8 KB receipt crashes the receipt path before verification (self-DoS) | G4 | open |
| [B10](#b10) | low | confirmed | Offers (app) | StoreKit2Client throws away the back-deployed AppTransaction.appTransactionID below iOS 18.4, so offer signatures on iOS 16.0–18.3 are never bound to the customer | G7 | open |
| [B11](#b11) | low | confirmed | Signer worker | Signer worker logs the malformed APPLE_BUNDLE_IDS / ALLOWED_OFFERS value it promises never to log, and its "never its value" test cannot fail | G6 | open |
| [B12](#b12) | low | narrower | Offers (app) | Signer `timeout` is only URLSession's idle timer and nothing sets a total deadline, so README's "15-second timeout" overstates how long the offer purchase can wait | G7 | open |
| [B13](#b13) | low | narrower | Tests | The production-receipt lane's account-key check copies the receipt's own values, and no test compares a real AppTransaction with the same install's receipt | G4 | open |
| [B14](#b14) | low | narrower | Tests, fakes | FakeStore models "store down" as a thrown entitlement read, which StoreKit2Client can never produce. With the shipped store, `.storeUnavailable` never fires, and the offline tests and the storeDown preset pin the fake's mechanism | G3 | open |
| [O1](#o1) | operational | checked by the lead | Secrets | An In-App Purchase private key (`.p8`) sits in the working copy, kept out of git only by `.gitignore` | - | open |

The docs-vs-code corrections D1 to D10 are in §4.

## 2. Fix groups and order

Findings in one group either share a root cause or edit the same code. Fix each group in one change, or in the order given. The groups are independent of each other except where noted. Each entry's "Related findings" has the details.

| Group | Findings | Theme |
|---|---|---|
| G1 | A6, A7, A1, A9 | Wallet durability: the CloudKit cursor, the reinstall baseline, the outbox |
| G2 | A2, A5, A8, A12 | Lifecycle discipline: finish only what is credited, and nothing runs after `shutdown()` |
| G3 | A4, A3, A10, B14 | Entitlement resolution: ordering, the grace period, the trial flag, the fake's failure model |
| G4 | A11+B6, B1, B2, B13, B9 | Grandfathering trust: device binding, cache authentication, receipt types, key parity, DER parsing |
| G5 | B3, B4 | Release hygiene: what debug tooling and fakes ship in a release build |
| G6 | B5, B11 | The signing worker: volume limits and what it logs |
| G7 | B8, B10, B12 | Promotional offers on the app side: the JWS in logs, `appTransactionID`, the signer timeout |
| G8 | B7 | The coverage gate |
| Docs | D1 to D10 | Doc corrections. Land each one with its finding's fix where it has one, and the rest as one batch. |

**Recommended order**

1. **A2 (G2).** Finish a pack transaction only when its credit is in the ledger. The change is small, it closes a permanent loss of paid credits, and A5's fix depends on it.
2. **G1.**
   - First settle the cursor design once, for both **A6 and A7**: an engine-owned cursor, stored in the journal and committed with the merged events.
   - Then **A1**: a durable baseline that settles only on an answer that was merged, and never counts a nil `lastEventID` as seen.
   - Then **A9**: a bounded outbox, designed with A7's restore rule.
3. **A5 together with A4.** A5 adds guards after every await in `start`, `refresh`, `handle`, `purchase` and `restore`, and closes the journal fd at `shutdown()`. Add one generation check, bumped by `shutdown()`, that also orders overlapping refreshes. Then:
   - **A8**: reopen live view sessions on the successor engine.
   - **A12**: take the audit repair off the launch path, after A4.
4. **A3 and A10 together.** They edit the same `StoreTransaction` mapping and the same `Subscription` construction. Land them after A4's ordering fix, and land **B14** with A4.
5. **G4.**
   - **A11+B6** (device binding) goes before or with **B1** (authenticate the caches, by re-verifying the signed payload or with a Keychain-keyed MAC).
   - **B9** (a depth budget for the DER parser) goes before or with B1 if B1 re-verifies the cached payload at load, because an edited backup can plant that file on stock iOS. Otherwise B9 can go at any time.
   - **B2** goes before **B13**'s parity test starts comparing environments.
6. **G5 to G8.** The groups can go in any order, but some findings inside them cannot:
   - **G5:** fix B3 and B4 in one change to `Scripts/check-release-symbols.sh`. B4 also takes PaywallTesting out of the release link closure. If it does that by copying the fakes into PaywallSimulator (its option (a)), land B14 and A7 first, or apply them to both copies.
   - **G7:** B8 goes before or with B10. B10's fix puts the customer's `appTransactionID` into the JWS that B8 leaks to the logs, on iOS 16.0 and later. B12 goes with B8 if it adds a deadline at the engine level.
   - **G6** (B5, B11) and **G8** (B7) have no internal order.
7. **Docs last, D10 included.** Rewrite README's "Known defects and limitations" so it lists only what is still open after the cycle.

## 3. Findings

Each entry was written by the verification judge from the reviewer's report and two independent verifications (see §8), and the lead edited it only to point local files at the appendices (or mark them as not kept) and to drop wording about the review's own setup. Most severe first.

<a id="a1"></a>
### A1 · critical · After a delete-and-reinstall, the Keychain snapshot's balance lasts only one launch when the carrier lacks the old history. The next launch drops it and writes `grant:welcome` again

**Verdict.** Confirmed. **Fix group:** G1. **Status:** open.

**Where**

- Sources/PaywallCore/GateEngine+Store.swift:399-406: `persistSnapshot` writes `lastEventID: ledger.lastEventID` (:403).
- Sources/PaywallCore/GateEngine.swift:186, :288-293: the baseline is held in memory only and adopted only over a ledger with no events.
- Sources/PaywallCore/Ledger.swift:235-241: a baseline whose `lastEventID` is nil is ignored (:237).
- Sources/PaywallCore/GateEngine+Store.swift:389-397: `settleBaseline` counts a nil id as seen (:391) and judges `answered` on the raw remote (:392).
- Sources/PaywallCore/GateEngine+Store.swift:51-61: in production, `bind()` makes the first write after adoption (:59).
- Sources/PaywallCore/GateEngine.swift:272, :531-540: the init recompute persists the ledger-only balance.
- Sources/PaywallCore/GateEngine+Store.swift:355-359, GateEngine.swift:584-587: the welcome grant is written again.
- Sources/PaywallCloudSync/PaywallCloudSync.swift:54-57: `noAccount` answers `[]`.
- Docs that promise the opposite: HANDBOOK.md:200-201 and :469-473, README.md:230 and :237, Sources/PaywallCloudSync/KeychainWalletSnapshotStore.swift:5-6.
- Tests that stop at the first launch: Tests/PaywallCoreTests/GateEngineTests.swift:461-470, Tests/PaywallCoreTests/WelcomeTokensTests.swift:105-121.

**Defect**

The Keychain baseline adopted after a reinstall exists only in memory (GateEngine.swift:186, :292). The first balance change after adoption rewrites the single Keychain item from the ledger (GateEngine+Store.swift:403). In production that change is the `bind()` recompute from 0 to B at GateEngine+Store.swift:59. The item gets `lastEventID: ledger.lastEventID`. That id is nil on the reinstall's empty ledger, or this install's own event id once it writes any event: a draw, a credit or a grandfathered grant.

At the next launch, neither shape brings B back:
- `Ledger.balance` ignores a nil id (Ledger.swift:237).
- `settleBaseline` counts a nil id as seen (GateEngine+Store.swift:391), so `grantWelcomeIfNew` writes `grant:welcome` again.
- A ledger with events refuses adoption (GateEngine.swift:288), and the init recompute persists the ledger-only balance (GateEngine.swift:272, :538).

If the carrier never delivers the old history, the balance is lost for good, and the Keychain item no longer records it.

**Failure scenario**

The app uses the recommended `configuration.sync = PaywallCloudSync()`, with the default Keychain store and the facade's `welcomeTokens` of 100 (Paywall.swift:29). The user has no iCloud account: CloudKit's `.notAuthenticated` becomes `noAccount`, so `pull()` answers `[]`. They hold 120 tokens (100 welcome plus two purchased 10-packs), then delete and reinstall the app.
- **Launch 1** binds K, shows 120, and rewrites the item as `{K, 120, nil}`.
- **Launch 2** shows 0, then 100 after the first sync, from a new `grant:welcome`. The 20 purchased tokens are gone.
- **One draw on launch 1** (119): every later launch shows −1 and token gates stay closed.
- **A further reinstall** starts from the damaged item: 0, then 100.

With iCloud on, the loss is just as permanent when the old history never reached the container. It is transient when the first launch after the reinstall could not pull. A user with iCloud off and fewer than 100 tokens can reset to 100 by reinstalling and launching twice.

**Evidence**

Decisive lines at b5c20e4, all re-read by the judge:
- `lastEventID: ledger.lastEventID, headHash: ledger.head(for: deviceID))` (GateEngine+Store.swift:403)
- `if let baseline, baseline.accountKey == accountKey, let last = baseline.lastEventID, !contains(last) {` (Ledger.swift:237)
- `let seenLast = baseline.lastEventID.map(ledger.contains) ?? true` (GateEngine+Store.swift:391)
- `!ledger.hasEvents(for: snapshot.accountKey)` (GateEngine.swift:288). `baseline` is assigned only at :292 and cleared only at GateEngine+Store.swift:394, and is never persisted (grep over Sources/).
- `catch CloudDatabaseError.noAccount { … return [] }` (PaywallCloudSync.swift:54-57). CloudKitDatabase.swift:88 and :92 map `.notAuthenticated` to it.
- The facade passes `configuration.sync` straight to `GateEngine` (Paywall.swift:178-183). Nothing else in PaywallKit touches the Keychain.

Reproduction: verifier 2 re-ran reviewer A's probes (`swift test --skip-build --filter "probe1_reinstall|probe2_reinstall|probe3_icloud|probe15_icloud"`):
- PROBE3: `oldInstall=120 reinstall=120 relaunch=100 welcomeGrantsInNewLedger=1`
- PROBE15: `afterDraw=119 relaunch=-1 relaunchAgain=-1 canDraw=false`
- PROBE2 (throwing carrier): `persisted=…lastEventID: nil… relaunched=0`
- PROBE1: `relaunched=-1`

Verifier 2's own probe used a bound account key (`FakeStore(app:)`) and the default 3600 s pull interval:
- launch 2: `afterStart=0 afterSync=100`
- draw case: −1 on every relaunch
- second reinstall: 0, then 100

None of these probes uses `injectedFault` or another test hook. The only stand-in is an in-memory Keychain item behind the public `LedgerSync` load and save seam.

The existing reinstall tests pass only because they stop at the first launch after the reinstall.

**Fix direction**

Keep the old balance and its provenance until the carrier delivers the history the baseline stands for.
1. **Make the baseline durable on the device.** One way is an opening-balance record that is never pushed. It must stay out of `pendingUpload`, `ids`, `head(for:)` and `firstBrokenLink`, and must survive `compact(checkpoint:keepingOutbox:)`. A new `JournalEntry` case is public API, and older builds truncate the log at a frame they cannot decode. A `LedgerCheckpoint` field must be decoded only if present. The balance is the baseline plus the events written since adoption.
2. **Settle carefully.** Never count a nil `lastEventID` as seen. Clear the baseline only when the carrier returns history for the account that this install did not write since adoption: the CloudKit change feed and InMemoryCloudDatabase echo this install's own pushes (CloudDatabase.swift:64-70). Clear it only after a durable merge, because `merge` returns silently on a journal error (GateEngine+Store.swift:370-375; see A6).
3. **Keep provenance in the Keychain.** While a baseline stands, write its `lastEventID`, with the balance as baseline plus local events, so the item survives a dropped log (A7) and a second reinstall. Load the baseline before the init recompute (GateEngine.swift:272) rather than dropping that write, because the init write repairs a save lost to process death.
4. **Protect K's snapshot.** There is one Keychain slot for every key, so a write while still `unbound` must not overwrite K's snapshot.
5. **Handle existing items.** Treat `{0, nil}` as no history so the welcome grant still fires. Honour legacy `{K, B≠0, nil}` items on an empty ledger. New `WalletSnapshot` fields must be optional.
6. **Decide the new-device case.** A durable baseline makes adopting another device's synchronizable snapshot permanent when the carrier never answers. One option is `synchronizable: false`, migrating once via `kSecAttrSynchronizableAny`.
7. **Update the docs.** Make HANDBOOK.md:469-473 and README.md:230 match. Losses and welcome grants already on devices cannot be undone.

**Regression test (the finding is fixed when this passes)**

Put it in Tests/PaywallCloudSyncTests/CloudSyncTests.swift as plain Swift Testing so it builds for macOS 14, not in the Simulator suite.

Setup:
- Reuse `SharedSnapshotItem` and `SharedKeychainCarrier` (:24-44) over `PaywallCloudSync(database: InMemoryCloudDatabase(), keychain: nil)`.
- Use `setAccount(false)`, `welcomeTokens: 100`, and `FakeStore(app: AppTransactionSnapshot(…))` so the key binds in `refresh`.
- Old install: welcome plus two 10-packs gives 120. Wait for `item.value?.balance == 120`, then shut down.
- Reinstall on a new directory with the same item.

Assertions:
1. Two relaunches each show 120, and the new ledger has no `grant:welcome`.
2. Draw 1 on the reinstall launch. Two relaunches show 119, and `canPass(.tokens(1))` is true.
3. A second reinstall after one launch shows 120, both after `start` and after `syncNow`.
4. Cases 1 and 2 again with `setReachable(false)`.
5. With the account present and the history uploaded, two offline launches after the reinstall show 120. Online `syncNow` then yields the old ids and exactly one `grant:welcome`.
6. iCloud on, empty container, a purchase after the reinstall: the balance stays 130.

Also extend GateEngineTests:461-470 and WelcomeTokensTests:105-121 with relaunches.

**Related findings**

- **A6** (the change token is saved before the merge is durable, and `settleBaseline` still runs after a failed merge): fix it together with A1, so the baseline settles only after a durable merge.
- **A7** (recovering a dropped or corrupt journal depends on the snapshot that A1 drops): land A1 first or in the same change.
- **A9** (with no iCloud account, the outbox is never acknowledged): if its fix makes the carrier report "no account" to the engine, keep A1's settle rule consistent with it.

**Verification**

Reported by reviewer A as critical. Verifier 1 (code trace): confirmed, critical. Verifier 2 (reachability and reproduction): confirmed, critical; reachable in production: yes, with preconditions. Judge: confirmed, critical.

Both verifiers confirmed the finding at critical, and they do not disagree.
- **Production path:** reviewer A's probes use `FakeStore()` with no AppTransaction, so the first write comes from `start()`'s recompute (GateEngine.swift:294). In production it comes through `bind()` (GateEngine+Store.swift:56-59). Verifier 2 reproduced it with a bound key and got the same outcome.
- **Wider variant:** verifier 1 found that with iCloud on and an empty container, the echo of this install's own pushes clears the baseline in the first session. This was not probed; it is folded into the fix direction.
- **Judge's trace:** any event written on the reinstall launch, including an automatic `grant:grandfathered:K` from a token GrandfatheringPolicy, causes the same loss as a draw. This was traced in the code, not run.
- **Unverified, device-only:**
  - Keychain items outliving app deletion (Apple calls this an implementation detail).
  - Synchronizable items being kept locally with iCloud Keychain off.
  - A signed-out device getting `.notAuthenticated`. If it gets another error, `pull()` throws and launch 2 shows 0 instead of 100; the loss remains.
  - The size of the affected population.

<a id="a2"></a>
### A2 · high · A pack credit whose journal write fails is still finished and reported as purchased, so the paid tokens are lost for good

**Verdict.** Confirmed. **Fix group:** G2. **Status:** open.

**Where**

- Sources/PaywallCore/GateEngine+Store.swift:93: `applyPlanned` ignores a nil append.
- GateEngine+Store.swift:117-125: `handle`. Its only guard is `!isTerminated` at :123; it finishes at :124.
- GateEngine+Store.swift:224-234: `purchase`. It finishes at :229, emits `.completed` at :230 and returns `.purchased` at :234.
- Sources/PaywallCore/GateEngine.swift:551-569: `appendLedger`. It returns nil at :554 (id already present, or `isTerminated`) and at :562 (`journal.append` threw).
- Sources/PaywallKit/StoreKit2Client.swift:135-142: the real `finish`.
- Sources/PaywallCore/CreditReconciler.swift:38-43: only revoked packs are planned again.
- Sources/PaywallCore/Journal.swift:191-209: failed write and poisoning. :226-229: append is write, then sync. :318-326: fd left at -1 after a failed rename or reopen.
- GateEngine.swift:653-667: a runtime checkpoint error is only logged.
- Broken contract: README.md:163 and :237, HANDBOOK.md:298-299 and :311, GateEngine.swift:47-48, GateEngine+Store.swift:208-209.
- Contrast: GateEngine+Draw.swift:122-134, where the draw path fails closed.

**Defect**

When the journal write of a pack credit fails, `appendLedger` logs the error and returns nil, and `applyPlanned` returns without a word. `handle` and `purchase` still call `store.finish`, and `purchase` also emits `.purchase(stage: .completed)` and returns `.purchased`. StoreKit never delivers a finished consumable again, and `planRevocations` plans only revoked packs, so when write(2) fails the paid credit is lost for good: ENOSPC, EIO, a poisoned journal, or the fd lost after a failed checkpoint rename. A failure of the sync alone is narrower: the frame is already in the file, so the credit comes back at relaunch.

**Failure scenario**

A device with no free storage buys `tokens.10`, and StoreKit returns success. The credit frame is about 415 bytes. It needs a new APFS block, so write(2) fails with ENOSPC; the journal rewinds cleanly and is not poisoned. The engine logs the error, finishes the transaction, posts `paywallPurchaseCompleted` and returns `.purchased`, and `onPurchaseCompleted` dismisses the paywall with the balance unchanged. No later launch, refresh, restore or sync credits the pack, so the user has to go to Apple or to support. An Ask to Buy approval, or an interrupted purchase delivered on `Transaction.updates`, fails the same way through `handle`. Once a runtime checkpoint rename fails (fd -1) or the journal is poisoned, every pack bought in the rest of the session is lost.

**Evidence**

Code:
- GateEngine+Store.swift:93: `guard appendLedger(id: planned.id, kind: planned.kind) != nil else { return }`. `appendLedger` catches the journal error, logs it and returns nil (GateEngine.swift:558-563).
- `await store.finish(transactionID: transaction.id)` runs at GateEngine+Store.swift:124 and :229.
  - :124 is guarded only by `!isTerminated`, which only the DrawObserver test hook sets, via `terminate()` at GateEngine.swift:694-695.
  - :229 has no guard; `.completed` (:230) and `.purchased` (:234) follow it.
- StoreKit2Client.swift:136-139 finishes the matching `Transaction.unfinished` entry.
- `planRevocations` loops `where transaction.revocationDate != nil` (CreditReconciler.swift:43). Its only other callers are `handle` and `purchase`.
- Nothing reads `journal.isPoisoned`, and `StoreClient` has no call for unfinished transactions (StoreClient.swift:118-143).

Reproduction (by the verifiers; the judge ran nothing):
- probe4, using the `injectedFault = .write` seam: `PROBE4 finishedAfterHandle=[21] outcome=purchased(transactionID: 1001) finishedAfterPurchase=[21, 1001] balance=0 afterRelaunchAndRefresh=0`.
- Verifier 2, without the seam: RLIMIT_FSIZE made the kernel refuse write(2) with EFBIG. Output: `outcome=purchased(transactionID: 1001) finished=[1001] … creditInLedger=false … purchaseCompletedEvent=true … afterRelaunchRefreshRestore balance=5 credit=false`. The updates path failed the same way.
  - Counterfactual: a pack left unfinished and delivered again was credited once (balance 5 to 15).
  - Sync-only fault: the credit was back after relaunch.
- On a real, full 16 MB APFS image, an O_APPEND write that crossed a block boundary failed with ENOSPC. A write that stayed inside the block succeeded. The ftruncate and F_FULLFSYNC still worked.

Not documented: README.md:235-252 lists nothing like this, and :237 says there is no known correctness defect.

**Fix direction**

- **Gate `finish` on the ledger.** In `handle` (GateEngine+Store.swift:117-125) and `purchase` (:224-234), keep the plan, apply it, then call `finish` only if every planned id, credit and revocation alike, is in `ledger`.
  - Check membership, not `appendLedger`'s return value, which is also nil when the id is already present or `isTerminated` is set.
  - An empty plan (a non-pack product) still finishes, as today.
  - Keep `refresh` before `finish`.
- **Retry.** StoreKit delivers an unfinished transaction again only once, at the next launch, on `Transaction.updates`. The `credit:<id>` id and `Ledger.append`'s dedup (Ledger.swift:174-175) keep that delivery idempotent.
  - Optionally hold the deferred pack transactions in memory, retry them on refresh or foreground, and finish each once it lands.
  - A `Transaction.unfinished` scan would need a new requirement on the public `StoreClient`, which README.md:206 tells apps to implement. It needs a default implementation and support in FakeStore, and should be shared with A5.
- **Purchase outcome.** `purchase` must not return `.purchased` or emit `.purchase(stage: .completed)` when the credit did not land; that event posts `paywallPurchaseCompleted` (PaywallSignals.swift:334).
  - Throwing after a payment went through invites a second charge.
  - A new `PurchaseOutcome` case breaks exhaustive switches, and no chain handler would fire for it.
  - `.pending` keeps the API, and its doc fits (GateEngine.swift:33).
  - Document the choice in README and HANDBOOK.
- **Don't replay.** Never credit unrevoked consumables from `Transaction.all`. While the baseline's last event is unseen, the balance is `baseline.balance + total` (Ledger.swift:237-238), so a replay would double-count.
- **Optional.** As the draw path does (GateEngine+Draw.swift:129-134), treat a failed sync after a successful write as landed in `appendLedger`. Today the frame stays in the file but not in the ledger, so the next event forks the chain at reload.
- **To check.** In the StoreKit lane, see how buying the same pack again behaves while an earlier purchase of it is unfinished.

**Regression test (the finding is fixed when this passes)**

Target: PaywallCoreTests, suite "Failure paths" (Tests/PaywallCoreTests/FailurePathTests.swift, `.serialized`, `@MainActor`). Use `Harness`, `FakeStore` and the `journal.injectedFault` seam, which takes the same branch as a real failed write(2). Don't use RLIMIT_FSIZE: it applies to the whole process.

1. `credit_write_failure_leaves_the_purchase_unfinished`:
   - Setup: `Harness.free()`, `setProducts(products)`, `injectedFault = .write`.
   - Act: `purchase(productID: "tokens.10", source: source("paywall"))`.
   - Assert: `finished.isEmpty`, balance 0, the outcome is not `.purchased`, and `h.events` has no `.purchase(stage: .completed, …)`.
   - Then `let engine = try await h.relaunch()` and `await h.store.deliver(tx)`, where `tx` is `history.last`.
   - Assert: `eventually { finished == [tx.id] }`, balance 10, exactly one `credit:<id>`.
2. The same through `handle(.tokenPack(id: 21, …))`.
3. Poison variant: poison the journal with one write under `.poison`, clear the seam, then handle a pack. It stays unfinished; after relaunch and `deliver` it is credited once and finished once.
4. Optional `.sync` variant: after relaunch and `deliver`, balance 10, one credit, finished once.

Each test must call `deliver` explicitly. FakeStore.updates() never replays unfinished transactions (FakeStore.swift:120-128), so probe4's closing check of balance 20 cannot pass even after a correct fix.

**Related findings**

A5: a shut-down engine keeps appending and finishing. A5's fix makes `appendLedger` refuse after `shutdown()` and closes the fd. Without A2's membership gate, every write it refuses would leave an uncredited transaction finished. So land A2's finish gate first, or in the same change. A5 also proposes a `Transaction.unfinished` scan in `start()`; if that new `StoreClient` requirement is added, A2's in-session retry should reuse it.

**Verification**

Reported by reviewer A as critical. Verifier 1 (code trace): confirmed, high. Verifier 2 (reachability and reproduction): confirmed, high; reachable in production: yes, with preconditions. Judge: confirmed, high.

- **Mechanism:** no disagreement. Both verifiers confirmed it by code trace and by reproduction. I re-read every decisive line at b5c20e4 and the citations hold. `appendLedger` spans GateEngine.swift:551-569 and has a third nil cause, `isTerminated`, which is a test hook.
- **Severity:** the reviewer said critical; both verifiers and I say high. The consequence is in the critical class, but the trigger is rare and environmental: a full volume, where by verifier 2's APFS measurement only frames that cross a block boundary fail; EIO; or a journal that is already broken. A sync-only failure heals at relaunch.
- **Reviewer's test:** as written it cannot pass under FakeStore without an explicit `deliver`.
- **Unverified (device or StoreKit only):**
  - whether the purchase sheet completes on a device with no free space;
  - whether StoreKit's own `finish()` persists on a full disk;
  - what buying the same pack again does while an earlier purchase of it is unfinished;
  - the trigger where the host defaults to NSFileProtectionComplete and the app runs in the background with the device locked.
- **Not reproduced:** the chain fork in the sync-only case comes from reading the code only.

<a id="a3"></a>
### A3 · high · Subscribers in a billing grace period resolve to .free, because the resolver drops the lapsed auto-renewable that currentEntitlements still lists

**Verdict.** Confirmed. **Fix group:** G3. **Status:** open.

**Where**

- Sources/PaywallCore/EntitlementResolver.swift:103-106: the live filter. `expirationDate > now` at :104 drops the listed lapsed row.
- EntitlementResolver.swift:128-138: the Subscription is built with `phase: .active` (:135) and `expiresAt: tx.expirationDate` (:138). :141 falls through to `.free`.
- Sources/PaywallKit/StoreKit2Client.swift:18-25: currentEntitlements is passed through unchanged. :165-187 `map` copies expirationDate (:179) and adds no renewal or grace data. :144-156 subscriptionPhase is the only place grace is read.
- Sources/PaywallCore/StoreClient.swift:18-30: StoreTransaction has no grace field. :138 documents the status read as a network call, account screen only.
- Sources/PaywallCore/GateEngine+Store.swift:8 ("Never waits for the network"), :25 (resolve at clock.now), :28-31 (publish, save the snapshot, arm the timer), :76-89 (armExpiryTimer).
- Sources/PaywallCore/GateEngine.swift:347-350: `.paid` opens only on isPaying. :745-752: the launch snapshot downgrades a lapsed subscription to free.
- Sources/PaywallSimulator/PaywallSimulator.swift:147-152 (grace is only a phase flag), :134-135 and :249 (the expiry stays in the future).
- Tests/PaywallSimulatorTests/SimulatorTests.swift:294-297: cannot fail on this bug.
- Tests/PaywallCoreTests/ResolverTests.swift:41-51 and :125-140: assert that an expired row is not paying.

**Defect**

The resolver keeps a transaction only while its expirationDate is after the injected clock (EntitlementResolver.swift:104). StoreKit2Client passes `Transaction.currentEntitlements` through with no renewal or grace data. During an App Store billing grace period, StoreKit still lists the subscription's latest transaction, and that transaction's expirationDate is the failed renewal date. So the package resolves `.free` and closes `.paid` gates for users Apple says are entitled to full service. The simulator models grace with a future expiry, so the test that covers grace cannot catch this.

**Failure scenario**

1. The app turns on Billing Grace Period in App Store Connect. It is opt-in, lasting 3, 16 or 28 days (at most 6 for weekly plans).
2. A monthly subscriber's card fails at renewal.
3. At the old expiry, the expiry timer (GateEngine+Store.swift:76-89) re-resolves. currentEntitlements still lists the lapsed transaction, and the resolver drops it.
4. The entitlement becomes `.free`, entitlement.json is saved as free, and no timer is re-armed. Every launch and foreground does the same.
5. `.paid` gates close with `requiresPaid`. Token gates draw from the user's wallet. Meanwhile `subscriptionPhase()` reports `.inGracePeriod`.

Access comes back only when billing recovers and a new transaction with a future expiry arrives. Recovery inside grace does not move the billing date, so the user pays for the days they were locked out. If grace ends without recovery, StoreKit drops the row and `.free` is correct. Apps without grace are unaffected.

**Evidence**

**Code**
- `tx.revocationDate == nil && !tx.isUpgraded && (tx.expirationDate.map { $0 > now } ?? true)` (Sources/PaywallCore/EntitlementResolver.swift:104). With nothing left it returns `.free` (:141).
- `for await result in Transaction.currentEntitlements { ... Self.map(transaction) }` (Sources/PaywallKit/StoreKit2Client.swift:21-22). `map` copies `expirationDate: transaction.expirationDate` (:179).
- StoreTransaction has no grace field (StoreClient.swift:18-30).
- Nothing reads RenewalInfo, gracePeriodExpirationDate or Status.updates. A grep for "grace" in Sources finds only the phase enum, StoreKit2Client.swift:150 and the simulator.
- `if entitlement.isPaying { return .open(.paying) }`, then `guard cost > 0 else { return .closed(.requiresPaid) }` (GateEngine.swift:347, :350).

**Stated intent**
- PaywallSimulator.swift:147: "Grace period keeps access."
- README.md:19: "StoreKit 2 decides entitlements". HANDBOOK.md:4: "StoreKit 2 is the only authority".
- README's known-defects list (README.md:235-252) does not mention grace.

**Apple's documentation** (as quoted by verifier 2)
- currentEntitlements emits the latest transaction for auto-renewables in the `subscribed` or `inGracePeriod` state.
- Grace begins when billing retry begins, after expirationDate.
- The grace end exists only as `RenewalInfo.gracePeriodExpirationDate`.

**Reproduction** (verifier 2, `swift test` in an isolated build; I ran nothing)
- Resolver: `A3V-RESOLVER entitlement=free expiresAt=nil`.
- Engine across the renewal moment: `changes=["launch->free","foreground->paying","expiryTimer->free"] paidAfter=false`.
- Reviewer A's probe7: `PROBE7 entitlement=free paidGate=false phase=Optional(...inGracePeriod)`.
- Simulator replay: `A3V-SIM isPaying=true secondsUntilExpiry=[604800.0]`.

FakeStore returns its scripted rows unfiltered (FakeStore.swift:105-108), so the only modelled fact is StoreKit's listing. Nothing ran against StoreKit Testing or the sandbox.

**Fix direction**

Keep a listed, lapsed auto-renewable paying until its grace ends, and keep a bounded expiry.

**Option A: grace end from the renewal info**
- Add an optional grace-end field to StoreTransaction with a defaulted init parameter, since the type is public and Codable.
- StoreKit2Client fills it from `Product.SubscriptionInfo` status/RenewalInfo. StoreKit's Transaction has no such field.
- Read the status only when a listed auto-renewable has lapsed. StoreClient.swift:138 documents that read as network and account-screen only, and refresh promises not to wait for the network (GateEngine+Store.swift:8).
- Define what happens when that read fails offline.

**Option B: trust membership in currentEntitlements**
- Needs no network, but removes the expiry boundary. StoreKit Testing, and perhaps a stale cache, list rows past expiry.
- Bound it, for example with an app-declared grace length of at most 28 days.

**Either way**
1. Keep the revocation, isUpgraded and family filters. StoreKit Testing keeps upgraded rows (StoreKitIntegrationTests.swift:223-226).
2. Set `EntitlementResolution.expiresAt` to the grace end or nil, never to the past expirationDate. Otherwise armExpiryTimer returns at once (PaywallClock.swift:22-25, FakeClock.swift:38) and refresh loops, rewriting entitlement.json on every pass.
3. Carry the effective end into the snapshot, because GateEngine.swift:747-748 launches `expiresAt <= now` as `.free`. Decode any new Subscription field with decodeIfPresent, as Entitlement.swift:178 does.
4. Report `phase: .inGracePeriod` instead of the hard-coded `.active` (:135).
5. Give any new StoreClient requirement a default implementation (README.md:206 invites custom conformers), and let FakeStore script it.
6. Make the simulator's `enterGracePeriod`/`storeState` publish a lapsed row that stays listed.
7. Keep "expired without grace resolves `.free`" true in ResolverTests.swift:41-51 and :125-140.

**Regression test (the finding is fixed when this passes)**

- **ResolverTests**, new test `a_subscription_in_billing_grace_stays_subscribed_until_grace_ends`.
  - Input: `pro.monthly` that expired an hour ago, with a grace end 16 days ahead.
  - Expect `.subscribed(.monthly)`, `isPaying`, phase `.inGracePeriod`, and `resolution.expiresAt` equal to the grace end.
  - The same input after the grace end gives `.free`. An expired row without grace data gives `.free`.
- **GateEngineTests** (`Harness.free()`).
  - Setup: a subscription expiring at T, then the same row with grace end T+16d and `setPhase(.inGracePeriod)`, then `clock.advance(by: 3_601)`.
  - Expect `canPass(.paid)` to stay true, no `entitlementChanged` to `.free` with cause `.expiryTimer`, and `clock.pendingSleepers == 1` (no refresh loop).
  - Advancing past the grace end flips to `.free` via `.expiryTimer`.
- **FailurePathTests**: a snapshot taken inside grace does not launch as `.free`.
- **SimulatorTests** `renewal_expiry_grace_and_billing_retry`: after `enterGracePeriod`, the listed row has `expirationDate <= clock.now` and the user still pays.
- Reviewer A's probe7 passes.
- **Host lane** (simulator only): SKTestSession grace and billing retry at an accelerated rate. Expect `.inGracePeriod` and `canPass(.paid)`.

**Related findings**

- **A4** (an older refresh overwrites a newer one): Option A adds an await inside refresh, which widens A4's window. Land A4's ordering fix first or together, and cover the new read with it.
- **DOCS D2** (clock-based expiry, on the same line EntitlementResolver.swift:104 and the snapshot check at GateEngine.swift:747): fix together so the README describes the new rule.
- **DOCS D8** ("never waits for the network"): Option A must keep the status read off the network or bounded, or update that comment.
- **A10** (isTrial is set for paid intro offers): it edits the same Subscription construction (EntitlementResolver.swift:129-137) and `StoreKit2Client.map`, so coordinate the edits.

**Verification**

Reported by reviewer A as high. Verifier 1 (code trace): confirmed, high. Verifier 2 (reachability and reproduction): confirmed, high; reachable in production: yes, with preconditions. Judge: confirmed, high.

Both verifiers confirmed the finding and rated it high. They disagreed on nothing of substance. I re-read every decisive line at b5c20e4 and all of them match.

**Corrections folded in**
- The finding's "carried on StoreTransaction" is a proposal: no such field exists.
- `phase: .active` is a documented design choice (Entitlement.swift:128), but it has to change once a grace row is kept.

**Severity**
High rather than critical: it needs an opt-in App Store Connect setting, the window is bounded, it heals when billing recovers, and nothing persisted is corrupted.

**Unverified (device-only or service-only facts)**
- That real StoreKit on iOS 15 through 26 lists the lapsed row during grace. This rests on Apple's documentation and was not observed in StoreKit Testing or the sandbox.
- Whether status and renewal info can be read offline.
- How StoreKit's cache behaves when grace ends while the device is offline.
- The SKTestSession grace API names.
- Whether the host app enables grace.

<a id="a6"></a>
### A6 · high · CloudKit change token is committed before pulled events are durable: a failed merge or a mid-pull shutdown loses them for that install, and the baseline and welcome grant still settle

**Verdict.** Confirmed. **Fix group:** G1. **Status:** open.

**Where**

- Sources/PaywallCloudSync/PaywallCloudSync.swift:59-66: pull() sets changeToken (:59), writes cloudkit.token with try? (:60-63) and sets lastPull/pullRequested (:64-65). Only then does it return the decoded events (:66).
- Sources/PaywallCore/GateEngine+Store.swift:355-359: performSync drops the pull result after a shutdown. Otherwise it runs merge, settleBaseline and grantWelcomeIfNew without checking whether the merge succeeded.
- Sources/PaywallCore/GateEngine+Store.swift:363-381: public merge. It catches the journal error, logs it and returns Void (:370-375).
- Sources/PaywallCore/GateEngine+Store.swift:389-397: settleBaseline computes `answered` from `remote` (:392) and drops the baseline (:394).
- Sources/PaywallCore/GateEngine.swift:531-540: the recompute calls persistSnapshot (:538; body at GateEngine+Store.swift:399-406), which overwrites the Keychain item.
- Sources/PaywallCore/GateEngine.swift:584-587: the welcome guard.
- Sources/PaywallCore/LedgerSync.swift:8-11 and :20-24: the pull contract has no acknowledgement; the extension holds the defaults.
- Sources/PaywallCloudSync/CloudKitDatabase.swift:143-153: the only places the token is reset.
- Sources/PaywallKit/Paywall.swift:133-134 and :208-214, and PaywallServiceProvider.swift:67-71: a reconfigure calls shutdown (GateEngine.swift:307-313).
- Tests/PaywallCoreTests/FailurePathTests.swift:50-60, and Tests/PaywallCloudSyncTests/CloudSyncTests.swift:131-157

**Defect**

`PaywallCloudSync.pull()` moves the change token, writes it to disk and starts the pull interval before it returns the events. `performSync` cannot tell whether `merge` made those events durable, because merge swallows the journal error, and after a shutdown it throws them away. Nothing ever delivers them again. In the running process this holds at once. Across launches it holds once the advanced token reaches disk: immediately if only the journal write fails, otherwise at the next fetch in the same process after the disk recovers. A relaunch before that fetch heals. Meanwhile `settleBaseline` treats the unmerged answer as settled: it drops the Keychain baseline, which rewrites the item with 0. `grantWelcomeIfNew` then writes this install's own `grant:welcome` on the empty ledger.

**Failure scenario**

Case 1, a second device:
- Device A buys a 10-pack and uploads it.
- Device B's first sync hits ENOSPC. The merge fails and B shows 0.
- Space is freed. A silent push, a purchase, a restore or the hourly pull then fetches, and the advanced token is written to disk.
- B shows 0 for good, until a reinstall or a CloudKit token expiry.
- With the facade's welcomeTokens=100, B also writes its own welcome and shows 100 whatever A's real balance is. The error can over-credit or under-credit.

Case 2, a reinstall with iCloud on and a 110 snapshot (100 welcome + 10-pack):
- The first merge fails. The balance drops to 0 and the Keychain item is rewritten with 0.
- After the disk recovers, the install writes grant:welcome.
- A relaunch shows 100, with only grant:welcome in the ledger. credit:5 never comes back.

Other triggers:
- EIO, or a poisoned journal.
- A reconfigure during an in-flight pull.
- Process death between PaywallCloudSync.swift:62 and the journal write. This one needs no fault at all.

The cloud is not damaged: the duplicate welcome collides with the existing record and is acknowledged (CloudKitDatabase.swift:127).

**Evidence**

Code (re-read at b5c20e4; every cited line matches):
- PaywallCloudSync.swift:59 `changeToken = page.token`, then :62 `try? token.write(to: tokenURL, options: .atomic)`, then :64-65 `lastPull = Date()` and `pullRequested = false`. Only after that does :66 return the events.
- GateEngine+Store.swift:355 `guard let remote = try? await sync.pull(), !isTerminated, !isShutDown else { return }`. Lines :356-359 run merge, settleBaseline and grantWelcomeIfNew with no success check. In merge, :370-375 catches the error, logs `journal: merge failed` and returns.
- :392 computes `answered` from `remote`, and :394 sets the baseline to nil. GateEngine.swift:538 calls persistSnapshot, which writes balance 0. The guard at GateEngine.swift:585 then passes on the empty ledger.
- The token is reset only on changeTokenExpired or a vanished zone (CloudKitDatabase.swift:143-153).
- FailurePathTests.swift:50-60 assumes a retry of the same events, which the real carrier never sends. InMemoryLedgerSync.pull returns the whole cloud (Sources/PaywallTesting/InMemory.swift:61), so the engine tests cannot see this bug.

Reproduction (run by the verifiers; I ran nothing):
- Reviewer A's probes use the `Journal.injectedFault = .write` seam. Verifier 2 re-ran them and got identical output:
  - `PROBE8 cloudCount=1 deviceA=10 deviceB_sameProcess=0 deviceB_relaunched=0`
  - `PROBE14 oldInstall=110 adopted=110 afterFailedMerge=0 baseline=dropped afterDiskRecovers=100 relaunch=100 ledgerIDs=["grant:welcome"]`
- Verifier 2 also ran a probe without the seam: public API only, the default 3,600 s interval, and B's directory on a 16 MB APFS image filled until writes failed with ENOSPC (errno 28):
  - `A6V2-PULL ... whileFull=0 tokenFileWhileFull=false recovered=true sameProcess=0 tokenFileAfter=true relaunched=0`
  - Control, relaunch before any pull: `A6V2-RELAUNCH ... relaunched=10`
  - Reinstall: `A6V2-REINSTALL pullAfterRecovery=true ... oldInstall=110 whileFull=0 afterRecovery=100 relaunched=100 ledgerIDs=["grant:welcome"]`
  - Near-full disk, a 2,000-event (575 KB) merge with 64-512 KB free: `tokenWritten=true journalBytes=0 relaunched=0` (expected 2009)

**Fix direction**

Preferred: a two-phase pull and commit.
- PaywallCloudSync: pull() keeps the fetched token as pending. Four things advance only in commit: the in-memory token, cloudkit.token, lastPull and pullRequested (:59-65). If lastPull or pullRequested still advance in pull(), the next pull inside minimumPullInterval (3,600 s by default, :27) returns [] at :50 without fetching. performSync takes that as an answer and grants the welcome on the incomplete ledger, and the retry waits up to an hour. Test with the default interval.
- LedgerSync is public. Add the acknowledgement with a default no-op in the extension (LedgerSync.swift:20-24) so third-party carriers still compile. Wrapping carriers, such as the one at CloudSyncTests.swift:41, must forward it, or the inner carrier never advances.
- merge (public, GateEngine+Store.swift:363) must report success in a source-compatible way, for example a @discardableResult Bool. A batch with nothing fresh counts as success. In performSync, if the engine was shut down or terminated after the pull, or the merge failed, return without commit, settleBaseline or grantWelcomeIfNew.
- Redelivery after a crash between the append and the commit is harmless: merge dedups by id, and a checkpoint's ids seed the Ledger (Ledger.swift:131-149).
- Update the docs at LedgerSync.swift:8-10 and HANDBOOK.md:192-195 and :469-473. Update the tests that expect pull to advance the token: CloudSyncTests.swift:131-157 and :175-184, CloudKitDatabaseTests.swift:274-278, and TestHost/TestHostTests/LiveCloudKitTests.swift:121-124.
- Optional: reset the token once on upgrade to heal installs already affected. A full re-pull is safe under the union merge.

Alternative: store the token as a journal record. This also fixes A7, but it needs all of the following:
- downgrade safety: an older build stops at an unknown JournalEntry case and truncates the rest of the file (Journal.swift:116-123);
- carrying the record through rewrite (:293-295);
- writing it even when the batch has nothing fresh (GateEngine+Store.swift:368);
- a pull(since:) carrier API;
- a migration for the existing cloudkit.token.

Not required, but next to this code: :66 also commits past records this build cannot decode.

**Regression test (the finding is fixed when this passes)**

Put these in Tests/PaywallCloudSyncTests/CloudSyncTests.swift (the serialized "Cloud sync" suite). Use the real PaywallCloudSync on InMemoryCloudDatabase with a tokenURL, not InMemoryLedgerSync. Add `@testable import PaywallCore` for `journal.injectedFault`.

1. `a_failed_merge_does_not_move_the_change_token`:
   - A handles tokenPack(id: 9, "tokens.10") and syncs. B uses the default minimumPullInterval.
   - Set `.write`, then start, syncNow, and clear the fault.
   - A plain syncNow, with no requestPull, shows 10.
   - A relaunch on the same directory and tokenURL shows 10.

2. Reinstall (probe14's shape, welcomeTokens 100, a snapshot-item carrier):
   - While the fault is on, the balance stays 110 and the baseline is not nil.
   - After the fault clears and a syncNow, the balance is 110, the ledger holds credit:5, and it holds exactly one grant:welcome.
   - A relaunch shows 110.

3. Shutdown: a wrapper carrier whose pull suspends on a continuation. Call shutdown() while it is suspended, then resume it. A new engine and carrier on the same tokenURL show 10.

4. FailurePathTests: under `.write`, merge reports failure, and performSync neither drops the baseline nor writes grant:welcome.

**Related findings**

- A7: same root cause, a token that is not tied to the journal's state. Storing the token in the journal fixes both; the two-phase design fixes only A6. Settle the token design once, for both findings.
- A1: also touches settleBaseline, grantWelcomeIfNew and the snapshot (GateEngine+Store.swift:389-406, GateEngine.swift:584-587). Coordinate the two fixes so only a merged answer settles the baseline and the welcome.
- A5: an engine keeps working after shutdown. A6's shutdown case is covered by not committing after a shutdown, whatever A5 does.
- No hard ordering. Land A6's commit API before A7's or together with it.

**Verification**

Reported by reviewer A as high. Verifier 1 (code trace): confirmed, high. Verifier 2 (reachability and reproduction): confirmed, high; reachable in production: yes, with preconditions. Judge: confirmed, high.

Both verifiers confirmed the finding and both rated it high. They did not disagree. Refinements folded in:
- Verifier 1 narrowed the trigger to write(2) failures. An fsync failure after a successful write heals at relaunch, because the frames are already in the file (Journal.swift:236-239). Verifier 1 also found a process-death window that needs no fault.
- Verifier 2 used a real ENOSPC. When the token write fails too, permanence needs a later fetch in the same process (reproduced), and a relaunch before that heals (reproduced). A near-full disk with a large batch makes the loss immediate.

I re-read every cited line at b5c20e4 and ran nothing.

Not verified:
- whether CloudKit's async fetch honours task cancellation, which sets how wide the shutdown window is;
- the process-death and NSFileProtectionComplete triggers;
- how often ENOSPC happens on iOS devices. iOS purges purgeable space first, and the runs were on macOS APFS.

Not documented: README.md:237 claims no known correctness defect. Rated high rather than critical: the consequence is critical-class, but the trigger is uncommon.

<a id="a4"></a>
### A4 · medium · Overlapping refreshes apply in the order they finish, so a stalled older resolution can undo a subscription just bought (or a refund) until the next resolution

**Verdict.** Confirmed, narrower than reported. **Fix group:** G3. **Status:** open.

**Where**

- Sources/PaywallCore/GateEngine+Store.swift:9-39: `refresh`. It reads at :13, awaits at :21 and then applies unconditionally at :25-31 (`setEntitlement` :28, snapshot :30, `armExpiryTimer` :31). The only guards are the `isTerminated` checks at :10 and :24.
- GateEngine+Store.swift:76-79: `armExpiryTimer` cancels the existing timer first. A nil expiry leaves no timer.
- GateEngine+Store.swift:212-234: `purchase` calls `refresh(.purchase)` at :228. Nothing re-resolves after that.
- Sources/PaywallCore/GateEngine.swift:542-549: `setEntitlement` compares values, not age. `lastResolution` is declared at :178 and written at GateEngine+Store.swift:26, but never read.
- Callers:
  - GateEngine.swift:298 (launch)
  - GateEngine+Store.swift:87 (expiry), :122 (`handle`), :270 (`restore`), :279 (`didBecomeActive`)
  - Sources/PaywallKit/Paywall.swift:435 (`refresh`); `start` runs in a Task nobody awaits (:197-200)
  - Sources/PaywallKit/PaywallSignals.swift:217-220 (scene becomes active), installed at :48 and :88 and at PaywallServiceProvider.swift:117
  - Debug-only: PaywallSimulator.swift:99, :216
- Sources/PaywallKit/StoreKit2Client.swift:38-55: `AppTransaction.shared` (:41) is the only source of a stall on iOS 16+.
- Docs it contradicts: GateEngine.swift:47-48, HANDBOOK.md:311, README.md:237.

**Defect**

`refresh(cause:)` reads `currentEntitlements()` (GateEngine+Store.swift:13) and suspends on `appTransaction()` (:21). It then always sets the entitlement, writes `entitlement.json` and re-arms or cancels the expiry timer (:25-31). Nothing orders overlapping resolutions, so the one that finishes last wins even when its read is older. The trigger is narrower than reported: the older resolution's one remaining call (`AppTransaction.shared`) must outlast a whole purchase plus the purchase's own two store calls, which takes a stall of several seconds. A refresh fired when the payment sheet is dismissed reads the landed transaction, so it is not the trigger. The same race also runs in reverse: a stalled older read that still shows paying can undo a refund's resolution.

**Failure scenario**

The most plausible case is the first launch after install on a slow network:
1. `start()` runs in a Task nobody awaits (Paywall.swift:197-198). Its `refresh(.launch)` reads no transactions, then stalls in a first `AppTransaction.shared` fetch.
2. The user buys from an onboarding paywall. `purchase` resolves `.subscribed`, and `.onPurchaseCompleted` dismisses the paywall.
3. The launch resolution resumes. The entitlement drops to `.free` (cause `.launch`), gates close and the paywall can reappear. `entitlement.json` says free and the expiry timer is cancelled.

Nothing re-resolves: an in-app purchase is not re-sent on `Transaction.updates`. The state heals at the next scene activation, launch, restore or update. StoreKit still holds the purchase, and no credits are lost.

Mirror case: an older read showing paying resumes after a refund's `handle` and restores paid access until the next resolution.

**Evidence**

Code (re-read at b5c20e4):
- GateEngine+Store.swift:13 `transactions = try await store.currentEntitlements()`, then :21 `if let fresh = try? await store.appTransaction()`, then :28 `setEntitlement(resolution.entitlement, cause: cause)`, :30 `saveEntitlementSnapshot`, :31 `armExpiryTimer(resolution.expiresAt)`. A nil expiry cancels the timer and arms none (:77-79).
- The only guards are `isTerminated` (:10, :24). `setEntitlement` returns early only when the value is equal (GateEngine.swift:543). `lastResolution` is never compared.
- `runningSync` (:331-342) serialises sync only.
- `purchase` does finish, emit, pull, sync and storefront after :228, but no resolve.
- StoreKit2Client methods are `@concurrent` (StoreKit2Client.swift:18-55), so both awaits release the main actor.
- FakeStore.purchase does not broadcast (FakeStore.swift:148-175). That matches Apple's `Transaction.updates` documentation.

Reproduction (verifier 2, `swift test` at b5c20e4 in an isolated build; I ran nothing):
- probe10: `PROBE10 outcome=purchased(transactionID: 1001) afterPurchase=true afterStaleRefresh=free storeHas=["pro.monthly"]`.
- With a simulated 600 ms payment sheet, a 0 or 200 ms stall ends paying. A 1500 ms stall ends `final=free snapshotPaying=false expiryArmed=false`.
- A refresh fired at dismissal with a 1 s stall ends paying.
- Refund mirror: `before=true afterRefund=false final=true`.
- Deterministic latch test: `V2A4-LATCH final=false snapshot=Optional(PaywallCore.Entitlement.free) expiryArmed=false`.

Not documented: README.md:237 says there is no known correctness defect. HANDBOOK.md:311 and GateEngine.swift:47-48 promise that the entitlement is already updated when `.onPurchaseCompleted` runs.

**Fix direction**

Use a generation stamp, not serialisation:
- Increment a main-actor `resolutionGeneration` immediately before `store.currentEntitlements()` (GateEngine+Store.swift:13).
- After the last await that feeds the resolution (today :21, plus any await added by A3 or A5), run the synchronous block :25-31 (resolve, `lastResolution`, `recordGrandfather`, `setEntitlement`, `saveEntitlementSnapshot`, `armExpiryTimer`) only if `generation > lastAppliedGeneration`, then record it.
- Compare against the last applied stamp, not the last started one, so a newer resolution that returns at :14-17 or :24 does not block an older one.
- The check and the apply must stay synchronous, with no await between them.

What can stay as it is:
- The revocation scan (:33-37) and `reevaluateSessions()` (:38) can still run for a dropped resolution. They are idempotent and one-way.
- Credits are written before refresh (:119-121, :225-227), so nothing changes in the ledger, the persisted format or the public API.
- The `simulateEntitlement` writer (GateEngine.swift:688, DEBUG-only SPI) can stay outside the ordering.

`bind(fresh)` (:22) runs before the check. If a dropped resolution bound a different app transaction from the one the applied resolution saw, re-resolve once, because the grandfather rule reads `resolverInput`. Otherwise a grandfathered entitlement waits until the next resolution.

Don't copy the `syncNow` serialisation pattern. It would make `purchase` (and so `.onPurchaseCompleted`) and `handle`'s `finish()` wait behind a launch resolution stuck in `AppTransaction.shared`, which is exactly the case that makes this race reachable. A coalesced rerun would also have to publish the right cause (`.purchase`, `.revoked` or `.update`, bridged as `.paywallEntitlementChanged`), and `shutdown()` would have to drop it.

The fix must cover both directions: a stale free read after a purchase, and a stale paying read after a refund. Causes must not change when nothing overlaps.

**Regression test (the finding is fixed when this passes)**

Put a new `@Suite("Resolution ordering", .serialized) @MainActor` in PaywallCoreTests, with `@testable import PaywallCore`.

Store stand-in: a test-local `actor LatchedStore: StoreClient` that forwards to `FakeStore(products: products, now: { await clock.now })`. `holdNext()` makes the next `appTransaction()` wait on a CheckedContinuation; it also has `isHolding` and `release()`. Use no sleeps.

1. Purchase:
   - Call `start()` and `holdNext()`, then `older = Task { await engine.refresh(cause: .foreground) }`, and wait for `isHolding`.
   - Buy `pro.monthly` inside a Task and `#expect(await eventually { engine.entitlement.isPaying })` before releasing, so a serialising fix fails instead of hanging.
   - Release and await both tasks.
   - Expect `.purchased(transactionID: 1001)`, `isPaying`, `PaywallFiles(directory:).entitlementSnapshot(now:)?.isPaying == true` and `expiryTask != nil`, and no `.entitlementChanged(to: .free)` through `onEvent` after the purchase's change.
2. Refund mirror:
   - Start subscribed with transaction 77, hold, and start the older refresh.
   - Call `fake.refund(77, at:, deliver: false)` and then `engine.handle(revoked)`, and release.
   - Expect not paying, a snapshot that is not paying, and `expiryTask == nil`.
3. Repeat test 1 with the hold on `start()`'s launch resolution.

All three fail at b5c20e4.

**Related findings**

- A3 (grace period resolves free): its fix may add an await inside `refresh`, such as one reading renewal or grace info. The generation check has to sit after the last await.
- A5 (shut-down engine keeps writing): it adds `isShutDown` checks after every await in `refresh`, `start` and `purchase`, at the same place this fix touches. Land them together, or apply A4 on top of A5 and keep one guard block just before the synchronous apply.
- B14: the real `currentEntitlements()` never throws, so a newer resolution that fails is a fake-only case, but keep the last-applied rule anyway.

There is no other ordering constraint.

**Verification**

Reported by reviewer A as high. Verifier 1 (code trace): confirmed, narrower than reported, medium. Verifier 2 (reachability and reproduction): confirmed, narrower than reported, medium; reachable in production: yes, with preconditions. Judge: confirmed, narrower than reported, medium.

Both verifiers independently returned partly_confirmed and medium. I re-read every cited line at b5c20e4 and agree; all citations are correct. I added the missing callers: restore :270, Paywall.refresh :435, PaywallSignals :48, and the simulator. The two differ only in emphasis. Verifier 1 argued that a refresh fired by the sheet's dismissal usually heals the state. Verifier 2 measured that such a refresh reads the landed transaction, and that a 200 ms stall stops reproducing once the purchase takes 600 ms.

I downgraded it from high: StoreKit at normal speed cannot invert the order, and the race needs a multi-second `AppTransaction.shared` stall. That needs iOS 16 or later; on iOS 15 the receipt path is local (AppleReceiptVerifier.swift:130).

Unverified (device or service only):
- How long a first `AppTransaction.shared` fetch can stall in production.
- Whether StoreKit coalesces concurrent calls. If it does, the purchase's call cannot finish first and the outcome is benign.
- Whether the transaction lands before or after `scenePhase` returns to `.active` when the sheet is dismissed. The only source is one anecdotal StoreKit 1 log.
- That an in-app purchase is never re-sent on `Transaction.updates`. This comes from Apple's documentation only.

<a id="a5"></a>
### A5 · medium · After a same-directory reconfigure, a shut-down engine still credits, journals and finishes work already in flight. The bought tokens stay hidden until relaunch, both chains fork, and the credit is lost if the successor compacted.

**Verdict.** Confirmed, narrower than reported. **Fix group:** G2. **Status:** open.

**Where**

- Sources/PaywallCore/GateEngine+Store.swift:212-242: `purchase` never checks the flag after `store.purchase` (:218). It credits (:225-227), refreshes (:228), finishes (:229), calls requestPull (:231) and returns .purchased (:234).
- Sources/PaywallCore/GateEngine.swift:553-554: `appendLedger` checks isTerminated only.
- GateEngine.swift:307-323: `shutdown` leaves the journal fd, the sessions and the AuditTrail live.
- GateEngine.swift:284-304: `start` checks only at :285. After :286 it starts listeners (:295-297), refreshes (:298) and grants welcome (:301).
- GateEngine.swift:600-601: `emit` checks isTerminated only.
- GateEngine.swift:212-213: the broken guarantee.
- GateEngine+Store.swift:
  - :9-39 `refresh`: checks at :10/:24 only. Writes through bind (:51-61), recordGrandfather (:63-74), :30 and revocations (:33-36).
  - :91-101: `applyPlanned` ignores a nil.
  - :117-125: `handle`.
  - :262-275: `restore`.
  - :105/:131/:286: listeners start unguarded.
- Sources/PaywallCore/Journal.swift:289-322: `rewrite` rebuilds from in-memory entries and renames over the log. Also :95-97 and :103-105.
- Sources/PaywallKit/Paywall.swift:
  - :208-224: teardown.
  - :152, :159-183: same directory, threshold 4096.
  - :406-411: the caller keeps the old engine.
- Tests/PaywallCoreTests/ReviewFixTests.swift:201-218: asserts the opposite contract.

**Defect**

`shutdown()` (GateEngine.swift:307-323) only sets `isShutDown` and cancels the stored tasks. Of the code that writes, only the checkpoint, sync, Keychain snapshot, expiry timer and storefront check the flag, so `appendLedger` (:554), `emit` (:601), `refresh`, `handle`, `purchase` and `restore` keep running after their awaits, and so does `start()` after `await repairAudit()`. When `Paywall.configure` replaces the engine on the same storage directory while one of these is suspended, the old engine:
- journals the credit through its own fd;
- rewrites the entitlement, app-transaction and account files;
- appends audit records to the shared audit.jsonl;
- calls `store.finish`.

The successor never re-reads the journal, so none of this reaches it, and a successor compaction in that session orphans or drops the late frame. The defect is narrower than reported in four ways:
- only a successor on the same directory is affected (`useSimulated` and passthrough are not);
- `merge` cannot be reached after shutdown;
- listeners started after shutdown go inert once the old engine is released;
- GateEngine.swift:651-652 and HANDBOOK.md:449 are the checkpoint rule, which the code honours (:657).

**Failure scenario**

1. While a `tokens.10` purchase is waiting on the payment sheet, the app's code calls `Paywall.shared.configure(productionConfig)` again, for example from a remote-config callback, or calls `provider.useProduction()` while it is already on production. Both configurations use the default Application Support/ztron.paywall.
2. The sheet succeeds. The old engine journals `credit:<id>` and calls `finish`, and the caller receives `.purchased`.
3. The facade's wallet, which mirrors the successor, stays the same until the next launch.
4. The late credit and the successor's next event share a `previousHash`. That is a permanent fork, and `verifyAuditChain()` reports it.
5. The old engine's late audit records also break the audit chain, even when the purchase was cancelled.

If more than 4096 events have accumulated since the last checkpoint and this session crossed that line, permanent loss follows (more than 4096 upload markers works the same way). The successor's `start()` checkpoint has already renamed over ledger.log, so the credit goes into the unlinked inode. The pack is finished and gone for good.

A reconfigure during the first engine's `start()` writes `grant:welcome`, grandfather grants and file snapshots in the same way. These are deduped by id, but they break the chain.

**Evidence**

Code at b5c20e4:
- `guard !isTerminated, !ledger.contains(id) else { return nil }` (GateEngine.swift:554).
- `refresh` and `handle` check only `!isTerminated` (GateEngine+Store.swift:10, :24, :118, :123).
- `purchase` has no check between `store.purchase` (:218) and the credit (:225-227), `finish` (:229) and `.purchased` (:234).
- `start()` checks the flag only at GateEngine.swift:285.
- The journal fd is closed only in `deinit` (Journal.swift:103-105).
- `teardown` shuts the engine down, then `configure` opens a new Journal on the same default directory (Paywall.swift:152, :178-183). The caller still holds the old engine (Paywall.swift:409-410).
- The successor's `rewrite` encodes its own in-memory `entries` and renames over ledger.log (Journal.swift:289-322).
- Nothing recovers the credit: `planRevocations` replays revocations only (CreditReconciler.swift:38-53).
- A fork is permanent (Ledger.swift:257-260) and only diagnostic (Paywall+Audit.swift:18).
- Callers of `merge`: only GateEngine+Store.swift:356, after the guard at :355.

Reproduction was done by the verifiers. This judge did not build or run anything.
- Reviewer A's probes 5, 6 and 11 reproduce byte for byte. They are synthetic: they call `old.handle` directly, and probe5 uses threshold 2.
- Verifier 2 ran a probe through the facade:
  - Setup: `Paywall.configure` called twice, threshold 4096, F_FULLFSYNC, default sinks. Only StoreKit is faked, by a FakeStore wrapper that holds the purchase until released, like the sheet.
  - Output: `A5V2-COMPACT ... successorCheckpointed=true outcome=purchased(transactionID: 1001) finished=[1001] oldEngineWallet=4105 facadeWalletAfterPurchase=4095 nextLaunchBalance=4095 nextLaunchHasCredit=false`.
  - Short history: `facadeWalletAfterPurchase=5 ... nextLaunchBalance=14 brokenLedgerLink=debit:...`.
  - Controls: a cancelled purchase breaks only the audit chain; with nothing in flight, neither chain breaks.
  - The probe was deleted afterwards and the tree left clean.

**Fix direction**

Make `shutdown()` a hard stop for every durable side effect, and hand a late purchase to the live engine.

1. After every await, check `isShutDown` (together with `isTerminated`) before any journal append, file write, audit emit or `store.finish`. This covers:
   - `start()` (GateEngine.swift:286-303), including `grantWelcomeIfNew`;
   - `refresh`, including `bind` and `recordGrandfather` (GateEngine+Store.swift:13-36);
   - `handle` (:122-124), `purchase` (:218-233) and `restore` (:265-274);
   - `appendLedger` (GateEngine.swift:554).

   Start no listener after shutdown (GateEngine+Store.swift:105, 131, 286), and skip `requestPull` after it.
2. Do not guard `appendLedger` on its own. `applyPlanned` ignores a nil (GateEngine+Store.swift:93) and its callers still finish, so a late credit would become a purchase that is finished but never credited. Finish only when every planned credit id is in the ledger, which is A2's rule.
3. A purchase that returns after shutdown must neither credit nor finish on the old engine:
   - Return the transaction to the facade, which forwards it to the current engine's `handle(_:)` (Paywall.swift:406-424). With no current production engine, leave the transaction unfinished.
   - A `Transaction.unfinished` scan in `start()` alone is not enough, because the successor has already started.
   - Any new `StoreClient` requirement needs a default implementation, and FakeStore needs a model of unfinished transactions (FakeStore.swift:182 only records ids).
4. Close the journal in `shutdown()`:
   - Add a closed flag and set `fd = -1`, because the successor's `open()` usually reuses the same descriptor number.
   - Make `rewrite` refuse once the journal is closed (Journal.swift:303-322).
5. Flush the old AuditTrail, then stop it. Clear `sessions`, or make `draw` fail closed after shutdown (coordinate with A8).
6. Rewrite ReviewFixTests.swift:201-218.

The persisted format does not change. Forks that already exist stay.

**Regression test (the finding is fixed when this passes)**

**Primary test.** Tests/PaywallKitTests/ServiceProviderTests.swift, suite "Service provider". Use an isolated `Paywall()`, never `Paywall.shared`, and macOS-14 APIs only.

Setup:
- A fresh directory seeded through the public Journal API: device.id plus 4096 chained grants.
- A production-shaped Configuration: default threshold and sinks, connectivity nil, no carrier, FakeClock.
- A StoreClient over FakeStore whose `purchase` suspends until the test releases it.

Steps:
1. configure, then waitUntilStarted.
2. Draw `.tokens(1)`.
3. Start `purchase(tokens.10)` and wait until the sheet is up.
4. Configure again with the same configuration, then waitUntilStarted.
5. Pin the precondition: `#require(engine.journal.checkpoint != nil)`.
6. Release the sheet and expect `.purchased(id)`.
7. Open a fresh facade on the directory, as the next launch.

Assertions:
- `ledger.contains("credit:\(id)") || !finished.contains(id)`.
- After the fix, both the live wallet and the next launch show 4105, and `verifyAuditChain() == (nil, nil)` after a successor draw.

Twins in the same suite: 5 seeded events, where the live wallet should reach 15 with intact chains; and a cancelled sheet.

**Secondary test.** RetentionTests, using `ShuttingDownSink`, `welcomeTokens: 100` and no sync. Expect nil `updatesTask`/`intentsTask`, no live store listeners, an empty journal and no entitlement.json.

**Related findings**

- **A2** (a credit that fails to write is still finished): same root cause. Land A2's rule (finish only when the credit is in the ledger) first, or in the same change. Without it, guarding `appendLedger` after shutdown turns a late credit into a purchase that is finished and never credited.
- **A8** (gated views keep sessions on the replaced engine): coordinate the two fixes. `shutdown`/`teardown` close the old engine's sessions, which removes the path where a late credit lets an old session draw. A8 then reopens the sessions on the successor.
- **A4** (a stale `refresh` overwrites a newer one): both fixes add after-await checks in `refresh`. One generation check that shutdown also bumps can serve both.
- **A12** (the audit repair runs before the launch resolution): moving the repair reorders `start()`, so the post-shutdown guards must stay correct in the new order. A12 makes the `start()` window shorter but does not remove it.

**Verification**

Reported by reviewer A as medium. Verifier 1 (code trace): confirmed, narrower than reported, medium. Verifier 2 (reachability and reproduction): confirmed, medium; reachable in production: yes, with preconditions. Judge: confirmed, narrower than reported, medium.

**How I resolved it.** Verifier 1 found the defect real but narrower: only a successor on the same directory is affected, the facade's threshold is fixed at 4096, and the listeners go inert. Verifier 2 confirmed it and reproduced the reported scenario through the facade with production settings. Their facts do not conflict. I re-read the code, and every mechanism holds. My verdict is partly_confirmed because:
- `use(_:)` triggers this only when the new configuration opens the same directory;
- `merge` cannot be reached after shutdown;
- the claim that listeners keep running is overstated;
- two of the three cited docs are the checkpoint rule, which the code honours.

Severity is medium. It needs a reconfigure from code onto the same directory while a purchase, `start()`, refresh or restore is in flight, and the HANDBOOK's release setup never does that. Permanent loss also needs a compaction in that same session.

**Unverified:**
- how real StoreKit behaves with several `Transaction.updates` listeners;
- whether a listener created mid-session receives transactions that are still unfinished;
- on-device timing;
- a possible trigger where an app holds the provider in a per-window root view, so a new iPad window reconfigures;
- the draw after shutdown through sessions left on the old engine, which is traced in code only.

I did not rebuild or re-run the probes.

<a id="a7"></a>
### A7 · medium · A dropped or truncated ledger.log is never refilled from CloudKit: PaywallCloudSync's change token outlives the drop, so the recovery HANDBOOK promises does not happen

**Verdict.** Confirmed. **Fix group:** G1. **Status:** open.

**Where**

- Sources/PaywallCloudSync/PaywallCloudSync.swift:34: the token is read from its file at init. :39 and :42: the production init stores it at Application Support/ztron.paywall/cloudkit.token. :53: fetch since the token. :59-63: the token is persisted after every answered pull.
- Sources/PaywallCore/Journal.swift:111-124: load(), truncating at :122. :137-155: decodeFrames stops at the first bad frame (:146, :148-150).
- Sources/PaywallCore/GateEngine.swift:273-275: a drop is only logged. :288-293: snapshot adoption. :584-587: grant:welcome.
- Sources/PaywallCore/LedgerSync.swift:5-18: no cursor or reset hook.
- Sources/PaywallCloudSync/CloudKitDatabase.swift:143-153: restarts from nil only on server expiry or zone loss.
- Sources/PaywallCore/GateEngine+Store.swift:389-397 (settleBaseline) and :399-406 (snapshot written with lastEventID nil, as in A1).
- Sources/PaywallCore/Ledger.swift:235-241 and :389 (strict checkpoint version).
- Sources/PaywallTesting/InMemory.swift:61: the fake's pull returns the whole cloud.
- Tests/PaywallCoreTests/RetentionTests.swift:195-218 and Tests/PaywallCoreTests/Support.swift:76-85.
- HANDBOOK.md:456-458: the false claim.

**Defect**

Journal.load() truncates ledger.log at the first frame that fails its CRC or does not decode. A bad first frame, or a checkpoint in a newer format, empties the file; a bad middle frame drops everything after it. PaywallCloudSync keeps its CloudKit change token in a separate file that survives the drop, and nothing resets it. Later pulls therefore return only records newer than the token, and the device never gets the uploaded history back, purchased credits included. HANDBOOK.md:456-458 says the snapshot and the carrier "restore the ledger as after a reinstall". RetentionTests:195 passes only because InMemoryLedgerSync.pull returns the whole cloud.

**Failure scenario**

Setup: facade defaults (PaywallCloudSync(), welcomeTokens 100). The history is grant:welcome (100), a 10-pack and a 3-token draw, a balance of 107. All three events are uploaded, and a later launch's pull moves cloudkit.token past them.

Damage: ledger.log frame 0 fails its CRC (flash corruption), or it is a checkpoint this build cannot decode (a downgrade after a format change).

- Launch N: the log is truncated to 0 bytes. The Keychain snapshot is adopted and the device shows 107, but persistSnapshot rewrites the snapshot with lastEventID nil, and the pull returns nothing.
- Launch N+1: the baseline is ignored and settled away, and a new local grant:welcome is written. The balance is 100, or 0 with welcomeTokens 0 as in probe9.

The pack and the draw are lost on this device while CloudKit still holds all three records. A corrupt middle frame drops the suffix silently instead: the surviving prefix keeps hasEvents true, so the snapshot is never adopted and is overwritten. The device heals only on a reinstall, a server-side changeTokenExpired, or a zone deletion.

**Evidence**

Code:
- Journal.swift:148-150: `guard CRC32.checksum(payload) == crc, let entry = try? decoder.decode(...) else { break }`. Journal.swift:122: `truncate(url.path, off_t(goodLength))`. The truncation is intended and tested (Tests/PaywallCoreTests/JournalTests.swift:50-62, :204-236).
- PaywallCloudSync.swift:34: `self.changeToken = tokenURL.flatMap { FileManager.default.contents(atPath: $0.path) }`. :53 calls `database.fetchChanges(since: changeToken)`, and :59-63 persist the new token.
- Nothing resets the token. LedgerSync.swift:5-18 has no reset hook, GateEngine.swift:273-275 only logs the drop, and CloudKitDatabase.swift:143-153 restarts from nil only on changeTokenExpired or zone loss.
- The fake hides the gap: InMemory.swift:61 is `pull() { try await cloud.all() }`, and Support.swift:76-85 reuses that carrier across the relaunch.
- The snapshot lasts one launch. GateEngine+Store.swift:401-403 writes `lastEventID: ledger.lastEventID` (nil), Ledger.swift:237 then ignores it, and the `?? true` at :391 settles it away.
- StoreKit does not heal it: CreditReconciler.swift:38-40 replays revoked packs only.

Reproduction: verifier 2 ran these; I ran nothing, as this is a read-only judge.
- Reviewer A's probe9 (`swift test --filter ReviewerAProbeCloudTests3`) uses the real GateEngine and PaywallCloudSync over InMemoryCloudDatabase and flips byte 12 of the log. It printed `PROBE9 cloudCount=2 recovered=7 recoveredEvents=0 nextLaunch=0 nextEvents=0`.
- Verifier 2's own suite (Appendix B) used welcomeTokens 100, the default 3,600 s interval and a fresh carrier for every launch:
  - frame-0 flip: `L3=107 L3events=[] L4=100 L4events=["grant:welcome"]`;
  - a valid-CRC checkpoint that does not decode: the same failure;
  - a flip in the middle (debit) frame: `L3=100`;
  - control, the same drop with cloudkit.token deleted: restores 107, which shows the surviving token is the cause.

The token semantics of InMemoryCloudDatabase (CloudDatabase.swift:64-70) match CloudKit's, as TestHost/TestHostTests/LiveCloudKitTests.swift:123-124 asserts.

**Fix direction**

Goal: after any truncation (head, middle or tail), the next pull must start from a cursor no newer than the surviving frames, and from nil after a head drop.

- **Preferred: an engine-owned cursor.** Append the cursor to the journal in the same `append(contentsOf:)` as the merged events. This also fixes A6. It needs:
  - Journal.rewrite (:289-327) to carry the latest cursor through compaction;
  - a cursor API on the public LedgerSync, such as pull(since:) returning a cursor or a commit step, with defaults for third-party carriers;
  - a migration that ignores the legacy cloudkit.token once and then deletes it. One full fetch is safe, because merge dedupes by id (GateEngine+Store.swift:366);
  - no cursor written after a failed merge or after shutdown.

  A new JournalEntry case is itself a format change, and older builds will drop the log from that frame on.
- **Generation-id alternative.** The id must change on every truncation and be durable before or with load()'s truncate (:122). Otherwise a kill before the first pull leaves a clean file next to the stale token.
- **Optional hardening.** Move an undecodable middle region aside instead of truncating the valid frames after it. This needs resync when the length field is corrupt, must keep torn-tail truncation (JournalTests.swift:27-48), and changes JournalTests.swift:50-62 and :204-236.
- **Chain fork.** device.id survives the drop (GateEngine.swift:707-714), and head(for:) restarts at genesis (Ledger.swift:229-231). Events written before the refetch therefore fork the device stream (Ledger.swift:67). Either refetch before writing, or rotate device.id on a drop.
- **Docs and fakes.** Correct HANDBOOK.md:456-458. Make InMemoryLedgerSync's cursor opt-in or keyed to the install directory: there are about 29 constructions, PaywallSimulator.swift:28 and :61 among them, and the reinstall tests reuse one instance.
- **Ordering.** The strict version check at Ledger.swift:389 would route every checkpointed install through this path after a future version bump. Land this fix first.

**Regression test (the finding is fixed when this passes)**

Location: Tests/PaywallCloudSyncTests/CloudSyncTests.swift. PaywallCoreTests cannot import the Darwin-only PaywallCloudSync.

Setup:
- Carrier: PaywallCloudSync(database: cloud, keychain: nil, tokenURL: dir/cloudkit.token) with the default interval, built fresh for each launch, with the snapshot in a SharedSnapshotItem. The existing SharedKeychainCarrier passes no tokenURL, so it cannot be reused as is.
- Settings: welcomeTokens 100.
- Launch 1: start, syncNow, handle(.tokenPack(id: 3, "tokens.10")), run(.tokens(3)), syncNow. Wait until the snapshot reads 107, then shut down.
- Launch 2: start, syncNow, shutdown. Assert that the persisted cursor is past all 3 records (at b5c20e4 the token file reads "3") and that cloud.count == 3.

Damage, as a parameterized test:
- (a) flip a byte in frame 0;
- (b) compactionThreshold 0, with frame 0 replaced by a checkpoint carrying "version":2, re-framed with a valid CRC32;
- (c) flip a byte in the middle debit frame.

Run each case twice: as is, and with an extra launch that only calls init and shutdown (the truncation) before the first pull.

Assertions:
- After the next launch's syncNow, ledger.events holds all 3 ids and the balance is 107.
- The launch after that also shows 107.
- The ledger holds exactly one grant:welcome, equal to the cloud's copy.
- cloud.count == 3.

Assert the events, not only the balance, so an A1-only fix fails the test.

**Related findings**

- **A6** (the token is persisted inside pull() before the merge is durable). It has the same root, a carrier-owned cursor that does not follow the journal. Fix A6 and A7 together with an engine-owned cursor stored in the journal.
- **A1** (the snapshot is rewritten with lastEventID nil, so the Keychain fallback lasts one launch). A1 amplifies A7 but is fixed independently. Fixing A1 alone must not make A7's test pass.
- **Ordering:** fix A7 together with, or before, A6's cursor change, and before any JournalEntry or checkpoint format bump (Ledger.swift:389). Each such bump creates a downgrade trigger for this drop path.

**Verification**

Reported by reviewer A as medium. Verifier 1 (code trace): confirmed, medium. Verifier 2 (reachability and reproduction): confirmed, medium; reachable in production: yes, with preconditions. Judge: confirmed, medium.

- **Agreement.** Both verifiers confirmed independently (verifier 1 by code trace, verifier 2 by reproduction), and both rated it medium, so there was no disagreement to resolve.
- **My own read.** I re-read the decisive lines at b5c20e4: Journal.swift:116-123 and :137-155, PaywallCloudSync.swift:22, :34, :53 and :59-63, CloudKitDatabase.swift:143-153, GateEngine+Store.swift:389-406, Ledger.swift:235-241 and :389, InMemory.swift:61. Nothing resets the token or refetches after a drop.
- **Corrections folded in:**
  - load() spans :111-124.
  - probe9 corrupts an event frame, not a checkpoint; verifier 2 reproduced the checkpoint case.
  - "0" holds only with welcomeTokens 0. The facade default yields a new local 100 grant.
  - "Never" means until a reinstall, a server-side token expiry or a zone deletion.
  - probe9's balance-only assertion would pass after an A1-only fix.
- **Severity.** The consequence is critical-class, but at b5c20e4 only storage corruption or a downgrade across a future format can trigger it; torn tails cannot.
- **Unverified:**
  - real CloudKit behaviour: Apple's docs and LiveCloudKitTests:123-124 cover it, but I did not run that test;
  - whether TestFlight downgrades keep app data;
  - real corruption rates.

I ran nothing.

<a id="a8"></a>
### A8 · medium · Reconfiguring the facade (provider use*, a passthrough flip, simulator reset) orphans .paywallGated views on screen: they keep their old decision until they disappear

**Verdict.** Confirmed. **Fix group:** G2. **Status:** open.

**Where**

- Sources/PaywallKit/Paywall.swift:208-224: `teardown` shuts the engine down and never drops or migrates view sessions.
- Sources/PaywallKit/Paywall.swift:133-201: `configure` reopens nothing. Its early exits are :136-145 (passthrough), :147-151 (invalid catalog) and :184-188 (journal failure).
- Sources/PaywallKit/Paywall.swift:376-384: with no engine or under passthrough, a fixed state is returned and `onChange` is dropped (:378).
- Sources/PaywallKit/Paywall.swift:388: `closeSession` goes to the current engine.
- Sources/PaywallKit/PaywallGated.swift:150-165: `guard !isOpen`, and the model keeps no open parameters.
- Sources/PaywallKit/PaywallGated.swift:201-209: the only open triggers are onAppear and presence true.
- Sources/PaywallCore/GateEngine.swift:183, :403: sessions belong to one engine.
- Sources/PaywallCore/GateEngine.swift:307-323: `shutdown` keeps sessions.
- Sources/PaywallCore/GateEngine.swift:492: `onChange` fires only after the first state.
- Sources/PaywallKit/PaywallServiceProvider.swift:65-72 and Sources/PaywallSimulator/PaywallSimulator.swift:185-188: these reconfigure at runtime.

**Defect**

A view session lives only in the GateEngine that opened it. Under passthrough or with no engine it lives nowhere, and `onChange` is discarded. `Paywall.configure` tears the old engine down and builds a new one, but never drops or reopens the live `GateSessionModel`s. A model reopens only on appear or when presence turns true. So every `.paywallGated` view on screen keeps its previous decision and stops following entitlement, wallet, lease, refund and expiry changes until it next disappears and reappears. That contradicts README.md:141 and PaywallGated.swift:100-101 ("A refund or an expiry while on screen flips the view live").

**Failure scenario**

1. Passthrough to live. HANDBOOK.md:124 and Paywall.swift:62 say to flip passthrough "by calling `configure` again". A `.tokens(1)` `.deductNow` view that opened as `.open(.free)` stays rendered with an empty wallet and no debit. A commit through `gate.withPaywall` inside it is blocked, because the new engine decides it again.
2. Live to `provider.use(.fake…)`, or live to live with `useProduction(updated)`. A `.paid` view that was denied stays locked even after the user buys lifetime on the new engine.
3. Live to passthrough. Denied views stay denied although `canPass` is true.
4. Debug menu (`useSimulated`, `PaywallSimulator.reset()`). The gates underneath show stale decisions, which misleads QA.

In every case the view heals at its next disappear and appear. Users cannot trigger the reconfigure themselves. Nothing is persisted and no credits are lost.

**Evidence**

Code at b5c20e4, re-read by the judge:
- Paywall.swift:208-224: `teardown` calls `engine?.shutdown(); ... engine = nil` and nothing touches sessions.
- Paywall.swift:378: `return GateSessionState(holder: holder, level: level, source: source, scope: scope, decision: .open(.free))`. `onChange` is never stored.
- PaywallGated.swift:151 `guard !isOpen else { return }`. :201-209 opens only from `.onAppear` (no presence) or `onReceive(presence) true`. :180 `var paywall = Paywall.active` is not observed. Sources contain no `.id(`, and the documented root (HANDBOOK.md:70-88) adds none.
- GateEngine.swift:307-323: `shutdown` leaves `sessions`. :492 `if previous != nil { session.onChange?(state) }`.
- GateEngine+Draw.swift:66-100: `begin` decides afresh. This is why `.reserve` commits do not leak.

Reproduction (run by verifier 2; the judge ran nothing):
- Reviewer A's probe12 (Tests/PaywallKitTests/ReviewerAProbeKitTests.swift, Appendix A) printed `PROBE12 firstState=open(PaywallCore.GateOpenMode.free) entitlement=free wallet=0 engineKnowsHolder=false onChangeCalls=0 freshEvaluation=false`, and its expectation failed.
- Verifier 2 hosted real `.paywallGated` views in an NSHostingController under `.paywallProvider`, with an isolated facade and the public `useProduction`/`use(.fake)`. A copy is at Appendix B (`Tests/PaywallKitTests/Verifier2A8ProbeTests.swift`). Results:
  - Passthrough to live, `.deductNow`: content stays, balance=0, engineSessions=0, commitInside=blocked(insufficientTokens).
  - Live to `use(.fake)` with lifetime: still denied, newEngineSessions=0, oldEngineSessions=1.
  - Live to live, then a purchase: still denied. The same purchase without the reconfigure opens the view.
  - Hiding and showing the view again re-evaluates it correctly.
  - Controls on a single engine flip the view, so the stale results are not a harness artifact.

**Fix direction**

- The facade must know which view sessions are live. Track them at `Paywall.openSession`/`closeSession` (holder mapped to level, policy, source, scope and `onChange`), including the passthrough and no-engine branches (:376-384), which drop `onChange` today. Tracking at this level also lets probe12 work as a test. A registry inside `GateSessionModel` alone would need tests that go through hosted views. Only sessions that are still open get reopened, so UIKit views closed by presence stay closed.
- On every exit of `configure` (the new engine, plus :136-145, :147-151 and :184-188), re-evaluate each registered session and deliver the result through `onChange` yourself. `engine.openSession` returns the first state without calling `onChange` (GateEngine.swift:492).
- In `teardown`, drop the old engine's sessions, holds and pins silently, or clear their `onChange`. Do not call `closeSession` for each holder:
  - It runs `reevaluateSessions` (GateEngine.swift:422), which can `draw` (no isShutDown guard, GateEngine+Draw.swift:112-137) into the old journal.
  - It emits through the unguarded `emit` (GateEngine.swift:600-601).
  - Both break GateEngine.swift:650-652: "Nothing is written to the journal after `shutdown()`".
  - Dropping the sessions also stops an in-flight old `refresh` (it only checks isTerminated, GateEngine+Store.swift:9-39) from pushing the dead engine's decision.
- A `.deductNow` view that already drew must stay drawn: re-pin its lease before evaluating. Pins live in memory only (LeaseTable.swift:3-4), so once `leaseUntil` has passed, a reopen on the same journal would draw a second debit or close content the user paid for. That breaks HANDBOOK.md:227-229.
- Choose on purpose whether a passthrough-to-live flip draws, closes, or lets the current appearance finish for an open `.deductNow` view, and test that choice.
- Avoid a burst of `.gateDenied(.entitlementUnavailable)` events, and the paywall sheet they would trigger, when reopening on a fresh directory before `start()` resolves (GateEngine.swift:263, :348).

**Regression test (the finding is fixed when this passes)**

Put these in PaywallKitTests with isolated facades only. Do not configure Paywall.shared there, and use macOS-14 APIs only.
- Host the views with the `show`/`pump` helpers in ServiceProviderTests.swift:31-60, or with the pattern in FacadeEdgeTests.swift:95-146.
- Build inside `Paywall.$override.withValue(paywall)` or through `PaywallServiceProvider(service, paywall:)`.
- Base configuration: FakeStore, FakeClock, a temp directory, welcomeTokens 0, includesDefaultAudit false, connectivity nil.
- Count onAppear and onDisappear on both the content and the denied view.

Tests:
1. PassthroughTests `flipping_passthrough_off_re_evaluates_gated_views_on_screen`: start in passthrough with a `.tokens(1)` `.deductNow` view, then configure live, wait, pump. Expect the denied view shown, balance 0, and `engine.sessions.count == 1`. Variant with welcomeTokens 1: the view stays open and exactly one tokensConsumed is published.
2. `flipping_passthrough_on_opens_denied_views`: a denied `.paid` view opens after the switch to passthrough.
3. ServiceProviderTests: a denied `.paid` view opens after `use(.fake lifetime)`, and the old engine's sessions are empty.
4. ServiceProviderTests: after `useProduction` on the same journal and a purchase, the view opens.
5. ServiceProviderTests: a drawn `.deductNow` view survives a `useProduction` on the same journal, with the clock advanced past `tolerance`, and no second debit is written.

**Related findings**

None identified. This interacts with any finding about GateEngine work that continues after `shutdown()`: `refresh` (GateEngine+Store.swift:9-39), `emit` (GateEngine.swift:600-601) and `draw` (GateEngine+Draw.swift:112-137) have no isShutDown guard. If such a fix lands first, the teardown here can rely on it. Either way, the teardown here must drop the old sessions without going through those paths.

**Verification**

Reported by reviewer A as medium. Verifier 1 (code trace): confirmed, medium. Verifier 2 (reachability and reproduction): confirmed, medium; reachable in production: yes, with preconditions. Judge: confirmed, medium.

The two verifiers agreed on the mechanism, on reachability and on medium severity.

- **Resolved in favour of the finding.** README.md:119 ("Once at launch, before any gate") does not rule out the documented runtime flows: HANDBOOK.md:98-103 and :124, README.md:117, Paywall.swift:62 and :130-132, and `PaywallSimulator.reset()`.
- **Impact narrowed.** `.reserve` commits are decided again by the new engine, so the only free value is `.deductNow` or `.paid` content already on screen.
- **Citation corrections.** The no-engine branch is :376-384, not :372-386. A model opens once per appearance or presence spell, not once for its lifetime, because `close()` resets it (:161-165).
- **Reviewer's fix direction corrected.** Closing the old sessions in teardown is unsafe, and probe12 cannot verify a registry kept only on the model.
- **Unverified.** Behaviour on iOS: the probes ran on macOS 14 AppKit, although the modifier has no platform branches. The UIKit `PaywallHostingController` path was not exercised. Real StoreKit was not run, and the result does not depend on it.

<a id="a9"></a>
### A9 · medium · With the CloudKit carrier set and no iCloud account, every checkpoint keeps the whole unacknowledged history, so ledger.log and the main-actor decode at launch grow without bound

**Verdict.** Confirmed. **Fix group:** G1. **Status:** open.

**Where**

- Sources/PaywallCore/GateEngine.swift:659-660: the checkpoint keeps the outbox whenever `sync != nil`.
- Sources/PaywallCore/Journal.swift:289-299: `rewrite` keeps covered events that are not acknowledged (line 298).
- Sources/PaywallCore/GateEngine+Store.swift:350-353: only a successful push writes `.uploaded`.
- Sources/PaywallCloudSync/PaywallCloudSync.swift:44-47: push rethrows `noAccount`. Only pull catches it (:54-58).
- Sources/PaywallCloudSync/CloudKitDatabase.swift:87-89, 96: `.notAuthenticated` from `ensureZone` is mapped to `noAccount`.
- Sources/PaywallCore/Journal.swift:95: compaction at open counts markers only.
- Sources/PaywallCore/Journal.swift:111-118, 245-256, 260-270: the whole file is decoded at open, the outbox is scanned at every sync, and `ledgerEvents` includes the outbox.
- Sources/PaywallCore/GateEngine.swift:229, 253-256, 271: the open is synchronous on the @MainActor. The next checkpoint counts only events the last one does not cover.
- Sources/PaywallCore/Ledger.swift:175: covered events are skipped by id.
- Sources/PaywallKit/Paywall.swift:159-170, 181: `sync` is passed straight through. The threshold is the default 4096 (GateEngine.swift:123).
- HANDBOOK.md:41, 197-199, 426, 451-454, 458-460; README.md:68.

**Defect**

Compaction keeps the outbox whenever a carrier object exists (`keepingOutbox: sync != nil`). It does not check whether that carrier can ever acknowledge anything. On a device with no iCloud account, `PaywallCloudSync.push` rethrows `noAccount`, so no `.uploaded` marker is ever written. Every checkpoint therefore keeps every event it covers. The log becomes the checkpoint plus every event ever written, which is bigger than a log that was never checkpointed. `GateEngine.init` decodes all of it synchronously on the main actor at every launch.

The report says the journal "never compacts". That is wrong: it does checkpoint, but it drops nothing.

There are further costs from the same cause:
- Each sync scans the whole outbox on the main actor, then re-encodes it on the carrier actor before failing.
- A later sign-in uploads everything but writes only one marker, so the acknowledged events stay in the log until there are more than 4096 markers or more than 4096 new events.

Ledger, credit and entitlement state stay correct.

**Failure scenario**

1. The app sets `configuration.sync = PaywallCloudSync()`, as README.md:68 and HANDBOOK.md:41 recommend.
2. A user with no iCloud account builds up more than 4096 ledger events on one install: heavy token use (debits, refunds, credits, grants).
3. From the next launch on, at 20,000 events, `ledger.log` is 8.5 MB, against 2.2 MB with an account or with no carrier.
4. The engine open, synchronous on the main actor before the first frame, takes a median of about 713 ms on macOS. It takes about 163 ms from a checkpoint, and 587 ms for the uncheckpointed full replay, so this is worse than full replay.
5. The log grows by about 425 B per event, without limit.
6. Every sync, at most one per 30 s after draws, adds a main-actor scan of 14-49 ms and a re-encode of 0.2-0.5 s.

The balance is identical in every case. Below 4096 events nothing differs on disk.

**Evidence**

**Code (the judge re-read every decisive line at b5c20e4):**
- GateEngine.swift:660: `try journal.compact(checkpoint: candidate.checkpoint(), keepingOutbox: sync != nil)`.
- Journal.swift:298: `if let checkpoint, checkpoint.ids.contains(event.id), acknowledged || !keepingOutbox { continue }`. A covered event is dropped only if it is acknowledged or no outbox is kept.
- GateEngine+Store.swift:351-353: a marker is written only when `try? await sync.push(pending)` returns.
- PaywallCloudSync.swift:45-46 encodes every record and then calls `database.save`. CloudKitDatabase.swift:96 runs `ensureZone()`, which fails with `.notAuthenticated`, and :88 rethrows it as `noAccount`. Only `pull` catches that, at PaywallCloudSync.swift:54-58.
- Journal.swift:95: compaction at open needs more than 4096 markers, and this log has none.
- Journal.swift:116 decodes the whole file inside the synchronous @MainActor init (GateEngine.swift:253-256).
- Ledger.swift:175 makes covered events no-ops, so GateEngine.swift:271 rewrites the log only every 4096 new events, not at every launch.

**Reproduction.** The judge did not rerun anything (read-only task).
- Reviewer A's probe13 (`InMemoryCloudDatabase.setAccount(false)`, threshold 50) printed `PROBE13 withAccount entries=1 bytes=62158 ... | noAccount entries=302 bytes=175762`.
- Verifier 2 used the real `CloudKitDatabase` over a stub that throws `CKError(.notAuthenticated)`, at the production threshold of 4096. Source: Appendix B (`Tests/PaywallCloudSyncTests/Verifier2A9ProbeTests.swift`).
  - At 20,000 events with no account: 20,001 entries and 8,508 KB, against 1 entry and 2,280 KB with an account or no carrier.
  - Opens: median 713 ms with no account, 163 ms from a checkpoint, 587 ms for the full replay.
  - Balances were identical in all configurations.
  - Signing in later: `uploadedToCloud=5000 markers=1`, and the next launch still had `entries=5002`.
  - Entry counts and byte sizes are deterministic. The timings are noisy.

**Fix direction**

**Do not apply the no-carrier rule on `noAccount`.** That breaks the promise that a later sign-in uploads everything (HANDBOOK.md:197-199, PaywallCloudSync.swift:5-8). After a sign-in, a reinstall or a second device sees only the history uploaded after the checkpoint. `settleBaseline` drops the Keychain baseline as soon as the pull returns any event for the account (GateEngine+Store.swift:389-397), and finished consumables are never re-credited (CreditReconciler.swift:38-39). Purchased credits would be lost. It would also miss other persistent refusals, such as quotaExceeded records that are never acknowledged (CloudKitDatabase.swift:121-128).

**Do this instead:** keep the covered outbox out of what open decodes. Either put it in a side file, or have the checkpoint record the outbox's frame span so `load()` skips it. Read it lazily and off the main actor, only when a push runs.

**Constraints the fix must meet:**
1. Make the outbox durable before the compacted log is renamed. Re-pushing is harmless: record name = event id, and `serverRecordChanged` counts as acknowledged.
2. `pendingUpload` and the `.uploaded` markers must cover the outbox, and acknowledged ids must be pruned from it.
3. Never replay the outbox into the ledger at open.
4. Migrate b5c20e4 logs, where covered events that were never acknowledged sit behind the checkpoint.
5. A corrupt checkpoint drops the main log (HANDBOOK.md:456-458). Decide what happens to the outbox then, consistently with A7.
6. Stop re-encoding the outbox at every sync while the carrier refuses. Add an account or back-off signal to the public `LedgerSync` protocol, with a default implementation.
7. Compact once a large covered outbox is acknowledged. Count acknowledged ids, not markers, since one sync writes one marker.
8. The public `Journal.entries` changes shape: update RetentionTests.swift:105 and HANDBOOK.md:451-454.
9. The outbox still grows on disk while the user never signs in. List that under README's Known defects.

**Regression test (the finding is fixed when this passes)**

**Where:** Tests/PaywallCloudSyncTests/CloudSyncTests.swift, suite "Cloud sync". Use Swift Testing and isolated `GateEngine`s, not `Paywall.shared`. Only macOS 14 APIs are needed.

**Test:** `a_device_without_an_icloud_account_still_bounds_its_journal`.

**Setup:** an `InMemoryCloudDatabase` with `setAccount(false)` and one directory. Each launch builds `GateEngine(settings: .init(compactionThreshold: 50), clock: FakeClock(), store: FakeStore(), sync: PaywallCloudSync(database: cloud, keychain: nil, minimumPullInterval: 0, tokenURL: dir/cloudkit.token))`, then calls `start()` and `syncNow()`.

**Launches:**
1. `grant(tokens: 1000)`, then 300 `run(.tokens(1))` calls on distinct gates, then `shutdown()`.
2. `start()` writes the checkpoint.
3. Assert `checkpoint.eventCount == 301`, balance 700, and that `ledger.log` decodes at most the checkpoint plus 50 events. At b5c20e4 it decodes 302 entries; the control with `setAccount(true)` decodes 1.
4. `setAccount(true)`, then `syncNow()`. Assert `cloud.count == 301`.
5. The main log is still bounded and the outbox is empty.
6. Reinstall into a fresh directory from the cloud. The balance is 700.

**Also add:** a migration test that loads a log in the b5c20e4 shape, and a test for a crash between the outbox write and the log rename.

**Related findings**

- **A7** (a dropped or corrupt journal is never restored): what happens to a separate outbox when a corrupt checkpoint drops the main log must agree with A7's restore semantics, so design the two together.
- **A5** (a shut-down engine keeps writing the journal its successor owns): any new outbox file must be covered by the same shutdown and close guard. Fix A5 first or in the same change.
- **A12** (launch-time audit decode) has the same theme, launch cost growing with history, but it is an independent code path with no ordering constraint.

**Verification**

Reported by reviewer A as medium. Verifier 1 (code trace): confirmed, medium. Verifier 2 (reachability and reproduction): confirmed, medium; reachable in production: yes, with preconditions. Judge: confirmed, medium.

Both verifiers confirmed the finding and rated it medium; verifier 2 put it at the low end. They did not disagree. The judge re-read every decisive line at b5c20e4 and all the citations hold.

Corrections to the report:
- "The journal never compacts" is wrong. It does checkpoint, but it drops nothing and the log grows.
- "Pays the full-replay open time" understates it. Verifier 2 measured it as worse than the full replay on macOS.
- The per-sync re-encode and the persistence after sign-in come from the same cause and were missing from the report.

Severity is medium: the trigger is narrow (the recommended carrier, no account for the whole history, and more than 4096 events on one install), and no state is wrong. But the growth has no bound, contradicts HANDBOOK.md:426, and is not listed in README's Known defects.

Still unverified:
- Device timings. The figures are macOS `swift test` runs plus HANDBOOK's simulator numbers.
- Which CKError a device without an account actually returns from `saveZone`. The conclusion holds for any push that throws.
- Full iCloud storage (quotaExceeded) and the per-app iCloud switch turned off, as further persistent triggers.
- How many devices have no iCloud account.

<a id="a11b6"></a>
### A11+B6 · medium · ReceiptClient never checks the field-5 device hash, so a planted stranger's paid-era receipt grandfathers the install (lasting on iOS 15, temporary on iOS 16+); the reason HANDBOOK.md:396-397 gives for skipping the check is wrong

**Verdict.** Confirmed, narrower than reported. **Fix group:** G4. **Status:** open.

**Where**

- Sources/PaywallKit/ReceiptClient.swift:35-40: `snapshot()` checks only the verifier and the bundle id. :43-57: `parse` reads fields 19, 18, 2 and 0, at :45-49.
- Sources/PaywallKit/AppleReceiptVerifier.swift:36-60: signature and chain, checked at the field-12 date (:44). No device check.
- Sources/PaywallKit/StoreKit2Client.swift:40-54: falls back to the receipt when AppTransaction throws or is `.unverified`. The fallback is documented at :11 and :36.
- Sources/PaywallCore/GateEngine+Store.swift:21-22: binds whatever the store returns. :51-60: `bind` switches `accountKey`. :71-73: the token grant is keyed by the current `accountKey`.
- Sources/PaywallCore/GateEngine.swift:259-261: the cached `account.key` and `app-transaction.json` are reloaded at init.
- Sources/PaywallCore/Ledger.swift:474-477: the balance counts only `unbound` plus the bound key.
- Sources/PaywallCore/EntitlementResolver.swift:44-61 and 119-123: `admits`, then `.lifetime(.grandfathered)`.
- HANDBOOK.md:396-397: the wrong rationale. HANDBOOK.md:383 and README.md:168: the receipt is described as "iOS 15" only.
- HANDBOOK.md:657-658: the receipt of an iOS app on a Mac is root-owned.
- Tests/PaywallKitTests/ReceiptClientTests.swift:412-415 and Scripts/make-receipt-fixtures.sh:73: neither the tests nor the fixtures carry field 4 or 5.

**Defect**

`ReceiptClient.snapshot()` accepts any Apple-signed receipt that names this bundle id. Neither it nor `AppleReceiptVerifier` reads field 4 or field 5, so a receipt is never bound to the device. That binding is step 5 of Apple's validation guide.

`StoreKit2Client.appTransaction()` uses this receipt in two cases:
- on iOS 15;
- on iOS 16+ and macOS 13+, whenever `AppTransaction.shared` throws or comes back `.unverified`.

So another buyer's genuine paid-era receipt passes `GrandfatheringPolicy.admits`. HANDBOOK.md:396-397 says the check "only matters against a user copying their own receipt between their own devices". That has it backwards: copying your own receipt is harmless, and replaying someone else's is the case the check exists to stop.

The effect is narrower than reported. On iOS 16+ and macOS 13+, the next verified AppTransaction rebinds the snapshot and the account key. That ends the lifetime, and the `.tokens` grant, which was written under the donor's key, stops counting. The effect lasts only:
- on the receipt-only path (iOS 15, or the iOS app on macOS 12);
- or while the store call fails at every resolution and the cached planted snapshot keeps being reused.

**Failure scenario**

**Preconditions**
- The host sets a `GrandfatheringPolicy`. That is the documented setup (HANDBOOK.md:37).
- The attacker has a genuine Production receipt for this bundle from a paid-era buyer. One leaked receipt serves everyone, indefinitely, because the chain is checked at the field-12 date.
- The attacker can write `Bundle.main.appStoreReceiptURL` on their own install. That takes a jailbreak, or sudo for the iOS app on an Apple-silicon Mac (HANDBOOK.md:657-658). It is not possible on stock iOS.

**What happens**
- **iOS 15** (the deployment floor, Package.swift:100) **or the iOS app on macOS 12:** every resolution yields `.lifetime(.grandfathered)` for as long as the file stays. With a `.tokens(n)` grant, it credits `grant:grandfathered:<donorKey>` instead.
- **iOS 16+ and macOS 13+:** it works only at resolutions where AppTransaction throws, and ends at the first one that verifies. That means a fresh install that has never fetched an AppTransaction, or possibly a signed-out account (unverified).

Honest users are unaffected, because their own receipt yields the same snapshot as their AppTransaction.

**Evidence**

**The fallback and the receipt check**
- Sources/PaywallKit/StoreKit2Client.swift:41-54: `if let result = try? await AppTransaction.shared, case .verified(let app) = result { … }`, then `return try receipt.snapshot()`. The fallback on throw is intended (:11, :36).
- ReceiptClient.swift:37-38 checks only three things: `verifier.isAuthentic(data)`, `parse`, and `parsed.bundleID != expectedBundleID`.

**What is read**
- `grep -rn 'fields\[' Sources` finds only ReceiptClient.swift:45-49 (fields 19, 18, 2, 0) and AppleReceiptVerifier.swift:44 (field 12).
- `identifierForVendor` occurs only at HANDBOOK.md:397, and Sources never uses `UIDevice`.
- `origin` is set at ReceiptClient.swift:56 but never read for a decision.

**Lines that bound the impact**
- GateEngine+Store.swift:21-22 binds whatever the store returns.
- `bind` sets `accountKey` (:55-58) before `grant(…, id: "grant:grandfathered:\(accountKey)")` (:71-72), which is appended under that key (GateEngine.swift:556).
- Ledger.swift:474-477 counts only `unbound` plus the bound key.
- GateEngine.swift:259-261 reloads `account.key` and `app-transaction.json`, and both persist when the store returns nil.

**The tests accept the replay**
- ReceiptClientTests.swift:413-415 accepts a production receipt copied to a temp path.
- The fixtures carry no field 4 or 5 (Scripts/make-receipt-fixtures.sh:73).

**Reproduction by verifier 2** (not kept; I did not re-run it)
- Inputs: the snapshot's ReceiptClient, AppleReceiptVerifier, StoreClient and EntitlementResolver (I diffed the copies: identical), a throwaway trust anchor, and a synthetic donor receipt whose field 5 is bound to another device's identifierForVendor.
- Output: `snapshot()` returned origin=receipt, version=116, env=production, and `admits` returned true. As controls, a tampered payload and another bundle id both returned nil.

**Not exercised:** real StoreKit AppTransaction behaviour, and writing into a real container.

**Fix direction**

1. **Where the check goes.** Check the binding in `ReceiptClient.snapshot()`, which serves both the iOS 15 path and the iOS 16+ fallback. Limiting it to "the iOS 15 path", as B6 words it, leaves the fallback open. Keep it out of `parse` and `AppleReceiptVerifier`, because the Mac App Store and production-receipt lanes call those.

2. **What the check is.** Accept only when `fields[5]` equals SHA-1 of: the 16 raw `uuid_t` bytes of identifierForVendor, then `fields[4]`, then `fields[2]`. `fields[n]` already holds the OCTET STRING contents, so field 2 is the UTF8String DER that the hash covers. Return nil when field 4 or 5 is missing.

3. **Injecting the identifier.** Add a defaulted init parameter so the API stays source-compatible, for example `deviceIdentifier: @Sendable () -> UUID?`. It defaults to `UIDevice.current.identifierForVendor` under `canImport(UIKit)` and to nil elsewhere. A nil identifier (before first unlock) returns nil, and `refresh` then keeps its cache instead of downgrading.

4. **iOS app on an Apple-silicon Mac.** Before failing closed there, confirm against a real Mac-installed receipt which identifier Apple hashes. Otherwise legitimate Mac users lose grandfathering.

5. **Planted state that survives the fix.** A cached receipt-origin `app-transaction.json` and the donor's `account.key` (GateEngine.swift:259-261) survive, because the store then returns nil. On load, re-validate cached receipt-origin snapshots with the same check, drop the ones that fail, and reset the key. B1's re-verification of `signedPayload` must include this check.

6. **Optional.** On `.unverified`, return nil instead of the receipt (keep the fallback on throw). Also, never let a receipt-origin snapshot replace a cached `.appTransaction` one. Reject the alternative of granting no tokens from receipt snapshots: it leaves `.lifetime` open and denies honest iOS 15 users.

7. **Docs.** Correct HANDBOOK.md:396-397, the heading at HANDBOOK.md:383, and README.md:168. Name `restorePurchases()` (HANDBOOK.md:303) as the way to recover from a receipt that does not match the device.

**Regression test (the finding is fixed when this passes)**

**Where:** target PaywallKitTests, file Tests/PaywallKitTests/ReceiptClientTests.swift. Keep the tests isolated (no `Paywall.shared`). Use only Foundation `UUID` and CryptoKit `Insecure.SHA1`, so they still build for macOS 14.

**Fixtures:** extend `payload()` in Scripts/make-receipt-fixtures.sh to write fields 4 and 5, computed for a fixed fixture identifierForVendor, in every accepted layout. Add receipt-other-device.der and receipt-no-device-hash.der, then regenerate.

**Receipt assertions**
- With the fixture identifier, the sha256, sha1 and attrs layouts each give a non-nil snapshot.
- Each of these gives nil: `{ UUID() }`, the other-device receipt, the no-hash receipt, and `{ nil }`.

**Existing tests to update**
- :122-133 (the synthetic receipts).
- ProductionReceiptTests at :412-415: the copied receipt is refused with a random UUID. Keep the parse and rule assertions.

**Engine test** (isolated harness)
- Seed a receipt-origin `app-transaction.json` built from receipt-other-device.der, plus its `account.key`, with `FakeStore(app: nil)`.
- Relaunch.
- Assert that the entitlement is not `.lifetime(.grandfathered)` and that no grandfathered grant counts.

**If `.unverified` handling changes:** test it through an extracted pure decision function, because SKTestSession cannot produce an unverified AppTransaction.

**Related findings**

- **Sources:** this entry merges A11 and B6.
- **B1** (unauthenticated `app-transaction.json` and `entitlement.json`) has the same write-access precondition and is the cheaper route at b5c20e4.
- **Ordering:** B1's fix, which re-verifies `signedPayload`, must reuse this device check and confirm that the cached fields match the payload. Otherwise a stranger's genuine receipt passes it. Land this check before B1's fix or together with it.
- **Shared step:** fix step 5 (dropping cached receipt-origin snapshots and resetting `account.key`) belongs to whichever of the two lands second.

**Verification**

Reported by reviewer A and B as low. Verifier 1 (code trace): confirmed, narrower than reported, low. Verifier 2 (reachability and reproduction): confirmed, medium; reachable in production: yes, with preconditions. Judge: confirmed, narrower than reported, medium.

**Where the verifiers agree.** Both agree on the substance: field 5 is never checked, the receipt fallback runs on throw and on `.unverified`, the HANDBOOK rationale is wrong, and the iOS 16+ effect heals at the next verified AppTransaction. I read the decisive lines myself and agree.

**Verdict.** I chose partly_confirmed because the reported trigger and impact hold only on the receipt-only path, or while AppTransaction keeps failing. That covers both the "permanent" grant or lifetime and the "launch offline, so it throws" trigger. StoreKit reportedly serves a cached AppTransaction offline.

**Severity.** Verifier 1's reasoning ("hardening, so low") contradicts the scale, which rates hardening medium. The check turns a no-code file drop into an attack that needs a code hook plus the donor's identifierForVendor. It is not high: the attacker needs root or a jailbreak plus a leaked receipt.

**Unverified:**
- whether AppTransaction.shared throws when offline once cached, or when the account is signed out;
- whether the Mac container is writable, given TCC on macOS 14+;
- which identifier Apple hashes for iOS apps on Apple-silicon Macs;
- the concatenation order, which verifier 2 quoted without re-fetching;
- whether a real receipt replays the same way, since the reproduction used a synthetic donor receipt.

**Citation corrections:**
- A11's "HANDBOOK:657" should be :657-658, and those lines show copying a receipt out, not writing one in.
- B6's "ReceiptClient.swift:43-56" should be :43-57.

<a id="b1"></a>
### B1 · medium · Unauthenticated app-transaction.json and entitlement.json are trusted as store answers: anyone who can write the container gets a grandfathered lifetime unlock while StoreKit yields no app transaction

**Verdict.** Confirmed, narrower than reported. **Fix group:** G4. **Status:** open.

**Where**

Sources/PaywallCore/GateEngine.swift:726-728 (PaywallFiles.load: plain JSON decode, no MAC or signature check); :735 (app-transaction.json loader); :260-261 (cached snapshot becomes `appTransaction` at init); :263 and :745-752 (entitlement.json becomes the initial entitlement); :347 (`.paying` opens `.paid` and `.tokens(n)` with no draw)
Sources/PaywallCore/GateEngine+Store.swift:19-23 (binds only a fresh store answer; the comment claims a re-check); :25 and :42-49 (in release the resolver input is the cached snapshot); :27 and :63-74 (token grant minted from the cached snapshot); :30 (launch resolution overwrites entitlement.json)
Sources/PaywallCore/EntitlementResolver.swift:44-61 (admits checks only environment, version, window and sentinel); :83-84 (claims store-only inputs)
Sources/PaywallCore/StoreClient.swift:74-75 (signedPayload is kept only for export; its only reader is Sources/PaywallKit/Paywall+Audit.swift:31)
Sources/PaywallKit/StoreKit2Client.swift:38-55 (returns nil when AppTransaction fails and the receipt is absent or unauthentic); :19-25 (currentEntitlements cannot throw)
Sources/PaywallKit/ReceiptClient.swift:35-40 (nil or a throw for a missing, unauthentic or malformed receipt)
Sources/PaywallKit/Paywall.swift:78 (default directory is in Application Support, which is backed up)
Sources/PaywallCore/Journal.swift:37, 137-155 (ledger.log is CRC-32 only; context for the token variant)
README.md:19-20, 222, 228 (the guarantees this contradicts)

**Defect**

PaywallFiles decodes app-transaction.json and entitlement.json as plain JSON, with no MAC or signature check (GateEngine.swift:726-728), and nothing re-verifies the stored signedPayload. On every refresh where the store client returns no app transaction, the cached snapshot is the resolver's input (GateEngine+Store.swift:21-25, 42-49). So a planted paid-era snapshot resolves to `.lifetime(.grandfathered)`, and with `grant: .tokens(n)` it mints a `grant:grandfathered:<accountKey>` event that nothing reverses. A planted entitlement.json opens `.paid` and `.tokens` gates (GateEngine.swift:263, 347) until the launch resolution overwrites it.

The defect is narrower than reported:
- It needs deliberate writes to the container plus StoreKit yielding nothing on every launch. No honest user can trigger it.
- The lifetime unlock heals at the first launch where AppTransaction or a valid receipt answers.
- The token variant gives nothing to an attacker who can already append grant frames to the CRC-only ledger.log.

**Failure scenario**

Setup: policy `lastPaidBuild: "116"`, paidWindow 1.6e9 to 1.72e9, `grant: .lifetime`. The user is a free-era customer (build 200, bought at 1.75e9) running the iOS build on an Apple-silicon Mac, or on a jailbroken device.

1. They write `{"bundleID":"…","environment":"production","origin":"receipt","originalAppVersion":"100","originalPurchaseDate":1700000000}` to Application Support/ztron.paywall/app-transaction.json.
2. They remove the root-owned StoreKit/receipt with sudo (HANDBOOK.md:657-658).
3. They launch while AppTransaction.shared throws (signed out, or offline with nothing cached).

StoreKit2Client.appTransaction returns nil and the resolver admits the file. `.paid` gates open at every launch and foreground for as long as StoreKit keeps failing. At the first launch where AppTransaction or a valid receipt answers, the engine rebinds and the user drops to `.free`. With `grant: .tokens(50)`, the 50 tokens stay.

On stock iOS, a backup edit can plant the file, but the App Store receipt heals it at the first launch unless the receipt is gone too.

**Evidence**

Code at b5c20e4, read by the judge:
- **No authentication on load.** GateEngine.swift:727 is `FileManager.default.contents(atPath: url(name).path).flatMap { try? CanonicalJSON.decoder().decode(type, from: $0) }`. At :260-261, `let cachedApp = files.appTransaction()` then `self.appTransaction = cachedApp`. At :263 the entitlement is taken from entitlement.json.
- **Only a fresh answer rebinds.** GateEngine+Store.swift:21-23 is `if let fresh = try? await store.appTransaction() { bind(fresh) }`. At :25 the resolver runs on `resolverInput`, which in release is `appTransaction` (:42-49).
- **The cached snapshot mints the grant.** :27 reaches :71-72, `grant(tokens: n, reason: "grandfathered", id: "grant:grandfathered:\(accountKey)")`, and nothing reverses it (CreditReconciler plans only credits and revocations, :91-101).
- **No other check.** `admits` checks only environment, numeric version, window and sentinel (EntitlementResolver.swift:44-61). signedPayload is "kept for `exportAudit()`" (StoreClient.swift:74) and read only at Paywall+Audit.swift:31.
- **When the client yields nil.** StoreKit2Client.swift:41-54 returns nil when AppTransaction throws or is unverified and the receipt is missing or unauthentic (ReceiptClient.swift:36-38). A malformed receipt throws, and `try?` turns that into nil. currentEntitlements cannot throw (StoreKit2Client.swift:19-25), so the launch resolution always overwrites entitlement.json (GateEngine+Store.swift:30).
- **The ledger is no better protected.** Journal.swift:137-155 checks CRC-32 only, and Ledger.swift:131-150 does not check the hash chain at load.
- **Offline trust is intended.** Trusting the cache offline is designed and tested: GateEngineTests.swift:374-390.

Reproduction: verifier 2 ran `swift test --filter VerifierB1RealityProbeTests` in an isolated build. The source is at Appendix B (`Tests/PaywallCoreTests/VerifierB1RealityProbeTests.swift`). All 6 probes passed on production code with FakeStore, and no test hooks were involved:
- p1 (forged launch): `lifetime(...grandfathered(originalAppVersion: "100")) paid=true`; healed: `free`, file rewritten to 200.
- p2 (store answers at the first launch): `free balance=0`.
- p3 (appTransaction throws): lifetime.
- p4 (tokens): 0, then 50, then 50 after healing.
- p5 (raw ledger frame): balance 1000, brokenLink=none.
- p6 (entitlement.json): `paid=true` at init, `free` after start.

Reviewer B's numbers match. The judge ran nothing.

**Fix direction**

Goal: nothing read from disk may on its own grant `.paid` or mint the grandfather grant, and honest offline grandfathering must keep working.

**1. Authenticate both caches.** Preferred approach: HMAC-SHA256 each file with a random per-install key kept in the Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), so an edited backup or container cannot forge a MAC.
- PaywallCore builds on Linux and `GateEngine.init` is public API. Inject an authenticator protocol, put the Keychain default in PaywallKit, and document what happens without one.
- Regenerate the key only on errSecItemNotFound. A transient error (errSecInteractionNotAllowed) must not rotate it, or every MAC is orphaned.
- On a MAC failure, drop the file. A dropped app-transaction.json means nil. A dropped entitlement.json means `.unknown`, the same state as a fresh install's first launch (fail-closed `.entitlementUnavailable` until start() resolves). Cover `entitlementSnapshotDate` (:754) too, and consider account.key (:718-724).
- Files written before the fix have no MAC. Never MAC one that has not been verified, because that launders a forgery. Either drop it, or re-verify a `.receipt` signedPayload with AppleReceiptVerifier and re-derive its fields from the verified payload.

Alternative: re-verify signedPayload on load.
- Re-derive every field from the verified payload.
- Bind the payload to the device (JWS deviceVerification, receipt field 5; see A11/B6).
- Verifier 1 says StoreKit cannot verify a stored JWS, so this route needs an ES256/x5c check to Apple Root CA G3.
- entitlement.json carries no payload and still needs a MAC.

**2. Restrict the token grant.** Mint `grant:grandfathered:` only when the admitting snapshot was bound in the same refresh (GateEngine+Store.swift:21-27). Keep the debug override working (AppReviewTests.swift:177-191).

**3. Decide the scope.** ledger.log is CRC-only, so a container writer can still mint tokens. Either authenticate the journal, which touches crash-critical files, the checkpoint format and synced events, or add a Known-limitations entry that scopes tamper resistance to `.paid`.

**4. Fix the docs.** Correct the comment at GateEngine+Store.swift:19-20, and README.md:19-20 and :222 if any trust in disk remains.

**Regression test (the finding is fixed when this passes)**

Where: PaywallCoreTests, suite "Gate engine" (Tests/PaywallCoreTests/GateEngineTests.swift), next to `grandfather_survives_offline_launch`. Use an isolated Harness and no Paywall.shared, with macOS-14 APIs only.

**Test 1: `forged_app_transaction_cache_grants_nothing_offline`**, parameterised over `.lifetime` and `.tokens(50)`.

Setup:
1. Policy: `lastPaidBuild: "116"`, window 1.6e9 to 1.72e9.
2. A Harness on `FakeStore(app:)` with a free-era snapshot: `originalAppVersion: "200"`, `originalPurchaseDate: 1.75e9`, `.production`. Call `start()`.
3. Overwrite app-transaction.json with the raw JSON `{"bundleID":"com.example.app","environment":"production","origin":"receipt","originalAppVersion":"100","originalPurchaseDate":1700000000}`.
4. Call `store.setApp(nil)`, then `relaunch()`, then `didBecomeActive()`.

Assertions:
- `.free` and `!canPass(.paid)`.
- No `.grandfathered` event in `h.events`.
- With tokens: balance 0 and no `grant:grandfathered:` id.
- After `setApp(real)` and a relaunch, the balance is still 0.

**Test 2:** write the raw entitlement.json `{"entitlement":{"lifetime":{"_0":{"purchase":{"transactionID":1}}}},"resolvedAt":1700000000}`. Expect `.unknown` and `!canPass(.paid)` before `start()`.

**Must keep passing:**
- `grandfather_survives_offline_launch`: a cache bound from a real store answer still grandfathers offline.
- `a_lapsed_subscription_snapshot_launches_as_free` (FailurePathTests.swift:221).

**If the fix uses an HMAC:**
- A transient Keychain error keeps the key.
- A legacy file without a MAC is never MAC'd.

**Related findings**

- **A11** (planting a genuine paid-era receipt, rated low) and **B6** (receipt field 5 / device binding not checked):
  - If B1 is fixed by re-verifying the payload, what remains is exactly A11's replay of a genuine payload. Device binding must then land with that fix or right after it.
  - An HMAC fix covers both ways of writing the container.
- **Any finding on ledger.log / journal authentication:** it subsumes B1's token variant. Decide the scope of B1 (only `.paid`, or tokens too) together with it.
- **Ordering:** no other constraint.

**Verification**

Reported by reviewer B as high. Verifier 1 (code trace): confirmed, medium. Verifier 2 (reachability and reproduction): confirmed, narrower than reported, medium; reachable in production: yes, with preconditions. Judge: confirmed, narrower than reported, medium.

**Where the verifiers stood:** verifier 1 said confirmed, medium; verifier 2 said partly_confirmed, medium. They agree on the mechanism.

**What the judge checked:** every cited line at b5c20e4, and they match. Two corrections:
- The assignment is GateEngine.swift:261; the load is at :260.
- The lapsed-snapshot test is in FailurePathTests.swift:221.

**Why partly_confirmed:** the report overstates reach and rates it high.
- The stock-iOS backup route heals at the first launch (probe p2).
- The "weaker access" claim still needs write access to the receipt.
- The token variant is subsumed by forging ledger.log (probe p5).

**Why it is not an accepted limitation:** README.md:228 shows device-owner tampering is in the threat model, and the defect contradicts README.md:19-20 and :222 and EntitlementResolver.swift:83-84.

**Why medium:** the trigger is deliberate tampering combined with StoreKit failing, with no honest-user path.

**Unverified (needs a real device):**
- Whether AppTransaction.shared can be kept failing on a Mac or on stock iOS.
- Whether a backup edit can remove the receipt.
- How long AppTransaction.shared can stall, which sets the entitlement.json window.
- Whether StoreKit can verify a stored JWS.
- Whether the Mac route applies depends on the app staying available on Apple-silicon Macs, which README.md:233 does not address.

<a id="b3"></a>
### B3 · medium · check-release-symbols.sh passes a non-empty release PaywallSimulator made of plain extension members, misses word-substituted Paywall* function names, and skips missing objects silently

**Verdict.** Confirmed, narrower than reported. **Fix group:** G5. **Status:** open.

**Where**

Scripts/check-release-symbols.sh:36: the PaywallSimulator emptiness test, anchored on `^_?\$s16PaywallSimulator` (:40 prints "ok")
Scripts/check-release-symbols.sh:21-31: FORBIDDEN is applied (:25) only to PaywallCore, PaywallKit and PaywallCloudSync, never to PaywallSimulator
Scripts/check-release-symbols.sh:10: FORBIDDEN; the words that start with "Paywall" are word-substituted in shipping-module symbols
Scripts/check-release-symbols.sh:23 and :34-42: silent skip when no objects are found (no else branch)
Scripts/check-release-symbols.sh:13, :25, :36: `2>/dev/null` plus `|| true`, so an nm failure reads as "ok"
Scripts/check-release-symbols.sh:2-4: header claims, including "the same patterns over its .ipa"
.github/workflows/test.yml:76-79: macOS release build, then the script; :133-134: the Linux job runs it too
README.md:28-29, :222 and HANDBOOK.md:510-511: the contract this gate backs. HANDBOOK.md:695-696: the .ipa check is host-side. :700-701: a runtime refusal was decided out
Package.swift:41-42, :60-67: the simulator product's "Debug only" comment; it depends on PaywallTesting (B4)
Extension sites today, all guarded: Sources/PaywallSimulator/PaywallServiceProvider+Simulated.swift:5, :36; Sources/PaywallSimulator/PaywallSimulator.swift:338, :360-366, :368

**Defect**

Scripts/check-release-symbols.sh:36 treats PaywallSimulator as empty when no symbol starts with `$s16PaywallSimulator`, and FORBIDDEN never runs on that module. But Swift mangles a member of an extension on another module's type under that type's module (`$s10PaywallKit…0A9SimulatorE…`). So an unguarded Simulator file that holds only plain extension members passes as "compiles to nothing". "Plain" here means no nominal type, no conformance, no `some` result, and no reference to a simulator type. In the shipping modules, the FORBIDDEN words that start with "Paywall" are word-substituted. They therefore catch nominal types, through the descriptor name string, but not functions or properties. Missing objects, or an nm failure, exit 0 without a word. Nothing leaks at b5c20e4, and removing the guard from any existing Simulator file is caught, either by a compile error or by the anchor.

**Failure scenario**

A contributor adds Sources/PaywallSimulator/Demo.swift without `#if DEBUG`. It contains `extension Paywall.Configuration { public static func demo(catalog: ProductCatalog) -> Self { var c = Self(catalog: catalog); c.store = FakeStore(); return c } }`. This compiles in release: `store` is public (Sources/PaywallKit/Paywall.swift:48), and FakeStore compiles in release (B4). `swift build -c release -Xswiftc -warnings-as-errors` succeeds. The script prints "ok: PaywallSimulator compiles to nothing" and exits 0. Now take an app that links ZTronPaywallSimulator in Release, which README.md:28-29 says is safe because the module is empty, and calls `.demo` outside `#if DEBUG`. That call now compiles where it should fail, and the app ships a fake store (App Review 3.1.1).

Lesser paths:
- A PaywallKit function named like `applyPaywallPreset()` passes.
- A change in where the toolchain puts object files turns the gate into a silent no-op. The layout has already changed once (script :15-17).

Harm needs a new regression of exactly this shape plus an app call site outside `#if DEBUG`.

**Evidence**

Code:
- :36 `hits=$(symbols $simulator | grep -E '^_?\$s16PaywallSimulator' || true)`
- :21 `for module in PaywallCore PaywallKit PaywallCloudSync; do` is the only loop in which :25 applies FORBIDDEN.
- :23 `[[ -z "$objects" ]] && continue`; :34 `if [[ -n "$simulator" ]]` has no else; :13 `nm "$@" 2>/dev/null`.
- The mangling grammar encodes an extension context as `entity module … 'E'` and repeated words as `0A…` substitutions.

Reproduction (I built and ran nothing):
- **Reviewer B** (probe deleted): planted unguarded `PaywallServiceProvider.grantEverythingForDemo() -> Bool` and `GateEngine.simulatorUnlock() -> Int` in Sources/PaywallSimulator. The script printed "ok" and exited 0. nm showed `_$s10PaywallKit0A15ServiceProviderC0A9SimulatorE22grantEverythingForDemoSbyF` and `_$s11PaywallCore10GateEngineC0A9SimulatorE15simulatorUnlockSiyF`; both decode correctly by hand.
- **Verifier 2** (real `swift build -c release -Xswiftc -warnings-as-errors`, unmodified script, Xcode 27 / Swift 6.4):
  - Unmodified tree: four "ok" lines. PaywallSimulator.o defines only `___swift_reflection_version` and `__swift_FORCE_LOAD_$_swiftCompatibility56_$_PaywallSimulator`.
  - Planted: plain extensions, including a FakeStore-backed `Paywall.Configuration` factory, plus `b3v2ApplyPaywallPreset()` in PaywallKit. Every line was "ok" and the exit code 0, yet `nm -U` lists 14 defined `_$s` symbols in PaywallSimulator.o, and PaywallKit.o has `_$s10PaywallKit09b3v2ApplyA6PresetSiyF`.
- **Measured narrowing:**
  - `-> some View` is caught through `_$s16PaywallSimulatorMXM`.
  - A `struct PaywallPreset` in PaywallKit is caught through `l_.str.13.PaywallPreset`. That string survives `-disable-reflection-metadata`.
  - Removing the guard from PaywallServiceProvider+Simulated.swift fails the release compile.
  - An empty BIN gives no output and exit 0.

**Fix direction**

1. **PaywallSimulator: count defined symbols only.** Use `nm --defined-only`, or keep only lines that carry an address, and fail on any `_?$s` symbol. A stricter option fails on any defined symbol outside an allowlist (`___swift_reflection_version`, `__swift_FORCE_LOAD_$_*`). Also run FORBIDDEN over this module. Removing the anchor from today's pattern is not enough: extensions on Paywall* types spell the module `0A9Simulator`. Verifier 2 measured zero defined `$s` symbols at b5c20e4.
2. **Shipping modules: grep demangled names.** Demangle after the awk extraction and keep the raw names in the input too (`l_.str.*` passes through unchanged). Demangled names have no word substitution, which can also split any multi-word pattern (inferred). Use `swift demangle`, not `xcrun`: the Linux job runs this script (test.yml:133-134) and has no xcrun. Fail if the demangler is missing. Verifier 2 measured 0 hits at b5c20e4 on macOS; confirm on Linux.
3. **Replace the silent skips (:23, :34).** Use a per-platform list of expected modules: Darwin expects PaywallCore, PaywallKit, PaywallCloudSync and PaywallSimulator; Linux expects PaywallCore. Fail naming any expected module that has no objects. Also fail when nm exits non-zero or a shipping module's listing is empty; that means removing the masking at :13, :25 and :36.
4. **Make the classifier testable.** Factor each module's verdict into a function that reads nm lines on stdin, so fixtures can test it without a build.
5. **Fix the wording.** Make the script header (:2-4), HANDBOOK.md:510-511 and README.md:28-29 / :222 say what is actually checked. Drop the claim that the host's .ipa scan uses "the same patterns": stripped binaries keep few symbols, and that check is host-side and unverified.
6. **Keep the scope tight.** Coordinate with B4, which touches the same script and module list. No changes to the public API, persisted data or credits. Never plant probes in the checkout, because parallel sessions share it.

**Regression test (the finding is fixed when this passes)**

Add `Scripts/check-release-symbols.sh --self-test`, or a sibling script, run in both CI jobs before the real check (test.yml:78, :133). It is not a Swift test, because no Swift lane produces release objects.

(a) **Fixtures, no build:**
- PaywallSimulator must FAIL on:
  - `T _$s10PaywallKit0A15ServiceProviderC0A9SimulatorE22grantEverythingForDemoSbyF`
  - `T _$s11PaywallCore10GateEngineC0A9SimulatorE15simulatorUnlockSiyF`
  - `T _$s10PaywallKit0A0C13ConfigurationV0A9SimulatorE17b3v2DemoFakeStore7catalogAE0A4Core14ProductCatalogV_tFZ`
- PaywallSimulator must PASS the unmodified tree's listing: `___swift_reflection_version`, `U __swift_FORCE_LOAD_$_swiftCompatibility56`, `__swift_FORCE_LOAD_$_swiftCompatibility56_$_PaywallSimulator`.
- A shipping module must FAIL on `T _$s10PaywallKit09b3v2ApplyA6PresetSiyF` and on `l_.str.13.PaywallPreset`.
- A missing expected module, and an nm failure, must FAIL with the module named.

(b) **Optional macOS end-to-end:**
1. Export HEAD to a temp dir outside the checkout.
2. Add an unguarded Sources/PaywallSimulator/ZZLeakProbe.swift containing `extension PaywallServiceProvider { public func leakProbe() -> Bool { true } }` and a `ProductCatalog` static let. Give it no `some` results.
3. Add Sources/PaywallKit/ZZLeakProbe.swift with `public func applyPaywallPresetLeakProbe() -> Int { 1 }`.

The probe tree must exit 1 and name both; the unmodified tree must exit 0.

**Related findings**

B4: PaywallTesting compiles into release through the simulator product (Package.swift:60-67), and this script never scans it. Both touch the same script, so fix them together. Alternatively, land B3's restructure first (expected-module list, defined-symbol rule, demangled grep), and have B4 add PaywallTesting, or the simulator product's whole dependency closure, to that list. While both stay open, a leaked FakeStore-backed factory passes every check.

**Verification**

Reported by reviewer B as medium. Verifier 1 (code trace): confirmed, narrower than reported, medium. Verifier 2 (reachability and reproduction): confirmed, medium; reachable in production: yes, with preconditions. Judge: confirmed, narrower than reported, medium.

Verifier 1 (code trace) said partly_confirmed and Verifier 2 (reproduction) said confirmed; they agree on the facts. I chose partly_confirmed because the report claims more than holds:
- Removing `#if DEBUG` from any existing Simulator file is caught. Verifier 2 got a release compile error for PaywallServiceProvider+Simulated.swift, and the other files declare nominal types that the anchor catches.
- No Simulator file extends GateEngine. Its hooks are PaywallCore SPI under `#if DEBUG` (Sources/PaywallCore/GateEngine.swift:672-690).
- `some` results and nominal types are caught.
- The "reflection string" is the type descriptor's name and survives `-disable-reflection-metadata`, so that traced claim is refuted.
- The "16 symbols" count is unchecked and does not matter.

Severity is medium: this hardens a CI gate, nothing leaks today, and harm needs two mistakes.

Unverified: the host's .ipa check (outside the repo), a real app archive, the demangler and false-positive behaviour on Linux, the object layout under CI's Xcode 26, and conformance-only leaks (inferred to be caught). I read code only.

<a id="b4"></a>
### B4 · medium · ZTronPaywallSimulator links PaywallTesting's fakes into every Release app that uses it, and the release symbol gate never scans PaywallTesting

**Verdict.** Confirmed. **Fix group:** G5. **Status:** open.

**Where**

- Package.swift:60-67: PaywallSimulator depends on PaywallTesting with no condition.
- Package.swift:41: the comment "Link from Debug configurations only", which nothing enforces.
- Sources/PaywallTesting/*.swift, e.g. FakeStore.swift:6: no `#if` anywhere in the target.
- Sources/PaywallSimulator/PaywallSimulator.swift:
  - :6 `public import PaywallTesting`;
  - :10-12 and :26-30 public API typed as the fakes;
  - :77 FakePromotionalOfferSigner;
  - :339-340 the false claim "never links this product".
- Scripts/check-release-symbols.sh:
  - :2-4 its contract;
  - :21 the module list, which leaves out PaywallTesting;
  - :33-42 the simulator check, which matches only the module's own prefix.
- .github/workflows/test.yml:78-79, :133-134: the only release gate.
- HANDBOOK.md:74-79 and :485: the setup that puts the product in the app target.
- README.md:28-29, :189, :222 and HANDBOOK.md:22, :510-511: the claims this falsifies.

**Defect**

Every PaywallSimulator file is `#if DEBUG`, but its dependency PaywallTesting has no guard, and nothing can make that dependency Debug-only: SwiftPM target-dependency conditions accept only platforms and traits, and Xcode's package-product links accept only platform filters. Package targets reach the app link as whole `<Target>.o` objects, and Swift type and conformance records are never dead-stripped, so any Release app that links ZTronPaywallSimulator ships FakeStore, FakeClock, FakeConnectivity, FakePromotionalOfferSigner and the in-memory carriers. The code is dormant, since nothing in Release constructs a fake, but the package's release-hygiene claims are false, and check-release-symbols.sh still passes because it never scans PaywallTesting.

**Failure scenario**

An adopter follows the HANDBOOK setup: `.fromLaunchArguments(production:)` under `#if DEBUG` in the `@main` App (HANDBOOK.md:74-79) plus `.paywallSimulation` previews (HANDBOOK.md:485). That puts ZTronPaywallSimulator in the app target's Frameworks phase.

The Release archive then links PaywallTesting.o:
- about 110 KB of extra code;
- 398 of 410 FakeStore symbols survive `-dead_strip`;
- `FakeStore` and `_TtC14PaywallTesting9FakeStore` survive strip.

CI's gate prints "ok". As a result:
- README.md:222, the script header and HANDBOOK.md:510-511 are false.
- A host .ipa check that runs the script's FORBIDDEN patterns over `strings` (the header at :4 says the host runs them over its .ipa) would fail every archive, and there is no supported remedy. An `nm` check on the stripped binary passes without seeing anything.
- Non-DEBUG app code that references FakeStore compiles and ships.

Users can reach none of it. Entitlements, credits and persisted state are untouched.

**Evidence**

**Code at b5c20e4**
- Package.swift:60-67 lists `.target(name: "PaywallTesting")` for PaywallSimulator with no condition. The manifest is tools 6.0 (Package.swift:1).
- `grep '#if'` over Sources/PaywallTesting finds nothing. All four Sources/PaywallSimulator files are wrapped in `#if DEBUG`.
- check-release-symbols.sh:21 is `for module in PaywallCore PaywallKit PaywallCloudSync`, and :36 matches only `^_?\$s16PaywallSimulator`.
- PaywallCore, PaywallKit and PaywallCloudSync never import PaywallTesting.

**Platform**
- In Xcode 27, PackageDescription.swiftinterface:841-850 gives TargetDependencyCondition only `when(platforms:)` and `when(traits:)` (6.1). SE-0273 configuration conditions were never implemented.
- Swift Build's ProductTypes.xcspec:146-177 defines `com.apple.product-type.objfile` with `MACH_O_TYPE = mh_object`, the type package targets build as.

**Reproduction by verifier 2** (Swift 6.4, iPhoneOS 27.0 SDK)
- `swift build -c release`: .build/out/Products/Release/PaywallTesting.o holds 410 FakeStore symbols. The script prints four "ok" lines and exits 0.
- Hand-linked iOS stub in the HANDBOOK setup shape: `swiftc -O -wmo`, no DEBUG, `-Xlinker -dead_strip`, then strip. With the simulator closure versus without it:
  - 398 vs 0 FakeStore symbols;
  - 1,909,360 vs 1,799,080 bytes after stripping;
  - 9 vs 0 FORBIDDEN strings.
- `-why_live`: dont-dead-strip, then type metadata, then nominal type descriptor.

**My own check of those binaries** (nm and strings on verifier 2's two hand-linked stubs, with and without the simulator closure; not kept):
- 398 vs 0 `9FakeStore` symbols;
- 850 vs 0 `14PaywallTesting` symbols;
- 9 vs 0 FORBIDDEN strings;
- built for iOS (platform 2), minimum OS 15.0.

No xcodebuild archive was run.

**Fix direction**

**1. Take PaywallTesting out of ZTronPaywallSimulator's Release link closure.** Two routes, each with a cost.

(a) Make PaywallSimulator self-contained under `#if DEBUG`: its own store, clock, sync, connectivity and signer stand-ins, plus the StoreTransaction helpers it uses at PaywallSimulator.swift:170, :251, :257, :259. Costs:
- It changes debug public API: the typealiases at :10-12 and the properties at :26-30.
- SimulatorTests.swift imports PaywallTesting (:6) and `@testable` PaywallSimulator (:10), so internal copies with the same names become ambiguous. It also reads `connectivity.hasPath` (:360, :363).
- The coverage ratchet fails on copied code no test exercises (coverage-baseline.json, PaywallSimulator 98.12/91.71).
- The two copies drift; B14 and A7 already edit FakeStore and InMemory.swift.

(b) Wrap all of Sources/PaywallTesting in `#if DEBUG`. Simpler, and a non-DEBUG reference to a fake becomes a Release compile error. Costs:
- It breaks consumers that build tests in Release; this repo has no such lane.
- It changes the documented contract (HANDBOOK.md:23, README.md:40, :194-199).
- A tools-6.0 manifest cannot add a test-only define.

**2. Fix the script.**
- Replace the hard-coded list at :21 with the module closure of every product an app ships (Core, Kit, CloudSync, Simulator; not Testing), taken from `swift package describe --type json`.
- Fail on any FORBIDDEN name or `14PaywallTesting` symbol.
- Modules meant to be empty must define no `$s` symbol.
- Fail when an expected module has no objects.
- These are the same lines B3 changes; keep Linux working.

**3. Correct the claims:** Package.swift:41, PaywallSimulator.swift:339-340, README.md:28-29/:39/:189/:222, HANDBOOK.md:22/:510-511, and script lines :2-4.

No persisted data is affected.

**Regression test (the finding is fixed when this passes)**

Extend Scripts/check-release-symbols.sh, which CI runs as release_archive_has_no_simulator_symbols (test.yml:78-79, :133-134). Swift test bundles build Debug, so no Swift suite can see what a Release build contains.

1. **Closure scan.** After `swift build -c release`, scan every module in the closures of the products an app ships. At b5c20e4 this must fail and name PaywallTesting (410 FakeStore symbols in .build/out/Products/Release/PaywallTesting.o).
2. **Link check (Darwin only).**
   - Compile a stub main.swift in the HANDBOOK setup shape: it imports PaywallCore and PaywallKit, and PaywallSimulator under `#if DEBUG`. Use `swiftc -O -parse-as-library` without DEBUG.
   - Link it with `-Xlinker -dead_strip` against the closure's .o files, then strip.
   - Assert that nm finds no `14PaywallTesting` or `16PaywallSimulator` symbol and that `strings` finds no FORBIDDEN name. At b5c20e4: 398 symbols and 9 strings. After the fix: 0 and 0.
3. **Self-test.** The same scan over Debug objects must report hits, so a change in build layout cannot let the gate pass without checking anything.

**Related findings**

- **B3:** same script and same lines (:10, :21, :23, :33-42). B4's "combined with B3" scenario needs both defects. Fix them in one change to the script, including B3's rule that a module meant to be empty defines no `$s` symbol.
- **B14 and A7:** they change FakeStore and Sources/PaywallTesting/InMemory.swift. If B4 takes option (a) and copies the fakes into PaywallSimulator, land B14 and A7 first, or apply them to both copies. Option (b) removes this ordering constraint.

**Verification**

Reported by reviewer B as medium. Verifier 1 (code trace): confirmed, medium. Verifier 2 (reachability and reproduction): confirmed, medium; reachable in production: yes, with preconditions. Judge: confirmed, medium.

Both verifiers confirmed the finding at medium, and I agree. How I resolved the open points:
- **The app link:** the reviewer only inferred that the fakes reach the app. Verifier 2 reproduced it with a hand link that follows Xcode's object-file model. I re-inspected those binaries myself, along with Xcode 27's objfile spec and PackageDescription interface.
- **README.md:28-29:** verifier 1 notes that its second sentence is literally true, because the PaywallSimulator module is empty. The claims the behaviour actually falsifies are README.md:222, Package.swift:41, PaywallSimulator.swift:339-340, the script header and HANDBOOK.md:510-511.
- **"Grants whatever it is told":** this describes what the fake can do, not a path anyone can reach. No Release path builds a fake, and in-process code can already install any StoreClient (Paywall.swift:48, PaywallServiceProvider.swift:21). The issue stays hardening.
- **Citation fix:** the setup block is HANDBOOK.md:74-79, not :72-78.

**Unverified:**
- a real xcodebuild archive or .ipa;
- the variant where Xcode embeds the product as a dynamic framework;
- how App Review treats dormant fake code;
- the host's own .ipa check, which is not in the repo.

<a id="b5"></a>
### B5 · medium · The signing worker has no volume limit on its documented workers.dev deployment, but README.md:225 and the worker README say Cloudflare rate limiting bounds it

**Verdict.** Confirmed, narrower than reported. **Fix group:** G6. **Status:** open.

**Where**

- README.md:225: the risk row says "Cloudflare rate limiting bounds volume" in the column headed "What the package does" (header at :220).
- Workers/PromotionalOfferSigner/README.md:88-89: "Cloudflare's rate limiting rules bound the volume".
- Workers/PromotionalOfferSigner/wrangler.jsonc:5-13: no `ratelimits`, `routes` or `workers_dev`, so it deploys to workers.dev.
- Workers/PromotionalOfferSigner/src/app.ts:31-43: routing with no limiter.
- Workers/PromotionalOfferSigner/src/app.ts:61-64: content-length fast path, unbounded `request.text()`, UTF-16 length check.
- Workers/PromotionalOfferSigner/README.md:63-71: deploy recipe with no rule and no ALLOWED_OFFERS; workers.dev endpoint at :77.
- HANDBOOK.md:43, :337 and Sources/PaywallKit/RemotePromotionalOfferSigner.swift:34: workers.dev endpoint examples.
- Sources/PaywallKit/RemotePromotionalOfferSigner.swift:41-42, :87-89: `Failure.http` doc and mapping.
- Workers/PromotionalOfferSigner/src/app.ts:9-10 and worker README:38-45: the error lists.
- Workers/PromotionalOfferSigner/src/config.ts:17: ALLOWED_OFFERS unset signs any offer.
- Workers/PromotionalOfferSigner/test/app.test.ts:150-157: oversize test, ASCII bodies only.
- Workers/PromotionalOfferSigner/test/support.ts:50, :61-64: `EnvOverrides` assumes every Env key is a string.

**Defect**

The worker has no limit on request volume. wrangler.jsonc declares no Rate Limiting binding and no routes, so it serves only on workers.dev, the URL every doc example uses, and `handleRequest` routes straight to health, keys, sign or 404. Yet README.md:225 and the worker README:88-89 say Cloudflare rate limiting bounds the volume; the recipe sets up no rule, and zone WAF rules cannot apply to workers.dev. Lesser issues: a body with no content-length is read in full before the 4 KB check, which counts UTF-16 units. The reported "deepest discount by calling the endpoint" needs a tampered client and is an accepted risk.

**Failure scenario**

- Setup: the signer is deployed with worker README:63-71 on the Workers Free plan. That is the default, and the docs name no plan.
- Attack: one client sends about 100k requests in a UTC day to any path (sign, health, keys or a 404 all run the Worker). That is about 17 minutes at 100 req/s.
- Result: the account-wide daily cap is hit, and Cloudflare answers Error 1027 until 00:00 UTC.
  - `RemotePromotionalOfferSigner.sign` throws `Failure.http` (RemotePromotionalOfferSigner.swift:87-89), so every offer purchase fails before the payment sheet (README.md:226). Plain purchases still work.
  - Every other Worker on that Free account fails too.
- The attacker gains nothing and must repeat it daily. On Workers Paid it only costs money (about $0.30 per million past 10M a month).
- No entitlement, credit or persisted state is touched.
- Not reachable as reported: a signature fetched with curl only works through the app's own purchase call (StoreKit2Client.swift:111). Taking an offer the app does not show needs a tampered client.

**Evidence**

Code at b5c20e4:
- Workers/PromotionalOfferSigner/wrangler.jsonc:5-13 holds only `$schema`, `name`, `main`, `compatibility_date` and `observability`. There is no `ratelimits`, `routes` or `workers_dev`.
- src/app.ts:31-43 is a path switch to health, keys, sign or 404, with nothing before it.
- A grep for ratelimit, 429, throttl, cf-connecting-ip, workers_dev and routes over src/, test/ and the configs finds nothing. The CI worker job (.github/workflows/test.yml:101-114) only runs `npm run check`.
- README.md:225 says "Cloudflare rate limiting bounds volume", under the "What the package does" header at :220. Worker README.md:89 says "Cloudflare's rate limiting rules bound the volume".
- The recipe (worker README:63-71) sets up no rule. The endpoint is workers.dev at worker README:77, HANDBOOK.md:43 and :337, and RemotePromotionalOfferSigner.swift:34. The gap is not listed in Known defects (README.md:235-252).
- Body handling: app.ts:61 `Number(request.headers.get("content-length") ?? "0")`, :63 `await request.text()`, :64 `text.length > MAX_BODY_BYTES`. That constant is documented as bytes at :17.

Reproduction, by verifier 2:
- The probe is Appendix B (`Workers/PromotionalOfferSigner/test/b5-repro.test.ts`). I read it: it calls the production `handleRequest` under vitest on Node 22, with only a throwaway key. I did not re-run it, because the judge's pass was read-only.
- 2,000 sign POSTs from one cf-connecting-ip: all 200, none 429.
- 900 calls to 404, health and keys: all answered.
- A 32 MiB stream with no content-length: all 33,554,432 bytes read, then 413.
- "é" repeated 4,096 times (8,192 bytes): passes the size check, then 400.

Cloudflare facts, not reproducible locally:
- These come from Cloudflare's docs via verifier 2 and match my own knowledge.
- The Free plan allows 100k requests a day per account, resets at 00:00 UTC, and answers Error 1027 past that.
- workers.dev is a Cloudflare-managed zone, so the deployer's WAF rules do not reach it.
- `workers_dev` is on by default when no routes are set.

**Fix direction**

1. Docs, the required fix. Rewrite README.md:225 and worker README.md:88-89 so they claim no limit the code lacks. They should say:
   - The worker has no volume limit, and on workers.dev nothing provides one.
   - On Workers Free the 100k-a-day cap is account-wide, so a flood stops offer purchases and the account's other Workers until 00:00 UTC.
   - Production should use Workers Paid, and/or a route or custom domain with a WAF rate limiting rule. That rule only limits per-IP volume.
   - With a custom domain, the deploy config needs `workers_dev: false` and `preview_urls: false`, or the workers.dev hostname bypasses the rule.
   Do not commit `workers_dev: false` without routes (the Worker would have no URL), and do not commit any real domain or account (the repo is public).

2. A Rate Limiting binding that answers 429 does not fix the quota or billing problem, because throttled requests still run the Worker and count. If it is added anyway as an extra layer:
   - Make it optional in `Env`; no binding means no limit.
   - Check it before reading the body.
   - Key it on cf-connecting-ip with a generous limit, because of carrier-grade NAT. Do not key it on transactionId: that field is optional and any digit string passes (validate.ts:13, :42).
   - Document `429 rate_limited` with Retry-After in app.ts:9-10, worker README:38-45 and RemotePromotionalOfferSigner.swift:41-42. The client already maps it at :87-89.
   - Retype `EnvOverrides` in test/support.ts:50, which assumes every Env key is a string. Otherwise tsc fails.

3. Body read:
   - Read `request.body` with a reader, count bytes, and cancel past MAX_BODY_BYTES.
   - Decode with a fatal TextDecoder, so invalid UTF-8 gives 400.
   - Keep the content-length fast path at :61-62.
   - A null body stays 400.

4. Optional: put ALLOWED_OFFERS in the recipe with placeholder ids. Describe it as limiting unused offers, not as stopping a tampered client.

No persisted state, ledger or entitlement is touched by any of this.

**Regression test (the finding is fixed when this passes)**

All in the worker suite (Workers/PromotionalOfferSigner, `npm run check`, plain Node).

1. test/app.test.ts, extend "refuses oversized bodies, declared or actual":
   - A ReadableStream body (duplex "half", no content-length) of 1 MiB returns 413, and no more than MAX_BODY_BYTES plus one chunk is read.
   - `"é".repeat(2049)` (4,098 bytes) returns 413.
   - Invalid UTF-8 returns 400.
   - The ASCII cases still pass.

2. Only if a limiter binding is added, use a stub `{ limit: async ({ key }) => ({ success: ++n[key] <= 3 }) }`:
   - 4 signs from one cf-connecting-ip give [200, 200, 200, 429].
   - The 429 has body `{"error":"rate_limited"}`, a retry-after header and cache-control no-store.
   - Another IP still gets 200.
   - A refused request reads 0 body bytes.
   - Without the binding, signing still works.

3. Docs: no unit test covers the correction, and none can show the Free-plan quota is protected. Check README.md:225 and worker README:88-89 by reading them.

Optional Swift test (PaywallKitTests, isolated facade, macOS 14 APIs only): a stub HTTPTransport answering 429 makes `sign` throw `.http(status: 429, code: "rate_limited")`.

**Related findings**

- B11: changes Workers/PromotionalOfferSigner/src/app.ts:50-51 and the worker README, the same files as this fix.
- B12: changes Sources/PaywallKit/RemotePromotionalOfferSigner.swift and README.md:226, the risk row next to :225. Coordinate if 429 docs are added.
- DOCS D6: worker public-endpoint wording (README.md:267-268, app.ts:85).
None of these has to land before the others; only the edits to shared files need coordinating.

**Verification**

Reported by reviewer B as medium. Verifier 1 (code trace): confirmed, narrower than reported, medium. Verifier 2 (reachability and reproduction): confirmed, narrower than reported, medium; reachable in production: yes, with preconditions. Judge: confirmed, narrower than reported, medium.

Both verifiers said partly_confirmed and medium, and did not disagree on substance. I re-read every decisive line at b5c20e4 and read verifier 2's probe, which drives the production `handleRequest`. I ran nothing.

- Kept: no limiter, the unbacked volume claim, the workers.dev-only deployment, the unbounded body read.
- Narrowed:
  - The deepest-discount consequence needs a tampered client. That is accepted at README.md:225, and ALLOWED_OFFERS cannot exclude an offer the app shows.
  - The body read is capped by Cloudflare at 100 MB, and the UTF-16 slack is harmless.
- Rejected: the reviewer's 429 binding as a fix for the quota scenario.

Severity is medium, not critical or high. "Abuse the signer" means misusing its signing, which is public by design. This needs a motivated attacker with nothing to gain, fails gracefully, and on Paid only costs money.

Unverified, service-only:
- The Free daily cap and Error 1027.
- Whether WAF rules can reach workers.dev.
- Whether requests blocked by WAF count toward the quota.
- Cloudflare's memory and CPU limits on the buffered read.

<a id="a10"></a>
### A10 · low · Paid introductory offers (pay as you go, pay up front) resolve as a free trial: Subscription.isTrial is true and the tier is .freeTrial

**Verdict.** Confirmed. **Fix group:** G3. **Status:** open.

**Where**

- Sources/PaywallKit/StoreKit2Client.swift:182: `isIntroductoryOffer: transaction.offerType == .introductory`. The payment mode is never read; `map(_:)` (:165) is synchronous.
- Sources/PaywallCore/StoreClient.swift:26-27: the field doc says "(the free trial)", the wrong assumption.
- Sources/PaywallCore/EntitlementResolver.swift:134: `isTrial: tx.isIntroductoryOffer`, the only production builder of `Subscription`.
- Sources/PaywallCore/Entitlement.swift:121: `subscription.isTrial ? .freeTrial : …`
- Sources/PaywallCore/Entitlement.swift:85 (doc), :86 (case), :99-100: `.freeTrial` is the "introductory free trial", rank 1, below `.tokens` at 2.
- HANDBOOK.md:179-180: the tier spec. HANDBOOK.md:162-165: the screen loop `product.tier > current`.
- Sources/PaywallKit/StoreKit2Client.swift:225-228: the storefront already requires `paymentMode == .freeTrial`.
- Sources/PaywallTesting/FakeStore.swift:194-199: `trial:` maps to `isIntroductoryOffer`, the same conflation.
- Sources/PaywallCore/GateEngine.swift:347, :174 and Sources/PaywallKit/Paywall.swift:94, :237: gates use `isPaying`; `tier` is exposed here.

**Defect**

`StoreKit2Client.map(_ transaction:)` sets `StoreTransaction.isIntroductoryOffer` from `Transaction.offerType` alone, so a pay-as-you-go or pay-up-front introductory offer counts as a free trial. `EntitlementResolver` copies the flag into `Subscription.isTrial`, and `Entitlement.tier(wallet:)` then reports `.freeTrial` (rank 1, below `.tokens`), which contradicts the spec that `.freeTrial` means the introductory free trial. Only `isTrial`, `GateEngine.tier` and `Paywall.tier` are wrong; gates, credits, the ledger and persisted state are unaffected.

**Failure scenario**

An adopting app sets up a paid introductory offer in App Store Connect, for example $0.99 for the first month (pay as you go) on pro.monthly. Nothing in the package or its docs excludes this. A new subscriber buys and StoreKit applies the offer by itself (HANDBOOK.md:169). The transaction's offerType is `.introductory`, so `Subscription.isTrial == true` and `Paywall.tier == .freeTrial` for the discounted period. With pay up front that is the whole term, up to a year. With pay as you go it is at least the first period.

The account screen then calls a paying customer a free-trial user. The documented paywall loop (HANDBOOK.md:162-165) offers every product as an upgrade: their own plan, the cheaper weekly plan and the token packs. For a monthly subscriber the right list is yearly and lifetime. The state corrects itself at the first resolution after a renewal that carries no offer.

**Evidence**

Code at b5c20e4, re-read by me:
- StoreKit2Client.swift:182 is `isIntroductoryOffer: transaction.offerType == .introductory`, with no payment-mode check.
- EntitlementResolver.swift:134 is `isTrial: tx.isIntroductoryOffer`.
- Entitlement.swift:121 is `return subscription.isTrial ? .freeTrial : subscription.tier.accessTier`.
- GateEngine.swift:174 and Paywall.swift:237 expose the result.
- Grep over Sources: production code reads `isTrial` only at Entitlement.swift:121. The debug simulator also touches it (PaywallSimulator.swift:136, :253).
- README.md:235-252 ("Known defects and limitations") does not mention this.

The package already treats paid intros as not a trial elsewhere:
- StoreKit2Client.swift:227 filters `$0.kind == .introductory && $0.paymentMode == .freeTrial`.
- ProductCatalog.swift:144 models `freeTrial, payAsYouGo, payUpFront`.
- Tests/PaywallKitTests/StoreKitMappingTests.swift:30-38 asserts that a `.payUpFront` intro is not the disclosure's trial.

SDK, from the installed Xcode iPhoneOS StoreKit.swiftinterface, read by me:
- `Transaction.OfferType` has only `introductory`, `promotional`, `code` and `winBack`.
- The payment mode is separate: `Transaction.Offer.paymentMode`, iOS 17.2 / macOS 14.2.
- `offerPaymentModeStringRepresentation` is `@backDeployed(before: iOS 17.2, macOS 14.2)`. Before 17.2 it reads the signed transaction's `offerDiscountType`.

Reproduction: reviewer A left no probe for A10. Verifier 2 compiled the unmodified PaywallCore sources, minus the three GateEngine files that import swift-log. A driver fed the StoreTransaction the mapper produces for a paid intro (`isIntroductoryOffer: true`) through `EntitlementResolver.resolve` and `tier(wallet:)`. Output:
- paid intro: `isTrial=true tier=freeTrial offeredAsUpgrade=["pro.weekly","pro.monthly","pro.yearly","pro.lifetime","tokens.10","tokens.50"]`
- same plan at regular price: `tier=monthly offeredAsUpgrade=["pro.yearly","pro.lifetime"]`

Not run: a real StoreKit Transaction with a paid intro, which needs the TestHost simulator lane.

**Fix direction**

1. Decide per transaction, in the mapper: a free trial means introductory AND the free-trial payment mode.
   - iOS 17.2 / macOS 14.2+: `transaction.offer?.type == .introductory && transaction.offer?.paymentMode == .freeTrial`.
   - Keep the type check. Payment mode alone would make free promotional, offer-code and win-back periods `.freeTrial`, which contradicts Entitlement.swift:85. Widen only on purpose, with doc changes.
2. Earlier OS versions: `transaction.offerType == .introductory && transaction.offerPaymentModeStringRepresentation == "FREE_TRIAL"`.
   - This property is back-deployed and reads the signed transaction's own `offerDiscountType`.
   - Both properties are deprecated only at 17.2 / 14.2, above the iOS 15 / macOS 12 deployment target (Package.swift:99-102). CI's `-warnings-as-errors` stays as clean as with today's `offerType`.
3. Do not use the reviewer's fallback, `Product.subscription.introductoryOffer?.paymentMode`:
   - `map(_:)` is synchronous.
   - It describes the offer on sale now in the current storefront, not the one the transaction redeemed. Intro offers are scheduled and set per territory.
   - It returns nothing for a plan removed from sale.
4. Put the decision in a pure static, for example `isIntroductoryFreeTrial(offerType:paymentMode:)`, so unit tests reach it without a Transaction.
5. Preferred layer is the mapper only:
   - Keep `StoreTransaction`'s public shape, make `isIntroductoryOffer` mean "introductory free trial", and fix its doc at StoreClient.swift:26.
   - If you add a public field instead, give it a default and update FakeStore's `.subscription(trial:)` (FakeStore.swift:194-199). ResolverTests.swift:53, GateEngineTests.swift:522, SimulatorTests.swift:190 and PaywallSimulator.swift:253 must still resolve as trials.
6. No migration is needed: `Subscription`'s Codable shape is unchanged, and entitlement.json is rewritten at every resolution.

**Regression test (the finding is fixed when this passes)**

A resolver test alone cannot reach this defect, because it lives in the mapper. Use two layers.

1. Mapping: Tests/PaywallKitTests/StoreKitMappingTests.swift, suite "StoreKit 2 mapping" (isolated, no `Paywall.shared`). Assert the pure helper:
   - (.introductory, free trial): true
   - (.introductory, pay as you go): false
   - (.introductory, pay up front): false
   - (.promotional, free trial): false
   - (nil, nil): false
   - Cover the pre-17.2 strings the same way: "FREE_TRIAL", "PAY_AS_YOU_GO", "PAY_UP_FRONT".
   - If the helper takes `Transaction.Offer.PaymentMode`, annotate the test `@available(iOS 17.2, macOS 14.2, *)`, not `#available`. Test bundles build for macOS 14.

2. Real StoreKit: TestHost/TestHostTests/StoreKitIntegrationTests.swift, simulator only, iOS 26 runtime.
   - Give pro.yearly a pay-up-front introductory offer in Tests/PaywallKitTests/Fixtures/Paywall.storekit.
   - New test, in a fresh session:
     1. Expect the account eligible for the intro.
     2. Expect yearly to list an `.introductory` `.payUpFront` offer, with `introOffer == nil`.
     3. Buy it and require `.purchased`.
     4. Expect the account no longer eligible, which proves the intro was redeemed.
     5. Expect `s.tier == .yearly && !s.isTrial` and `Paywall.shared.tier == .yearly`.
   - At b5c20e4 this test fails.
   - Keep the listing test (:78-103) and the crossgrade test (:216-229, which buys pro.yearly) green.

**Related findings**

- A3 (grace period) edits the same code:
  - `StoreTransaction` (Sources/PaywallCore/StoreClient.swift)
  - `StoreKit2Client.map`
  - the `Subscription` built at EntitlementResolver.swift:129-137 (A3 changes `phase` at :135, A10 changes `isTrial` at :134)
  - possibly FakeStore's `.subscription` helper.

  Neither has to go first. Do them in one pass, or rebase so both survive.
- DOCS D8 says the doc at GateEngine+Store.swift:8 ("Never waits for the network") is already untrue. So the case against a Product-lookup fallback rests on `map` being synchronous and on the offer mismatch, not on that doc.

**Verification**

Reported by reviewer A as low. Verifier 1 (code trace): confirmed, low. Verifier 2 (reachability and reproduction): confirmed, low; reachable in production: yes, with preconditions. Judge: confirmed, low.

- Both verifiers confirmed the defect and rated it low, with no disagreement. They corrected the reviewer's fix direction the same way: keep the introductory check, drop the Product-based fallback, and test the mapper rather than the resolver.
- I re-read every decisive line at b5c20e4 and checked the SDK interface myself.
- Citation fix: Entitlement.swift:86 is the case declaration; its doc is at :85.
- Why low: the effect is display only (gates use `isPaying`, GateEngine.swift:347; nothing moves credits and nothing persists wrongly). It also needs a paid intro offer, which the project's fixture does not use, though once one is configured every subscriber who redeems it is affected.
- Unverified, because it needs a simulator or Apple's service:
  - that a paid-intro transaction, under StoreKit Testing or in production, carries offerType `.introductory` and the expected `offerDiscountType`;
  - that every discounted pay-as-you-go period carries the offer;
  - the literal "FREE_TRIAL" raw value before 17.2, which I inferred from Apple's `offerDiscountType` docs;
  - that SKTestSession accepts a pay-up-front intro in the .storekit file.

<a id="a12"></a>
### A12 · low · Every launch decodes the whole retained audit (up to 50 MB) before start() starts the StoreKit listeners and its own launch resolution

**Verdict.** Confirmed, narrower than reported. **Fix group:** G2. **Status:** open.

**Where**

Sources/PaywallCore/GateEngine.swift:286 — `await repairAudit()` runs first in start(), before the listeners and refresh(.launch) at :295-298 and the outbox drain at :302
Sources/PaywallCore/GateEngine.swift:623-645 — repairAudit(): :630 calls recordedDebitIDs() unconditionally; the candidates and the floor are applied only at :639-642
Sources/PaywallCore/Audit.swift:171-181 — JournalSink.recordedDebitIDs(), built on records()
Sources/PaywallCore/Audit.swift:146-155 — records() and records(in:) load and JSON-decode every line of every file
Sources/PaywallCore/Audit.swift:97, :110 — defaults of 5 MB × 10 files
Sources/PaywallKit/Paywall.swift:41, :154-155 — JournalSink is installed by default; :197-198 start() runs in a Task
Sources/PaywallCore/GateEngine.swift:264-270 — debitsAtLaunch: this device's debits since the last checkpoint
Sources/PaywallCore/Audit.swift:247-259 — AuditTrail keeps records in memory until resume (GateEngine.swift:638)
Sources/PaywallKit/PaywallSignals.swift:217-219 → Sources/PaywallCore/GateEngine+Store.swift:278-279 — scene-phase refresh, which does not wait for start()
Sources/PaywallCore/GateEngine.swift:745-749 — a lapsed cached subscription loads as .free
Tests/PaywallCoreTests/RetentionTests.swift:35-44, :169-181 — ShuttingDownSink, which depends on recordedDebitIDs() being called
HANDBOOK.md:426 — the retention intent

**Defect**

At every launch `start()` first awaits `repairAudit()`, which always calls `JournalSink.recordedDebitIDs()`. That call loads and JSON-decodes every line of every retained audit file (up to 10 × 5 MB), even when no launch debit needs checking, and only after it do the `Transaction.updates` and `PurchaseIntent` listeners, `refresh(cause: .launch)` and the outbox drain start. The decode runs on the sink actor, gates keep the cached snapshot and nothing is lost, and two reported effects do not hold: the `.unknown`-after-journal-loss case does not happen, and in the documented iOS setup the scene-phase refresh consults StoreKit while the scan runs.

**Failure scenario**

An engaged, long-lived install fills the rotation set: about 85k records, which is roughly 27-40k gate passes. That takes months to years, depending on how often the app evaluates gates. From then on, every cold or background launch spends about 1.1-1.5 s of CPU on an Apple M3 (about 28 ms per MB) and about 66 MB of transient heap before start() continues. Older devices and the iOS 15/16 JSONDecoder are slower; that is not measured.

During that window:
- An Ask to Buy approval, an interrupted consumable purchase or a promoted-IAP intent waits for the listeners. It is delayed, not lost.
- Audit records emitted meanwhile exist only in memory, so a kill loses them. A lost `tokensConsumed` record is repaired at the next launch.
- A host that never calls `didBecomeActive()` keeps a stale snapshot for longer. For example, a subscriber whose cached expiry passed before a renewal starts as `.free`.

**Evidence**

Code at b5c20e4, which I read directly:
- GateEngine.swift:286 `await repairAudit()` comes before :295-298 (`startUpdatesListener`, `startPurchaseIntentsListener`, `startConnectivityListener`, `refresh(cause: .launch)`) and :302 `scheduleSync(immediately: true)`.
- The only early-out is :624 `guard !repairingSinks.isEmpty`. :630 `recorded.formUnion(await sink.recordedDebitIDs())` runs before `debitsAtLaunch` and the floor are consulted (:639-642), and `recorded` is used nowhere else.
- Audit.swift:172-173 `Set(records().compactMap ...)` sits on :148 `urlsNewestFirst.reversed().flatMap(Self.records(in:))`, and :152-154 decodes every line.
- Defaults: :97 `maxBytes: Int = 5 * 1024 * 1024, maxFiles: Int = 10`; Paywall.swift:41 `includesDefaultAudit = true`, and :155 inserts `JournalSink(directory:)`.
- The work is off the main thread: JournalSink is an actor (Audit.swift:90), and start() runs in `startTask = Task` (Paywall.swift:197-198).
- Records emitted meanwhile queue at Audit.swift:257-258 until `audit.resume` (GateEngine.swift:638).
- PaywallSignals.swift:217-219 → GateEngine+Store.swift:278-279 does not depend on start(). It is applied by `.paywallLifecycle()` (:48), `.paywallSheet` (:88) and `.paywallProvider` (PaywallServiceProvider.swift:117).
- entitlement.json loads independently of ledger.log (GateEngine.swift:263, :745-752).
- Not documented: README.md:235-252 does not mention it, and HANDBOOK.md:465 covers only lastRecordHash().

Reproduction (verifier 2): a standalone benchmark (not kept) copies the AuditRecord Codable surface, CanonicalJSON and JournalSink's file logic verbatim, and ran under `swift -O` on an M3.
- Full set (52 MB, 85,243 records): 1.27-1.34 s of CPU, 65.6 MB heap.
- Subscriber set: 1.17 s.
- Two-file subset: about 28 ms per MB.
- lastRecordHash plus retainedSince: 18 ms.

I inspected the script and its data but did not rerun it. Its decoder matches Digest.swift:104-107, and about 7% of lines contain "debitID". Nothing was run on the engine, a simulator or a device.

**Fix direction**

1. Required, and exact: in `repairAudit()`, read every sink's `retainedSince()` and `lastRecordHash()` first, and compute the floor as today.
   - Keep the `debitsAtLaunch` entries with `at > floor`, or all of them when some sink retains everything.
   - Skip the debit lookup when none is left.
   - Still call `audit.resume(after:)` before any `.auditRepaired` emit.
   - This removes the cost for subscribers, lifetime users and users who never draw.
2. Required for users who draw tokens: an exact lookup scoped to the candidates.
   - Add a `PaywallAuditRepairing` requirement, for example `recordedDebitIDs(among:)`, whose extension default is `recordedDebitIDs().intersection(candidates)`, so InMemoryAuditSink and host sinks still compile.
   - JournalSink overrides it: newest file first, decoding only lines that contain `"debitID"` (the key that all three debit-bearing events encode), and stopping once every candidate is found.
   - Keep `recordedDebitIDs()` returning the full set. It is public, and RetentionTests.swift:269, :298, :331 and GateEngineTests.swift:504 assert it.
   - Report an id only from a decoded record. A false hit suppresses a repair that is needed.
   - Never stop on a record's wall-clock `at`. If the clock is set back, newer records look older, and the same debit is repaired at every launch.
   - Any per-file index must fall back to decoding for files written by b5c20e4.
3. Optional: start the listeners and `refresh(cause: .launch)` before the lookup.
   - Keep the checkpoint after the repair and the flush (HANDBOOK.md:444-448).
   - Keep the Keychain baseline adoption (GateEngine.swift:288-293) before the listeners and the refresh.
   - Check `isShutDown` after every await (A5), and keep refreshes ordered (A4).
   - On its own, this step leaves the CPU and memory cost in place.

Step 1 breaks RetentionTests.swift:169 as written: that test has no debits, so `ShuttingDownSink.recordedDebitIDs()` (:39-42) is never called. Move its `shutdown()` into `lastRecordHash()`.

**Regression test (the finding is fixed when this passes)**

Target: PaywallCoreTests, suite "Retention" (Tests/PaywallCoreTests/RetentionTests.swift, @MainActor, .serialized). Use isolated GateEngines and only APIs available on macOS 14.

1. `a_launch_with_no_debit_to_check_does_not_scan_the_audit` (fails at b5c20e4, where the count is 1).
   - A `CountingRepairSink` actor wraps `JournalSink(directory: dir)`. It forwards `write`, `lastRecordHash` and `retainedSince`, and counts calls to `recordedDebitIDs()` and to the candidate lookup.
   - Launch 1, with the plain sink: start, `grant(tokens: 5)`, one `.free` gate, `flushAudit()`, shutdown.
   - Launch 2, with the counting sink: both counts are 0, no `.auditRepaired` is emitted, and after `flushAudit()`, `AuditRecord.firstBrokenLink(in: records(), after: chainAnchor()) == nil`.
   - Repeat with every debit rotated below the floor (`maxBytes: 4_000, maxFiles: 2`, then non-debit records written on an advancing FakeClock).
2. `the_candidate_lookup_matches_a_full_decode`. A rotated JournalSink holds:
   - a tokensConsumed record in the oldest file;
   - a tokensRefunded record;
   - an auditRepaired record;
   - a torn line;
   - a non-debit record whose source contains "debitID".
   The lookup must equal `recordedDebitIDs().intersection(candidates)`.
3. Only if step 3 is implemented: block a gated sink, and while it is blocked, expect `store.listenerCount == 1` and `intentListenerCount == 1`.

RetentionTests :137, :169 (adapted), :255 and :303 must still pass. Time a full set only outside the gating suite.

**Related findings**

- A5: start() checks isShutDown only at its top, and its probe11 delays through SlowRepairSink's recordedDebitIDs().
  - A step-3 reorder must add A5's isShutDown checks after every await.
  - After step 1, probe11 and RetentionTests.swift:169 must put their delay or shutdown in lastRecordHash(), because recordedDebitIDs() is no longer called when there is no debit.
  - Verifier 1's "A11/probe11" refers to A5.
- A4: concurrent refreshes, where the last one to finish wins. Step 3 makes refresh(.launch) overlap the launch .foreground refresh, so land step 3 with A4's fix or after it.
- Steps 1 and 2 do not depend on either finding.

**Verification**

Reported by reviewer A as low. Verifier 1 (code trace): confirmed, low. Verifier 2 (reachability and reproduction): confirmed, narrower than reported, low; reachable in production: yes, with preconditions. Judge: confirmed, narrower than reported, low.

Verifier 1 said confirmed and verifier 2 said partly_confirmed. I side with partly_confirmed.

Agreed by both, and confirmed in my own reading:
- The mechanism is exactly as reported (GateEngine.swift:286, :630; Audit.swift:147-181).
- The `.unknown`-after-journal-loss case is wrong: entitlement.json is a separate file (GateEngine.swift:263, :745-752).

The disputed "before StoreKit is consulted": the scene-phase path (PaywallSignals.swift:217-219 → GateEngine+Store.swift:278-279) does not wait for start(). In the documented iOS setup it therefore resolves during the scan, provided SwiftUI delivers the launch inactive→active change to `onChange`. That can only be checked on a device and is unverified; a secondary source says it does on iOS. macOS is a test host only (README), so its stale window does not matter.

Still unverified:
- The timings come from verifier 2's script, run on an M3. I inspected it but did not rerun it. Device, iOS 15/16 and background-launch costs are not measured.
- Delivery of unfinished transactions when the listener starts late rests on Apple's tvOS 15.4 release note. iOS before 15.4, and whether PurchaseIntent buffers intents, are not verified.

The finding's proposed SlowRepairSink test covers only a reorder, so I replaced it.

<a id="b2"></a>
### B2 · low · ProductionVPP receipts are labelled .xcode, but this is latent: the VPP receipts seen so far lack fields 18/19 and fail closed before the switch

**Verdict.** Confirmed, narrower than reported. **Fix group:** G4. **Status:** open.

**Where**

- Sources/PaywallKit/ReceiptClient.swift:49-53: the receipt-type switch. Any unmatched value, ProductionVPP and ProductionVPPSandbox included, falls to `default: .xcode` at :52.
- Sources/PaywallKit/ReceiptClient.swift:45-47: returns nil when field 19, 18 or 2 is missing, or when field 18 is not ISO-8601. This runs before the switch.
- Sources/PaywallKit/ReceiptClient.swift:240-243: `ASN1.string` returns "" for an empty string value, so an empty field 19 gets past the guard.
- Sources/PaywallCore/EntitlementResolver.swift:30, :46: the default `[.production]` and the environment gate. At :48 and :55 an empty version passes both the numeric compare and the sentinel check.
- Sources/PaywallKit/StoreKit2Client.swift:41, :48, :54, :190-195: AppTransaction `try?`/`.verified`, the environment map, and the receipt fallback. The finding's :46 is the `originalAppVersion` line.
- Sources/PaywallCore/GateEngine+Store.swift:21-22, :51-54: binds and persists a snapshot only when it is non-nil.
- Sources/PaywallCore/GateEngine.swift:604: the audit environment label comes from the bound snapshot.
- Tests/PaywallKitTests/ReceiptClientTests.swift:68-73 (fixture), :93-99, :332-341, :404.
- HANDBOOK.md:383-401; README.md:235-252.

**Defect**

ReceiptClient.parse classifies Apple's documented `ProductionVPP` and `ProductionVPPSandbox` receipt types as `.xcode` (ReceiptClient.swift:52). A VPP receipt that parsed would therefore be refused by the default `[.production]` grandfathering policy and audited as "xcode". The reported user impact is not established. The only publicly examined VPP receipts leave fields 19 and 18 empty, so parse returns nil at :45-47 before reaching the switch, and VPP installs fail closed whatever the mapping says. The claim that iOS 16+ VPP users keep the grant through AppTransaction is unsupported: reports say AppTransaction does not serve VPP installs.

**Failure scenario**

This needs a receipt shape no one has observed. A paid app goes freemium with the documented policy (default environments `[.production]`). An organisation bought it through Apple School Manager or Apple Business Manager. The install takes the receipt path: always on iOS 15, and on iOS 16+ whenever AppTransaction.shared throws or comes back unverified (StoreKit2Client.swift:41, :54), which reportedly happens on every VPP install. Suppose that VPP receipt had a non-empty field 19 and an ISO-8601 field 18 inside the paid window. Then parse returns `.xcode` and `admits` fails at EntitlementResolver.swift:46. The user resolves to `.free` instead of the `.lifetime` grant, and audit records say "xcode" (GateEngine.swift:604). With the shape actually observed (fields 19 and 18 empty), parse returns nil at ReceiptClient.swift:45-47 and nothing is bound (GateEngine+Store.swift:21-22). The outcome is then identical before and after a remap: VPP installs are never grandfathered.

**Evidence**

Code, read at b5c20e4:
- ReceiptClient.swift:49-53 matches only "Production", "ProductionSandbox" and "Sandbox". Anything else becomes `.xcode`.
- EntitlementResolver.swift:46 rejects `.xcode` under the default at :30. README.md:66-67 and HANDBOOK.md:37-38 both use that default.
- AppleReceiptVerifier.swift:44 reads only field 12, so nothing filters on the receipt type before parse.
- The guard at ReceiptClient.swift:45-47 runs before the switch. An empty or absent field 18 returns nil. An empty string in field 19 becomes "" (:240-243) and passes the guard.

Reproduction: both verifiers ran `swift test` probes built on `DER.receipt(fields:)`; the probes are now deleted. I ran nothing.
- With fields 18/19 filled: ProductionVPP gives `environment=xcode admits=false` and Production gives `admits=true`. On an isolated FakeStore facade, an iOS 15 VPP receipt resolves to `free`.
- Verifier 2: a VPP receipt with 19/18 empty or absent returns `nil` in all four combinations. The iOS 16 fallback to such a receipt binds nothing and keeps the grant.
- Verifier 2: 19 empty with 18 valid gives `version='' admitsIfMappedToProduction=true`.
- Local Mac App Store receipts: 7 Production, 3 ProductionStub, 0 ProductionVPP.

External sources (I re-checked GitHub only):
- AppReceiptValidator's UnofficialReceipt.swift lists "ProductionVPP" as a field-0 value it has encountered.
- Its issue #96 (Nov 2023): the author's 2017 VPP receipt has an empty originalAppVersion and an empty field 18. A contributor confirms this for 2017/2018 files and has no recent one. The author says AppTransaction does not support VPP.
- The Apple forum reports (2022, 2024) and the Apple docs are as verifier 2 reported them; I did not re-fetch them.

**Fix direction**

1. In ReceiptClient.parse (ReceiptClient.swift:49-53), add exact matches: "ProductionVPP" maps to `.production` and "ProductionVPPSandbox" to `.sandbox`. Keep the existing four values.
   - Do not match on a "Production" prefix: it would admit ProductionSandbox, ProductionVPPSandbox and ProductionStub.
   - An unknown or missing field 0 stays `.xcode`, so it still fails closed.
   - Do not add a StoreEnvironment case: the enum is public, CaseIterable and Codable, and its raw values are the audit vocabulary.
   - Optional: log unknown types in `snapshot()` or StoreKit2Client, because parse is a pure static with no logger. Do the same for StoreKit2Client.swift:194.
2. Ship this with step 1, or the fix fails open: treat an empty field 19 as missing, so parse returns nil. Today "" compares ascending against any lastPaidBuild and skips the "1.0" sentinel check (EntitlementResolver.swift:48, :55).
3. If VPP receipts become admissible, read field 21 (the VPP-only expiration date) and fail closed once it has passed. Apple's archived receipt-field guide says to compare it with the current date; I did not re-fetch it. parse has no clock, so do the check in `snapshot()` or pass `now` in. Otherwise, document why the date is ignored.
4. No migration is needed. The next refresh re-parses and re-binds (GateEngine+Store.swift:21-22), and the grant id at :72 is idempotent.
5. Docs:
   - Add the receipt-type mapping to HANDBOOK.md:383-401.
   - Add a README limitation (README.md:239-252): VPP installs are not grandfathered. The VPP receipts examined so far carry no original version or purchase date, and AppTransaction reportedly does not serve VPP installs.
6. Optional: ReceiptClientTests.swift:339-341 calls every non-Production receipt a stub, and :404 asserts `== "Production"`.

**Regression test (the finding is fixed when this passes)**

All of these go in PaywallKitTests, suite "Receipt (iOS 15 path)" (Tests/PaywallKitTests/ReceiptClientTests.swift). They are pure parse tests using Foundation and Testing, and they build for macOS 14.

(1) A parameterised `receipt_type_maps_every_apple_value` that replaces :93-99. Use `receiptFields` (:68-73) with field 0 set as follows, and assert `parse(DER.receipt(fields:))?.environment`:
- Production → .production
- ProductionVPP → .production
- ProductionSandbox → .sandbox
- ProductionVPPSandbox → .sandbox
- Sandbox → .sandbox
- Xcode → .xcode
- ProductionStub → .xcode
- "SomethingNew" → .xcode
- field 0 absent → .xcode

(2) `vpp_receipt_without_purchase_history_fails_closed`: field 0 ProductionVPP and field 2 "com.ztron.app". Make fields 19 and 18 each either empty (`DER.utf8("")`, `DER.ia5("")`) or absent. parse must return nil in all four combinations.

(3) `empty_original_version_is_never_admitted`: field 0 set to ProductionVPP, and separately to Production; field 19 ""; field 18 "2024-03-01T10:00:00Z". Use a policy with lastPaidBuild "116" and a paid window from 2020 to 2025. Assert that parse returns nil or `admits` is false. A plain remap fails this test.

(4) If the fix reads field 21: a past date is not admitted and a future date is.

**Related findings**

No other finding id is known to interact with this one. Within this fix, the empty-version guard (fix step 2) must land in the same change as the ProductionVPP remap, never after it, or the remap fails open. The README limitation that VPP installs are never grandfathered is a separate gap that verifier 2 raised; document it in the same change.

**Verification**

Reported by reviewer B as medium. Verifier 1 (code trace): confirmed, medium. Verifier 2 (reachability and reproduction): confirmed, narrower than reported, low; reachable in production: unknown. Judge: confirmed, narrower than reported, low.

The verifiers agree on the code; they split on the external facts.
- Verifier 1 (confirmed, medium) traced the code correctly but assumed VPP receipts carry fields 18/19.
- Verifier 2 (partly_confirmed, low) found that the VPP receipts examined so far leave those fields empty, so parse returns nil before the switch. It also found reports that AppTransaction does not serve VPP installs.

I re-read every load-bearing line, and both verifiers' code facts hold. I re-checked the GitHub sources, which support verifier 2, though the receipts date from 2017/2018. I side with verifier 2: the "medium" rating assumed the mapping causes the loss, and no observed receipt shows that.

Citation fixes:
- StoreKit2Client.swift:46 should read :41/:48/:54/:190-195.
- The iOS 16+ drop lasts until the next refresh that gets a verified AppTransaction, not until the next launch.

Unverified, and only checkable on a VPP-assigned device: what fields 0, 18, 19 and 21 hold in a current iOS VPP receipt, whether AppleReceiptVerifier accepts it, and how AppTransaction behaves for device-assigned versus user-assigned VPP licences.

<a id="b7"></a>
### B7 · low · Coverage gate fails open for a target with no coverage data when --targets is absent, and --write-baseline replaces the baseline with the measured subset

**Verdict.** Confirmed, narrower than reported. **Fix group:** G8. **Status:** open.

**Where**

- Scripts/coverage-gate.sh:137: without --targets, the expected set is just the measured targets.
- :144-148: the "missing" branch, which cannot fire in that mode.
- :163-164: crash-critical files are skipped when PaywallCore is unmeasured.
- :174-184: the ratchet. :174 `os.path.exists` silently turns it off; :177 walks measured targets only; :179-180 skip; :182 has a +0.01 tolerance.
- :187-190: write-back dumps the measured summary (:189).
- :132-138: no region data reads as 100%.
- :108, :131: the target name comes from Sources/<dir>.
- :5-6, :19, :186: header claims.
- .github/workflows/test.yml:74-75: macOS call, no --targets.
- test.yml:130: Linux call with --targets.
- HANDBOOK.md:630 and :611-612.
- coverage-baseline.json:1-22: five keys.
- Package.swift:85-93: only PaywallSimulatorTests links PaywallSimulator.

**Defect**

CI's macOS call passes no --targets (test.yml:74-75), so the gate expects only the targets that show up in the coverage data (Scripts/coverage-gate.sh:137). A target with no data is never reported: the "missing" branch (:144-148) cannot fire, the ratchet walks only measured targets (:177-180), the crash-critical files are skipped when PaywallCore is unmeasured but another target is (:163), and `--write-baseline` replaces the file with the measured subset (:189). This contradicts HANDBOOK.md:630. Neither reported trigger produces it. The real triggers are renaming or moving a target directory and writing back a subset run.

**Failure scenario**

(1) Sources/PaywallKit is renamed, for example to match its ZTronPaywallKit product. The macOS job lists the new key, which has no baseline entry, and never mentions PaywallKit. The 98.18% lines / 84.09% regions ratchet stops applying and only the 97% lines floor remains, so the same PR can lose region coverage and stay green. Renaming PaywallCore fails the Linux job (test.yml:130 reports it missing) until that line is edited. If CRITICAL (:34-42) is not edited too, all seven crash-critical checks are then skipped on both jobs.

(2) `--targets "PaywallCore PaywallTesting" --baseline coverage-baseline.json --write-baseline coverage-baseline.json` exits 0 and leaves two keys. Committing that drops the three Darwin-only ratchets, which shows as a diff.

The scenario as reported cannot happen. SwiftPM builds one umbrella PackageTests.xctest, so a discovery miss exits 2 (:76-79). Every target is also measured by swift test and the package xccov lane, so a host-lane change only lowers numbers, and the ratchet catches that.

**Evidence**

Code at b5c20e4:
- Scripts/coverage-gate.sh:137 `requested = targets_arg.split() if targets_arg.strip() else sorted(by_target)`. test.yml:74-75 passes `--baseline` and two `--xccov` but no `--targets`.
- :145 `if t is None:` is the only missing-target failure.
- :163 `if requested and target not in requested: continue`.
- :174 `if baseline_path and os.path.exists(baseline_path):`, then :177 `for target, numbers in summary.items():` and :179-180 `if not before: continue`.
- :189 `json.dump(summary, out, indent=2, sort_keys=True)`.
- :132-138: a target with no llvm-cov file keeps regions [0,0], and `pct` returns 100.0 for it.
- README.md:235-252 does not list this. HANDBOOK.md:630 and the script header (:5-6) claim the opposite.

Reproduction (verifier 2, the real script, not the extracted Python): the copy is byte-identical to b5c20e4, which I re-checked with cmp. It ran under bash with only `swift` (its two path queries) and `xcrun llvm-cov export` stubbed. Results:
- PaywallCore-only export with `--baseline`: "coverage gate: passed", exit 0, empty ratchet section.
- The same with `--write-baseline`: the written file holds only PaywallCore.
- PaywallCore under Sources/Core: passed, with an empty crash-critical section.
- `--targets "PaywallCore PaywallTesting" --baseline B --write-baseline B`: exit 0, and B keeps two keys.

The controls behave as expected:
- An explicit `--targets` reports `missing` and exits 1.
- PaywallKit at 98.00% fails the 98.18% ratchet.
- An export with no Sources files fails on the seven critical files.
- A bundle nested below depth 1 exits 2.

I read the written baselines in verifier 2's scratch directory. Reviewer B's own probe was deleted, and the output it reported matches the first result. I ran nothing myself.

**Fix direction**

Change Scripts/coverage-gate.sh only. Keep the coverage-baseline.json format, and keep both CI calls (test.yml:74-75 and :130) passing.

1. Expected set. Load the baseline before :137. Without `--targets`, request the union of the measured and baseline targets, so a vanished target hits the existing missing branch (:144-148). With `--targets`, keep the explicit list and skip the union, or a Linux run with `--baseline` fails on the three Darwin-only keys. An alternative is to derive the expected targets from `swift package describe --type json`.
2. Make a `--baseline` path that does not exist an error (exit 2) instead of a silent skip (:174). The exception is a path equal to `--write-baseline`, which is a bootstrap.
3. Without `--targets`, check every CRITICAL file, so a missing one prints `FAIL (no data)`. At :163, test `targets_arg.strip()` instead of `requested`.
4. Write-back merges into the file being written and replaces only the targets measured in this run. It must also ratchet against that file even without `--baseline`. :19 and :186 promise a ratchet that never lowers, but today that holds only when both flags are given.
5. Give a deliberate rename or removal an explicit way to retire a key: a documented hand edit of coverage-baseline.json in the same change, or a flag. Without it, union plus merge deadlocks: the old key reports missing, so the write at :187 never runs.
6. A target with no region data must read n/a, not 100% (:132-138). It must fail when its baseline has a regions number, and it must never be written as 100.0.

Optional: the `+ 0.01` at :182 lets each write-back lower a number by 0.01. Both sides are rounded to two decimals, so a 1e-6 epsilon is enough.

Merging does not make a wrong-shape run safe to write back; HANDBOOK.md:611-612 still applies. Update HANDBOOK.md:630 and the header (:5-6, :19) to match.

**Regression test (the finding is fixed when this passes)**

This is a script test, not a Swift test. Add Scripts/coverage-gate-selftest.sh (bash plus python3) and run it as a step in the ubuntu-latest `forbidden-constructs` job.

Setup:
- Copy coverage-gate.sh into a `mktemp -d` root (resolved with `pwd -P`), with a five-key baseline fixture.
- Put stubs first on PATH. `swift` answers only `test --show-codecov-path` (a path beside an empty default.profdata) and `build --show-bin-path` (a directory holding one X.xctest).
- `llvm-cov` and `xcrun` both print $STUB_EXPORT, because :56 calls `llvm-cov` off Darwin and `xcrun llvm-cov` on Darwin.
- Exports use llvm-cov's summary shape, under $root/Sources/<Target>/, with the seven CRITICAL files at 100/100.

Assert:
- (a) PaywallCore-only export, `--baseline`, no `--targets`: exit 1, with four targets `missing`.
- (b) (a) plus `--write-baseline` on a copy: exit 1, and the copy is unchanged (cmp).
- (c) All five targets with `--targets "PaywallCore PaywallTesting" --baseline B --write-baseline B`: exit 0, and B keeps all five keys unchanged.
- (d) PaywallCore under Sources/Core: exit 1, with seven `FAIL (no data)`.
- (e) A `--baseline` path that does not exist: non-zero exit.
- (f) PaywallSimulator only in an `--xccov` report: exit 1.
- (g) Control, all five at 100/100: exit 0.

**Related findings**

none. No other finding touches Scripts/coverage-gate.sh, coverage-baseline.json or the CI gate steps.

**Verification**

Reported by reviewer B as low. Verifier 1 (code trace): confirmed, narrower than reported, low. Verifier 2 (reachability and reproduction): confirmed, narrower than reported, low; reachable in production: yes, with preconditions. Judge: confirmed, narrower than reported, low.

Both verifiers returned partly_confirmed / low and agree on the code. I re-read every cited line in the export of `b5c20e4`:
- The finding's :175-185 is really :174-184, with :177 and :179-180 decisive.
- The critical-file skip is :163-164.
- The missing branch is :144-148.

Both refute the finding's triggers:
- SwiftPM's default umbrella test product makes bundle discovery all-or-nothing. Verifier 2 cites PackageBuilder for this; I did not re-check it.
- swift test, the package lane and the host lane all measure each target the host links (TestHost/TestHost.xcodeproj/project.pbxproj:10-13, :58-61).

"Drops both targets for good" overstates it: a later CI-shaped write restores the keys. What is lost is the ratchet values, and that shows as a diff.

Unverified:
- Whether Xcode's xccov report lists a library that no test bundle links. This decides whether deleting PaywallSimulatorTests (Package.swift:85-93) makes PaywallSimulator vanish silently.
- Whether a future SwiftPM build system emits one bundle per test target.

There was no real CI run; only stubs.

<a id="b8"></a>
### B8 · low · A promotional-offer signature mismatch writes the unredeemed JWS to audit.jsonl, the export zip and host-wired sinks (OSLog redacts it). Only a non-echoing custom signer can trigger it.

**Verdict.** Confirmed, narrower than reported. **Fix group:** G7. **Status:** open.

**Where**

- Sources/PaywallCore/PromotionalOffer.swift:54: `signatureMismatch(received: SignedPromotionalOffer)` carries `compactJWS`.
- Sources/PaywallCore/GateEngine+Store.swift:254-256: the mismatch guard throws the signer's whole answer.
- Sources/PaywallCore/GateEngine+Store.swift:220: emits `.purchase(stage: .failed(String(describing: error)), …)`.
- Sources/PaywallCore/GateEngine.swift:610-617: emit sends the event to the audit trail and to `onEvent`.
- Sources/PaywallCore/Audit.swift:238 fans the record out to every sink. :112-126 is JournalSink, which writes the line verbatim. :84 is ClosureSink.
- Sources/PaywallKit/Paywall.swift:154-157: the default sinks are JournalSink and OSLogSink.
- Sources/PaywallKit/Paywall+Audit.swift:32,47: the export copies the audit files into the zip.
- Sources/PaywallKit/PaywallSignals.swift:364: the notification userInfo carries the error text.
- Sources/PaywallKit/OSLogSink.swift:23: the detail is logged as `privacy: .private`, so it is redacted here (no leak).
- The docs it contradicts: Sources/PaywallCore/PromotionalOffer.swift:22-23 and HANDBOOK.md:352.
- The test that pins the current error shape: Tests/PaywallCoreTests/PromotionalOfferTests.swift:109-124.

**Defect**

On a mismatch the engine throws `PromotionalOfferError.signatureMismatch(received:)` holding the signer's full answer, and `purchase` records `.failed(String(describing: error))`. The default printing writes the compact JWS out in full. That puts it in audit.jsonl, in the zip from `exportAudit()`, in ClosureSink records, in `onEvent` and in the notification userInfo. If the signer added a `transactionId` claim, which the package sends on iOS 18.4+, the per-account appTransactionID goes too. OSLogSink redacts it, so the reported "every sink" is wrong. The shipped worker and RemotePromotionalOfferSigner always echo the requested ids, so the trigger needs a host-written signer, a third-party signer or a compromised one. The behaviour contradicts "never stores it/one".

**Failure scenario**

1. A host configures its own `PromotionalOfferSigner`, for example an App Attest client as README.md:206 invites, or a non-shipped server that "speaks its JSON" (RemotePromotionalOfferSigner.swift:29-30).
2. A bug makes the signer return pro.yearly when asked for pro.monthly.
3. Each offer purchase fails before the payment sheet. Nothing is charged and no credit or ledger state changes.
4. Each attempt appends a hash-chained audit.jsonl record holding the unredeemed JWS. `exportAudit()` zips that record, and an analytics ClosureSink or NotificationCenter observer that forwards the error text sends it to the host's vendor.

The impact is small. The JWS is single-use (nonce) and expires, and a `transactionId` binds it to one account. The endpoint is public anyway (README.md:225). The appTransactionID is already stored in clear in app-transaction.json (GateEngine.swift:736), and the export carries it inside `app-transaction.signed` (Paywall+Audit.swift:51).

**Evidence**

Code (judge re-read at b5c20e4):
- GateEngine+Store.swift:254-256: `guard signed.productID == productID, signed.offerID == offerID else { throw PromotionalOfferError.signatureMismatch(received: signed) }`
- GateEngine+Store.swift:220: `emit(.purchase(stage: .failed(String(describing: error)), …))`
- A grep of Sources/, Tests/ and TestHost/ finds no CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable, LocalizedError or CustomNSError conformance, so the default reflection printing applies.
- Audit.swift:238 sends every record to every sink.
- OSLogSink.swift:23 logs the detail as `.private`.
- StoreKit2Client.swift:106-125 does not wrap the offer into any error. RemotePromotionalOfferSigner.Failure carries no token. So the mismatch is the only path.
- The worker cannot mismatch. app.ts:80-84 echoes `offer.productId` and `offer.offerId`. validate.ts:23-37,50 returns the input strings unchanged and refuses anything outside `[A-Za-z0-9._-]`. RemotePromotionalOfferSigner.swift:84,92 round-trips the ids as-is.

Reproduction (verifier 2):
- Throwaway suite `VerifierB8Probe`, run with `swift test --filter VerifierB8Probe`.
- Setup: an isolated `Paywall()` with the default audit sinks, the real `RemotePromotionalOfferSigner`, and only its transport scripted to a 200 that names pro.yearly.
- Output: `audit.jsonl contains JWS: true`, `closure sink saw JWS: true`, `export zip contains JWS: true`. The control with a matching answer printed false for all three. Both tests passed.
- Verifier 2 also drove the worker's real `handleRequest` with 96 adversarial id variants: `idMismatch=0`.

Reviewer B's own probe used `FakePromotionalOfferSigner(next: .answer(...))`. Its output matches the default printing. The judge built and ran nothing.

**Fix direction**

**Preferred: Option A.** Change the case to carry only the received ids, for example `signatureMismatch(productID: String, offerID: String)`.
- This removes the token from the error value itself. That also covers host code that logs `"\(error)"`, `String(reflecting:)`, `dump()` or Mirror-based crash and analytics SDKs.
- It keeps the diagnosis a misconfiguration needs: which product and offer the signer named.
- It breaks source for the public `PromotionalOfferError`, which was introduced in b5c20e4.
- Update Tests/PaywallCoreTests/PromotionalOfferTests.swift:109-124, which matches `.signatureMismatch(received:)`.

**Weaker: Option B,** a redacting `CustomStringConvertible` on `SignedPromotionalOffer`.
- It fixes `String(describing:)`.
- It does not hide the field from `dump` or Mirror unless `CustomReflectable` is added too.
- It regresses silently if someone later adds a non-redacting `CustomDebugStringConvertible`.
- It redacts every test failure message.

**Constraints:**
- Keep the shape of `PurchaseStage.failed(String)` and every persisted format.
- The mismatch already throws before `store.purchase`; keep it that way.
- Do not rewrite existing audit.jsonl records. They are hash-chained (Audit.swift:44-58, `firstBrokenLink`), and rotation ages them out.
- Keep Sources/PaywallCore/PromotionalOffer.swift:22-23 and HANDBOOK.md:352-354 accurate. Add that the `.failed` text is `String(describing:)` of whatever the signer throws, so a host-written signer's own errors must not embed tokens or App Attest assertions. The package cannot redact those.
- Leave OSLogSink alone; it already redacts.

**Regression test (the finding is fixed when this passes)**

**Core test.** Add `a_mismatched_answer_keeps_the_signature_out_of_the_audit_and_the_error` to Tests/PaywallCoreTests/PromotionalOfferTests.swift, suite "Promotional offers".
- Setup: `FakePromotionalOfferSigner(next: .answer(SignedPromotionalOffer(productID: "pro.yearly", offerID: "comeback", compactJWS: "h.p.UNREDEEMED-SIG")))` and the existing `harness(signer:)`.
- Act: `h.engine.purchase(productID: "pro.monthly", offer: Self.comeback, source: nil)`.
- The error is the mismatch case and still names pro.yearly and comeback.
- Neither `String(describing:)` nor `String(reflecting:)` of the error contains "UNREDEEMED-SIG".
- No record from `await h.records()` contains it when encoded with `CanonicalJSON.encoder()`.
- The single `.purchase(.failed(text))` event in `h.events` does not contain it.
- `h.store.purchaseCalls == 0`.

**Facade test.** Add a companion to Tests/PaywallKitTests/PromotionalOfferTests.swift. The core harness collects records in memory, so this test covers the file.
- Use an isolated `Paywall()`, not `.shared`, with `includesDefaultAudit = true`, `makeTemporaryPaywallDirectory()`, a ClosureSink capture, and `RemotePromotionalOfferSigner` over `ScriptedTransport` returning a 200 that names pro.yearly.
- After `flushAudit()`, the JWS is absent from audit.jsonl, the ClosureSink records and the `.failed` text.
- Use macOS 14 APIs only.

**Related findings**

none

**Verification**

Reported by reviewer B as low. Verifier 1 (code trace): confirmed, narrower than reported, low. Verifier 2 (reachability and reproduction): confirmed, narrower than reported, low; reachable in production: yes, with preconditions. Judge: confirmed, narrower than reported, low.

Both verifiers judged it real but narrower (partly_confirmed, low), and the judge's own re-read agrees.

**Corrections to the report:**
- "Every sink" is wrong. OSLogSink logs the detail as `.private` (OSLogSink.swift:23).
- A "misconfigured signer" cannot be the shipped worker. It echoes the validated ids, and its secrets cannot change that.
- Third-party exposure happens only if the host wires a ClosureSink, `onEvent` or a notification observer to analytics.
- The appTransactionID is not new exposure overall: app-transaction.json and app-transaction.signed already hold it. It is new to the audit and event text.

**Unverified:**
- Apple's single-use, expiry and account-binding semantics for the JWS, and whether app-transaction.signed carries appTransactionId. Both come from Apple's documentation as cited by verifier 2; nothing here exercised a real App Store server.
- OSLog redaction on a device.
- Whether `PromotionalOfferError` has shipped to consumers yet, which decides the cost of the source break.

<a id="b9"></a>
### B9 · low · ASN1.parseNode has no depth bound and copies every subtree, so a crafted ~8 KB receipt crashes the receipt path before verification (self-DoS)

**Verdict.** Confirmed. **Fix group:** G4. **Status:** open.

**Where**

- Sources/PaywallKit/ReceiptClient.swift:193-237: parseNode. It recurses at :207 (indefinite length) and :232 (definite length). The finding's :231 is the loop header. It copies subtrees at :212 (raw) and :236 (contents + raw).
- Sources/PaywallKit/ReceiptClient.swift:188-191: the ASN1.parse entry. Its callers are :112 (container), :133 (payload fields) and :241 (field strings).
- Sources/PaywallKit/ReceiptClient.swift:35-37: reads the whole file with no size limit, then calls the verifier. :109 copies the file into [UInt8].
- Sources/PaywallKit/AppleReceiptVerifier.swift:
  - :37: the full parse runs first.
  - :44: payload fields are parsed before the signature loop at :46.
  - :117: certificates are re-parsed.
  - :96-97: `raw[0]` is mutated, which breaks if raw becomes a slice.
  - :16: the doc says "Fails closed on any parse error".
- Sources/PaywallKit/StoreKit2Client.swift:38-54: the @concurrent appTransaction. The receipt fallback is at :54.
- Launch and foreground path:
  - Sources/PaywallCore/GateEngine+Store.swift:21 (refresh) and :279 (foreground).
  - Sources/PaywallCore/GateEngine.swift:298 (launch).
  - Sources/PaywallKit/Paywall.swift:48 (StoreKit2Client is the default store).
- HANDBOOK.md:385: claims the verifier runs "before anything is parsed".

**Defect**

`ASN1.parseNode` recurses once per nesting level with no depth limit (ReceiptClient.swift:207, :232). An unterminated indefinite-length level costs only 2 bytes. Each definite node stores `Array(contents)` and `Array(raw)` of its whole subtree (:236), and each indefinite node stores `Array(raw)` (:212), so memory grows as about 2 × depth × size. The whole tree is built from the unverified receipt before any signature check (AppleReceiptVerifier.swift:37, :44). Deep input therefore overflows the 512 KiB cooperative-pool stack and kills the process, instead of failing closed as AppleReceiptVerifier.swift:16 promises.

**Failure scenario**

**Trigger.** Someone who can replace the file at `Bundle.main.appStoreReceiptURL` writes about 8 KB of nested BER. On iOS that means root or a jailbreak, and possibly a same-user process for an iOS app on an Apple-silicon Mac. A Release build needs about 2,000 well-formed levels or about 4,000 `30 80` headers; Debug needs about 400.

**Effect.**
- iOS 15: every refresh takes the receipt path (launch at GateEngine.swift:298, foreground, purchase, restore), and the app dies with SIGBUS.
- iOS 16+: the same happens only when `AppTransaction.shared` throws or comes back unverified.

**Limits.**
- Natural corruption cannot reach this depth: random corruption tops out at depth 12.
- It only hurts the person who planted the file:
  - nothing verifies;
  - nothing is persisted, because bind runs only on success;
  - removing the file or reinstalling ends it.
- There is no remote, CloudKit or cross-user path. The parser is reached only from `ReceiptClient.snapshot()`, and the cached signedPayload is never re-parsed.

**Evidence**

**Code at b5c20e4.**
- ReceiptClient.swift:207 `guard let child = parseNode(bytes, &index) else { return nil }` and :232 `guard let child = parseNode(contents, &inner) else { return nil }`. Neither passes a depth, and the end-of-contents check (:210) runs only after the child returns.
- :236 `Node(tag: tag, contents: Array(contents), children: children, raw: Array(bytes[start..<index]))`, and :212 copies raw.
- AppleReceiptVerifier.swift:37 runs the full parse (ReceiptClient.swift:112), and :44 parses the payload before the signature checks at :46-57.
- Path: GateEngine.swift:298 → GateEngine+Store.swift:21 → StoreKit2Client.swift:54 → ReceiptClient.swift:36-37, on a cooperative-pool thread (@concurrent, :38). The `try?` cannot catch a stack overflow.
- No test covers depth or size (ReceiptClientTests.swift:113-160).

**Reproduction (verifier 2).** The probe has since been deleted. It used the real AppleReceiptVerifier and ReceiptClient.snapshot() on a temp file, called from a @concurrent function (stack 536,576 B) on macOS arm64.
- Debug: 300 levels survive; 400, 500 and 1,000 die with signal 10. The crash report says "Thread stack size exceeded due to excessive recursion" in parseNode.
- Release:
  - terminated indefinite: survives 1,750, dies at 2,000 (8,000 B);
  - definite: survives 1,500, dies at 2,000 (7,829 B);
  - unterminated: survives 3,500, dies at 4,000.
- The well-formed Release inputs die in the tree's recursive deinit (destroy for ASN1.Node).
- parseNode's frame is 144 B in both the macOS and the iOS-SDK release objects.
- Memory: a 1 MB leaf under 200 levels peaks at 452.8 MB RSS, against 83.2 MB at baseline.
- Fuzz: 20,000 corruptions reach a maximum depth of 12, with no crash.
- Reviewer B's Debug run agrees: 200 levels survive, 500 crash, and a 1,502-byte nest holds 451,202 B.

I ran nothing.

**Fix direction**

**1. Required: a depth budget in parseNode.**
- Add an internal depth parameter that ASN1.parse starts at 0. Put `guard depth < max else { return nil }` on entry, and pass depth + 1 at both :207 and :232.
- Returning nil keeps everything fail-closed:
  - SignedReceipt becomes nil;
  - isAuthentic returns false;
  - snapshot() returns nil;
  - ReceiptClient.parse throws .malformed.
- Every ASN1.parse entry starts at 0: the container (:112), the payload (:133), string (:241) and certificates (AppleReceiptVerifier.swift:117).
- The budget must reject deep input outright. An iterative parser alone is not enough, because in Release a tree about 2,000 levels deep still crashes in its recursive deinit.
- Choosing the budget:
  - Observed receipts nest 10-11 levels. ESS-style signed attributes could reach about 17-18. 32 covers both; 64 gives more margin for about 9 KB of stack.
  - A budget set too low fails closed on genuine receipts. iOS 15 users would then lose grandfathering, a critical regression.
  - Prove the budget against the fixture tests (ReceiptClientTests.swift:201 and :288), the Mac App Store receipt test (:324-325) and ProductionReceiptTests (:355, PAYWALL_PRODUCTION_RECEIPT).

**2. Recommended: store ArraySlice or ranges instead of copies at :212 and :236.**
- AppleReceiptVerifier.swift:96-97 must copy first (`var set = Array(attributes.raw)`). On a slice, `set[0]` traps.
- ReceiptClient.swift:122 needs `Array($0.raw)`.
- octetBytes must still return [UInt8].
- These types are internal, so no public API or persisted format changes.
- Without slices, the copies still multiply memory by about 2 × budget.

**3. Optional.**
- Cap the file size before the read at :36, set well above any genuine receipt.
- Reword AppleReceiptVerifier.swift:16 and HANDBOOK.md:385.

**Regression test (the finding is fixed when this passes)**

**Where:** target PaywallKitTests, file Tests/PaywallKitTests/ReceiptClientTests.swift, in a new suite such as "Receipt parser bounds". It needs no Paywall.shared.

**Inputs:**
- open(n): `[0x30,0x80]` repeated n times.
- indefinite(n): open(n) followed by `[0,0]` repeated n times.
- definite(n): n nested SEQUENCEs. This needs a tlv helper that emits 0x83/0x84 lengths, because DER.tlv (:11-21) stops at 0xFFFF.
- Sizes: n = 100_000 for open and indefinite, 20_000 for definite. At these depths the pre-fix code crashes in Release as well.

**Assertions**, made from a @concurrent helper:
- `ASN1.parse(x[...]) == nil`.
- `AppleReceiptVerifier().isAuthentic(Data(x)) == false`.
- `ReceiptClient.parse` throws `.malformed`.
- `ReceiptClient(receiptURL: tmp, verifier: AppleReceiptVerifier(), expectedBundleID: nil).snapshot() == nil`.

**Payload case:** a shallow container whose payload is deeply nested. It must not crash, and `ReceiptClient.parse` must return nil.

**Boundary:** a nest exactly at the budget parses, and budget + 1 returns nil. The fixture tests must stay green.

**Slices:** if the fix uses slices, assert that node storage lies inside the input buffer. Summing `.count` does not show this.

**Related findings**

**B1 sets the order.** One of B1's fix options re-verifies the cached signedPayload in app-transaction.json with AppleReceiptVerifier on load. On stock iOS that file can be written through an edited, restored backup, so with that option this crash would be reachable without a jailbreak and would recur at every launch. Land B9's depth budget first or in the same change.

**A11 / A11-B6:** stopping the fallback when AppTransaction is unverified narrows where B9 can trigger on iOS 16+. No ordering constraint.

**B6:** the field-5 GUID check edits the same ReceiptClient/AppleReceiptVerifier code. Merge carefully; no ordering constraint.

**Verification**

Reported by reviewer B as low. Verifier 1 (code trace): confirmed, low. Verifier 2 (reachability and reproduction): confirmed, low; reachable in production: yes, with preconditions. Judge: confirmed, low.

Both verifiers confirmed the finding and agree on the substance. Points I resolved:
- **Citation:** the recursive call is at :232, not :231.
- **"Corrupted":** dropped from the trigger. The fuzz tops out at depth 12, so only a file crafted on purpose triggers it.
- **"macOS affected":** true of the macOS 12 code, but README.md:233 says not to ship on macOS.
- **HANDBOOK.md:385:** imprecise, not contradictory.
- **Severity:** low. It is a self-DoS that needs root or a jailbreak, gains the attacker nothing and damages no persisted state.

I ran nothing. My reading of the code at b5c20e4 matches both traces.

Unverified:
- the thresholds on iOS hardware and the iOS 15 runtime (they were measured on macOS arm64);
- jetsam behaviour for the memory blow-up;
- who can write the receipt on stock iOS;
- verifier 2's single observation of a user-owned 0600 receipt for an iOS app on a Mac, against HANDBOOK.md:657-658's "root-owned".

<a id="b10"></a>
### B10 · low · StoreKit2Client throws away the back-deployed AppTransaction.appTransactionID below iOS 18.4, so offer signatures on iOS 16.0–18.3 are never bound to the customer

**Verdict.** Confirmed. **Fix group:** G7. **Status:** open.

**Where**

- Sources/PaywallKit/StoreKit2Client.swift:43: the `#available(iOS 18.4, macOS 15.4, *)` gate, nested in the iOS 16 block at :40; the nil is passed on at :49.
- Sources/PaywallCore/GateEngine+Store.swift:252: `transactionID: appTransaction?.appTransactionID` goes into the signing request.
- Sources/PaywallKit/RemotePromotionalOfferSigner.swift:64, :82-85: a nil Optional is left out of the JSON body.
- Workers/PromotionalOfferSigner/src/signer.ts:74: the `transactionId` claim is added only when present.
- Sources/PaywallCore/PromotionalOffer.swift:8: the comment says "(iOS 18.4+)", which is wrong.
- Sources/PaywallCore/StoreClient.swift:71: the comment says "(iOS 16+)", which is right and contradicts :8.
- HANDBOOK.md:348-349 and Workers/PromotionalOfferSigner/README.md:24: both promise the binding "when the store reports it".
- TestHost/TestHostTests/StoreKitIntegrationTests.swift:337-338: a circular equality check plus a non-nil assert that runs only on 18.4+.
- Workers/PromotionalOfferSigner/src/validate.ts:13, :42, src/app.ts:72 and test/validate.test.ts:43: an empty "" is rejected with 400.

**Defect**

`StoreKit2Client.appTransaction()` reads `AppTransaction.appTransactionID` only under `#available(iOS 18.4, macOS 15.4, *)`. The SDK declares the property for iOS 16.0 / macOS 13.0 and back-deploys it (`@backDeployed(before: iOS 18.4)`), so on iOS 16.0–18.3 every snapshot still carries `appTransactionID: nil`. Promotional-offer signing requests from those devices therefore never carry `transactionId`, and the worker signs without Apple's optional-but-recommended customer binding, which HANDBOOK.md:348-349 promises. Two code comments also disagree on when the ID is available (iOS 16+ vs 18.4+).

**Failure scenario**

1. An app sets `configuration.promotionalOfferSigner` (nil by default, Sources/PaywallKit/Paywall.swift:52).
2. It calls `purchase(_:promotionalOffer:)` (Paywall.swift:418-423) on an iPhone running iOS 16.0–18.3, where `AppTransaction.shared` returns a verified value.
3. The default `StoreKit2Client()` (Paywall.swift:48) returns `appTransactionID: nil`, GateEngine+Store.swift:252 sends `transactionID: nil`, the body leaves out `transactionId`, and the worker mints a JWS with no `transactionId` claim.

The purchase still succeeds because the claim is optional, but the signature is not bound to the customer. This happens on every offer purchase on those iOS versions. macOS 13.0–15.3 behaves the same, but nothing ships on macOS (HANDBOOK.md:8-10).

Severity is low because the practical impact is small. The worker is public by design and signs with any transactionId or none (validate.ts:42; Workers/PromotionalOfferSigner/README.md:85-88), so the missing binding opens no new abuse path, and iOS 16.0–18.3 is a shrinking minority of devices.

**Evidence**

**Code.** Sources/PaywallKit/StoreKit2Client.swift:42-43 declares `var appTransactionID: String?` and sets it only in `if #available(iOS 18.4, macOS 15.4, *) { appTransactionID = app.appTransactionID }`, inside `if #available(iOS 16.0, macOS 13.0, *)` at :40. Nothing else fills the field:
- ReceiptClient.swift:54, PaywallSimulator.swift:262 and GrandfatherOverride.swift:26 build snapshots without it.
- The cached file (GateEngine.swift:260-261) holds only what StoreKit2Client produced.
- The request at GateEngine+Store.swift:252 passes the field through unchanged.

**SDK.** I read this myself and built nothing. In iPhoneOS27.0.sdk, StoreKit arm64e-apple-ios.swiftinterface:1004-1019, inside `public struct AppTransaction` (:984), the property is declared `@available(iOS 16.0, macOS 13.0, …) @backDeployed(before: iOS 18.4, macOS 15.4, …) public var appTransactionID: String`. Before 18.4 its getter returns `backing.value(atKeyPath: "appTransactionId", sentinel: "", …)`.

**Compile probe (verifier 2).** It used the production file with no test hooks:
- With the read ungated at :43, the build was clean for `--triple arm64-apple-ios15.0` against iPhoneOS27.0.sdk, and for the macOS host.
- Control: `_ = app.originalPlatform` added at :44 failed with "only available in iOS 18.4 or newer", so the availability checker was active in that scope.
- Reviewer B's probe, since deleted, gave the same result.

**Worker.** `TRANSACTION_ID = /^[0-9]{1,40}$/` (validate.ts:13) rejects "" (validate.test.ts:43; verifier 2's node check returned `{"empty":false}`), and app.ts:72 then answers 400 `invalid_request`.

**Not covered anywhere.** The host lane checks a non-nil ID only on 18.4+ (StoreKitIntegrationTests.swift:338), and README's "Known defects" section (README.md:235-252) does not list this.

**Not reproduced.** No iOS 16.0–18.3 runtime was run. That StoreKit fills the value there rests on the SDK getter and Apple's documentation, which gives iOS 16.0+.

**Fix direction**

1. In `StoreKit2Client.appTransaction()`, read `app.appTransactionID` directly inside the existing iOS 16 / macOS 13 block and delete the 18.4 gate at :43.
2. **Map "" to nil. This is mandatory.** Below 18.4 the back-deployed getter returns "" when the payload lacks `appTransactionId`. The worker answers "" with 400 `invalid_request`, and the engine then fails the purchase before the payment sheet (GateEngine+Store.swift:216-221). Removing the gate without the mapping would turn "unbound but working" into "offer purchase fails". Specifically:
   - Normalise on both OS branches, since the 18.4+ storage is also a non-optional String.
   - Put the mapping in a small pure helper that the macOS 14 test target can call.
   - Apply it again where the request is built (GateEngine+Store.swift:252), or in RemotePromotionalOfferSigner. `AppTransactionSnapshot` is public, so a third-party StoreClient can supply "".
3. Fix the docs: PromotionalOffer.swift:8 should say iOS 16+. Keep StoreClient.swift:71, HANDBOOK.md:348-349 and Workers/PromotionalOfferSigner/README.md:24 consistent with it.
4. Check that it builds under CI's Xcode 26 (.github/workflows/test.yml:42). Only the Xcode 27 SDK was inspected. A clean build is expected: the package already needs Swift 6.2 for `@concurrent` (StoreKit2Client.swift:18), and the back-deployment shipped with Xcode 26. It is still unverified.

**What the fix does not break:**
- No public API changes.
- app-transaction.json gains a field that old files decode as nil.
- `accountKey` (StoreClient.swift:97-100) does not include the ID, so the ledger is not re-partitioned.
- Nothing in Sources compares whole snapshots, so a newly filled ID causes no change events.

**Out of scope:** the iOS 15 / offline receipt fallback (StoreKit2Client.swift:54) still sends no ID. `Transaction.appTransactionID` is back-deployed to iOS 15.0 and could fill that gap in a separate change.

**Regression test (the finding is fixed when this passes)**

**CI tests** (PaywallCoreTests / PaywallKitTests, isolated facades, never Paywall.shared):
- (a) Test the helper directly: "" gives nil, and "2000000123456789" comes back unchanged.
- (b) In Tests/PaywallCoreTests/PromotionalOfferTests.swift, a FakeStore snapshot with `appTransactionID: ""` must reach FakePromotionalOfferSigner with `transactionID == nil`.
- (c) If RemotePromotionalOfferSigner also normalises, add a test next to `leaves_transactionId_out_when_the_install_has_none` (Tests/PaywallKitTests/PromotionalOfferTests.swift:69) asserting that a "" request's body has no `transactionId` key.

**Host lane:** replace StoreKitIntegrationTests.swift:337-338 with these checks:
- Compare the request against `AppTransaction.shared`'s own `appTransactionID`, read in the test with "" mapped to nil.
- Assert the request never carries "".
- Keep the non-nil expectation on 18.4+.

TestHost's deployment target is iOS 17.0 (project.pbxproj:245, :271), so this lane can run only on 17.0–18.3 runtimes, never iOS 16. The StoreKit Testing server in those runtimes may not mint the ID, so do not assert non-nil there. End-to-end proof needs a sandbox offer purchase on a real iOS 16.0–18.3 device.

**Related findings**

- **B8** (a mismatched signer answer's JWS is persisted to the audit log and sinks; it notes the JWS carries the customer's transactionId on iOS 18.4+): fixing B10 extends that exposure to iOS 16.0+. Fix B8 first or in the same cycle.
- **A11 / A11-B6** edit the same function (StoreKit2Client.swift:39-55, the receipt fallback). Coordinate with them to avoid conflicting edits.
- **B5** (rate limiting keyed on `transactionId` when present) gets better coverage once B10 is fixed.
- **DOCS D8** touches the doc comment of the same function.

**Verification**

Reported by reviewer B as low. Verifier 1 (code trace): confirmed, low. Verifier 2 (reachability and reproduction): confirmed, low; reachable in production: yes, with preconditions. Judge: confirmed, low.

Both verifiers confirmed the finding and rated it low. They agree on every fact, so there was no disagreement to settle. I re-read the decisive lines at b5c20e4 and the iPhoneOS27.0 SDK interface myself, and ran or built nothing.

The 18.4 gate has no documented reason. The package already relies on SDK back-deployment for `promotionalOffer(_:compactJWS:)` (HANDBOOK.md:351, StoreKit2Client.swift:104), so the gate reads as a mistaken belief about availability, not a design choice.

The finding's own regression test cannot work as written. TestHost cannot run on iOS 16 (its target is 17.0), and older runtimes' StoreKit Testing may not emit the ID. I replaced it.

Still unverified:
1. That App Store payloads on iOS 16.0–18.3 really carry `appTransactionId`. Only a device or the live service can show this. If they don't, the fix yields nil, which is no regression.
2. That CI's Xcode 26 SDK has the same back-deployed declaration.
3. That the production App Store accepts unbound signatures. Apple documents the claim as optional.

Both verifiers disclosed one run of `xcodebuild -version`, which built nothing.

<a id="b11"></a>
### B11 · low · Signer worker logs the malformed APPLE_BUNDLE_IDS / ALLOWED_OFFERS value it promises never to log, and its "never its value" test cannot fail

**Verdict.** Confirmed. **Fix group:** G6. **Status:** open.

**Where**

- Workers/PromotionalOfferSigner/src/config.ts:53: the bundle-id error embeds `JSON.stringify(id)`.
- Workers/PromotionalOfferSigner/src/config.ts:71: the product-id error embeds `JSON.stringify(productId)`.
- Workers/PromotionalOfferSigner/src/config.ts:73: the offers error embeds a well-formed productId (the finding omits this line).
- Workers/PromotionalOfferSigner/src/app.ts:49-52: withConfig logs error.message. :50 is the "never its value" comment; :52 is the constant 500 body.
- Workers/PromotionalOfferSigner/wrangler.jsonc:10-12: observability is enabled.
- Workers/PromotionalOfferSigner/test/config.test.ts:13: asserts the value IS in the message.
- Workers/PromotionalOfferSigner/test/config.test.ts:55, :65, :73-75: the test name, a case that tolerates the value, and the vacuous key check.
- Workers/PromotionalOfferSigner/src/key.ts:48: forwards WebCrypto's error text (harmless today).
- Workers/PromotionalOfferSigner/README.md:45: "the log names which, never its value".
- README.md:267: the "two places only" claim (handled by DOCS D6).

**Defect**

Three ConfigError messages contain configured values:
- Workers/PromotionalOfferSigner/src/config.ts:53: a malformed bundle-id entry.
- config.ts:71: a malformed product id.
- config.ts:73: a well-formed product id whose offer list is bad.

withConfig writes error.message to console.error (src/app.ts:51), and Workers Logs records it because observability is on (wrangler.jsonc:10-12). That contradicts app.ts:50, the worker README.md:45 and the test name at test/config.test.ts:55.

The suite cannot catch it. The only negative check (config.test.ts:73-75) runs on an env with the key removed, so the message can only be "APPLE_IAP_PRIVATE_KEY is not set". config.test.ts:13 asserts that the value is present.

Clients never see the value: the HTTP body is always {"error":"misconfigured"} (app.ts:52).

**Failure scenario**

The operator stores an APPLE_BUNDLE_IDS value containing a character outside [A-Za-z0-9.-]: semicolons or spaces as separators, an underscore, or pasted quotes. A stray letter or digit passes validation and logs nothing. A bad ALLOWED_OFFERS entry has the same effect.

From then on, every unauthenticated GET /v1/keys and every well-formed sign request returns 500 and writes the value to the account's Workers Logs. With a wrong separator that is the whole list of real bundle ids. Failures are not cached (config.ts:107), so it repeats on every request.

Worst case, from an unusual mistake: the .p8 PEM is stored as APPLE_BUNDLE_IDS while the other secrets are valid. A PEM has no commas and its leading "-" fails BUNDLE_ID, so config.ts:53 logs the entire private key.

Separately, a future change that logs key material passes the suite: a mutant that does so still passes 37/37.

**Evidence**

Code at b5c20e4 (Workers/PromotionalOfferSigner/), re-read by the judge:
- src/config.ts:53: `APPLE_BUNDLE_IDS: malformed bundle id ${JSON.stringify(id)}`
- src/config.ts:71: `ALLOWED_OFFERS: malformed product id ${JSON.stringify(productId)}`
- src/config.ts:73: `ALLOWED_OFFERS: ${productId} must list offer ids`
- src/app.ts:49-51 catch ConfigError/KeyError and run `console.error(JSON.stringify({ event: "misconfigured", detail: error.message }))`. The comment above reads "never its value".
- The log is reached from app.ts:37 (/v1/keys) and from app.ts:74, after request validation at :71-72.
- loadConfig (src/config.ts:82-89) checks key presence, key id, issuer id, bundle ids, offers, and only then imports the key. A PEM stored in APPLE_BUNDLE_IDS is therefore rejected at :53 and logged whole.

Tests:
- test/config.test.ts:13 expects `/malformed bundle id "bad id"/`, and :65 expects `/malformed bundle id/`.
- :73-75 drop the key, then test `new RegExp(key.pem.slice(30, 60))`. That slice is base64 characters 2-31 of the fixed P-256 PKCS#8 header (`MIGHAgEAMBMGByqGSM49…`), the same for every key.

Messages that carry no value: config.ts:42, :84 and :86, and key.ts:15-27. key.ts:48 forwards the runtime's text: Node says "Invalid keyData", and workerd's strings are static.

Reproduction (verifier 2, on a scratch copy under Node/vitest, through src/index.ts fetch with a console.error spy):
- Semicolon-separated ids logged `malformed bundle id "com.acme.secretapp;com.acme.secretapp.beta"`.
- The product-id case and the :73 case both logged their markers.
- A stray letter gave 403 and logged nothing.
- Malformed key id and issuer id, and 6 malformed-key variants, logged no value.
- A mutant whose errors carry the full PEM still passed 37/37.

The judge ran nothing.

**Fix direction**

Messages:
- Rewrite src/config.ts:53, :71 and :73 so they name the secret and, at most, the position of the bad entry. They must never contain any substring of the value.
- If you give a position, make it 1-based. For bundle ids, count in the raw comma-separated text, or say "non-empty entry", because :50 filters out empty entries.
- For ALLOWED_OFFERS, Object.entries puts integer-like keys first (for example "1001", which PRODUCT_ID allows). Either leave the position out or say how it is counted.
- Where possible keep the phrases "malformed bundle id", "malformed product id" and "must list offer ids", so test/config.test.ts:35-38 and :65 still pass. Invert :13.
- key.ts:48: either replace the forwarded runtime text with a fixed phrase, or let the new test prove it carries no key bytes.

Scope:
- Only log text changes. What the worker accepts and signs stays the same.
- The 500 body {"error":"misconfigured"} at app.ts:52 stays, and so does the Swift client, which reads only `error`.
- No persisted state or wire contract is involved.
- Once fixed, README.md:45 and app.ts:50 are true and need no edit. Leave README.md:267 to DOCS D6.

Tests:
- The key-leak check must be key-specific. Use substrings of the base64 body after the 48-character fixed prefix, checked with not.toContain, because '+' is a regex metacharacter.
- Assert at the real sink, the logged `detail`, not only on loadConfig's rejection.

**Regression test (the finding is fixed when this passes)**

Where: Workers/PromotionalOfferSigner/test/config.test.ts. Replace "names the secret at fault, never its value" with a case table. Build each case with testEnv(overrides) and give each a unique marker m (for example zq7MARKERzq7):
- APPLE_IAP_KEY_ID `K<m>`
- APPLE_IAP_ISSUER_ID `I<m>`
- APPLE_BUNDLE_IDS `com.example.app, com.<m>_x`
- APPLE_BUNDLE_IDS `com.<m>.app;com.example.app`
- APPLE_BUNDLE_IDS set to the env's own PEM
- ALLOWED_OFFERS `{"pro <m>": ["comeback"]}`
- ALLOWED_OFFERS `{"pro.<m>": ["has space"]}`
- APPLE_IAP_PRIVATE_KEY relabelled EC PRIVATE KEY
- APPLE_IAP_PRIVATE_KEY with base64 characters 8-15 replaced by AAAAAAAA, so it reaches importKey

Assertions:
- loadConfig rejects, and the message names the secret.
- The message contains neither m nor any 16-character window of the key body past character 48.
- Under vi.spyOn(console,"error"), handleRequest(GET /v1/keys) returns 500 {"error":"misconfigured"}, and nothing logged contains those fragments.

The test is red at b5c20e4. It runs in CI's worker job (`npm run check`). A draft exists at Appendix B (`Workers/PromotionalOfferSigner/test/b11-regression.test.ts`), but it lacks the PEM-in-APPLE_BUNDLE_IDS case.

**Related findings**

- DOCS D6: it rewrites README.md:267-268 ("two places only"), which the logging also contradicts. Leave that sentence to D6; B11 needs no edit there.
- B5 (rate limiting): it also edits Workers/PromotionalOfferSigner/src/app.ts and wrangler.jsonc. There is no ordering constraint, but merge with care. A limiter would reduce how often the misconfigured line is repeated, but it does not replace this fix.

**Verification**

Reported by reviewer B as low. Verifier 1 (code trace): confirmed, low. Verifier 2 (reachability and reproduction): confirmed, low; reachable in production: yes, with preconditions. Judge: confirmed, low.

Both verifiers confirmed the finding and rated it low; they did not disagree on any fact. Additions folded in:
- config.ts:73, which the finding omits.
- config.test.ts:13, which asserts the leak.
- The PEM-in-APPLE_BUNDLE_IDS worst case. Verifier 1 found it; the judge re-traced config.ts:46-56 and :82-89.
- Verifier 2's narrowing: only characters outside the allowed set trigger the log (a stray letter gives 403 and logs nothing).

Severity stays low. The realistic values are bundle ids and product ids, which are public (the app sends both on every request), and they reach only the owner's own account logs. The key-in-logs case needs an unusual operator mistake.

Unverified:
- That `wrangler secret put <name> < file` stores multi-line stdin under any name. wrangler was not run, though README.md:66 relies on it.
- Workers Logs sampling and retention, and Logpush behaviour. These come from Cloudflare's docs only.
- workerd's importKey error text, read from binary strings rather than exercised.

The probes ran under Node; the judge ran nothing.

<a id="b12"></a>
### B12 · low · Signer `timeout` is only URLSession's idle timer and nothing sets a total deadline, so README's "15-second timeout" overstates how long the offer purchase can wait

**Verdict.** Confirmed, narrower than reported. **Fix group:** G7. **Status:** open.

**Where**

- Sources/PaywallKit/RemotePromotionalOfferSigner.swift:78: `URLRequest(url: endpoint, timeoutInterval: timeout)`, the only bound
- Sources/PaywallKit/RemotePromotionalOfferSigner.swift:86: `transport.send(urlRequest)`, awaited with no deadline
- Sources/PaywallKit/RemotePromotionalOfferSigner.swift:18, :23: the default transport runs on `URLSession.shared` and calls `session.data(for:)`
- Sources/PaywallKit/RemotePromotionalOfferSigner.swift:51-54: the `timeout` doc ("A paywall waits on this before the payment sheet, so keep it short") and the default of 15
- Sources/PaywallCore/GateEngine+Store.swift:217-218, :253: signing is awaited before `store.purchase`, with no deadline; :219-221 emit `.failed` only on a throw
- Sources/PaywallKit/Paywall.swift:418-424: the facade passes the call straight through
- README.md:226: "the request has a 15-second timeout"
- Tests/PaywallKitTests/PromotionalOfferTests.swift:62, :107: assert only the `timeoutInterval` values

**Defect**

`RemotePromotionalOfferSigner.sign` limits the exchange only through `URLRequest.timeoutInterval` (default 15 s), which Apple defines as an idle timer that resets on every load-activity event. The default transport runs on `URLSession.shared`, whose resource timeout is 7 days. No total deadline is added by `sign`, by `GateEngine.purchase` or by the facade. If the response's HTTP events (headers, body chunks) each arrive less than `timeout` apart, the offer purchase waits longer than `timeout` before the payment sheet. That contradicts README.md:226 and the intent stated at :51.

The defect is narrower than reported. Captive portals cannot trigger it. A refused, offline, black-holed or slow-to-first-byte signer still fails at 15 s. With the documented worker over HTTPS (one small JSON body), the overrun is a small multiple of `timeout` and ends in a late success or a late failure. The wait is unbounded only with a custom endpoint that streams slowly, a TLS-intercepting proxy that re-chunks the body, or an endless trickle.

**Failure scenario**

An app configures `RemotePromotionalOfferSigner(endpoint:)` as documented (HANDBOOK.md:42-43) and calls `purchase(_:promotionalOffer:)` from a Buy button's unstructured Task. On a degraded link the signer's response events arrive just under 15 s apart. The spinner runs about 30 s, possibly longer if connection setup also counts as activity, before the payment sheet or the error appears. Behind a TLS-intercepting proxy that paces the body, or against a custom endpoint that streams its JSON slowly, only the 7-day resource timeout or the app cancelling the task ends the wait; a cancel ends it at once with -999.

These cases do not trigger it:
- refused or offline: fails immediately
- black-holed, hung or slow to first byte: the idle timer fires at 15 s
- captive portals: TLS to workers.dev fails or black-holes

The impact is UX only. No entitlement, credit, persisted state or secret is affected.

**Evidence**

Code at b5c20e4:
- RemotePromotionalOfferSigner.swift:78 `var urlRequest = URLRequest(url: endpoint, timeoutInterval: timeout)`
- :86 `let (data, response) = try await transport.send(urlRequest)`
- :18 `public init(session: URLSession = .shared)`
- :54 `timeout: TimeInterval = 15`
- GateEngine+Store.swift:217 `if let offer { signed = try await signPromotionalOffer(offer, productID: productID) }` and :253 `let signed = try await signer.sign(request)`
- A grep of Sources finds no task group, no deadline and no `URLSessionConfiguration`.
- The worker answers with one non-streamed JSON body (Workers/PromotionalOfferSigner/src/app.ts:20-25, :80-88).

SDK text, checked in the local MacOSX.sdk:
- NSURLRequest.h:219-224: "the limit on the idle interval", reset to 0 whenever load activity occurs.
- NSURLSession.h:225: the shared session "is based on a default configuration".
- NSURLSession.h:1339: "The default value is 7 days."

Reproduction (I ran nothing myself; the judge's pass was read-only):
- Reviewer B, probe since deleted: loopback HTTP, 70-byte body sent 1 byte per 0.12 s, timeout 1.0. The call succeeded after 8.72 s.
- Verifier 2, an independent loopback POSIX-socket server driving the real default transport (probe since deleted):
  - `URLSession.shared` reports `timeoutIntervalForResource=604800`.
  - Silent server: -1001 at 1.03 s.
  - Header bytes trickled: -1001 at 1.03 s, so partial headers do not reset the timer.
  - Body trickled: success at 8.56 s.
  - Documented default (15 s) with the last 3 body bytes 10 s apart: success at 30.04 s.
  - Isolated facade, timeout 1: `purchased` at 8.54 s, with no `.failed` event.
  - Task cancelled at 1.50 s: -999 at 1.504 s.

Not reproduced: an overrun over HTTPS against the real worker, because contacting Cloudflare is forbidden.

**Fix direction**

Preferred fix: a total deadline inside `RemotePromotionalOfferSigner.sign`. It covers every `HTTPTransport` and keeps the public API.
- Start the deadline at the top of `sign`. Keep `URLRequest(url:timeoutInterval: timeout)` so PromotionalOfferTests.swift:62 and :107 still pass.
- Race `transport.send` against `Task.sleep(nanoseconds:)` in a throwing task group. Do not use `Task.sleep(for:)` or `Duration`: Package.swift:100-101 supports iOS 15 and macOS 12.
- Clamp the conversion. `timeout` is a public var, and a NaN, negative, infinite or huge value traps `UInt64(...)`. Copy the guard in Sources/PaywallCore/PaywallClock.swift:24-25.
- When the deadline fires, throw `URLError(.timedOut)`, which is what URLSession throws for its idle timeout. Do not rethrow the cancelled loser's `URLError(.cancelled)`. Do not add a case to the public `Failure` enum (:40-46): that breaks exhaustive switches in apps.
- Cancel the losing child and let the caller's cancellation propagate. A task group waits for all its children, so document on `HTTPTransport` (:4-8) that `send` must honour cancellation (`data(for:)` already does).
- The fix carries no double-credit risk:
  - the deadline fires before `store.purchase` (GateEngine+Store.swift:217-218);
  - the JWS is single-use and never stored (Sources/PaywallCore/PromotionalOffer.swift:22-23);
  - the existing catch still emits `.purchase(stage: .failed)` (:219-221).

Weaker alternative: give the default session `timeoutIntervalForResource = timeout`. A default argument cannot read `timeout`, the var can change after init, custom transports stay unbounded, and a session created per call has to be invalidated.

Optional: a deadline in `GateEngine.signPromotionalOffer` (:253) using the injectable clock would also bound custom signers, such as the App Attest client README.md:206 suggests.

Docs: make README.md:226 and the comment at RemotePromotionalOfferSigner.swift:51 state the real bound. At this severity a doc-only fix is acceptable. It would call the value a "15-second idle timeout", tell apps to cancel the task or pass `URLSessionTransport(session:)` with `timeoutIntervalForResource`, and add an entry under Known defects (README.md:235-252).

**Regression test (the finding is fixed when this passes)**

Target PaywallKitTests, file Tests/PaywallKitTests/PromotionalOfferTests.swift. Use isolated facades; do not touch Paywall.shared.

1. Suite "Remote promotional offer signer":
   - Setup: add an actor `SlowTransport: HTTPTransport`. Its `send` records the call, runs `try await Task.sleep(nanoseconds: 10_000_000_000)` (recording a cancellation if that throws), then returns 200 with the suite's `answer`. Build the signer with `timeout: 0.5`.
   - Expect: `sign` throws `URLError` `.timedOut` within 2.0 s on ContinuousClock, and the transport saw the cancellation.
   - At b5c20e4 it returns the signed offer after about 10 s, so the test fails without hanging.

2. Suite "Promotional offers (facade)":
   - Setup: `makePaywall(signer: RemotePromotionalOfferSigner(endpoint:, transport: SlowTransport(), timeout: 0.5))`, then set the app transaction as at :150-154.
   - Expect: `purchase(products[1], promotionalOffer: comebackOffer)` throws within about 2 s, `.purchase(stage: .failed(...))` is published, and `store.purchaseCalls == 0`.

3. Optional, needed only if the fix lives in the transport: a loopback server that trickles the body at 1 byte per 0.1 s, with timeout 1. Expect a throw within 2.5 s.

**Related findings**

- B8 changes the same offer-signing failure path (Sources/PaywallCore/GateEngine+Store.swift:220, :254-256) and the same test file. There is no ordering constraint unless the fix takes the optional engine-level deadline in `signPromotionalOffer`; in that case land B8 and B12 together.
- B5 rewords README.md:225, the row next to :226 in the same risks table. That only affects merging.

**Verification**

Reported by reviewer B as low. Verifier 1 (code trace): confirmed, narrower than reported, low. Verifier 2 (reachability and reproduction): confirmed, narrower than reported, low; reachable in production: yes, with preconditions. Judge: confirmed, narrower than reported, low.

Both verifiers said partly_confirmed and low, and I agree. They differed only on how wide the trigger is. Verifier 1 allowed any trickling middlebox or a very bad link. Verifier 2 showed that partial header bytes do not reset the timer, and argued that a middlebox can delay TLS records but not split them, so with the documented worker a non-intercepting path adds about one interval. I adopt the narrower view but leave the exact multiple open.

I dropped two claims from the report:
- the captive-portal trigger;
- "the fallback never gets its failure": a finite trickle ends in a late success.

Still unverified:
- behaviour over HTTPS, h2 or h3 against Cloudflare (contacting it is forbidden);
- whether DNS, TCP connect or TLS-handshake completion counts as load activity;
- CFNetwork on an iOS device (the probes ran on macOS).

I ran nothing. I re-read every cited line at b5c20e4 and confirmed the SDK text locally. README's Known defects (README.md:235-252) does not list this.

<a id="b13"></a>
### B13 · low · The production-receipt lane's account-key check copies the receipt's own values, and no test compares a real AppTransaction with the same install's receipt

**Verdict.** Confirmed, narrower than reported. **Fix group:** G4. **Status:** open.

**Where**

- Tests/PaywallKitTests/ReceiptClientTests.swift:407-411: the check, inside `parses_what_the_rule_uses_and_the_client_binds_it_to_its_app` (393). Line 407 is the comment, 408-410 copy the receipt's values, 411 is the `#expect`. Line 396 asserts the receipt is `.production`. The suite is gated on an environment variable at 355.
- Sources/PaywallCore/StoreClient.swift:95-100: `accountKey` is SHA-256 of bundleID|floor(seconds)|originalAppVersion. The doc comment at 95-96 claims the two sources agree, with nothing to back it.
- Tests/PaywallCoreTests/ResolverTests.swift:142-149: the CI test. It varies only origin and the sub-second part of the date.
- Sources/PaywallKit/StoreKit2Client.swift:36-54: the AppTransaction mapping (44-51) and the iOS 16+ receipt fallback (41, 54).
- Sources/PaywallKit/ReceiptClient.swift:45-46: the receipt side reads fields 19, 18 and 2.
- Sources/PaywallCore/GateEngine+Store.swift:21-23, 51-61: every refresh binds the snapshot and re-keys the account.
- Sources/PaywallCore/Ledger.swift:474-477: the balance counts only the bound key plus unbound events.
- HANDBOOK.md:665-667: the support export, which yields the receipt and JWS pair.

**Defect**

ReceiptClientTests.swift:408-410 builds the "AppTransaction" snapshot from the parsed receipt's own bundleID, originalAppVersion and originalPurchaseDate. The assertion at 411 therefore only checks that `accountKey` ignores origin, appTransactionID ("1" vs nil) and signedPayload. Environment is `.production` on both sides (396, 410), so the report's "fails if it hashes environment" is wrong, and the origin part already runs in CI (ResolverTests.swift:142-149). This is a test gap, not shipping code: nothing in the repo compares a real AppTransaction with the same install's receipt, so the parity claim at StoreClient.swift:95-96 is untested. iOS 15 devices and the iOS 16+ receipt fallback both rely on that claim to keep their token partition.

**Failure scenario**

Suppose that for one install Apple's receipt and AppTransaction disagree on the bundle id, the version string or the whole purchase second. One example: field 18 is rounded while the JWS has .600 ms, and the key floors at StoreClient.swift:98.

1. An iOS 16+ launch where `AppTransaction.shared` throws or is unverified falls back to the receipt (StoreKit2Client.swift:41, 54) and binds key R. An iOS 15 device on the same account binds R too, through the PaywallCloudSync ledger or the Keychain snapshot.
2. `grant:welcome` and `credit:<id>` events are written under R (GateEngine.swift:553-557).
3. A later refresh binds key A (GateEngine+Store.swift:21-23, 55-60). `Balances.total(for: A)` excludes R's events (Ledger.swift:474-477), and the event ids are already taken (LedgerEvent.swift:70, GateEngine.swift:586). The purchased tokens disappear, and the balance flips whenever the source changes.

The lane still passes, because 408-410 copy the receipt's values. Whether Apple's two sources ever disagree is unverified.

**Evidence**

Code, read at b5c20e4:
- ReceiptClientTests.swift:396 has `#expect(snapshot.environment == .production)`.
- Lines 408-411:
```swift
let fromAppTransaction = AppTransactionSnapshot(
    bundleID: snapshot.bundleID, originalAppVersion: snapshot.originalAppVersion,
    originalPurchaseDate: snapshot.originalPurchaseDate, environment: .production, appTransactionID: "1", origin: .appTransaction)
#expect(snapshot.accountKey == fromAppTransaction.accountKey)
```
- StoreClient.swift:98-99 hash `"\(bundleID)|\(seconds)|\(originalAppVersion)"` only, with seconds floored.
- ResolverTests.swift:142-149 copies a snapshot and changes only `origin` and the sub-second date. No CI test varies appTransactionID or signedPayload.
- The suite runs only when PAYWALL_PRODUCTION_RECEIPT is set (ReceiptClientTests.swift:355), so CI skips it.
- I grepped Tests/, TestHost/, Scripts/ and Sources/ for jwsRepresentation, originalApplicationVersion, AppTransaction.shared and PAYWALL_PRODUCTION. Only StoreKit2Client.swift:36, 41, 51 and the receipt variable at ReceiptClientTests.swift:348-355 match.
- TestHost/TestHostTests/StoreKitIntegrationTests.swift:123-133 reads a real AppTransaction but checks only origin, environment, bundleID and that a key is bound. It also asserts that the receipt path fails closed, because the Xcode-signed receipt does not verify (132).

Reproduction: verifier 2 copied the shipped `accountKey`, SHA256Digest and `ReceiptClient.parse` into a standalone script (not kept) and ran it:
- With the shipped key and with a key that also hashes environment, the assertion passes.
- With a key that also hashes origin or appTransactionID, it fails.
- Against an AppTransaction one second later, or with version "116.0", the lane assertion still passes while the real keys differ.

I read its variants but did not re-run it, because the judge's pass was read-only. Its result follows directly from the lines above.

**Fix direction**

The fix is test-only: no change to public API, persisted data or credits.

1. Preferred: a real parity check.
   - Add an opt-in second input, PAYWALL_PRODUCTION_APP_TRANSACTION. It names a file holding the same install's `AppTransaction.shared.jwsRepresentation`, captured with the support export in HANDBOOK.md:665-667. Under xcodebuild, use the TEST_RUNNER_ prefix.
   - Keep the file outside the repo and never hard-code its bundle id, because it names the app.
   - Gate the new test on both variables, so receipt-only runs still pass.
   - Decode the JWS payload (bundleId, originalApplicationVersion, originalPurchaseDate in ms, receiptType). Map it exactly as StoreKit2Client.swift:44-51 does.
   - Assert the bundle id, the version and the purchase second separately, printing the raw ms. Then compare `accountKey` through the production property. Never re-implement the hash.
   - Fail loudly if the JWS bundleId differs from the receipt's, since that means a mismatched pair. Verifying the x5c chain is optional. A TestFlight pair and a cross-device pair are cheap extra evidence.
2. In either case, move the invariance check into CI.
   - Extend ResolverTests.swift:142-149 to also vary appTransactionID and signedPayload.
   - Then delete or reword ReceiptClientTests.swift:407-411. Deleting it alone would drop the only appTransactionID and signedPayload check.
   - Qualify StoreClient.swift:95-96 until real evidence exists.
3. If the real check ever fails, do not just change `accountKey`.
   - The key is part of every event's hash (LedgerEvent.swift:31, 57-61), and credits and the welcome grant are idempotent by id, so re-keying strands balances.
   - Instead alias both keys: take the union of the two partitions in `Balances.total` and the lease views, and dedupe `grant:grandfathered:<key>` (GateEngine+Store.swift:72).
   - Add a migration, and cover the iOS 16+ fallback as well as iOS 15.

**Regression test (the finding is fixed when this passes)**

Add `the_same_installs_app_transaction_derives_the_receipts_account_key` to PaywallKitTests, suite "Production receipt" (Tests/PaywallKitTests/ReceiptClientTests.swift).
- Enable it only when PAYWALL_PRODUCTION_RECEIPT and PAYWALL_PRODUCTION_APP_TRANSACTION are both set. CI skips it.
- Parse the receipt with `ReceiptClient.parse`.
- Decode the JWS middle segment: base64url to `+/` with padding, then JSONSerialization. This is plain Foundation and builds for macOS 14.
- Expect equal bundle ids and equal original versions.
- Expect `originalPurchaseDate` ms / 1000 to equal the floor of the receipt date's seconds.
- Expect `receiptType == "Production"` and the receipt's environment to be `.production`.
- Then expect the two snapshots' `accountKey`s to be equal.

CI companion: in `ResolverTests.account_key_matches_across_sources`, also set appTransactionID ("1" vs nil) and signedPayload (bytes vs nil), and expect equal keys.

Optional, in TestHost StoreKitIntegrationTests: decode `AppTransaction.shared`'s JWS and assert that `engine.appTransaction`'s version and purchase second match it. This guards the mapping at StoreKit2Client.swift:44-51, not production parity.

**Related findings**

- **A11 / A11-B6** (iOS 16+ falls back to the receipt whenever AppTransaction throws or is unverified): that fallback is the common same-device path where a key split would hurt. If A11's fix narrows the fallback, B13 still applies to iOS 15 and to the case where AppTransaction throws.
- **B2** (ProductionVPP receipts map to `.xcode`): if the parity test also compares environments, land B2 first, or a VPP pair fails the test spuriously.
- **B1**: it cites `grant:grandfathered:<accountKey>` (GateEngine+Store.swift:72), which any future key-aliasing fix must dedupe.

B13's own fix is test-only and can land independently.

**Verification**

Reported by reviewer B as low. Verifier 1 (code trace): confirmed, narrower than reported, low. Verifier 2 (reachability and reproduction): confirmed, narrower than reported, low; reachable in production: unknown. Judge: confirmed, narrower than reported, low.

Both verifiers returned partly_confirmed at low severity and agree on substance. Both corrected two things in the report:
- "fails if it hashes environment": lines 396 and 410 make both sides `.production`, so it would not.
- The location: the check is at 407-411, not 404-411.

I confirmed both by reading those lines and StoreClient.swift:97-99. Verifier 1 adds that the line is not a strict tautology: it is the only check, anywhere, that the key ignores appTransactionID and signedPayload. Deleting it without moving that check into CI therefore loses coverage. I did not run verifier 2's repro, because the judge's pass was read-only.

Unverified, and only checkable with device or service data: whether Apple's receipt fields 2, 18 and 19 and AppTransaction's bundleID, originalPurchaseDate and originalAppVersion agree for one install. The open case is whether the purchase second is truncated or rounded. Field 18 is not in Apple's documented receipt-field list. Apple documents the same meaning for both sources and one forum report saw agreement, so the trigger is likely rare. Settling it needs a real receipt and JWS from the same install.

<a id="b14"></a>
### B14 · low · FakeStore models "store down" as a thrown entitlement read, which StoreKit2Client can never produce. With the shipped store, `.storeUnavailable` never fires, and the offline tests and the storeDown preset pin the fake's mechanism

**Verdict.** Confirmed, narrower than reported. **Fix group:** G3. **Status:** open.

**Where**

Sources/PaywallTesting/FakeStore.swift:105-118: passive reads throw `.unreachable` (:106, :111, :116)
Sources/PaywallKit/StoreKit2Client.swift:18-25: `for await` over Transaction.currentEntitlements, no try; :27-34 same for Transaction.all; :39-55 appTransaction
Sources/PaywallCore/GateEngine+Store.swift:12-18: catch emits `.storeUnavailable` and returns (dead with StoreKit2Client); :25-38 resolve, save, arm timer
Sources/PaywallCore/StoreClient.swift:120: public protocol method `throws`
Sources/PaywallKit/Paywall.swift:48: default store is StoreKit2Client()
Sources/PaywallCore/PaywallEvent.swift:68; Sources/PaywallKit/OSLogSink.swift:37: the event
Sources/PaywallCore/PaywallFailure.swift:25: doc names a trigger production never produces
Sources/PaywallSimulator/PaywallPreset.swift:11, :38-40, :65: storeDown and the "resolution fails" doc
Sources/PaywallSimulator/PaywallSimulator.swift:10, :99-100, :213-214, :286, :387: SimulatedStore = FakeStore; forces .unknown
Sources/PaywallSimulator/PaywallLaunchArguments.swift:10, :64-65, :78: the `-paywall.store` switch
Tests relying on the throw: Tests/PaywallCoreTests/GateEngineTests.swift:32-56, AppReviewTests.swift:108-122, WelcomeTokensTests.swift:42-54, TierTests.swift:53-56, AuditTableTests.swift:165-175, TestDoubleTests.swift:52-54; Tests/PaywallSimulatorTests/SimulatorTests.swift:185-187, :222-239, :387-395

**Defect**

StoreKit's Transaction.Transactions iterator cannot throw, so StoreKit2Client's passive reads never throw. With the shipped store, the catch in GateEngine.refresh never runs. `.storeUnavailable` never fires, and the branch that keeps the snapshot exists only for FakeStore, which is also the simulator's store, or for a host-written StoreClient. FakeStore is a public test double (ZTronPaywallTesting, Package.swift:9), and it models "store down" as a thrown read. The package's offline tests, the storeDown preset and the doc comments at PaywallFailure.swift:25 and PaywallPreset.swift:65 all describe that mechanism.

The finding is narrower than reported:
- No store-down UI tests exist in the repo.
- `.unknown` with `.entitlementUnavailable` does appear in production, before the launch resolution answers.
- The appTransaction divergence has no effect.
- An empty answer resolving to free is the documented StoreKit-is-truth rule, and it is tested as refund and expiry.

What production never shows is `.unknown` held across or re-entered after a resolution, and `.storeUnavailable` itself.

**Failure scenario**

A host app, or the package's own tests, uses `FakeStore.setReachable(false)` or the storeDown preset to stand for "offline" or "StoreKit down", and builds analytics or alerts on `.storeUnavailable`. With StoreKit2Client the field looks different:
- Offline reads answer from StoreKit's cache and resolve normally.
- `.storeUnavailable` never fires.
- If a paying user's cache comes back empty, they resolve to `.free`, which overwrites entitlement.json until the next foreground, update or restore resolution. That is the rule documented at README.md:222 and :229, not a new bug.
- If the read never answers (seen in the sandbox; unverified in production), `start()` stalls at GateEngine.swift:298. Paid and token gates keep answering `.entitlementUnavailable`, no event fires, and no fake can model this today.

Nothing is lost or granted for free. The cost is false confidence from the tests and a public analytics event that never fires.

**Evidence**

I read all of this myself at b5c20e4:
- FakeStore.swift:106 has `guard isReachable else { throw Failure.unreachable }`, and :111 and :116 have the same guard.
- StoreKit2Client.swift:21 has `for await result in Transaction.currentEntitlements {`, and there is no `try` anywhere in :19-25. A `for await` without `try` only compiles over a non-throwing sequence. The Xcode 27 iPhoneOS27.0.sdk StoreKit.swiftinterface:1629-1647 declares `public mutating func next() async -> VerificationResult<Transaction>?` and `__AsyncSequence_Failure = Swift::Never`, and declares `currentEntitlements` and `all` as `Transaction.Transactions { get }`.
- GateEngine+Store.swift:13 is `transactions = try await store.currentEntitlements()`. The catch at :14-17 does `emit(.storeUnavailable(...)); return`.
- The only conformers are StoreKit2Client.swift:10 and FakeStore.swift:6. Paywall.swift:48 defaults the store to `StoreKit2Client()`, and PaywallSimulator.swift:10 declares `typealias SimulatedStore = FakeStore`.
- appTransaction: StoreKit2Client.swift:41-52 returns the verified AppTransaction first. The `try receipt.snapshot()` at :54 can only throw through ReceiptClient.swift:61, and AppleReceiptVerifier.swift:37 rejects that input first. The engine reads it with `try?` (GateEngine+Store.swift:21), and only after :13 has succeeded.
- `.unknown` in production: it is set at GateEngine.swift:263 when there is no snapshot and lasts until the refresh at :298. While it holds, :348 closes paid and token gates with `.entitlementUnavailable`.
- `.storeUnavailable` appears only at PaywallEvent.swift:68, GateEngine+Store.swift:16, OSLogSink.swift:37 and two tests. README and HANDBOOK never mention it.
- No UI tests exist. `-paywall.store down` appears only at HANDBOOK.md:487 and in the parser.
- The empty-answer path to free runs against the real client in TestHost/TestHostTests/StoreKitIntegrationTests.swift:136-148 (refund) and :189-212 (expiry).

Reproduction: I ran nothing (read-only pass). Verifier 2 typechecked both function bodies inside non-throwing functions with Xcode 27.0, for iOS 15 and macOS 12 targets, and got exit 0. Its throwing control failed with "errors thrown from here are not handled".

**Fix direction**

Pick one of the three options below. Two rules apply to all of them:
- Keep `.entitlementUnavailable`. Production still produces it before the first resolution (GateEngine.swift:263, :348) and on an unconfigured facade (Paywall.swift:317-319).
- Correct the doc comments at PaywallFailure.swift:25 and PaywallPreset.swift:65 to describe what production does.

1. Make the fake faithful (smallest change).
- `setReachable(false)` must stop making FakeStore's passive reads throw. products, purchase and sync keep throwing `.network`.
- Empty or missing answers need no new API: `setEntitlements([])` and `setApp(nil)` already script them.
- Add a no-answer mode: reads suspend until released, with a pending-read count.
- If a throwing read stays for hosts with their own client, name it so it is clearly not StoreKit behaviour, and document `.storeUnavailable` as firing only for such a client.
- Rewrite the listed tests. Under a suspending fake, `await h.start()` and `waitUntilStarted()` hang, so start the engine in a Task, using `relaunch(start: false)`.
- storeDown relies on the throw to stay `.unknown` through later refreshes. PaywallSimulator.swift:99 awaits a refresh, and :213-214 force `.unknown` only when a switch flips. Rebuild the preset on the no-answer mode without awaiting the held read, or drop it.

2. Add a timeout to StoreKit2Client, which makes the catch live.
- The catch must downgrade a lapsed snapshot subscription and arm the expiry timer. Today it returns before :31, and `isPaying` ignores expiry (Entitlement.swift:12-17), so even the expiry timer's own refresh (GateEngine+Store.swift:87) leaves a lapsed subscription paying.
- Revocations arriving on updates (:117-125) would wait for the next resolution that gets an answer.
- A late answer must not overwrite a newer resolution (see A4).

3. Remove the branch by making StoreClient.swift:120 non-throwing.
- This is a source break for host-written clients (README.md:205-206).
- Decide what happens to the public `PaywallEvent.storeUnavailable`, `PaywallSimulation.storeReachable`, `PaywallLaunchArgument.store` and `PaywallPreset.storeDown`.

None of the options changes a persisted format or touches credits.

**Regression test (the finding is fixed when this passes)**

Primary test (fails at b5c20e4):
- Target: PaywallCoreTests, suite "Test doubles and wire format" (TestDoubleTests.swift:8).
- Replace :52-54 with `fake_store_passive_reads_answer_like_storekit_when_offline`.
- Setup: `FakeStore(entitlements: [.lifetime(id: 7, productID: "pro.lifetime", purchased: now)], app: snapshot)`, then setReachable(false) and setNetwork(false).
- Expect currentEntitlements(), allTransactions() and appTransaction() to return the scripted values without throwing. products(for:), purchase and sync still throw `.network`.

Engine pin:
- Suite "Edge cases" (AppReviewTests.swift:105), using the new hold mode.
- Case (a): fresh Harness, hold the reads, start with `Task { await h.start() }`, wait with `eventually { pending == 1 }`. Expect `.unknown`, `.paid` failing with `.entitlementUnavailable`, and `.free` running. After release, expect `.free`.
- Case (b): resolve lifetime id 7, call `relaunch(start: false)`, hold the reads, start in a Task. Expect lifetime from the snapshot and canPass(.paid). Set entitlements to [] and release. Expect `.free` and entitlementChanged(.lifetime, .free, .launch).
- In both cases, h.events has no `.storeUnavailable`. Under option 2, expect exactly one after clock.advance(by: timeout).

Simulator guard:
- Suite "Simulator" (SimulatorTests.swift:119): the storeDown outcomes at :185-187 must still hold after `didBecomeActive()`.

**Related findings**

- A4 (concurrent refreshes are not ordered): option 2 and A4's fix must be designed together. If A4 serializes refreshes behind a plain queue, a read that never answers blocks every later refresh (purchase, updates, foreground). A generation stamp or a bounded read avoids that. Fix A4 first or together with this one.
- B3/B4 (fakes can be linked into release): independent. This verdict rests on the shipped default store (Paywall.swift:48), not on the release-symbol script.
- A7: the same class of problem (a test that passes only against a fake) in the sync layer. No ordering constraint.
- The doc-comment edits at PaywallFailure.swift:25 and PaywallPreset.swift:65 can go out with the DOCS batch.

**Verification**

Reported by reviewer B as low. Verifier 1 (code trace): confirmed, narrower than reported, low. Verifier 2 (reachability and reproduction): confirmed, narrower than reported, low; reachable in production: yes, with preconditions. Judge: confirmed, narrower than reported, low.

Both verifiers returned partly_confirmed and low, with no material disagreement. I re-read every decisive line and the SDK interface myself.

Narrowings adopted:
- No store-down UI tests exist in the repo.
- `.unknown` is visible in production before the launch resolution.
- The appTransaction divergence has no effect.
- Empty answers are the documented rule, and they are exercised against the real client.
- The catch is live API for host-written clients, so it is not dead code.

Not adopted: Verifier 2 relied on check-release-symbols.sh to keep fakes out of release builds. B4 disputes that, and this verdict does not need it.

Added: with any throwing read, the expiry timer's refresh also hits the catch, so a lapsed subscription stays paying for the rest of the session. Today only FakeStore or a host client can reach that.

Unverified (device-only facts):
- Whether production StoreKit returns an empty or partial list for paying users, or never answers. Forum reports only; the hang was seen in the sandbox.
- Whether its iterator ends early when the task is cancelled.

I built and ran nothing.

## 4. Docs vs code

Doc lines that belong to a single finding, such as README.md:163 for A2 or HANDBOOK.md:396-397 for A11+B6, are listed in that finding's entry and change with its fix. D1 to D9 stand on their own; each went to two independent verifiers and a judge. D10 is README's summary claim.

#### D1 · medium impact · confirmed

Each device decides against its own ledger (Sources/PaywallCore/GateEngine.swift:353) and merges remote events as a union (Sources/PaywallCore/GateEngine+Store.swift:363-381). PaywallCloudSync pulls at most once every 3,600 s (Sources/PaywallCloudSync/PaywallCloudSync.swift:27, :50) unless a purchase, a restore or an app-forwarded silent push calls requestPull() (GateEngine+Store.swift:231, :272; Sources/PaywallKit/Paywall.swift:455-456; README never mentions the silent push). Tests/PaywallCloudSyncTests/CloudSyncTests.swift:85-101 asserts the overspend: 10 tokens, 8 drawn on each offline device, balance -6, gates closed. Neither README nor HANDBOOK says so. README.md:224 covers crashes only, and Ledger.swift:20 admits a negative balance only after a pack refund.

*Citation corrections:* The citations are correct. Add PaywallCloudSync.swift:27 and :50 (the interval and the throttle), GateEngine+Store.swift:363-381 (the union merge), CloudSyncTests.swift:99-100 (the assertions), and Sources/PaywallCore/Ledger.swift:20, the only doc that admits a negative balance, and only for refunds.

*Why this impact:* Adopters, and whoever prices tokens, read README.md:12 as an absolute guarantee. With a carrier, k devices on one account can together spend up to k times the balance, welcome tokens included. Airplane mode makes this reliable, and online it happens whenever spends fall inside the pull interval. The excess is recovered only through later purchases, and a UI that shows Wallet.balance displays a negative count. Paid gates are unaffected.

*Change:* Doc only; the behaviour is intended. README.md:12: limit the promise to one device's ledger. Add a bullet to Known defects and limitations, a clause to the PaywallCloudSync row (README.md:181) and a HANDBOOK paragraph saying:
- Devices spend against the balance they last pulled.
- Offline, or between pulls, each device can spend the same tokens. Pulls are hourly unless a purchase, a restore or a forwarded CloudKit silent push calls requestPull() then syncNow().
- The merge keeps every debit, so balance goes negative and token gates stay closed until repaid. Display `available`, not `balance`.

Extend Ledger.swift:20 to name this case.

#### D2 · low impact · confirmed

Sources/PaywallCore/EntitlementResolver.swift:103-106 drops every transaction whose expirationDate <= now. `now` is clock.now (Sources/PaywallCore/GateEngine+Store.swift:25), which is Date() in production (Sources/PaywallCore/PaywallClock.swift:18). The cached snapshot is loaded with clock.now (Sources/PaywallCore/GateEngine.swift:263) and downgraded only when expiresAt <= now (:747). The expiry timer sleeps toward expiresAt by the wall clock (GateEngine+Store.swift:76-88).
- Clock set forward: a subscriber StoreKit still lists resolves as .free (fails closed).
- Clock set back: a lapsed cached subscription keeps paying until the launch refresh (GateEngine.swift:298). After that the package keeps only what StoreKit lists.

README.md:228 and EntitlementResolver.swift:83-84 are wrong. README.md:19 is wrong only in the fail-closed direction.

*Citation corrections:* The citations are correct. The filter spans EntitlementResolver.swift:103-106. The snapshot is loaded at GateEngine.swift:263 and checked at :747. Add GateEngine+Store.swift:25 and PaywallClock.swift:18. Add EntitlementResolver.swift:83-84 ("its only inputs are store values"), which makes the same claim.

*Why this impact:* The verified effects are small and mostly fail closed. A forward clock shows the user who moved it as free, which costs a support ticket. A backward clock honours a lapsed cache only until the launch resolution, normally well under a second. Nothing grants more than StoreKit lists. Both verifiers rated it medium because of the unverified billing-grace reading, which would be a separate code defect, not this doc mismatch.

*Change:* Doc, README.md:228: "Entitlements come only from StoreKit's verified transactions, but whether they have expired is judged by the device clock (the resolver, the launch snapshot and the expiry timer). A clock set forward shows a subscriber as free. A clock set back keeps a lapsed cached subscription until the launch resolution. Audit records carry uptime to expose clock changes." Also name the clock at EntitlementResolver.swift:83-84.

Separately, check in the StoreKit host lane with Billing Grace Period on: does currentEntitlements return grace-period subscriptions with a past expirationDate? PaywallSimulator.swift:154 assumes grace keeps access. If it does, line 104 drops paying users, and that is its own finding.

#### D3 · low impact · confirmed, narrower than reported

Sources/PaywallCore/GateEngine.swift:349 ("rejected at configuration time") is false:
- GateLevel.isValid (Sources/PaywallCore/GateLevel.swift:17-20) has no caller in Sources, only Tests/PaywallCoreTests/LedgerTests.swift:128-129.
- configure validates only the catalog (Sources/PaywallCore/ProductCatalog.swift:102-113, called from Sources/PaywallKit/Paywall.swift:135).
- Gate levels are call-site arguments, so nothing could reject them at configuration.

At run time decide() closes any cost <= 0 with .requiresPaid, after the paying and unknown checks (GateEngine.swift:347-350; Tests/PaywallCoreTests/GateEngineTests.swift:58-61). GateLevel.swift:16 claims no rejection: "configuration errors, never a free gate" holds as written.

*Citation corrections:* Only GateEngine.swift:349 claims rejection at configuration time; GateLevel.swift:16 is accurate. :349 names only .tokens(0), but :350 treats negative costs the same way.

*Why this impact:* It fails closed, so nothing leaks. A developer whose computed cost reaches 0 gets no configuration error and no debug warning. Instead, free users see a .requiresPaid paywall, and the developer learns about it from them.

*Change:* Doc, GateEngine.swift:349: "Nothing rejects `.tokens(n)` with n <= 0 up front; at run time it fails closed like `.paid`." GateLevel.swift:16 can stay, or say "caller errors" to avoid confusion with Paywall.ConfigurationError.

Code, optional: a DEBUG-only warning or assertionFailure when !level.isValid in begin, openSession and evaluate. That gives isValid its only production caller.

#### D4 · medium impact · confirmed

A gated view pins its gate id's lease once one exists, in any of three ways:
- it finds a live lease when it evaluates (Sources/PaywallCore/GateEngine.swift:438-441);
- it draws on appear with .deductNow (:454);
- something commits, including a plain withPaywall that consumes its hold (Sources/PaywallCore/GateEngine+Draw.swift:70, :78, :92, :140).

While the lease is pinned, LeaseTable.isActive ignores the time (Sources/PaywallCore/LeaseTable.swift:24). decide() checks the lease by gate id before the cost (GateEngine.swift:351), so any gate with the same id, at any n, opens .leased without drawing. The pin drops on disappear or on a closed decision (:421, :436). The tests intend this (Tests/PaywallCoreTests/GateEngineTests.swift:168-192). README.md:141-142 never mention pinning; HANDBOOK.md:227-229 covers only .deductNow.

*Citation corrections:* LeaseTable.swift:24 is the check, not the pinning. Pinning happens at GateEngine.swift:441, GateEngine+Draw.swift:92 and :140. A .reserve view that never commits and finds no live lease pins nothing. Add Tests/PaywallCoreTests/CrashSafetyTests.swift:135-139.

*Why this impact:* An integrator who prices per action inside a view gate, such as `gate.withPaywall { generate() }` (GateLevel.swift:7 promises "N tokens per use"), actually gets per-visit pricing. After the first commit, every further commit, and every withPaywall elsewhere with the same id, is free for as long as the screen stays open. That runs well past the 300 s tolerance the README describes.

*Change:* Doc; the tests make the behaviour intended. Update README.md:141-143 and :228, HANDBOOK.md:227-229 and GateLevel.swift:7 to say:
- Once a gated view has a lease (its first draw or commit, or a live lease found on appear), it pins it.
- While the view is on screen, commits through \.paywallGate and any withPaywall with that id, at any n, open .leased without drawing.
- tolerance starts counting only when the view leaves.
- A view gate costs N per visit. Per-use pricing needs a plain withPaywall with its own id, which is still free within tolerance.

Whether per-visit pricing is the intended product rule is the owner's call.

#### D5 · low impact · confirmed

Sources/PaywallCore/LedgerSync.swift:8-10 says any answer, even an empty one, means the carrier looked, and the engine settles on it. PaywallCloudSync.pull returns [] without fetching when no pull was requested and the last fetch is younger than minimumPullInterval (Sources/PaywallCloudSync/PaywallCloudSync.swift:50). performSync still merges, settles the baseline and checks the welcome grant on that answer (Sources/PaywallCore/GateEngine+Store.swift:355-359).

pullRequested starts true and lastPull is set only after a fetch (PaywallCloudSync.swift:22, :64), so a carrier instance's first answer is a real look. Only an engine that inherits a carrier that has already pulled can settle on a throttled []. PaywallServiceProvider.useProduction() does this (Sources/PaywallKit/PaywallServiceProvider.swift:83-85).

*Citation corrections:* The citations are correct. Add PaywallCloudSync.swift:22 and :64 (why a carrier's first pull fetches) and GateEngine+Store.swift:355-359 (where the engine settles).

*Why this impact:* It misleads authors of custom carriers, whom README.md:183 invites, about what an empty answer may mean. With the shipped carrier, the only engine that settles on a throttled [] is one reconfigured onto the same carrier. In the shipped flows that engine also uses the same directory, which its predecessor already settled, so no decision changes.

*Change:* Code, small: call `await sync?.requestPull()` at the start of GateEngine.start(), so each engine's first answer is a real look.

Doc, LedgerSync.swift:8-10: "An empty answer means nothing new since the carrier last looked. The engine settles the baseline and the welcome grant on it, so the first pull, and the first after requestPull(), must really fetch."

Separately, not part of D5: pull() saves the change token (PaywallCloudSync.swift:59-63) before the engine merges. An answer the engine then drops (GateEngine+Store.swift:355, :370-374) is never fetched again.

#### D6 · low impact · confirmed

README.md:267-268 says the real values exist only in App Store Connect and the Worker's secrets. The worker gives the key id and the issuer id to any caller:
- the JWS header kid and payload iss (Workers/PromotionalOfferSigner/src/signer.ts:64, :66);
- the response's keyId (src/app.ts:85);
- the kid at GET /v1/keys (app.ts:37, src/config.ts:92).

Signing needs only an allowed bundle id and, when ALLOWED_OFFERS is set, an allowed offer (app.ts:75-78). Apple's format requires kid and iss; keyId and /v1/keys are the worker's own choice. The downloaded .p8 (Workers/PromotionalOfferSigner/README.md:57, :66, :80) and the real receipt (README.md:263-264) also exist on the developer's machine.

*Citation corrections:* /v1/keys exposes only the key id (config.ts:92); the issuer id leaks through the JWS payload (signer.ts:66). Add signer.ts:64 and :66, app.ts:37 and config.ts:92. README.md:227 ("The key exists only as a Worker secret") has the same .p8 gap.

*Why this impact:* Key id and issuer id are identifiers, not credentials: nothing can be signed without the private key. Two real risks remain:
- A key-compromise or rotation runbook built from README.md:227 and :267 forgets the downloaded .p8.
- A publisher assumes the public worker hides which developer account (issuer) it belongs to.

*Change:* Doc, rewrite README.md:267-268: "The private key lives in the Worker's secrets and in the .p8 downloaded once from App Store Connect; keep that file out of the repository, or delete it after `wrangler secret put`. The key id and issuer id are not secret: every signature carries them, and the worker returns the key id and serves it at /v1/keys. They stay out of this repository because they identify the publisher. The real receipt for the production-receipt lane stays outside the repository. CI uses simulated values only."

Also add the .p8 to README.md:227.

#### D7 · low impact · confirmed

Sources/PaywallKit/Paywall+Audit.swift:21-22 calls the export "Tamper-evident" for a support case or an App Store dispute. README.md:13 and :175 and Sources/PaywallCore/LedgerEvent.swift:34 make the same claim. How the chain works:
- It is unkeyed SHA-256 of canonical JSON (Sources/PaywallCore/Audit.swift:44-46), checked link to link (:51-58).
- It starts from audit.anchor, a file beside the log (:105, :135) that is read back and exported with it (:202-211).
- The newest hash is read from the log's own tail (:183-189).

Whoever can write the container can drop the newest records undetected, or rewrite the whole chain consistently. Only the signed AppTransaction or receipt (Paywall+Audit.swift:31, :51) can be checked by a third party. "Timestamped twice" means the device's at plus uptime (Audit.swift:5-8).

*Citation corrections:* The citations are correct. Add Audit.swift:44-46, :105, :135, :183-189 and :202-211, LedgerEvent.swift:34, and README.md:13 and :175.

*Why this impact:* No balance, entitlement or gate decision depends on the audit chain, and Apple's refund process does not read these zips. The harm is limited to a support decision, such as a goodwill token grant, made on an export the customer controls. Rewriting it needs write access to the container: a jailbreak, a restored backup, or the iOS app running on a Mac. Verifier 1's medium rating overweights that path.

*Change:* Doc, Paywall+Audit.swift:21-22 and LedgerEvent.swift:34: "Hash-chained: detects corruption and edits that do not rewrite the records after them. Not tamper-proof against whoever controls the device: the chain is unkeyed, its head is not anchored off the device, and dropping the newest records goes unnoticed. Only the signed AppTransaction or receipt can be verified by a third party. When evidence must hold against the user, forward records or the chain head to your server with a ClosureSink."

Soften README.md:13 and :175 to match.

#### D8 · low impact · confirmed

Sources/PaywallCore/GateEngine+Store.swift:7-8 says refresh "Never waits for the network". But :21 awaits store.appTransaction(), which on iOS 16+ awaits AppTransaction.shared (Sources/PaywallKit/StoreKit2Client.swift:41). StoreKit's doc in the installed iPhoneOS SDK (StoreKit.swiftdoc) says shared returns the cached AppTransaction for this app version, or requests one from the App Store server when none is cached. GateEngine+Store.swift:19-20 and StoreKit2Client.swift:36 already admit it fails offline.

start() awaits this refresh before the welcome grant (when there is no carrier), the first sync and the storefront fetch (GateEngine.swift:298-303). Meanwhile a fresh install stays .unknown, so .paid and token gates are closed (:348). currentEntitlements and Transaction.all are read on the device.

*Citation corrections:* The citations are correct. Add GateEngine+Store.swift:21 (the await) and :19-20. Sources/PaywallCore/StoreClient.swift:123 promises only "Never prompts". Apple's wording is in the SDK's StoreKit.swiftdoc, not in the repo.

*Why this impact:* The wait happens only while StoreKit has no app transaction cached for this app version: a first launch, and possibly the first launch after an update. Gates fail closed during it. The real cost of the wrong doc is that maintainers treat the launch resolution as bounded local work, so nothing times out or is ordered around a slow fetch.

*Change:* Doc, GateEngine+Store.swift:7-8: "Reads currentEntitlements and Transaction.all from StoreKit's on-device cache. The app transaction comes from AppTransaction.shared, which asks the App Store when none is cached for this app version (typically the first launch), so this resolution can wait on the network. Offline it fails and the receipt answers. Never prompts."

Code, optional: resolve with the cached app-transaction.json first and bind the fresh AppTransaction afterwards, or put a timeout on the fetch.

#### D9 · low impact · confirmed

Sources/PaywallCore/EntitlementResolver.swift:24 documents paidWindow as "First paid release ..< the day the freemium build goes live", which reads as half-open. But admits() tests paidWindow.contains(originalPurchaseDate) (:52), and checks the sentinel window the same way (:56). DateInterval is closed, [start, end] (iPhoneOS SDK NSDateInterval.h:15, :28). So a purchase exactly at `end` is admitted, provided it also passes the environment and lastPaidBuild checks (:46-50).

No test sits on the boundary: Tests/PaywallKitTests/ReceiptClientTests.swift:426 is 1 s outside it, and Tests/PaywallCoreTests/ResolverTests.swift:89 is a day after.

*Citation corrections:* The citations are correct. Add EntitlementResolver.swift:56, the sentinel window, which uses the same closed contains.

*Why this impact:* The doc and the code differ at a single instant (milliseconds for an AppTransaction, seconds for a receipt). An install bought at that instant must still pass the lastPaidBuild check, so no realistic customer is misclassified. The only risk is a reader who relies on the `..<`.

*Change:* Doc, EntitlementResolver.swift:24: "First paid release through the moment the freemium build goes live, both ends included (DateInterval.contains is closed)." Leave the code as it is.

Only if a half-open window is wanted: test start <= date && date < end for both windows (:52, :56), and add a test exactly at `end`.

#### D10 · medium impact · confirmed

README.md:237 says "As of 2026-11-14 there is no known correctness defect in a shipping code path." The confirmed findings in §3 contradict it, starting with A1, A2, A3 and A6, and so do D1, D2 and D4 above. Integrators read that sentence, together with the "Known defects and limitations" list under it, as the package's current state.

*Verification:* the lead checked the line. Every entry in §3 reports the finding as absent from that list, except A11+B6, which HANDBOOK.md:396-397 lists as accepted with a rationale that is wrong.

*Change:* replace the sentence. As fixes land, keep the list under it in step with what is still open or accepted.

## 5. Operational item (not a code defect)

<a id="o1"></a>
### O1 · An App Store Connect In-App Purchase private key sits in the working copy

**What.** The local working copy has a file named `SubscriptionKey_<key id>.p8` at the repository root, dated 2026-11-14. It is the In-App Purchase private key that the signing worker uses. The only thing keeping it out of git is the `*.p8` rule in `.gitignore`. A `git add -f`, a tool that ignores `.gitignore`, a zip of the folder, or a sync or backup of the folder would carry it along. README.md:267 says the real values exist only in App Store Connect and the Worker's secrets (see D6).

**Action (owner).**
- The Worker already holds the key as a secret. Move this file, and any other local copy, to a password manager or another offline store, or delete it.
- If the folder has ever been synced or shared, treat the key as exposed. Revoke it in App Store Connect and `wrangler secret put` a new one, as README.md's risk table describes ("The In-App Purchase key is compromised or rotated").

**Optional hardening.** Add a pre-commit hook or a CI step that fails on `*.p8` files and on `BEGIN PRIVATE KEY` blocks outside the documented StoreKit Testing fixture.

**Verification.** The lead checked the file's name, size and date in a directory listing; its contents were not opened. The two reviewers worked on `git archive` exports, which do not contain ignored files.

## 6. Checked and found sound

The reviewers examined these areas closely and found them correct. These are the reviewers' statements; the verification pass checked findings, not these. A fix cycle can lean on them, but should re-check any of them it changes.

**Engine and journal (reviewer A)**
- **The draw's write-ahead order:** decided, `write(2)`, `F_FULLFSYNC`, ledger append, value, audit. Also what a crash at each step leaves behind, and treating a sync failure after a debit as durable (GateEngine+Draw.swift:110-145).
- **Journal mechanics:**
  - framing by length and CRC32
  - truncation of a genuinely torn tail
  - rewind after a short write, and poisoning when the rewind fails
  - compaction through a side file and a rename, after which the same engine reopens its fd (Journal.swift:185-240, :289-327)
- **Deterministic ids** (`credit:<txid>`, `revocation:<txid>`, `refund:<debitID>`, `grant:welcome`). A purchase result plus the same transaction on `Transaction.updates` never credits twice. Neither does a redelivery after a crash between the credit and the finish.
- **Revocations heal themselves.** `planRevocations` over `Transaction.all` re-plans a revocation whose write failed (CreditReconciler.swift:38-53).
- **Accounting:**
  - ledger balances per account partition, including the unbound and cross-account parts
  - reservation accounting in `decide`, which excludes the holder's own reservation (GateEngine.swift:336-355)
- **Lease protection** against clock rollback (`grantedAt <= now`), and the lease-pinning mechanics (LeaseTable.swift:20-32). D4 covers what the docs omit about pinning.
- **Ask to Buy.** `.pending` returns with no side effect, and the approval arrives through `Transaction.updates` and `handle`.
- **Upgrades and Family Sharing.** Upgrades are filtered by `isUpgraded`, and Family Sharing by policy, including on the cached launch snapshot.
- **The account key**, hashed from whole seconds, has the same derivation for AppTransaction and receipt snapshots. B13 notes that no test checks it against real data.
- **CloudKitDatabase:**
  - pagination over `moreComing`
  - the `changeTokenExpired` and `zoneVanished` resets
  - zone re-creation on save
  - `serverRecordChanged` counted as acknowledged
  - `notAuthenticated` mapped to `noAccount`
- **Upload markers.** `performSync` writes them only for acknowledged ids, and never after shutdown.
- **Signer echo check.** The engine checks that the signer echoes the product and offer it asked for (GateEngine+Store.swift:254).

**Trust boundaries (reviewer B)**
- **Receipt signature path:**
  - Every signer × certificate pair is tried, and Apple's receipt-signing marker (1.2.840.113635.100.6.11.1) is required on the candidate.
  - `SecTrust` is anchored only to the embedded Apple root, with network fetch disabled, at the receipt's field-12 date. The signature covers that date.
  - `messageDigest` is checked when signed attributes are present, and the digest and signature algorithms must agree.
  - The signature covers exactly the payload bytes that are parsed.
  - The bundle id is checked before the snapshot is used.
  - Tests pin the root fingerprint and the marker OID.
- **DER bounds.** Long-form lengths are capped at 4 bytes and checked against the buffer, and OID arcs are bounded. Depth is the only gap (B9).
- **Grandfathering rule:**
  - production-only by default
  - `.numeric` build comparison
  - "1.0" accepted only inside a sentinel window, so sandbox, TestFlight and review installs cannot grandfather
  - an idempotent grant id per account
- **Debug-only code.** `GrandfatherOverride`, `simulateBalance`/`simulateEntitlement` and the `resolverInput` override are under `#if DEBUG`. No release path reads launch arguments or the environment. Today every PaywallSimulator file is guarded (B3 and B4 cover what the release check would miss).
- **Logging.** `OSLogSink` logs details as `.private`.
- **The worker's JWS matches Apple's format:**
  - header `{alg: ES256, kid, typ: JWT}`
  - claims `iss`, `iat`, `aud: "promotional-offer"`, `bid`, a fresh lowercase UUID `nonce`, `productId`, `offerIdentifier`, an optional `transactionId`, and no `exp`
  - a raw r‖s signature
- **The worker's key and request handling:**
  - The key import is P-256 only. The signing key is non-extractable; its extractable twin is used only to read x and y.
  - Config failures are not cached.
  - Request validation is strict and rejects unknown fields.
  - `OPTIONS` gets 405 and no CORS headers.
  - `npx vitest run` passes 37 tests, and `npx tsc --noEmit` is clean.
- **App-side offers.** The purchase option is built from the checked offer, and an unverified purchase result throws.
- **Committed secrets.** The only committed key is the documented throwaway StoreKit Testing key, and `.dev.vars.example` holds placeholders. `*.p8` and `.dev.vars` are gitignored at the root and in the worker, and `DEVELOPMENT_TEAM` is empty.
- **CI.** It has `permissions: contents: read`, runs on `pull_request` (not `pull_request_target`) and uses no secrets. First-party actions are pinned by tag.
- **Tests.** In AuditTableTests, each `guard case … else { return }` follows a `first(...)` that already requires the case, so none of them is vacuous.

## 7. Not reviewed, and what only a device or a service can settle

**Read only on the surface, or not at all.** A later review should cover these:
- `StoreKitConfigurationCheck`, `PaywallDisclosure`, `WithPaywall`, the presenter logic in `PaywallHostingController`, and `NetworkPathConnectivity`.
- The TestHost suites (`StoreKitIntegrationTests`, `UIKitBoundaryTests`, `LiveCloudKitTests`). Both reviewers read parts of them, and none of them was run.
- Checkpoint equivalence. `LedgerIncrementalTests` was read but not re-derived.
- **File protection** (suspected, not exercised). The package never sets a data-protection class on its files. In a host app whose default is `NSFileProtectionComplete`, journal writes made in the background while the device is locked would fail and feed into A2 and A6. Check this on a device.
- Coverage numbers. No lane was run against the baseline.

**Facts that need a device, the sandbox, StoreKit Testing or a live service.** The entries name these where they matter. In summary:
- **StoreKit:**
  - Grace-period rows in `currentEntitlements` (A3).
  - How long `AppTransaction.shared` can stall, and whether it throws offline once cached (A4, B1, A11+B6, D8).
  - The `offerType` and payment mode of paid introductory offers (A10).
  - `finish()` and the purchase sheet on a full disk (A2).
  - Several `Transaction.updates` listeners at once (A5).
  - Empty or partial `currentEntitlements` answers in the field (B14).
  - Whether a receipt and an AppTransaction of one install agree to the second (B13).
- **CloudKit and Keychain:**
  - The CKError a signed-out device gets (A1, A9).
  - Whether Keychain items outlive app deletion (A1).
  - Whether a fetch honours task cancellation (A6).
- **Platform:**
  - Whether an iOS app's container is writable on an Apple-silicon Mac, and which identifier the receipt's device hash uses there (B1, A11+B6).
  - Whether downgrades keep app data (A7).
- **Cloudflare:**
  - The Free plan's daily cap.
  - Whether WAF rules can reach workers.dev (B5).
  - Workers Logs sampling and retention (B11).
- **Archives:**
  - What a release `.ipa` actually contains (B3, B4).
  - The DER depth that crashes a release build (B9).

## 8. Method

**Reviewers.** Two independent agents reviewed the whole repository in parallel, neither seeing the other's work. Each worked in a private `git archive` export of `b5c20e4`.
- Reviewer A's lens was runtime correctness: the engine, ledger, journal, StoreKit 2 client, facade and CloudKit sync. It wrote 15 throwaway probes (Appendix A).
- Reviewer B's lens was trust boundaries: receipt verification, grandfathering, the signing worker and its app-side client, release hygiene, CI and the coverage gate, test integrity, and the docs. Its probes were deleted after they ran.

Both could build and run the macOS test suites and the worker's vitest suite. Neither ran xcodebuild, a simulator or the live lanes, and neither contacted Apple, iCloud or Cloudflare.

**Verification.** Every finding then went to two further independent agents:
- Verifier 1 tried to refute the finding from the code alone, checking every citation.
- Verifier 2 judged whether the failure can happen in a shipping app or a deployed worker. It re-ran or rebuilt the reproduction in an isolated build of the same commit, and checked the platform facts against Apple's and Cloudflare's documentation.

A judge then read both verdicts and the code, settled the verdict and severity, and wrote the entry in §3. The docs claims went to two independent verifiers and a judge. A finding refuted by both verifiers would have been dropped; none was. A11 and B6 describe the same gap and were merged into one entry.

**Severity scale:**

| Severity | Meaning |
|---|---|
| critical | Loses paid entitlements or purchased credits, grants paid features for free in a way users can find, leaks a secret, lets third parties abuse the signer, or corrupts persisted state |
| high | Wrong behaviour that real users will hit, or an exploitable weakness |
| medium | An edge case or hardening |
| low | Anything smaller |

The judges weighed how likely the trigger is, not only the consequence. That is why several findings with critical-class consequences are rated high or medium.

**Toolchain.** Xcode 27.0 (Swift 6.4) on macOS 27, Node 22.

**Not involved.** No device, simulator, sandbox, TestFlight build, CloudKit container or deployed worker. §7 lists what only those can settle.

## Appendix A: reviewer A's probes

These are throwaway Swift Testing suites written against `b5c20e4`. Each `#expect` states the correct behaviour, so each probe fails until its finding is fixed. They use the test targets' own helpers (`Harness`, `eventually`, `source`, `catalog`, `products`) and `@testable` access. To run one, save it at the path shown and run `swift test --filter ReviewerAProbe`. Turn what you need into a real regression test, and don't commit the probes as they are.

| Probes | Finding |
|---|---|
| probe1, probe2, probe3, probe15 | A1 |
| probe4 | A2 |
| probe7 | A3 |
| probe10 | A4 |
| probe5, probe6, probe11 | A5 |
| probe8, probe14 | A6 |
| probe9 | A7 |
| probe12 | A8 |
| probe13 | A9 |

<details><summary><code>Tests/PaywallCoreTests/ReviewerAProbeTests.swift</code></summary>

```swift
import Foundation
import PaywallTesting
import Testing

@testable import PaywallCore

/// Throwaway probes written by reviewer A. Not part of the package.
@Suite("Reviewer A probes", .serialized)
@MainActor
struct ReviewerAProbeTests {
    /// Reinstall with iCloud off: the Keychain snapshot stands in. One draw, one relaunch.
    @Test func probe1_reinstall_snapshot_after_a_draw_and_a_relaunch() async throws {
        let sync = InMemoryLedgerSync(cloud: InMemoryCloud())
        _ = try await Harness.free(tokens: 10, sync: sync)
        #expect(await eventually { await sync.snapshot?.balance == 10 })
        await sync.cloud.setReachable(false)
        let reinstalled = try Harness(sync: sync)
        await reinstalled.start()
        let first = reinstalled.engine.wallet.balance
        _ = reinstalled.engine.run(.tokens(1), source: source("x")) {}
        let afterDraw = reinstalled.engine.wallet.balance
        _ = await eventually { await sync.snapshot?.balance == 9 }
        try await reinstalled.relaunch()
        _ = await eventually { false }  // let the init-time snapshot task run
        let snap = await sync.snapshot
        print("PROBE1 reinstall=\(first) afterDraw=\(afterDraw) relaunched=\(reinstalled.engine.wallet.balance) baseline=\(String(describing: reinstalled.engine.baseline)) keychain=\(String(describing: snap))")
        #expect(reinstalled.engine.wallet.balance == 9)
    }

    /// Reinstall with iCloud off, no activity, one relaunch.
    @Test func probe2_reinstall_snapshot_after_a_plain_relaunch() async throws {
        let sync = InMemoryLedgerSync(cloud: InMemoryCloud())
        _ = try await Harness.free(tokens: 10, sync: sync)
        #expect(await eventually { await sync.snapshot?.balance == 10 })
        await sync.cloud.setReachable(false)
        let reinstalled = try Harness(sync: sync)
        await reinstalled.start()
        let first = reinstalled.engine.wallet.balance
        _ = await eventually { await sync.snapshot?.lastEventID == nil }
        let persisted = await sync.snapshot
        try await reinstalled.relaunch()
        print("PROBE2 reinstall=\(first) persisted=\(String(describing: persisted)) relaunched=\(reinstalled.engine.wallet.balance) baseline=\(String(describing: reinstalled.engine.baseline))")
        #expect(reinstalled.engine.wallet.balance == 10)
    }
}

@Suite("Reviewer A probes 2", .serialized)
@MainActor
struct ReviewerAProbeTests2 {
    /// A credit the journal could not write is still finished: StoreKit never re-delivers it.
    @Test func probe4_credit_write_failure_still_finishes_the_transaction() async throws {
        let h = try await Harness.free()
        h.engine.journal.injectedFault = .write
        await h.engine.handle(.tokenPack(id: 21, productID: "tokens.10", purchased: h.clock.now))
        let finishedAfterHandle = await h.store.finished
        let outcome = try await h.engine.purchase(productID: "tokens.10", source: nil)
        let finishedAfterPurchase = await h.store.finished
        let balanceNow = h.engine.wallet.balance
        h.engine.journal.injectedFault = nil
        try await h.relaunch()
        await h.engine.refresh(cause: .foreground)
        print("PROBE4 finishedAfterHandle=\(finishedAfterHandle) outcome=\(outcome) finishedAfterPurchase=\(finishedAfterPurchase) balance=\(balanceNow) afterRelaunchAndRefresh=\(h.engine.wallet.balance)")
        #expect(h.engine.wallet.balance == 20)
    }

    /// An engine after `shutdown()` still appends to the journal; once its successor compacted the log, what it writes
    /// goes to the unlinked file and is lost, although the transaction was finished.
    @Test func probe5_a_shut_down_engine_writes_and_finishes_after_its_successor_compacted() async throws {
        let h = try Harness(settings: GateEngine.Settings(tolerance: 300, appVersion: "2.0", build: "200", compactionThreshold: 2))
        await h.start()
        for i in 0..<4 { h.engine.grant(tokens: 1, reason: "g\(i)") }
        let old = h.engine
        try await h.relaunch()  // shutdown + successor; the successor's start() checkpoints and renames the log
        let successorBalance = h.engine.wallet.balance
        await old.handle(.tokenPack(id: 41, productID: "tokens.10", purchased: h.clock.now))
        let granted = old.grant(tokens: 5, reason: "after shutdown")
        let finished = await h.store.finished
        try await h.relaunch()
        print("PROBE5 oldIsShutDown=\(old.isShutDown) successorBalance=\(successorBalance) oldWalletAfterLateWrites=\(old.wallet.balance) lateGrantReturned=\(granted) finished=\(finished) balanceAfterNextLaunch=\(h.engine.wallet.balance) hasCredit=\(h.engine.ledger.contains("credit:41"))")
        #expect(h.engine.ledger.contains("credit:41") || !finished.contains(41))
    }

    /// Without compaction the late writes land, but link to the head the successor also links to: a fork.
    @Test func probe6_late_write_forks_the_chain() async throws {
        let h = try await Harness.free(tokens: 5)
        let old = h.engine
        try await h.relaunch()
        _ = h.engine.run(.tokens(1), source: source("x")) {}
        await old.handle(.tokenPack(id: 42, productID: "tokens.10", purchased: h.clock.now))
        let successorSees = h.engine.wallet.balance
        try await h.relaunch()
        print("PROBE6 successorSawCredit=\(successorSees) nextLaunchBalance=\(h.engine.wallet.balance) firstBrokenLink=\(String(describing: h.engine.ledger.firstBrokenLink()?.id))")
        #expect(h.engine.ledger.firstBrokenLink() == nil)
    }

    /// A subscription in its billing grace period: StoreKit keeps its latest transaction in `currentEntitlements`
    /// although that transaction's expiration date has passed.
    @Test func probe7_grace_period_subscription_resolves_free() async throws {
        let h = try await Harness.free()
        let now = h.clock.now
        let lapsed = StoreTransaction.subscription(
            id: 51, productID: "pro.monthly", purchased: now.addingTimeInterval(-31 * 86_400), expires: now.addingTimeInterval(-3_600))
        await h.store.setEntitlements([lapsed])
        await h.store.setPhase(.inGracePeriod)
        await h.engine.refresh(cause: .foreground)
        print("PROBE7 entitlement=\(h.engine.entitlement) paidGate=\(h.engine.canPass(.paid)) phase=\(String(describing: try await h.store.subscriptionPhase(groupID: "pro")))")
        #expect(h.engine.entitlement.isPaying)
    }
}

/// Forwards to a `FakeStore`, with a one-shot delay on `appTransaction()` (an `AppTransaction.shared` that is slow
/// this time), so one resolution's store reads can be older than another's that finishes first.
actor SlowAppTransactionStore: StoreClient {
    let inner: FakeStore
    var delayNext: UInt64 = 0
    init(_ inner: FakeStore) { self.inner = inner }
    func setDelayNext(_ nanoseconds: UInt64) { delayNext = nanoseconds }
    func currentEntitlements() async throws -> [StoreTransaction] { try await inner.currentEntitlements() }
    func allTransactions() async throws -> [StoreTransaction] { try await inner.allTransactions() }
    func appTransaction() async throws -> AppTransactionSnapshot? {
        let delay = delayNext
        delayNext = 0
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        return try await inner.appTransaction()
    }
    func updates() async -> AsyncStream<StoreTransaction> { await inner.updates() }
    func purchaseIntents() async -> AsyncStream<String> { await inner.purchaseIntents() }
    func products(for ids: Set<String>) async throws -> [PaywallProduct] { try await inner.products(for: ids) }
    func purchase(productID: String, offer: SignedPromotionalOffer?) async throws -> StorePurchaseResult {
        try await inner.purchase(productID: productID, offer: offer)
    }
    func sync() async throws { try await inner.sync() }
    func finish(transactionID: UInt64) async { await inner.finish(transactionID: transactionID) }
    func subscriptionPhase(groupID: String) async throws -> SubscriptionPhase? { try await inner.subscriptionPhase(groupID: groupID) }
    func isEligibleForIntroOffer(groupID: String) async -> Bool { await inner.isEligibleForIntroOffer(groupID: groupID) }
    func storefrontCountryCode() async -> String? { await inner.storefrontCountryCode() }
}

@Suite("Reviewer A probes 3", .serialized)
@MainActor
struct ReviewerAProbeTests3 {
    /// The foreground resolution that started before the purchase landed finishes after the purchase's own: its
    /// stale read is applied last and the subscription the user just bought resolves away.
    @Test func probe10_a_stale_resolution_overwrites_a_newer_one() async throws {
        let clock = FakeClock()
        let fake = FakeStore(products: products, now: { await clock.now })
        let store = SlowAppTransactionStore(fake)
        let engine = try GateEngine(directory: makeTemporaryPaywallDirectory(), catalog: catalog, clock: clock, store: store)
        await engine.start()
        await store.setDelayNext(200_000_000)
        let foreground = Task { await engine.refresh(cause: .foreground) }  // the scene became active
        try await Task.sleep(nanoseconds: 30_000_000)  // it has read currentEntitlements, now waits on appTransaction
        let outcome = try await engine.purchase(productID: "pro.monthly", source: nil)
        let afterPurchase = engine.entitlement
        await foreground.value
        print("PROBE10 outcome=\(outcome) afterPurchase=\(afterPurchase.isPaying) afterStaleRefresh=\(engine.entitlement) storeHas=\(try await fake.currentEntitlements().map(\.productID))")
        #expect(engine.entitlement.isPaying)
    }
}

/// An audit sink whose launch repair takes a moment (a long audit log being read).
actor SlowRepairSink: PaywallAuditRepairing {
    func write(_ record: AuditRecord) async {}
    func recordedDebitIDs() async -> Set<String> {
        try? await Task.sleep(nanoseconds: 100_000_000)
        return []
    }
    func lastRecordHash() async -> String? { nil }
}

@Suite("Reviewer A probes 4", .serialized)
@MainActor
struct ReviewerAProbeTests4 {
    /// `shutdown()` while `start()` waits on the audit repair: `start()` carries on, starts listeners nobody cancels,
    /// resolves, and writes the welcome grant into the journal the successor owns.
    @Test func probe11_start_continues_after_shutdown() async throws {
        let store = FakeStore(products: products)
        let directory = makeTemporaryPaywallDirectory()
        let engine = try GateEngine(
            directory: directory, catalog: catalog, settings: GateEngine.Settings(welcomeTokens: 100), clock: FakeClock(),
            store: store, audit: [SlowRepairSink()])
        let started = Task { await engine.start() }
        try await Task.sleep(nanoseconds: 20_000_000)
        engine.shutdown()  // the facade reconfigured
        await started.value
        let journal = try Journal(directory: directory)
        print("PROBE11 isShutDown=\(engine.isShutDown) updatesTask=\(engine.updatesTask != nil) storeListeners=\(await store.listenerCount) entitlement=\(engine.entitlement) journalIDs=\(journal.ledgerEvents.map(\.id))")
        #expect(engine.updatesTask == nil)
        #expect(journal.ledgerEvents.isEmpty)
    }
}
```

</details>

<details><summary><code>Tests/PaywallCloudSyncTests/ReviewerAProbeCloudTests.swift</code></summary>

```swift
import Foundation
@testable import PaywallCore
import PaywallTesting
import Testing

@testable import PaywallCloudSync

/// Throwaway probes written by reviewer A. Not part of the package.
private actor ProbeItem {
    var value: WalletSnapshot?
    func save(_ snapshot: WalletSnapshot) { value = snapshot }
}

/// `PaywallCloudSync` for the events (the real carrier, on an in-memory database), the snapshot in a local item
/// standing in for the Keychain, which survives app deletion.
private actor ProbeCarrier: LedgerSync {
    let events: PaywallCloudSync
    let item: ProbeItem
    init(cloud: InMemoryCloudDatabase, item: ProbeItem) {
        events = PaywallCloudSync(database: cloud, keychain: nil, minimumPullInterval: 0)
        self.item = item
    }
    func push(_ batch: [LedgerEvent]) async throws -> Set<String> { try await events.push(batch) }
    func pull() async throws -> [LedgerEvent] { try await events.pull() }
    func requestPull() async { await events.requestPull() }
    func loadSnapshot() async -> WalletSnapshot? { await item.value }
    func saveSnapshot(_ snapshot: WalletSnapshot) async { await item.save(snapshot) }
}

@Suite("Reviewer A cloud probes", .serialized)
@MainActor
struct ReviewerAProbeCloudTests {
    private let catalog = ProductCatalog(subscriptionGroupID: "pro", lifetime: "pro.lifetime", tokenPacks: [TokenPack(productID: "tokens.10", tokens: 10)])

    private func launch(_ directory: URL, _ carrier: ProbeCarrier) async throws -> GateEngine {
        let engine = try GateEngine(
            directory: directory, catalog: catalog, settings: GateEngine.Settings(welcomeTokens: 100), clock: FakeClock(),
            store: FakeStore(), sync: carrier)
        await engine.start()
        await engine.syncNow()
        return engine
    }

    /// iCloud off (the carrier answers "no account"), Keychain on: delete and reinstall, then relaunch once.
    @Test func probe3_icloud_off_reinstall_then_relaunch() async throws {
        let cloud = InMemoryCloudDatabase()
        await cloud.setAccount(false)
        let item = ProbeItem()
        let old = try await launch(makeTemporaryPaywallDirectory(), ProbeCarrier(cloud: cloud, item: item))
        await old.handle(.tokenPack(id: 7, productID: "tokens.10", purchased: Date()))
        await old.handle(.tokenPack(id: 8, productID: "tokens.10", purchased: Date()))
        let before = old.wallet.balance
        for _ in 0..<200 where await item.value?.balance != before { try? await Task.sleep(nanoseconds: 2_000_000) }
        old.shutdown()

        let directory = makeTemporaryPaywallDirectory()
        let reinstalled = try await launch(directory, ProbeCarrier(cloud: cloud, item: item))
        let afterReinstall = reinstalled.wallet.balance
        for _ in 0..<200 where await item.value?.lastEventID != nil { try? await Task.sleep(nanoseconds: 2_000_000) }
        reinstalled.shutdown()

        let relaunched = try await launch(directory, ProbeCarrier(cloud: cloud, item: item))
        let welcome = relaunched.ledger.events.filter { $0.id == "grant:welcome" }.count
        print("PROBE3 oldInstall=\(before) reinstall=\(afterReinstall) relaunch=\(relaunched.wallet.balance) welcomeGrantsInNewLedger=\(welcome)")
        #expect(relaunched.wallet.balance == before)
    }
}

@Suite("Reviewer A cloud probes 2", .serialized)
@MainActor
struct ReviewerAProbeCloudTests2 {
    private let catalog = ProductCatalog(subscriptionGroupID: "pro", lifetime: "pro.lifetime", tokenPacks: [TokenPack(productID: "tokens.10", tokens: 10)])

    /// The carrier stores its change token before the engine has merged what the pull returned: a merge that fails
    /// (or an engine that was shut down meanwhile) loses those events for this install.
    @Test func probe8_change_token_moves_before_the_merge_is_durable() async throws {
        let cloud = InMemoryCloudDatabase()
        let a = try GateEngine(directory: makeTemporaryPaywallDirectory(), catalog: catalog, clock: FakeClock(), store: FakeStore(),
                               sync: PaywallCloudSync(database: cloud, keychain: nil, minimumPullInterval: 0))
        await a.start()
        await a.handle(.tokenPack(id: 9, productID: "tokens.10", purchased: Date()))
        await a.syncNow()

        let tokenURL = makeTemporaryPaywallDirectory().appendingPathComponent("cloudkit.token")
        let directoryB = makeTemporaryPaywallDirectory()
        let carrierB = PaywallCloudSync(database: cloud, keychain: nil, minimumPullInterval: 0, tokenURL: tokenURL)
        let b = try GateEngine(directory: directoryB, catalog: catalog, clock: FakeClock(), store: FakeStore(), sync: carrierB)
        b.journal.injectedFault = .write  // a full disk for one sync
        await b.start()
        await b.syncNow()
        b.journal.injectedFault = nil
        await carrierB.requestPull()
        await b.syncNow()
        let sameProcess = b.wallet.balance
        b.shutdown()
        let b2 = try GateEngine(directory: directoryB, catalog: catalog, clock: FakeClock(), store: FakeStore(),
                                sync: PaywallCloudSync(database: cloud, keychain: nil, minimumPullInterval: 0, tokenURL: tokenURL))
        await b2.start()
        await b2.syncNow()
        print("PROBE8 cloudCount=\(await cloud.count) deviceA=\(a.wallet.balance) deviceB_sameProcess=\(sameProcess) deviceB_relaunched=\(b2.wallet.balance)")
        #expect(b2.wallet.balance == 10)
    }
}

private actor ProbeTokenCarrier: LedgerSync {
    let events: PaywallCloudSync
    let item: ProbeItem
    init(cloud: InMemoryCloudDatabase, item: ProbeItem, tokenURL: URL) {
        events = PaywallCloudSync(database: cloud, keychain: nil, minimumPullInterval: 0, tokenURL: tokenURL)
        self.item = item
    }
    func push(_ batch: [LedgerEvent]) async throws -> Set<String> { try await events.push(batch) }
    func pull() async throws -> [LedgerEvent] { try await events.pull() }
    func requestPull() async { await events.requestPull() }
    func loadSnapshot() async -> WalletSnapshot? { await item.value }
    func saveSnapshot(_ snapshot: WalletSnapshot) async { await item.save(snapshot) }
}

@Suite("Reviewer A cloud probes 3", .serialized)
@MainActor
struct ReviewerAProbeCloudTests3 {
    private let catalog = ProductCatalog(subscriptionGroupID: "pro", lifetime: "pro.lifetime", tokenPacks: [TokenPack(productID: "tokens.10", tokens: 10)])

    private func launch(_ directory: URL, _ cloud: InMemoryCloudDatabase, _ item: ProbeItem) async throws -> GateEngine {
        let engine = try GateEngine(
            directory: directory, catalog: catalog, clock: FakeClock(), store: FakeStore(),
            sync: ProbeTokenCarrier(cloud: cloud, item: item, tokenURL: directory.appendingPathComponent("cloudkit.token")))
        await engine.start()
        await engine.syncNow()
        return engine
    }

    /// HANDBOOK: a log whose first frame no longer decodes is dropped and "the Keychain snapshot and the carrier then
    /// restore the ledger as after a reinstall". With the real carrier, the change token survives next to the log.
    @Test func probe9_dropped_log_is_not_restored_by_the_real_carrier() async throws {
        let cloud = InMemoryCloudDatabase()
        let item = ProbeItem()
        let directory = makeTemporaryPaywallDirectory()
        let first = try await launch(directory, cloud, item)
        await first.handle(.tokenPack(id: 3, productID: "tokens.10", purchased: Date()))
        _ = first.run(.tokens(3), source: PaywallSource(id: "g", fileID: "f", function: "f", line: 1)) {}
        await first.syncNow()
        for _ in 0..<200 where await item.value?.balance != 7 { try? await Task.sleep(nanoseconds: 2_000_000) }
        first.shutdown()

        let url = directory.appendingPathComponent("ledger.log")
        var bytes = [UInt8](try Data(contentsOf: url))
        bytes[12] ^= 0xFF  // inside the first frame
        try Data(bytes).write(to: url)

        let recovered = try await launch(directory, cloud, item)
        let recoveredBalance = recovered.wallet.balance
        let recoveredEvents = recovered.ledger.events.count
        for _ in 0..<200 where await item.value?.lastEventID != nil { try? await Task.sleep(nanoseconds: 2_000_000) }
        recovered.shutdown()
        let next = try await launch(directory, cloud, item)
        print("PROBE9 cloudCount=\(await cloud.count) recovered=\(recoveredBalance) recoveredEvents=\(recoveredEvents) nextLaunch=\(next.wallet.balance) nextEvents=\(next.ledger.events.count)")
        #expect(next.wallet.balance == 7)
    }
}

@Suite("Reviewer A cloud probes 4", .serialized)
@MainActor
struct ReviewerAProbeCloudTests4 {
    private let catalog = ProductCatalog(subscriptionGroupID: "pro", lifetime: "pro.lifetime", tokenPacks: [TokenPack(productID: "tokens.10", tokens: 10)])

    private func cycle(account: Bool) async throws -> (entries: Int, bytes: Int, events: Int) {
        let cloud = InMemoryCloudDatabase()
        await cloud.setAccount(account)
        let directory = makeTemporaryPaywallDirectory("outbox-\(account)")
        let settings = GateEngine.Settings(compactionThreshold: 50)
        func launch() async throws -> GateEngine {
            let engine = try GateEngine(directory: directory, catalog: catalog, settings: settings, clock: FakeClock(), store: FakeStore(),
                                        sync: PaywallCloudSync(database: cloud, keychain: nil, minimumPullInterval: 0,
                                                               tokenURL: directory.appendingPathComponent("cloudkit.token")))
            await engine.start()
            await engine.syncNow()
            return engine
        }
        let first = try await launch()
        first.grant(tokens: 1_000, reason: "probe")
        for i in 0..<300 { _ = first.run(.tokens(1), source: PaywallSource(id: "g\(i)", fileID: "f", function: "f", line: 1)) {} }
        await first.syncNow()
        first.shutdown()
        let second = try await launch()  // checkpoints: more than 50 events followed the last one at open
        second.shutdown()
        let third = try await launch()
        let bytes = (try? Data(contentsOf: directory.appendingPathComponent("ledger.log")).count) ?? -1
        let result = (third.journal.entries.count, bytes, third.ledger.events.count)
        third.shutdown()
        return result
    }

    /// HANDBOOK "Retention": the checkpoint lets a long-lived install not pay for its history. With the carrier
    /// configured and no iCloud account, nothing ever acknowledges the outbox.
    @Test func probe13_outbox_never_compacts_without_an_icloud_account() async throws {
        let withAccount = try await cycle(account: true)
        let withoutAccount = try await cycle(account: false)
        print("PROBE13 withAccount entries=\(withAccount.entries) bytes=\(withAccount.bytes) ledgerEvents=\(withAccount.events) | noAccount entries=\(withoutAccount.entries) bytes=\(withoutAccount.bytes) ledgerEvents=\(withoutAccount.events)")
        #expect(withoutAccount.entries < 50)
    }
}

@Suite("Reviewer A cloud probes 5", .serialized)
@MainActor
struct ReviewerAProbeCloudTests5 {
    private let catalog = ProductCatalog(subscriptionGroupID: "pro", lifetime: "pro.lifetime", tokenPacks: [TokenPack(productID: "tokens.10", tokens: 10)])

    private func engine(_ directory: URL, _ cloud: InMemoryCloudDatabase, _ item: ProbeItem) throws -> GateEngine {
        try GateEngine(
            directory: directory, catalog: catalog, settings: GateEngine.Settings(welcomeTokens: 100), clock: FakeClock(),
            store: FakeStore(), sync: ProbeTokenCarrier(cloud: cloud, item: item, tokenURL: directory.appendingPathComponent("cloudkit.token")))
    }

    /// Reinstall with iCloud on; the first sync's merge fails (a full disk). The change token moves anyway, the
    /// snapshot steps aside because the carrier "answered", and the account gets a second welcome grant.
    @Test func probe14_failed_merge_on_reinstall_settles_the_baseline_and_regrants_welcome() async throws {
        let cloud = InMemoryCloudDatabase()
        let item = ProbeItem()
        let old = try engine(makeTemporaryPaywallDirectory(), cloud, item)
        await old.start()
        await old.syncNow()
        await old.handle(.tokenPack(id: 5, productID: "tokens.10", purchased: Date()))
        await old.syncNow()
        for _ in 0..<200 where await item.value?.balance != 110 { try? await Task.sleep(nanoseconds: 2_000_000) }
        let before = old.wallet.balance
        old.shutdown()

        let directory = makeTemporaryPaywallDirectory()
        let reinstalled = try engine(directory, cloud, item)
        reinstalled.journal.injectedFault = .write
        await reinstalled.start()
        let adopted = reinstalled.wallet.balance
        await reinstalled.syncNow()
        let afterFailedMerge = reinstalled.wallet.balance
        let baselineAfter = reinstalled.baseline == nil ? "dropped" : "kept"
        reinstalled.journal.injectedFault = nil
        await reinstalled.syncNow()
        let afterRecovery = reinstalled.wallet.balance
        reinstalled.shutdown()
        let relaunched = try engine(directory, cloud, item)
        await relaunched.start()
        await relaunched.syncNow()
        print("PROBE14 oldInstall=\(before) adopted=\(adopted) afterFailedMerge=\(afterFailedMerge) baseline=\(baselineAfter) afterDiskRecovers=\(afterRecovery) relaunch=\(relaunched.wallet.balance) ledgerIDs=\(relaunched.ledger.events.map(\.id))")
        #expect(relaunched.wallet.balance == before)
    }
}

@Suite("Reviewer A cloud probes 6", .serialized)
@MainActor
struct ReviewerAProbeCloudTests6 {
    private let catalog = ProductCatalog(subscriptionGroupID: "pro", lifetime: "pro.lifetime", tokenPacks: [TokenPack(productID: "tokens.10", tokens: 10)])

    private func launch(_ directory: URL, _ carrier: ProbeCarrier) async throws -> GateEngine {
        let engine = try GateEngine(
            directory: directory, catalog: catalog, settings: GateEngine.Settings(welcomeTokens: 100), clock: FakeClock(),
            store: FakeStore(), sync: carrier)
        await engine.start()
        await engine.syncNow()
        return engine
    }

    /// iCloud off, Keychain on: reinstall, draw one token, relaunch twice.
    @Test func probe15_icloud_off_reinstall_draw_relaunch() async throws {
        let cloud = InMemoryCloudDatabase()
        await cloud.setAccount(false)
        let item = ProbeItem()
        let old = try await launch(makeTemporaryPaywallDirectory(), ProbeCarrier(cloud: cloud, item: item))
        await old.handle(.tokenPack(id: 7, productID: "tokens.10", purchased: Date()))
        await old.handle(.tokenPack(id: 8, productID: "tokens.10", purchased: Date()))
        let before = old.wallet.balance
        for _ in 0..<200 where await item.value?.balance != before { try? await Task.sleep(nanoseconds: 2_000_000) }
        old.shutdown()

        let directory = makeTemporaryPaywallDirectory()
        let reinstalled = try await launch(directory, ProbeCarrier(cloud: cloud, item: item))
        let afterReinstall = reinstalled.wallet.balance
        _ = reinstalled.run(.tokens(1), source: PaywallSource(id: "g", fileID: "f", function: "f", line: 1)) {}
        let afterDraw = reinstalled.wallet.balance
        for _ in 0..<200 where await item.value?.balance != afterDraw { try? await Task.sleep(nanoseconds: 2_000_000) }
        reinstalled.shutdown()
        let second = try await launch(directory, ProbeCarrier(cloud: cloud, item: item))
        let secondBalance = second.wallet.balance
        second.shutdown()
        let third = try await launch(directory, ProbeCarrier(cloud: cloud, item: item))
        print("PROBE15 oldInstall=\(before) reinstall=\(afterReinstall) afterDraw=\(afterDraw) relaunch=\(secondBalance) relaunchAgain=\(third.wallet.balance) canDraw=\(third.canPass(.tokens(1), gateID: "h"))")
        #expect(third.wallet.balance == before - 1)
    }
}
```

</details>

<details><summary><code>Tests/PaywallKitTests/ReviewerAProbeKitTests.swift</code></summary>

```swift
import Foundation
import PaywallCore
import PaywallTesting
import Testing

@testable import PaywallKit

/// Throwaway probe written by reviewer A. Not part of the package.
@Suite("Reviewer A kit probes", .serialized)
@MainActor
struct ReviewerAProbeKitTests {
    /// A gated view on screen while the facade is configured again (passthrough switched off at run time): its session
    /// lived on the old engine (or on no engine), the new engine never hears of it, and the view keeps its old state.
    @Test func probe12_sessions_are_orphaned_by_reconfigure() async throws {
        let paywall = Paywall()
        let store = FakeStore(products: products)
        let directory = makeTemporaryPaywallDirectory()
        var configuration = Paywall.Configuration(catalog: catalog)
        configuration.passthrough = true
        configuration.store = store
        configuration.storageDirectory = directory
        configuration.includesDefaultAudit = false
        configuration.connectivity = nil
        configuration.welcomeTokens = 0
        paywall.configure(configuration)
        let holder = UUID()
        var changes: [GateSessionState] = []
        let gate = PaywallSource(id: "chart", fileID: "f", function: "g", line: 1)
        let first = paywall.openSession(holder: holder, level: .tokens(1), policy: .deductNow, source: gate, scope: nil) { changes.append($0) }
        configuration.passthrough = false
        paywall.configure(configuration)
        await paywall.waitUntilStarted()
        print("PROBE12 firstState=\(first.decision) entitlement=\(paywall.entitlement) wallet=\(paywall.wallet.balance) engineKnowsHolder=\(paywall.engine?.sessionState(holder) != nil) onChangeCalls=\(changes.count) freshEvaluation=\(paywall.canPass(.tokens(1), id: "chart"))")
        #expect(paywall.engine?.sessionState(holder) != nil || !changes.isEmpty)
    }
}
```

</details>

## Appendix B: verifiers' reproductions

During verification, verifier 2 wrote these reproductions against `b5c20e4`, and the entries in §3 cite them. Like Appendix A, they are throwaways: save one at the path shown to run it, with `swift test --filter <suite>` or, in the worker, `npx vitest run <file>`. Then keep what the regression test needs. The Swift probes use the test targets' helpers and `@testable` access.

| Finding | Path to run it from | What it shows |
|---|---|---|
| A7 | `Tests/PaywallCloudSyncTests/A7Verifier2RealityProbeTests.swift` | Verifier 2's reproduction with the shipped carrier's change-token file: a corrupt frame drops the journal, and the history never comes back. |
| A8 | `Tests/PaywallKitTests/Verifier2A8ProbeTests.swift` | Verifier 2's reproduction: real `.paywallGated` views hosted in a window across a reconfigure, plus a control test. |
| A9 | `Tests/PaywallCloudSyncTests/Verifier2A9ProbeTests.swift` | Verifier 2's reproduction: the real `CloudKitDatabase` over a database that answers `notAuthenticated`, at the facade's compaction threshold. |
| B1 | `Tests/PaywallCoreTests/VerifierB1RealityProbeTests.swift` | Verifier 2's reproduction: a planted `app-transaction.json` answers while the store yields none, and the first real answer heals it. |
| B5 | `Workers/PromotionalOfferSigner/test/b5-repro.test.ts` | Verifier 2's probes against the production `handleRequest`: volume, `ALLOWED_OFFERS` unset, streamed bodies, UTF-16 length. |
| B11 | `Workers/PromotionalOfferSigner/test/b11-regression.test.ts` | Verifier 2's candidate regression test: it fails at `b5c20e4` and should pass after the fix. |

<details><summary>A7: <code>Tests/PaywallCloudSyncTests/A7Verifier2RealityProbeTests.swift</code></summary>

```swift
import Foundation
@testable import PaywallCore
import PaywallTesting
import Testing

@testable import PaywallCloudSync

/// Throwaway probes for verifier 2 of finding A7. Not part of the package.
private actor A7V2Item {
    var value: WalletSnapshot?
    func save(_ snapshot: WalletSnapshot) { value = snapshot }
}

/// The shipped carrier as `PaywallCloudSync()` builds it (default pull interval, change token in a file beside the
/// journal), on an in-memory database; the Keychain item in memory, since it outlives the journal.
private actor A7V2Carrier: LedgerSync {
    let events: PaywallCloudSync
    let item: A7V2Item
    init(cloud: InMemoryCloudDatabase, item: A7V2Item, tokenURL: URL) {
        events = PaywallCloudSync(database: cloud, keychain: nil, tokenURL: tokenURL)
        self.item = item
    }
    func push(_ batch: [LedgerEvent]) async throws -> Set<String> { try await events.push(batch) }
    func pull() async throws -> [LedgerEvent] { try await events.pull() }
    func requestPull() async { await events.requestPull() }
    func loadSnapshot() async -> WalletSnapshot? { await item.value }
    func saveSnapshot(_ snapshot: WalletSnapshot) async { await item.save(snapshot) }
}

@Suite("A7 verifier 2 reality probes", .serialized)
@MainActor
struct A7Verifier2RealityProbeTests {
    private let catalog = ProductCatalog(subscriptionGroupID: "pro", lifetime: "pro.lifetime", tokenPacks: [TokenPack(productID: "tokens.10", tokens: 10)])
    private let source = PaywallSource(id: "g", fileID: "f", function: "f", line: 1)

    /// One process launch: what `Paywall.shared.configure` does with `welcomeTokens = 100` and `PaywallCloudSync()`.
    private func launch(_ directory: URL, _ cloud: InMemoryCloudDatabase, _ item: A7V2Item, threshold: Int = 4096) async throws -> GateEngine {
        let engine = try GateEngine(
            directory: directory, catalog: catalog,
            settings: GateEngine.Settings(compactionThreshold: threshold, welcomeTokens: 100),
            clock: FakeClock(), store: FakeStore(),
            sync: A7V2Carrier(cloud: cloud, item: item, tokenURL: directory.appendingPathComponent("cloudkit.token")))
        await engine.start()
        await engine.syncNow()
        return engine
    }

    private func settle(_ item: A7V2Item, _ condition: @Sendable (WalletSnapshot?) -> Bool) async {
        for _ in 0..<400 {
            if condition(await item.value) { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    private func token(_ directory: URL) -> String {
        (try? Data(contentsOf: directory.appendingPathComponent("cloudkit.token"))).map { String(decoding: $0, as: UTF8.self) } ?? "nil"
    }

    /// Byte offsets of each frame in `ledger.log`.
    private func frameOffsets(_ bytes: [UInt8]) -> [Int] {
        var offsets: [Int] = []
        var offset = 0
        while offset + 8 <= bytes.count {
            offsets.append(offset)
            let length = Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
            offset += 8 + length
        }
        return offsets
    }

    /// Welcome 100 after the first pull, a purchased 10-pack, a 3-token draw, all uploaded; then an ordinary relaunch
    /// whose first pull moves the change token past that history.
    private func history(_ directory: URL, _ cloud: InMemoryCloudDatabase, _ item: A7V2Item, threshold: Int = 4096, drawFirst: Bool = false) async throws -> (Int, Int) {
        let first = try await launch(directory, cloud, item, threshold: threshold)
        if drawFirst {
            _ = first.run(.tokens(3), source: source) {}
            await first.handle(.tokenPack(id: 3, productID: "tokens.10", purchased: Date()))
        } else {
            await first.handle(.tokenPack(id: 3, productID: "tokens.10", purchased: Date()))
            _ = first.run(.tokens(3), source: source) {}
        }
        await first.syncNow()
        await settle(item) { $0?.balance == 107 }
        let firstBalance = first.wallet.balance
        first.shutdown()
        let second = try await launch(directory, cloud, item, threshold: threshold)
        let secondBalance = second.wallet.balance
        second.shutdown()
        return (firstBalance, secondBalance)
    }

    private func relaunches(_ label: String, _ directory: URL, _ cloud: InMemoryCloudDatabase, _ item: A7V2Item, prefix: String) async throws -> Int {
        let third = try await launch(directory, cloud, item)
        let dropped = third.journal.droppedTailBytes
        let thirdBalance = third.wallet.balance
        let thirdEvents = third.ledger.events.map(\.id)
        await settle(item) { $0?.lastEventID == nil || $0?.balance != 107 }
        third.shutdown()
        let fourth = try await launch(directory, cloud, item)
        let fourthBalance = fourth.wallet.balance
        let fourthEvents = fourth.ledger.events.map(\.id)
        await fourth.syncNow()
        fourth.shutdown()
        let fifth = try await launch(directory, cloud, item)
        let fifthBalance = fifth.wallet.balance
        print("A7V2 \(label): \(prefix) dropped=\(dropped) L3=\(thirdBalance) L3events=\(thirdEvents) L4=\(fourthBalance) L4events=\(fourthEvents) L5=\(fifthBalance) cloud=\(await cloud.count) token=\(token(directory))")
        fifth.shutdown()
        return fifthBalance
    }

    @Test func first_frame_corrupted() async throws {
        let cloud = InMemoryCloudDatabase()
        let item = A7V2Item()
        let directory = makeTemporaryPaywallDirectory()
        let (l1, l2) = try await history(directory, cloud, item)
        let tokenBefore = token(directory)
        let url = directory.appendingPathComponent(Journal.fileName)
        var bytes = [UInt8](try Data(contentsOf: url))
        bytes[12] ^= 0xFF
        try Data(bytes).write(to: url)
        let last = try await relaunches("first-frame", directory, cloud, item, prefix: "L1=\(l1) L2=\(l2) tokenBefore=\(tokenBefore)")
        #expect(last == 107)
    }

    /// Control: the same drop with the token gone too, as a reinstall leaves it.
    @Test func first_frame_corrupted_token_removed() async throws {
        let cloud = InMemoryCloudDatabase()
        let item = A7V2Item()
        let directory = makeTemporaryPaywallDirectory()
        let (l1, l2) = try await history(directory, cloud, item)
        let url = directory.appendingPathComponent(Journal.fileName)
        var bytes = [UInt8](try Data(contentsOf: url))
        bytes[12] ^= 0xFF
        try Data(bytes).write(to: url)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("cloudkit.token"))
        let last = try await relaunches("control-token-removed", directory, cloud, item, prefix: "L1=\(l1) L2=\(l2)")
        #expect(last == 107)
    }

    /// HANDBOOK's own case: a checkpoint written by a newer build's format (a CRC-valid frame this build cannot decode).
    @Test func newer_format_checkpoint() async throws {
        let cloud = InMemoryCloudDatabase()
        let item = A7V2Item()
        let directory = makeTemporaryPaywallDirectory()
        let (l1, l2) = try await history(directory, cloud, item, threshold: 0)
        let url = directory.appendingPathComponent(Journal.fileName)
        let original = [UInt8](try Data(contentsOf: url))
        let checkpointed = try Journal(directory: directory).checkpoint != nil
        let offsets = frameOffsets(original)
        let firstLength = (offsets.count > 1 ? offsets[1] : original.count)
        let payload = [UInt8](#"{"checkpointV2":{"_0":{"format":2}}}"#.utf8)
        var frame: [UInt8] = []
        for shift in stride(from: 0, to: 32, by: 8) { frame.append(UInt8(truncatingIfNeeded: UInt32(payload.count) >> UInt32(shift))) }
        let crc = CRC32.checksum(payload)
        for shift in stride(from: 0, to: 32, by: 8) { frame.append(UInt8(truncatingIfNeeded: crc >> UInt32(shift))) }
        frame += payload
        try Data(frame + original[firstLength...]).write(to: url)
        let last = try await relaunches(
            "newer-format-checkpoint", directory, cloud, item,
            prefix: "L1=\(l1) L2=\(l2) checkpointed=\(checkpointed) frames=\(offsets.count)")
        #expect(last == 107)
    }

    /// Storage corruption in the middle: the valid frames after it go too.
    @Test func middle_frame_corrupted() async throws {
        let cloud = InMemoryCloudDatabase()
        let item = A7V2Item()
        let directory = makeTemporaryPaywallDirectory()
        let (l1, l2) = try await history(directory, cloud, item, drawFirst: true)
        let url = directory.appendingPathComponent(Journal.fileName)
        var bytes = [UInt8](try Data(contentsOf: url))
        let before = try Journal(directory: directory).entries
        let offsets = frameOffsets(bytes)
        // Frame order: welcome, its upload marker, the debit, the credit, their marker.
        let debitFrame = before.firstIndex { if case .event(let e, _) = $0, case .debit = e.kind { return true } else { return false } }!
        bytes[offsets[debitFrame] + 12] ^= 0xFF
        try Data(bytes).write(to: url)
        let last = try await relaunches(
            "middle-frame", directory, cloud, item,
            prefix: "L1=\(l1) L2=\(l2) frames=\(offsets.count) corrupted=\(debitFrame)")
        #expect(last == 107)
    }
}
```

</details>

<details><summary>A8: <code>Tests/PaywallKitTests/Verifier2A8ProbeTests.swift</code></summary>

```swift
#if canImport(AppKit)
    import AppKit
    import Combine
    import Foundation
    @testable import PaywallCore
    import PaywallTesting
    import SwiftUI
    import Testing

    @testable import PaywallKit

    /// Throwaway probe written by verifier 2 for finding A8. Not part of the package.
    @MainActor
    private final class V2A8Recorder {
        var contentAppeared = 0
        var contentDisappeared = 0
        var deniedAppeared = 0
        var deniedDisappeared = 0
        var session: GateSession?
        var summary: String {
            "content(appeared=\(contentAppeared) disappeared=\(contentDisappeared)) denied(appeared=\(deniedAppeared) disappeared=\(deniedDisappeared))"
        }
    }

    /// The gated content: records its appearances and the gate session it finds in the environment.
    private struct V2A8Content: View {
        let recorder: V2A8Recorder
        @Environment(\.paywallGate) private var gate
        var body: some View {
            Text("content")
                .onAppear {
                    recorder.contentAppeared += 1
                    recorder.session = gate
                }
                .onDisappear { recorder.contentDisappeared += 1 }
        }
    }

    private struct V2A8Denied: View {
        let recorder: V2A8Recorder
        var body: some View {
            Text("locked")
                .onAppear { recorder.deniedAppeared += 1 }
                .onDisappear { recorder.deniedDisappeared += 1 }
        }
    }

    @MainActor
    private func v2a8Configuration(store: FakeStore, directory: URL, passthrough: Bool) -> Paywall.Configuration {
        var configuration = Paywall.Configuration(catalog: catalog)
        configuration.passthrough = passthrough
        configuration.store = store
        configuration.clock = FakeClock()
        configuration.storageDirectory = directory
        configuration.includesDefaultAudit = false
        configuration.connectivity = nil
        configuration.welcomeTokens = 0
        return configuration
    }

    /// Builds the view inside the facade override (the modifier captures `Paywall.active` at init, as an app's
    /// modifier captures `Paywall.shared`) and puts it in a real window.
    @MainActor
    private func v2a8Host<V: View>(_ paywall: Paywall, _ build: () -> V) -> NSWindow {
        Paywall.$override.withValue(paywall) {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered,
                defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: build())
            window.orderFront(nil)
            return window
        }
    }

    @MainActor
    private func v2a8Pump(_ window: NSWindow) async {
        for _ in 0..<20 {
            window.contentView?.layoutSubtreeIfNeeded()
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @Suite("Verifier 2 A8 probes", .serialized)
    @MainActor
    struct Verifier2A8ProbeTests {
        /// Control: on one engine, a state change while on screen flips the hosted view (the harness can see flips).
        @Test func control_one_engine_flips_a_denied_view_when_tokens_arrive() async {
            let paywall = Paywall()
            let store = FakeStore(products: products)
            let provider = PaywallServiceProvider(
                .production(v2a8Configuration(store: store, directory: makeTemporaryPaywallDirectory(), passthrough: false)),
                paywall: paywall)
            await paywall.waitUntilStarted()
            let recorder = V2A8Recorder()
            let window = v2a8Host(paywall) {
                V2A8Content(recorder: recorder)
                    .paywallGated(.tokens(1), policy: .deductNow, id: "chart") { _ in V2A8Denied(recorder: recorder) }
                    .paywallProvider(provider)
            }
            defer { window.close() }
            await v2a8Pump(window)
            print("A8V2 CONTROL before-grant \(recorder.summary) balance=\(paywall.wallet.balance) entitlement=\(paywall.entitlement)")
            paywall.grant(tokens: 1, reason: "test")
            await v2a8Pump(window)
            print("A8V2 CONTROL after-grant \(recorder.summary) balance=\(paywall.wallet.balance)")
            #expect(recorder.contentAppeared == 1 && paywall.wallet.balance == 0)
        }

        /// The finding: passthrough on, `.deductNow` token view on screen, then `useProduction` with passthrough off
        /// and an empty wallet.
        @Test func passthrough_to_live_keeps_a_deductNow_view_open_without_a_draw() async {
            let paywall = Paywall()
            let store = FakeStore(products: products)
            let directory = makeTemporaryPaywallDirectory()
            let provider = PaywallServiceProvider(
                .production(v2a8Configuration(store: store, directory: directory, passthrough: true)), paywall: paywall)
            let recorder = V2A8Recorder()
            let window = v2a8Host(paywall) {
                V2A8Content(recorder: recorder)
                    .paywallGated(.tokens(1), policy: .deductNow, id: "chart") { _ in V2A8Denied(recorder: recorder) }
                    .paywallProvider(provider)
            }
            defer { window.close() }
            await v2a8Pump(window)
            print("A8V2 P2L passthrough \(recorder.summary) isPassthrough=\(paywall.isPassthrough)")
            provider.useProduction(v2a8Configuration(store: store, directory: directory, passthrough: false))
            await paywall.waitUntilStarted()
            await v2a8Pump(window)
            await settle()
            await v2a8Pump(window)
            let commit: String
            if let session = recorder.session {
                let outcome = Paywall.$override.withValue(paywall) { session.withPaywall { "value" } }
                commit = outcome.value != nil ? "executed" : "blocked(\(String(describing: outcome.failure?.reason)))"
            } else {
                commit = "no-session"
            }
            print(
                "A8V2 P2L live \(recorder.summary) isPassthrough=\(paywall.isPassthrough) entitlement=\(paywall.entitlement) balance=\(paywall.wallet.balance) engineSessions=\(paywall.engine?.sessions.count ?? -1) canPass=\(paywall.canPass(.tokens(1), id: "chart")) commitInside=\(commit) pendingFailure=\(paywall.pendingFailure?.source.id ?? "nil")"
            )
            #expect(recorder.contentDisappeared == 1, "an empty wallet cannot pay for the view on the live engine")
        }

        /// The staleness ends at the next appearance: with a presence signal, hide and show again after the flip.
        @Test func passthrough_to_live_staleness_ends_at_the_next_appearance() async {
            let paywall = Paywall()
            let store = FakeStore(products: products)
            let directory = makeTemporaryPaywallDirectory()
            let provider = PaywallServiceProvider(
                .production(v2a8Configuration(store: store, directory: directory, passthrough: true)), paywall: paywall)
            let presence = CurrentValueSubject<Bool, Never>(true)
            let recorder = V2A8Recorder()
            let window = v2a8Host(paywall) {
                V2A8Content(recorder: recorder)
                    .paywallGated(.tokens(1), policy: .deductNow, id: "chart", presence: presence.eraseToAnyPublisher()) { _ in
                        V2A8Denied(recorder: recorder)
                    }
                    .paywallProvider(provider)
            }
            defer { window.close() }
            await v2a8Pump(window)
            provider.useProduction(v2a8Configuration(store: store, directory: directory, passthrough: false))
            await paywall.waitUntilStarted()
            await v2a8Pump(window)
            print("A8V2 BOUND after-flip \(recorder.summary)")
            presence.send(false)
            await v2a8Pump(window)
            presence.send(true)
            await v2a8Pump(window)
            print("A8V2 BOUND after-reappear \(recorder.summary) balance=\(paywall.wallet.balance) engineSessions=\(paywall.engine?.sessions.count ?? -1)")
            #expect(recorder.deniedAppeared >= 1)
        }

        /// The other direction: a denied `.paid` view, then the facade is configured so the gate passes.
        @Test func live_to_passthrough_keeps_a_denied_view_denied() async {
            let paywall = Paywall()
            let store = FakeStore(products: products)
            let directory = makeTemporaryPaywallDirectory()
            let provider = PaywallServiceProvider(
                .production(v2a8Configuration(store: store, directory: directory, passthrough: false)), paywall: paywall)
            await paywall.waitUntilStarted()
            let recorder = V2A8Recorder()
            let window = v2a8Host(paywall) {
                V2A8Content(recorder: recorder)
                    .paywallGated(.paid, id: "pro") { _ in V2A8Denied(recorder: recorder) }
                    .paywallProvider(provider)
            }
            defer { window.close() }
            await v2a8Pump(window)
            print("A8V2 L2P live \(recorder.summary)")
            provider.useProduction(v2a8Configuration(store: store, directory: directory, passthrough: true))
            await v2a8Pump(window)
            await settle()
            await v2a8Pump(window)
            print("A8V2 L2P passthrough \(recorder.summary) isPassthrough=\(paywall.isPassthrough) canPass=\(paywall.canPass(.paid, id: "pro"))")
            #expect(recorder.contentAppeared == 1, "every gate passes in passthrough")
        }

        /// The other direction on two engines: a denied `.paid` view, then `use(.fake)` on a store holding a lifetime purchase.
        @Test func live_to_entitled_fake_keeps_a_denied_view_denied() async {
            let paywall = Paywall()
            let provider = PaywallServiceProvider(
                .production(
                    v2a8Configuration(
                        store: FakeStore(products: products), directory: makeTemporaryPaywallDirectory(), passthrough: false)),
                paywall: paywall)
            await paywall.waitUntilStarted()
            let recorder = V2A8Recorder()
            let window = v2a8Host(paywall) {
                V2A8Content(recorder: recorder)
                    .paywallGated(.paid, id: "pro") { _ in V2A8Denied(recorder: recorder) }
                    .paywallProvider(provider)
            }
            defer { window.close() }
            await v2a8Pump(window)
            let old = paywall.engine
            let lifetime = StoreTransaction.lifetime(id: 9, productID: "pro.lifetime", purchased: Date())
            provider.use(
                .fake(
                    v2a8Configuration(
                        store: FakeStore(entitlements: [lifetime], products: products),
                        directory: makeTemporaryPaywallDirectory(), passthrough: false)))
            await paywall.waitUntilStarted()
            await v2a8Pump(window)
            print(
                "A8V2 L2F fake \(recorder.summary) entitlement=\(paywall.entitlement) newEngineSessions=\(paywall.engine?.sessions.count ?? -1) oldEngineSessions=\(old?.sessions.count ?? -1) oldShutDown=\(old?.isShutDown ?? false)"
            )
            #expect(recorder.contentAppeared == 1, "a lifetime purchase opens `.paid`")
        }

        /// A live-to-live reconfigure that does not change the decision still detaches the view: a purchase made on the
        /// new engine afterwards does not open it ("open view gates re-evaluate on their own").
        @Test func live_to_live_reconfigure_then_purchase_leaves_the_view_locked() async throws {
            let paywall = Paywall()
            let store = FakeStore(products: products)
            let directory = makeTemporaryPaywallDirectory()
            let provider = PaywallServiceProvider(
                .production(v2a8Configuration(store: store, directory: directory, passthrough: false)), paywall: paywall)
            await paywall.waitUntilStarted()
            let recorder = V2A8Recorder()
            let window = v2a8Host(paywall) {
                V2A8Content(recorder: recorder)
                    .paywallGated(.paid, id: "pro") { _ in V2A8Denied(recorder: recorder) }
                    .paywallProvider(provider)
            }
            defer { window.close() }
            await v2a8Pump(window)
            var next = v2a8Configuration(store: store, directory: directory, passthrough: false)
            next.tolerance = 600
            provider.useProduction(next)
            await paywall.waitUntilStarted()
            await v2a8Pump(window)
            let outcome = try await paywall.purchase(products[3])
            await settle()
            await v2a8Pump(window)
            print(
                "A8V2 L2L purchase=\(outcome) entitlement=\(paywall.entitlement) \(recorder.summary) engineSessions=\(paywall.engine?.sessions.count ?? -1)"
            )
            #expect(recorder.contentAppeared == 1, "the purchase opens the on-screen `.paid` view")
        }

        /// Control for the test above: without the reconfigure, the same purchase opens the view.
        @Test func control_purchase_without_reconfigure_opens_the_view() async throws {
            let paywall = Paywall()
            let store = FakeStore(products: products)
            let provider = PaywallServiceProvider(
                .production(v2a8Configuration(store: store, directory: makeTemporaryPaywallDirectory(), passthrough: false)),
                paywall: paywall)
            await paywall.waitUntilStarted()
            let recorder = V2A8Recorder()
            let window = v2a8Host(paywall) {
                V2A8Content(recorder: recorder)
                    .paywallGated(.paid, id: "pro") { _ in V2A8Denied(recorder: recorder) }
                    .paywallProvider(provider)
            }
            defer { window.close() }
            await v2a8Pump(window)
            let outcome = try await paywall.purchase(products[3])
            await settle()
            await v2a8Pump(window)
            print("A8V2 CONTROL-PURCHASE purchase=\(outcome) entitlement=\(paywall.entitlement) \(recorder.summary)")
            #expect(recorder.contentAppeared == 1)
        }
    }
#endif
```

</details>

<details><summary>A9: <code>Tests/PaywallCloudSyncTests/Verifier2A9ProbeTests.swift</code></summary>

```swift
import CloudKit
import Foundation
@testable import PaywallCore
import PaywallTesting
import Testing

@testable import PaywallCloudSync

/// Throwaway reproduction for finding A9 (verifier 2). Not part of the package.
///
/// CloudKit as a device without an iCloud account answers it: the private database "still returns a database, but any
/// attempt to use it results in an error". The production `CloudKitDatabase` maps `.notAuthenticated` to `noAccount`.
private struct SignedOutCloudKit: CloudKitOperations {
    func saveZone(_ zone: CKRecordZone) async throws { throw CKError(.notAuthenticated) }
    func saveSubscription(_ subscription: CKSubscription) async throws { throw CKError(.notAuthenticated) }
    func saveRecords(_ records: [CKRecord]) async throws -> [CKRecord.ID: Result<CKRecord, any Error>] { throw CKError(.notAuthenticated) }
    func changes(in zoneID: CKRecordZone.ID, since token: Data?) async throws -> CloudKitZoneChanges { throw CKError(.notAuthenticated) }
}

private let v2Catalog = ProductCatalog(subscriptionGroupID: "pro", lifetime: "pro.lifetime", tokenPacks: [TokenPack(productID: "tokens.10", tokens: 10)])

@Suite("Verifier two A9 probe", .serialized)
@MainActor
struct VerifierTwoA9ProbeTests {
    enum Carrier: String { case signedOut, signedIn, none }

    private func carrier(_ kind: Carrier, _ directory: URL) -> (any LedgerSync)? {
        switch kind {
        case .signedOut:
            return PaywallCloudSync(
                database: CloudKitDatabase(operations: SignedOutCloudKit()), keychain: nil,
                tokenURL: directory.appendingPathComponent("cloudkit.token"))
        case .signedIn:
            return PaywallCloudSync(database: InMemoryCloudDatabase(), keychain: nil, tokenURL: directory.appendingPathComponent("cloudkit.token"))
        case .none:
            return nil
        }
    }

    /// The journal as this device writes it (`.event(_, uploaded: false)`, GateEngine.swift:559), seeded directly like
    /// DrawPerformanceTests. `acknowledged` adds the `.uploaded` markers earlier syncs would have written.
    private func seed(_ directory: URL, events count: Int, acknowledged: Bool) throws {
        let device = "v2-device"
        try Data(device.utf8).write(to: directory.appendingPathComponent("device.id"))
        let journal = try Journal(directory: directory)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var batch: [JournalEntry] = []
        var ids: [String] = []
        func add(_ id: String, _ at: Date, _ source: PaywallSource?, _ kind: LedgerEvent.Kind) {
            batch.append(.event(
                LedgerEvent(id: id, at: at, deviceID: device, accountKey: unboundAccountKey, source: source, previousHash: paywallGenesisHash, kind: kind),
                uploaded: false))
            ids.append(id)
            if acknowledged, ids.count == 50 {
                batch.append(.uploaded(ids))
                ids = []
            }
        }
        add("grant:seed", base, nil, .grant(tokens: 1_000_000, reason: "seed"))
        for i in 1..<count {
            let at = base.addingTimeInterval(Double(i))
            if i % 7 == 0 {
                add("extend:\(i)", at, nil, .leaseExtended(debitID: "debit:\(i - 1)", until: at.addingTimeInterval(300)))
            } else {
                add("debit:\(i)", at, PaywallSource(id: "gate.\(i % 50)", fileID: "perf", function: "t", line: i % 50), .debit(tokens: 1, leaseUntil: at.addingTimeInterval(300)))
            }
            if batch.count >= 5_000 {
                try journal.append(contentsOf: batch)
                batch = []
            }
        }
        if acknowledged, !ids.isEmpty { batch.append(.uploaded(ids)) }
        try journal.append(contentsOf: batch)
    }

    private func open(_ directory: URL, _ kind: Carrier) throws -> (engine: GateEngine, seconds: TimeInterval) {
        let started = ProcessInfo.processInfo.systemUptime
        // GateEngine.Settings() is what the facade builds: compactionThreshold 4096 (Paywall.swift:159-170).
        let engine = try GateEngine(
            directory: directory, catalog: v2Catalog, settings: GateEngine.Settings(), clock: FakeClock(), store: FakeStore(),
            sync: carrier(kind, directory))
        return (engine, ProcessInfo.processInfo.systemUptime - started)
    }

    private func size(_ directory: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(Journal.fileName).path)[.size]) as? Int) ?? -1
    }

    private func measure(events count: Int, _ kind: Carrier) async throws -> String {
        let directory = makeTemporaryPaywallDirectory("v2a9-\(kind.rawValue)-\(count)")
        try seed(directory, events: count, acknowledged: kind == .signedIn)
        let seededBytes = size(directory)
        // Launch 1: full replay at open, then `start()` writes the checkpoint (more than 4096 events at open).
        let (first, fullReplay) = try open(directory, kind)
        await first.start()
        await first.syncNow()
        first.shutdown()
        // Launches 2...6: what every later launch pays at open.
        var opens: [TimeInterval] = []
        var line = ""
        for n in 0..<5 {
            let (engine, seconds) = try open(directory, kind)
            opens.append(seconds)
            if n == 0 {
                let pendingStarted = ProcessInfo.processInfo.systemUptime
                let pending = engine.journal.pendingUpload.count
                let pendingMs = (ProcessInfo.processInfo.systemUptime - pendingStarted) * 1_000
                await engine.start()
                let syncStarted = ProcessInfo.processInfo.systemUptime
                await engine.syncNow()
                let syncMs = (ProcessInfo.processInfo.systemUptime - syncStarted) * 1_000
                line = "entries=\(engine.journal.entries.count) checkpoint=\(engine.journal.checkpoint != nil) ledgerEvents=\(engine.ledger.events.count) pending=\(pending) pendingUploadMs=\(Int(pendingMs)) syncNowMs=\(Int(syncMs)) balance=\(engine.wallet.balance)"
            }
            engine.shutdown()
        }
        let median = opens.sorted()[2]
        return "V2A9 events=\(count) carrier=\(kind.rawValue) seededKB=\(seededBytes / 1024) fullReplayOpenMs=\(Int(fullReplay * 1_000)) | later: openMedianMs=\(Int(median * 1_000)) opensMs=\(opens.map { Int($0 * 1_000) }) logKB=\(size(directory) / 1024) \(line)"
    }

    @Test func v2a9_open_cost_and_log_size_after_the_checkpoint_launch() async throws {
        for count in [4_000, 5_000, 20_000] {
            for kind in [Carrier.none, .signedIn, .signedOut] {
                print(try await measure(events: count, kind))
            }
        }
    }

    /// Interleaved opens of the two 20k-event installs after their checkpoint launch, to damp the machine's load noise.
    @Test func v2a9_interleaved_open_timing_at_20k() async throws {
        var directories: [Carrier: URL] = [:]
        for kind in [Carrier.signedIn, .signedOut] {
            let directory = makeTemporaryPaywallDirectory("v2a9-interleaved-\(kind.rawValue)")
            try seed(directory, events: 20_000, acknowledged: kind == .signedIn)
            let (first, _) = try open(directory, kind)
            await first.start()
            await first.syncNow()
            first.shutdown()
            directories[kind] = directory
        }
        // `.none` here: the same 20k events never checkpointed (opened without `start()`), the full replay.
        let uncheckpointed = makeTemporaryPaywallDirectory("v2a9-interleaved-uncheckpointed")
        try seed(uncheckpointed, events: 20_000, acknowledged: false)
        directories[.none] = uncheckpointed
        var samples: [Carrier: [Int]] = [.signedIn: [], .signedOut: [], .none: []]
        for _ in 0..<9 {
            for kind in [Carrier.signedIn, .signedOut, .none] {
                let (engine, seconds) = try open(directories[kind]!, kind)
                samples[kind]!.append(Int(seconds * 1_000))
                if kind == .none { #expect(engine.journal.checkpoint == nil) }
                engine.shutdown()
            }
        }
        for kind in [Carrier.signedIn, .signedOut, .none] {
            let sorted = samples[kind]!.sorted()
            print("V2A9-INTERLEAVED carrier=\(kind.rawValue) logKB=\(size(directories[kind]!) / 1024) openMs median=\(sorted[4]) min=\(sorted[0]) max=\(sorted[8]) all=\(samples[kind]!)")
        }
    }

    /// The same install signs into iCloud later: does the promise (HANDBOOK:197-200) hold, and when does the log shrink?
    @Test func v2a9_sign_in_later_uploads_and_the_log_stays_until_the_next_compaction() async throws {
        let directory = makeTemporaryPaywallDirectory("v2a9-signin")
        try seed(directory, events: 5_000, acknowledged: false)
        let (first, _) = try open(directory, .signedOut)
        await first.start()
        await first.syncNow()
        let afterCheckpoint = first.journal.entries.count
        first.shutdown()
        let cloud = InMemoryCloudDatabase()
        func signedIn() throws -> GateEngine {
            try GateEngine(
                directory: directory, catalog: v2Catalog, settings: GateEngine.Settings(), clock: FakeClock(), store: FakeStore(),
                sync: PaywallCloudSync(database: cloud, keychain: nil, tokenURL: directory.appendingPathComponent("cloudkit.token")))
        }
        let second = try signedIn()
        await second.start()
        await second.syncNow()
        let uploaded = await cloud.count
        let markers = second.journal.uploadMarkerCount
        second.shutdown()
        let third = try signedIn()
        let (entries, compacted, pending, bytes) = (third.journal.entries.count, third.journal.compactedOnOpen, third.journal.pendingUpload.count, size(directory))
        await third.start()
        third.shutdown()
        let fourth = try signedIn()
        print("V2A9-SIGNIN afterCheckpointEntries=\(afterCheckpoint) uploadedToCloud=\(uploaded) markers=\(markers) | next launch: entries=\(entries) compactedOnOpen=\(compacted) pending=\(pending) logKB=\(bytes / 1024) | launch after: entries=\(fourth.journal.entries.count)")
        fourth.shutdown()
    }
}
```

</details>

<details><summary>B1: <code>Tests/PaywallCoreTests/VerifierB1RealityProbeTests.swift</code></summary>

```swift
import Foundation
import PaywallTesting
import Testing

@testable import PaywallCore

/// Throwaway probe for finding B1 (verifier 2). Not part of the package.
@Suite("Verifier B1 reality probe", .serialized)
@MainActor
struct VerifierB1RealityProbeTests {
    static let window = DateInterval(start: Date(timeIntervalSince1970: 1.6e9), end: Date(timeIntervalSince1970: 1.72e9))
    static let lifetimePolicy = GrandfatheringPolicy(lastPaidBuild: "116", paidWindow: window)
    static let tokenPolicy = GrandfatheringPolicy(lastPaidBuild: "116", paidWindow: window, grant: .tokens(50))
    /// A free-era customer: bought build 200 after the paid window closed.
    static let real = AppTransactionSnapshot(
        bundleID: "com.example.app", originalAppVersion: "200", originalPurchaseDate: Date(timeIntervalSince1970: 1.75e9),
        environment: .production, origin: .appTransaction)

    /// What a person editing the container types: plain JSON, no signature, no signedPayload.
    func plantForgedAppTransaction(_ directory: URL) throws {
        let json = #"{"bundleID":"com.example.app","environment":"production","origin":"receipt","originalAppVersion":"100","originalPurchaseDate":1700000000}"#
        try Data(json.utf8).write(to: directory.appendingPathComponent("app-transaction.json"))
    }

    func grandfatheredEvents(_ h: Harness) -> Int {
        h.events.filter { if case .grandfathered = $0 { return true } else { return false } }.count
    }

    /// The store yields no app transaction on this launch (StoreKit2Client: `AppTransaction.shared` failed and the
    /// receipt is absent or fails verification). The forged file answers.
    @Test func p1_forged_file_answers_when_store_yields_none() async throws {
        let directory = makeTemporaryPaywallDirectory()
        // An honest first launch online: the real snapshot is bound and cached.
        let store = FakeStore(app: Self.real)
        let h = try Harness(directory: directory, store: store, grandfathering: Self.lifetimePolicy)
        await h.start()
        print("PROBE-B1 p1 honest launch -> \(h.engine.entitlement) paid=\(h.engine.canPass(.paid))")
        #expect(h.engine.entitlement == .free)
        // The container is edited, then the app launches with no app transaction available.
        try plantForgedAppTransaction(directory)
        await store.setApp(nil)
        let forged = try await h.relaunch()
        print("PROBE-B1 p1 forged launch, store yields none -> \(forged.entitlement) paid=\(forged.canPass(.paid))")
        #expect(forged.entitlement == .lifetime(.grandfathered(originalAppVersion: "100")))
        // Foreground re-resolution with the store still yielding none: stays.
        await forged.didBecomeActive()
        print("PROBE-B1 p1 foreground, store yields none -> \(forged.entitlement)")
        // The first launch on which the store answers heals it and rewrites the file.
        await store.setApp(Self.real)
        let healed = try await h.relaunch()
        let onDisk = PaywallFiles(directory: directory).appTransaction()
        print("PROBE-B1 p1 store answers -> \(healed.entitlement) file now originalAppVersion=\(onDisk?.originalAppVersion ?? "nil")")
        #expect(healed.entitlement == .free)
        #expect(onDisk?.originalAppVersion == "200")
    }

    /// The stock-iOS shape: the receipt (iOS 15, and the iOS 16+ fallback) or AppTransaction answers at the first
    /// launch after the edit. Nothing is granted, not even for the one launch.
    @Test func p2_forged_file_heals_at_once_when_store_answers() async throws {
        let directory = makeTemporaryPaywallDirectory()
        try plantForgedAppTransaction(directory)
        let h = try Harness(directory: directory, store: FakeStore(app: Self.real), grandfathering: Self.tokenPolicy)
        print("PROBE-B1 p2 at init (before start) paid=\(h.engine.canPass(.paid)) entitlement=\(h.engine.entitlement)")
        await h.start()
        let onDisk = PaywallFiles(directory: directory).appTransaction()
        print("PROBE-B1 p2 after start -> \(h.engine.entitlement) balance=\(h.engine.wallet.balance) grandfatheredEvents=\(grandfatheredEvents(h)) file=\(onDisk?.originalAppVersion ?? "nil")")
        #expect(h.engine.entitlement == .free)
        #expect(h.engine.wallet.balance == 0)
        #expect(onDisk?.originalAppVersion == "200")
    }

    /// `ReceiptError.malformed` thrown from the receipt path, with currentEntitlements answering: same as nil.
    @Test func p3_throwing_app_transaction_is_the_same_as_none() async throws {
        let directory = makeTemporaryPaywallDirectory()
        try plantForgedAppTransaction(directory)
        let fake = FakeStore(app: Self.real)
        let h = try Harness(directory: directory, store: fake, grandfathering: Self.lifetimePolicy)
        h.engine.shutdown()
        let engine = try GateEngine(
            directory: directory, catalog: catalog, grandfathering: Self.lifetimePolicy, settings: h.settings, clock: h.clock,
            store: ThrowingAppTransactionStore(base: fake))
        await engine.start()
        print("PROBE-B1 p3 appTransaction throws -> \(engine.entitlement) paid=\(engine.canPass(.paid))")
        #expect(engine.entitlement == .lifetime(.grandfathered(originalAppVersion: "100")))
    }

    /// Token policy: one forged launch with no store answer mints the grant; the healing launch keeps it.
    @Test func p4_token_grant_is_not_reversed() async throws {
        let directory = makeTemporaryPaywallDirectory()
        let store = FakeStore(app: Self.real)
        let h = try Harness(directory: directory, store: store, grandfathering: Self.tokenPolicy)
        await h.start()
        print("PROBE-B1 p4 honest launch -> \(h.engine.entitlement) balance=\(h.engine.wallet.balance)")
        try plantForgedAppTransaction(directory)
        await store.setApp(nil)
        let forged = try await h.relaunch()
        print("PROBE-B1 p4 forged launch -> \(forged.entitlement) balance=\(forged.wallet.balance)")
        await store.setApp(Self.real)
        let healed = try await h.relaunch()
        print("PROBE-B1 p4 healing launch -> \(healed.entitlement) balance=\(healed.wallet.balance)")
        #expect(healed.wallet.balance == 50)
    }

    /// Control: the same attacker (write access to the container) appends a grant frame to `ledger.log` directly.
    /// CRC-32 framing, no MAC: no app-transaction forgery and no store outage is needed to mint tokens.
    @Test func p5_control_forged_ledger_frame_mints_tokens_directly() async throws {
        let directory = makeTemporaryPaywallDirectory()
        let store = FakeStore(app: Self.real)
        let h = try Harness(directory: directory, store: store, grandfathering: Self.lifetimePolicy)
        await h.start()
        h.engine.shutdown()
        let event = LedgerEvent(
            id: "grant:forged", at: Date(timeIntervalSince1970: 1.8e9), deviceID: "attacker", accountKey: unboundAccountKey,
            source: nil, previousHash: paywallGenesisHash, kind: .grant(tokens: 1000, reason: "forged"))
        let payload = try CanonicalJSON.encoder().encode(JournalEntry.event(event, uploaded: false))
        var frame: [UInt8] = []
        for value in [UInt32(payload.count), CRC32.checksum([UInt8](payload))] {
            for shift in stride(from: 0, to: 32, by: 8) { frame.append(UInt8(truncatingIfNeeded: value >> UInt32(shift))) }
        }
        frame.append(contentsOf: payload)
        let handle = try FileHandle(forWritingTo: directory.appendingPathComponent("ledger.log"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(frame))
        try handle.close()
        let relaunched = try await h.relaunch()
        print("PROBE-B1 p5 forged ledger frame -> \(relaunched.entitlement) balance=\(relaunched.wallet.balance) paid=\(relaunched.canPass(.paid)) tokens(500)=\(relaunched.canPass(.tokens(500))) brokenLink=\(relaunched.ledger.firstBrokenLink()?.id ?? "none")")
        #expect(relaunched.wallet.balance == 1000)
    }

    /// Entitlement variant: the forged snapshot opens `.paid` from init until the launch resolution lands, and the
    /// resolution overwrites it.
    @Test func p6_forged_entitlement_snapshot_lasts_until_first_resolution() async throws {
        let directory = makeTemporaryPaywallDirectory()
        let json = #"{"entitlement":{"lifetime":{"_0":{"purchase":{"transactionID":1}}}},"resolvedAt":1700000000}"#
        try Data(json.utf8).write(to: directory.appendingPathComponent("entitlement.json"))
        let h = try Harness(directory: directory, store: FakeStore(app: Self.real))
        print("PROBE-B1 p6 at init -> \(h.engine.entitlement) paid=\(h.engine.canPass(.paid))")
        await h.start()
        let onDisk = PaywallFiles(directory: directory).entitlementSnapshot(now: h.clock.now)
        print("PROBE-B1 p6 after start -> \(h.engine.entitlement) paid=\(h.engine.canPass(.paid)) file=\(String(describing: onDisk))")
        #expect(h.engine.entitlement == .free)
        #expect(onDisk == .free)
    }
}

/// Delegates to a `FakeStore`, except that `appTransaction()` throws, as `ReceiptClient.snapshot()` does for a
/// malformed receipt while `Transaction.currentEntitlements` still answers.
struct ThrowingAppTransactionStore: StoreClient {
    struct Malformed: Error {}
    let base: FakeStore
    func currentEntitlements() async throws -> [StoreTransaction] { try await base.currentEntitlements() }
    func allTransactions() async throws -> [StoreTransaction] { try await base.allTransactions() }
    func appTransaction() async throws -> AppTransactionSnapshot? { throw Malformed() }
    func updates() async -> AsyncStream<StoreTransaction> { await base.updates() }
    func purchaseIntents() async -> AsyncStream<String> { await base.purchaseIntents() }
    func products(for ids: Set<String>) async throws -> [PaywallProduct] { try await base.products(for: ids) }
    func purchase(productID: String, offer: SignedPromotionalOffer?) async throws -> StorePurchaseResult {
        try await base.purchase(productID: productID, offer: offer)
    }
    func sync() async throws { try await base.sync() }
    func finish(transactionID: UInt64) async { await base.finish(transactionID: transactionID) }
    func subscriptionPhase(groupID: String) async throws -> SubscriptionPhase? { try await base.subscriptionPhase(groupID: groupID) }
    func isEligibleForIntroOffer(groupID: String) async -> Bool { await base.isEligibleForIntroOffer(groupID: groupID) }
    func storefrontCountryCode() async -> String? { await base.storefrontCountryCode() }
}
```

</details>

<details><summary>B5: <code>Workers/PromotionalOfferSigner/test/b5-repro.test.ts</code></summary>

```ts
// B5 reproduction probes (scratch only, not for the repo).
import { describe, expect, it } from "vitest";
import { MAX_BODY_BYTES, handleRequest } from "../src/app";
import { SIGN_URL, signRequest, testEnv, validBody } from "./support";

const base = "https://signer.example";

describe("B5 probes", () => {
  it("P1: one client, 2,000 sign requests in a row: every one is signed, none is refused", async () => {
    const { env } = await testEnv();
    const statuses = new Map<number, number>();
    for (let i = 0; i < 2000; i++) {
      const request = signRequest(validBody, { headers: { "cf-connecting-ip": "203.0.113.7" } });
      const response = await handleRequest(request, env);
      statuses.set(response.status, (statuses.get(response.status) ?? 0) + 1);
    }
    console.log("P1 statuses", JSON.stringify([...statuses]));
    expect(statuses.get(200)).toBe(2000);
    expect(statuses.has(429)).toBe(false);
  });

  it("P2: 404, health and keys paths answer every call too (each is a Worker invocation on Cloudflare)", async () => {
    const { env } = await testEnv();
    const seen: number[] = [];
    for (let i = 0; i < 300; i++) {
      seen.push((await handleRequest(new Request(`${base}/nope/${i}`), env)).status);
      seen.push((await handleRequest(new Request(`${base}/v1/health`), env)).status);
      seen.push((await handleRequest(new Request(`${base}/v1/keys`), env)).status);
    }
    const counts = seen.reduce<Record<number, number>>((acc, s) => ((acc[s] = (acc[s] ?? 0) + 1), acc), {});
    console.log("P2 statuses", JSON.stringify(counts));
    expect(counts[429]).toBeUndefined();
  });

  it("P3: ALLOWED_OFFERS unset (the README recipe): an arbitrary offer id is signed", async () => {
    const { env } = await testEnv();
    const response = await handleRequest(signRequest({ ...validBody, offerId: "deepest-retention-discount" }), env);
    console.log("P3 status", response.status);
    expect(response.status).toBe(200);
  });

  it("P4: a streamed body without content-length is read to the end before the 4 KB check", async () => {
    const { env } = await testEnv();
    const total = 32 * 1024 * 1024; // 32 MiB
    const chunk = new Uint8Array(64 * 1024).fill(0x61);
    let pulled = 0;
    const stream = new ReadableStream<Uint8Array>({
      pull(controller) {
        if (pulled >= total) {
          controller.close();
          return;
        }
        pulled += chunk.byteLength;
        controller.enqueue(chunk);
      },
    });
    const request = new Request(SIGN_URL, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: stream,
      // @ts-expect-error Node's undici needs duplex for a stream body
      duplex: "half",
    });
    console.log("P4 content-length header seen by the worker:", request.headers.get("content-length"));
    const heapBefore = process.memoryUsage().heapUsed;
    const started = performance.now();
    const response = await handleRequest(request, env);
    const ms = performance.now() - started;
    console.log(
      "P4 status",
      response.status,
      "bytes pulled",
      pulled,
      "of",
      total,
      "ms",
      ms.toFixed(1),
      "heap delta MB",
      ((process.memoryUsage().heapUsed - heapBefore) / 1048576).toFixed(1),
    );
    expect(response.status).toBe(413);
    expect(pulled).toBe(total);
  });

  it("P5: text.length counts UTF-16 units: 4,096 two-byte characters (8,192 bytes) pass the size check", async () => {
    const { env } = await testEnv();
    const body = "é".repeat(MAX_BODY_BYTES);
    const bytes = new TextEncoder().encode(body).byteLength;
    const response = await handleRequest(
      new Request(SIGN_URL, { method: "POST", headers: { "content-type": "application/json" }, body }),
      env,
    );
    console.log("P5 bytes", bytes, "status", response.status);
    expect(bytes).toBe(2 * MAX_BODY_BYTES);
    expect(response.status).toBe(400); // past the size check, refused as not JSON
  });
});
```

</details>

<details><summary>B11: <code>Workers/PromotionalOfferSigner/test/b11-regression.test.ts</code></summary>

```ts
// Candidate regression test for B11, to be red at b5c20e4 and green after a fix.
import { afterEach, describe, expect, it, vi } from "vitest";
import { handleRequest } from "../src/app";
import { loadConfig } from "../src/config";
import { testEnv, type EnvOverrides } from "../test/support";

afterEach(() => vi.restoreAllMocks());

const MARK = "zq7MARKERzq7";

/** Every 16-character window of the key's base64 body that is past the fixed P-256 PKCS#8 prefix (key material). */
function keyWindows(pem: string): string[] {
  const body = pem.replace(/-----[A-Z ]+-----/g, "").replace(/\s+/g, "");
  const windows: string[] = [];
  for (let i = 48; i + 16 <= body.length; i += 4) windows.push(body.slice(i, i + 16));
  return windows;
}

describe("misconfiguration messages", () => {
  it("name the secret at fault and carry no part of its value", async () => {
    const { key } = await testEnv();
    const body = key.pem.replace(/-----[A-Z ]+-----/g, "").replace(/\s+/g, "");
    const cases: [EnvOverrides, RegExp, string[]][] = [
      [{ APPLE_IAP_KEY_ID: `K${MARK}` }, /APPLE_IAP_KEY_ID/, [MARK]],
      [{ APPLE_IAP_ISSUER_ID: `I${MARK}` }, /APPLE_IAP_ISSUER_ID/, [MARK]],
      [{ APPLE_BUNDLE_IDS: `com.example.app, com.${MARK}_x` }, /APPLE_BUNDLE_IDS/, [MARK]],
      [{ APPLE_BUNDLE_IDS: `com.${MARK}.app;com.example.app` }, /APPLE_BUNDLE_IDS/, [MARK]],
      [{ ALLOWED_OFFERS: `{"pro ${MARK}": ["comeback"]}` }, /ALLOWED_OFFERS/, [MARK]],
      [{ ALLOWED_OFFERS: `{"pro.${MARK}": ["has space"]}` }, /ALLOWED_OFFERS/, [MARK]],
      [{ APPLE_IAP_PRIVATE_KEY: key.pem.replace(/PRIVATE KEY/g, "EC PRIVATE KEY") }, /SEC1/, keyWindows(key.pem)],
      [{ APPLE_IAP_PRIVATE_KEY: key.pem.replace(body.slice(8, 16), "AAAAAAAA") }, /not an EC P-256 private key/, keyWindows(key.pem)],
    ];
    for (const [overrides, names, forbidden] of cases) {
      const { env } = await testEnv(overrides);
      env.APPLE_IAP_PRIVATE_KEY = overrides.APPLE_IAP_PRIVATE_KEY ?? key.pem;
      const error = await loadConfig(env).then(() => null, (e: unknown) => e as Error);
      expect(error, JSON.stringify(overrides)).not.toBeNull();
      expect(error!.message, JSON.stringify(overrides)).toMatch(names);
      for (const fragment of forbidden) expect(error!.message, JSON.stringify(overrides)).not.toContain(fragment);

      const log = vi.spyOn(console, "error").mockImplementation(() => {});
      const response = await handleRequest(new Request("https://signer.example/v1/keys"), env);
      expect(response.status).toBe(500);
      expect(await response.json()).toEqual({ error: "misconfigured" });
      const written = log.mock.calls.flat().map(String).join("\n");
      for (const fragment of forbidden) expect(written, JSON.stringify(overrides)).not.toContain(fragment);
      log.mockRestore();
    }
  });
});
```

</details>
