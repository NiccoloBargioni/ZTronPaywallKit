# PromotionalOfferSigner

A Cloudflare Worker that signs App Store **promotional offers** for apps built on ZTronPaywallKit. It holds the
App Store Connect In-App Purchase key as a Worker secret and mints the JWS that
`Product.PurchaseOption.promotionalOffer(_:compactJWS:)` takes, so the key never ships in an app. The package's
`RemotePromotionalOfferSigner` is its client; `Paywall.purchase(_:promotionalOffer:)` calls it.

Everything the worker does is in `src/`, on Web platform APIs only (fetch, WebCrypto): `src/index.ts` is the
Cloudflare entry point, `src/app.ts` the HTTP surface, `src/signer.ts` the JWS, `src/key.ts` the key import.

## What it signs

Apple's "Generating JWS to sign App Store requests" format, with the `promotional-offer` audience:

| | |
|---|---|
| Header | `{"alg": "ES256", "kid": "<key id>", "typ": "JWT"}` |
| `iss` | the issuer id from App Store Connect |
| `iat` | issued at, UNIX seconds; the App Store derives the expiry from it, so there is **no `exp`** (it makes the request fail) |
| `aud` | `promotional-offer` |
| `bid` | the app's bundle id |
| `nonce` | a one-time UUID, new for every signature |
| `productId`, `offerIdentifier` | the subscription and the offer as configured in App Store Connect |
| `transactionId` | optional, recommended: the customer's `AppTransaction.appTransactionID`; the package sends it when the store reports one |

The signature is ECDSA P-256 over SHA-256, the raw `r || s` pair base64url-encoded, as JWS ES256 specifies. Each
signature is good for one buy request; the app asks for a fresh one at every purchase.

## API

```
POST /v1/promotional-offers/sign      Content-Type: application/json
{"bundleId": "com.example.app", "productId": "pro.monthly", "offerId": "comeback", "transactionId": "2000000123456789"}

200 {"compactJWS": "eyJ…", "bundleId": "…", "productId": "…", "offerId": "…", "keyId": "…", "nonce": "…", "issuedAt": 1763100000}
```

| Status | `error` | When |
|---|---|---|
| 400 | `invalid_request` (+ `detail`) | a field is missing, malformed or unknown, or the body is not JSON |
| 403 | `bundle_not_allowed` | `bundleId` is not in `APPLE_BUNDLE_IDS` |
| 403 | `offer_not_allowed` | `ALLOWED_OFFERS` is set and does not list the offer for the product |
| 413 | `payload_too_large` | more than 4 KB, counted in bytes as they arrive (the read stops there) |
| 415 | `unsupported_media_type` | not `application/json` |
| 429 | `rate_limited` (+ `retry-after`) | only from a worker deployed with the optional `RATE_LIMITER` binding (below): this client address hit the limit |
| 500 | `misconfigured` | a secret is missing or malformed; the log names which (and at most the position of the bad entry), never its value |

