// Worker secrets (`wrangler secret put <NAME>`; `.dev.vars` for `wrangler dev`). Nothing about the account or the app
// is in wrangler.jsonc: the key, its id, the issuer id and the bundle ids all arrive as secrets.

import { BUNDLE_ID, OFFER_ID, PRODUCT_ID } from "./validate";
import { importKey } from "./key";
import type { SigningKey } from "./signer";

export interface Env {
  /** The .p8 from App Store Connect, verbatim (`wrangler secret put APPLE_IAP_PRIVATE_KEY < SubscriptionKey_XXXXXXXXXX.p8`). */
  APPLE_IAP_PRIVATE_KEY?: string;
  /** The key's id, 10 characters (the `XXXXXXXXXX` in the file name). */
  APPLE_IAP_KEY_ID?: string;
  /** The issuer id shown above the keys in Users and Access > Integrations > In-App Purchase. */
  APPLE_IAP_ISSUER_ID?: string;
  /** Comma-separated bundle ids this worker signs for. Requests naming another app are refused. */
  APPLE_BUNDLE_IDS?: string;
  /** Optional JSON `{"<productId>": ["<offerId>", ...]}`: only these offers get signed. Unset signs any offer of an allowed app. */
  ALLOWED_OFFERS?: string;
}

/** A JWK with the key id, as a JWKS lists it. */
export type PublicJWK = JsonWebKey & { kid: string };

export interface Config {
  key: SigningKey;
  /** The public point of the key, as `/v1/keys` serves it. */
  publicJWK: PublicJWK;
  bundleIds: ReadonlySet<string>;
  /** Product id to offer ids, or null when any offer is allowed. */
  allowedOffers: ReadonlyMap<string, ReadonlySet<string>> | null;
}

export class ConfigError extends Error {
  override readonly name = "ConfigError";
}

const KEY_ID = /^[A-Z0-9]{10}$/;
const ISSUER_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function required(env: Env, name: keyof Env): string {
  const value = env[name];
  if (typeof value !== "string" || value.trim().length === 0) throw new ConfigError(`${name} is not set`);
  return value;
}

export function parseBundleIds(text: string): ReadonlySet<string> {
  const ids = text
    .split(",")
    .map((id) => id.trim())
    .filter((id) => id.length > 0);
  if (ids.length === 0) throw new ConfigError("APPLE_BUNDLE_IDS names no bundle id");
  for (const id of ids) {
    if (!BUNDLE_ID.test(id)) throw new ConfigError(`APPLE_BUNDLE_IDS: malformed bundle id ${JSON.stringify(id)}`);
  }
  return new Set(ids);
}

export function parseAllowedOffers(text: string | undefined): ReadonlyMap<string, ReadonlySet<string>> | null {
  if (text === undefined || text.trim().length === 0) return null;
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    throw new ConfigError("ALLOWED_OFFERS is not JSON");
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new ConfigError("ALLOWED_OFFERS must be an object of product id to offer ids");
  }
  const map = new Map<string, ReadonlySet<string>>();
  for (const [productId, offers] of Object.entries(parsed as Record<string, unknown>)) {
    if (!PRODUCT_ID.test(productId)) throw new ConfigError(`ALLOWED_OFFERS: malformed product id ${JSON.stringify(productId)}`);
    if (!Array.isArray(offers) || offers.length === 0 || !offers.every((offer) => typeof offer === "string" && OFFER_ID.test(offer))) {
      throw new ConfigError(`ALLOWED_OFFERS: ${productId} must list offer ids`);
    }
    map.set(productId, new Set(offers as string[]));
  }
  if (map.size === 0) throw new ConfigError("ALLOWED_OFFERS is empty; unset it to allow every offer");
  return map;
}

export async function loadConfig(env: Env): Promise<Config> {
  const pem = required(env, "APPLE_IAP_PRIVATE_KEY");
  const keyId = required(env, "APPLE_IAP_KEY_ID").trim();
  if (!KEY_ID.test(keyId)) throw new ConfigError("APPLE_IAP_KEY_ID is not a 10-character App Store Connect key id");
  const issuerId = required(env, "APPLE_IAP_ISSUER_ID").trim();
  if (!ISSUER_ID.test(issuerId)) throw new ConfigError("APPLE_IAP_ISSUER_ID is not a UUID");
  const bundleIds = parseBundleIds(required(env, "APPLE_BUNDLE_IDS"));
  const allowedOffers = parseAllowedOffers(env.ALLOWED_OFFERS);
  const imported = await importKey(pem);
  return {
    key: { keyId, issuerId, signingKey: imported.signingKey },
    publicJWK: { ...imported.publicJWK, kid: keyId, use: "sig", alg: "ES256" } satisfies PublicJWK,
    bundleIds,
    allowedOffers,
  };
}

// One import per isolate: the Workers runtime hands every request the same `env` object, so the key is imported on
// the first request after a cold start and reused until the isolate goes away (a new deploy or new secrets make a
// new isolate). A failure is not cached, so a fixed secret takes effect on the next request.
const configs = new WeakMap<Env, Promise<Config>>();

export function configFor(env: Env): Promise<Config> {
  let pending = configs.get(env);
  if (pending === undefined) {
    pending = loadConfig(env);
    pending.catch(() => configs.delete(env));
    configs.set(env, pending);
  }
  return pending;
}
