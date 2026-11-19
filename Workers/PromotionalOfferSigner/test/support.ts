import type { Env } from "../src/config";
import { base64UrlDecode, splitCompactJWS, utf8 } from "../src/jws";

export const TEST_KEY_ID = "ABCDE12345";
export const TEST_ISSUER_ID = "57246542-96fe-1a63-e053-0824d011072a";
export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export interface TestKey {
  pem: string;
  publicKey: CryptoKey;
  publicJWK: JsonWebKey;
}

/** A throwaway P-256 key in the shape App Store Connect hands out: a PKCS#8 PEM. */
export async function generateTestKey(): Promise<TestKey> {
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const pkcs8 = new Uint8Array((await crypto.subtle.exportKey("pkcs8", pair.privateKey)) as ArrayBuffer);
  const jwk = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey;
  if (jwk.x === undefined || jwk.y === undefined) throw new Error("generated key has no public point");
  return { pem: toPEM(pkcs8), publicKey: pair.publicKey, publicJWK: { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y } };
}

export function toPEM(der: Uint8Array, label = "PRIVATE KEY"): string {
  let binary = "";
  for (const byte of der) binary += String.fromCharCode(byte);
  const lines = btoa(binary).match(/.{1,64}/g) ?? [];
  return `-----BEGIN ${label}-----\n${lines.join("\n")}\n-----END ${label}-----\n`;
}

export function decodeSegment(segment: string): Record<string, unknown> {
  return JSON.parse(new TextDecoder().decode(base64UrlDecode(segment))) as Record<string, unknown>;
}

export async function verifyCompactJWS(compactJWS: string, publicKey: CryptoKey): Promise<boolean> {
  const parts = splitCompactJWS(compactJWS);
  if (parts === null) return false;
  return crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    publicKey,
    base64UrlDecode(parts.signature),
    utf8(`${parts.header}.${parts.payload}`),
  );
}

export async function importPublicJWK(jwk: JsonWebKey): Promise<CryptoKey> {
  return crypto.subtle.importKey("jwk", jwk, { name: "ECDSA", namedCurve: "P-256" }, true, ["verify"]);
}

/** Secrets (and the optional binding) to replace, or remove with `undefined`. */
export type EnvOverrides = { [K in keyof Env]?: Env[K] | undefined };

/** A complete environment on a fresh throwaway key; `overrides` replace or (with `undefined`) remove secrets. */
export async function testEnv(overrides: EnvOverrides = {}): Promise<{ env: Env; key: TestKey }> {
  const key = await generateTestKey();
  const env: Env = {
    APPLE_IAP_PRIVATE_KEY: key.pem,
    APPLE_IAP_KEY_ID: TEST_KEY_ID,
    APPLE_IAP_ISSUER_ID: TEST_ISSUER_ID,
    APPLE_BUNDLE_IDS: "com.example.app, com.example.app.beta",
  };
  for (const [name, value] of Object.entries(overrides) as [keyof Env, Env[keyof Env] | undefined][]) {
    if (value === undefined) delete env[name];
    else (env as Record<string, unknown>)[name] = value;
  }
  return { env, key };
}

export const SIGN_URL = "https://signer.example/v1/promotional-offers/sign";

export function signRequest(body: unknown, init: { contentType?: string | null; headers?: Record<string, string> } = {}): Request {
  const headers = new Headers(init.headers ?? {});
  if (init.contentType !== null) headers.set("content-type", init.contentType ?? "application/json");
  return new Request(SIGN_URL, {
    method: "POST",
    headers,
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

export const validBody = {
  bundleId: "com.example.app",
  productId: "pro.monthly",
  offerId: "comeback",
  transactionId: "2000000123456789",
};