`GET /v1/keys` serves the public point of the signing key as a JWKS (`kid`, `x`, `y`), so what the worker mints
can be verified without Apple (the package's live test does). `GET /v1/health` answers `{"ok": true}`.

## Secrets

Nothing identifying is in `wrangler.jsonc`; all of it is Worker secrets. From App Store Connect, Users and Access →
Integrations → **In-App Purchase** (the In-App Purchase key, not the App Store Connect API key):

| Secret | Value |
|---|---|
| `APPLE_IAP_PRIVATE_KEY` | the downloaded `SubscriptionKey_<KEYID>.p8`, verbatim (a PKCS#8 PEM) |
| `APPLE_IAP_KEY_ID` | the key's id, 10 characters |
| `APPLE_IAP_ISSUER_ID` | the issuer id shown above the keys (a UUID) |
| `APPLE_BUNDLE_IDS` | comma-separated bundle ids the worker signs for |
| `ALLOWED_OFFERS` | optional, JSON `{"<productId>": ["<offerId>", …]}`: only these get signed |
| `RATE_LIMITER` | optional, not a secret: a Rate Limiting binding declared in `wrangler.jsonc` (see "Security model") |

```bash
npm install
npx wrangler login
npx wrangler secret put APPLE_IAP_PRIVATE_KEY < /path/outside/the/repo/SubscriptionKey_XXXXXXXXXX.p8
npx wrangler secret put APPLE_IAP_KEY_ID        # paste the key id
npx wrangler secret put APPLE_IAP_ISSUER_ID     # paste the issuer id
npx wrangler secret put APPLE_BUNDLE_IDS        # com.example.app,com.example.app.beta
npm run deploy
```

`wrangler deploy` prints the worker's URL; the app's endpoint is `<that URL>/v1/promotional-offers/sign`:

```swift
configuration.promotionalOfferSigner = RemotePromotionalOfferSigner(
    endpoint: URL(string: "https://promotional-offer-signer.<account>.workers.dev/v1/promotional-offers/sign")!)
```

Keep the `.p8` out of the repository (`*.p8` is gitignored at the root and here) and out of the app bundle. The key
is imported into WebCrypto once per isolate as a non-extractable key; only its public point is ever exported.

## Security model

The endpoint is public by design, as the paywall that shows the offers is: anyone can obtain a signature for an
offer of an allowed app, and the App Store still applies its own rules (promotional offers are for existing and
lapsed subscribers, and the signature only ever grants an offer you configured). Who is *shown* an offer stays the
app's decision, as it is without a server. `APPLE_BUNDLE_IDS` bounds the apps, `ALLOWED_OFFERS` the offers (unused
offers, that is: it cannot exclude an offer the app shows, and it does not stop a tampered client). If that decision
has to hold against a tampered client, put App Attest in front of this worker: the package's
`PromotionalOfferSigner` protocol is the seam for a client that attaches an assertion, and `src/app.ts` the place to
check it.

**Volume.** As deployed by the recipe above, nothing bounds the request volume: the worker has no limit of its own
and a `workers.dev` hostname has none in front of it. On Workers Free the 100 000-requests-a-day cap is account-wide,
so a flood stops offer purchases, and this account's other Workers, until 00:00 UTC. For production use Workers
Paid, and put a bound in front:

- The optional `RATE_LIMITER` binding (`ratelimits` in `wrangler.jsonc`, commented out there as an example) makes the
  sign route answer `429 rate_limited` with `retry-after` per client IP, before the body is read. Throttled requests
  still run the Worker and count toward the quota, so this bounds the signing, not the bill.
- A route or custom domain with a WAF rate limiting rule stops excess requests before they reach the Worker. With a
  custom domain set `workers_dev: false` and `preview_urls: false`, or the `workers.dev` hostname bypasses the rule.
  Neither a domain nor an account belongs in this repository, so that configuration stays with the deployment.

## Development

```bash
npm run check        # tsc --noEmit, then vitest
npm run dev          # wrangler dev on http://localhost:8787, with .dev.vars
```

The tests run under plain Node: the worker uses only APIs Node 20+ has as globals, so `handleRequest` is called
with a `Request` and an `Env` exactly as the Workers runtime would call it, on a throwaway key generated per test.
For `npm run dev`, copy `.dev.vars.example` to `.dev.vars` with a throwaway key (never the App Store Connect one):

```bash
openssl ecparam -name prime256v1 -genkey -noout | openssl pkcs8 -topk8 -nocrypt -out dev-key.p8
```

The package's live lanes (`LivePromotionalOfferSignerTests`, and the test host's promotional offer purchase) run
against that local worker; see the root `HANDBOOK.md`, "Live signer lane". The test host buys through StoreKit Testing,
which verifies the signature against the key pair in `Tests/PaywallKitTests/Fixtures/Paywall.storekit`, so for that
lane the `.dev.vars` comes from the fixture: `Scripts/worker-dev-vars.sh > Workers/PromotionalOfferSigner/.dev.vars`
from the repository root.
