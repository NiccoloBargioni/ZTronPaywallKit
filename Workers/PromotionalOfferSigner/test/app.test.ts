import { afterEach, describe, expect, it, vi } from "vitest";
import { MAX_BODY_BYTES, handleRequest } from "../src/app";
import worker from "../src/index";
import { splitCompactJWS } from "../src/jws";
import { SIGN_URL, TEST_ISSUER_ID, TEST_KEY_ID, UUID, decodeSegment, importPublicJWK, signRequest, testEnv, validBody, verifyCompactJWS } from "./support";

const base = "https://signer.example";

afterEach(() => {
  vi.restoreAllMocks();
});

describe("routing", () => {
  it("answers the health check and nothing else on that path", async () => {
    const { env } = await testEnv();
    const ok = await handleRequest(new Request(`${base}/v1/health`), env);
    expect(ok.status).toBe(200);
    expect(ok.headers.get("content-type")).toBe("application/json; charset=utf-8");
    expect(ok.headers.get("cache-control")).toBe("no-store");
    expect(await ok.json()).toEqual({ ok: true });
    const wrong = await handleRequest(new Request(`${base}/v1/health`, { method: "POST" }), env);
    expect(wrong.status).toBe(405);
    expect(wrong.headers.get("allow")).toBe("GET");
    expect(await wrong.json()).toEqual({ error: "method_not_allowed" });
  });

  it("is 404 everywhere else, 405 for a GET of the sign route", async () => {
    const { env } = await testEnv();
    for (const path of ["/", "/v1", "/v1/promotional-offers", "/v2/promotional-offers/sign", "/v1/keys/"]) {
      const response = await handleRequest(new Request(base + path), env);
      expect(response.status, path).toBe(404);
      expect(await response.json()).toEqual({ error: "not_found" });
    }
    const get = await handleRequest(new Request(SIGN_URL), env);
    expect(get.status).toBe(405);
    expect(get.headers.get("allow")).toBe("POST");
    expect((await handleRequest(new Request(`${base}/v1/keys`, { method: "DELETE" }), env)).status).toBe(405);
  });

  it("is what the Workers entry point serves", async () => {
    const { env } = await testEnv();
    const response = await worker.fetch(new Request(`${base}/v1/health`), env);
    expect(await response.json()).toEqual({ ok: true });
  });
});

describe("GET /v1/keys", () => {
  it("publishes the public point of the signing key as a JWKS, never the private scalar", async () => {
    const { env, key } = await testEnv();
    const response = await handleRequest(new Request(`${base}/v1/keys`), env);
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    const body = (await response.json()) as { keys: Record<string, unknown>[] };
    expect(body.keys).toEqual([{ kty: "EC", crv: "P-256", x: key.publicJWK.x, y: key.publicJWK.y, kid: TEST_KEY_ID, use: "sig", alg: "ES256" }]);
    expect(JSON.stringify(body)).not.toContain('"d"');
  });

  it("is 500 misconfigured, with the secret named in the log only, while a secret is missing", async () => {
    const { env } = await testEnv({ APPLE_IAP_ISSUER_ID: undefined });
    const error = vi.spyOn(console, "error").mockImplementation(() => {});
    const response = await handleRequest(new Request(`${base}/v1/keys`), env);
    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({ error: "misconfigured" });
    expect(error).toHaveBeenCalledOnce();
    expect(JSON.parse(error.mock.calls[0][0] as string)).toEqual({ event: "misconfigured", detail: "APPLE_IAP_ISSUER_ID is not set" });
  });
});

describe("POST /v1/promotional-offers/sign", () => {
  it("signs an allowed offer and the result verifies under the published key", async () => {
    const { env } = await testEnv();
    const response = await handleRequest(signRequest(validBody), env, { now: () => 1_763_100_000_500 });
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    const body = (await response.json()) as Record<string, unknown>;
    expect(body).toEqual({
      compactJWS: expect.any(String),
      bundleId: "com.example.app",
      productId: "pro.monthly",
      offerId: "comeback",
      keyId: TEST_KEY_ID,
      nonce: expect.stringMatching(UUID),
      issuedAt: 1_763_100_000,
    });
    const compactJWS = body.compactJWS as string;
    const parts = splitCompactJWS(compactJWS)!;
    expect(decodeSegment(parts.header)).toEqual({ alg: "ES256", kid: TEST_KEY_ID, typ: "JWT" });
    expect(decodeSegment(parts.payload)).toEqual({
      iss: TEST_ISSUER_ID,
      iat: 1_763_100_000,
      aud: "promotional-offer",
      bid: "com.example.app",
      nonce: body.nonce,
      productId: "pro.monthly",
      offerIdentifier: "comeback",
      transactionId: "2000000123456789",
    });
    const jwks = (await (await handleRequest(new Request(`${base}/v1/keys`), env)).json()) as { keys: JsonWebKey[] };
    expect(await verifyCompactJWS(compactJWS, await importPublicJWK(jwks.keys[0]))).toBe(true);
  });

  it("accepts a JSON content type with parameters and a request without transactionId", async () => {
    const { env } = await testEnv();
    const { transactionId: _omitted, ...bare } = validBody;
    const response = await handleRequest(signRequest(bare, { contentType: "application/json; charset=utf-8" }), env);
    expect(response.status).toBe(200);
    const body = (await response.json()) as { compactJWS: string };
    expect(decodeSegment(splitCompactJWS(body.compactJWS)!.payload)).not.toHaveProperty("transactionId");
  });

  it("refuses an app the worker was not configured for", async () => {
    const { env } = await testEnv();
    const response = await handleRequest(signRequest({ ...validBody, bundleId: "com.other.app" }), env);
    expect(response.status).toBe(403);
    expect(await response.json()).toEqual({ error: "bundle_not_allowed" });
    const beta = await handleRequest(signRequest({ ...validBody, bundleId: "com.example.app.beta" }), env);
    expect(beta.status).toBe(200);
  });

  it("refuses offers outside ALLOWED_OFFERS when it is set", async () => {
    const { env } = await testEnv({ ALLOWED_OFFERS: '{"pro.monthly": ["comeback"]}' });
    expect((await handleRequest(signRequest(validBody), env)).status).toBe(200);
    const otherOffer = await handleRequest(signRequest({ ...validBody, offerId: "winter" }), env);
    expect(otherOffer.status).toBe(403);
    expect(await otherOffer.json()).toEqual({ error: "offer_not_allowed" });
    const otherProduct = await handleRequest(signRequest({ ...validBody, productId: "pro.yearly" }), env);
    expect(otherProduct.status).toBe(403);
  });

  it("is 400 with the problems for a malformed body", async () => {
    const { env } = await testEnv();
    const notJSON = await handleRequest(signRequest("{nope"), env);
    expect(notJSON.status).toBe(400);
    expect(await notJSON.json()).toEqual({ error: "invalid_request", detail: ["the body is not JSON"] });
    const missing = await handleRequest(signRequest({ bundleId: "com.example.app", offerId: "x y" }), env);
    expect(missing.status).toBe(400);
    expect(await missing.json()).toEqual({ error: "invalid_request", detail: ["productId is required", "offerId is malformed"] });
    const array = await handleRequest(signRequest([validBody]), env);
    expect(array.status).toBe(400);
  });

  it("insists on a JSON content type", async () => {
    const { env } = await testEnv();
    expect((await handleRequest(signRequest(validBody, { contentType: null }), env)).status).toBe(415);
    const form = await handleRequest(signRequest(validBody, { contentType: "application/x-www-form-urlencoded" }), env);
    expect(form.status).toBe(415);
    expect(await form.json()).toEqual({ error: "unsupported_media_type" });
  });

  it("refuses oversized bodies, declared or actual, counted in bytes, and stops reading past the limit", async () => {
    const { env } = await testEnv();
    const declared = await handleRequest(signRequest(validBody, { headers: { "content-length": String(MAX_BODY_BYTES + 1) } }), env);
    expect(declared.status).toBe(413);
    expect(await declared.json()).toEqual({ error: "payload_too_large" });
    const actual = await handleRequest(signRequest({ ...validBody, padding: "x".repeat(MAX_BODY_BYTES) }), env);
    expect(actual.status).toBe(413);
    // B5: two-byte characters count as bytes, not as UTF-16 code units.
    const twoByte = await handleRequest(signRequest({ ...validBody, padding: "é".repeat(2049) }), env);
    expect(twoByte.status).toBe(413);
    // B5: a streamed body with no content-length is cut off past the limit: at most the limit plus one chunk is read.
    let pulled = 0;
    const chunk = new Uint8Array(1024).fill(0x20);
    const stream = new ReadableStream<Uint8Array>({
      pull(controller) {
        pulled += 1;
        if (pulled > 1024) controller.close();
        else controller.enqueue(chunk);
      },
    });
    const streamed = new Request(SIGN_URL, { method: "POST", headers: { "content-type": "application/json" }, body: stream, duplex: "half" } as RequestInit);
    expect((await handleRequest(streamed, env)).status).toBe(413);
    expect(pulled).toBeLessThanOrEqual(MAX_BODY_BYTES / 1024 + 2);
    // A body that fits still signs.
    expect((await handleRequest(signRequest(validBody), env)).status).toBe(200);
  });

  it("is 400 for a body that is not UTF-8, and for no body at all", async () => {
    const { env } = await testEnv();
    const invalid = new Request(SIGN_URL, { method: "POST", headers: { "content-type": "application/json" }, body: new Uint8Array([0x7b, 0xff, 0x7d]) });
    const response = await handleRequest(invalid, env);
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: "invalid_request", detail: ["the body is not UTF-8"] });
    const empty = await handleRequest(new Request(SIGN_URL, { method: "POST", headers: { "content-type": "application/json" } }), env);
    expect(empty.status).toBe(400);
    expect(await empty.json()).toEqual({ error: "invalid_request", detail: ["the body is not JSON"] });
  });

  it("answers 429 rate_limited per client IP when a RATE_LIMITER is bound, before reading the body", async () => {
    const counts: Record<string, number> = {};
    const limiter = { limit: async ({ key }: { key: string }) => ({ success: (counts[key] = (counts[key] ?? 0) + 1) <= 3 }) };
    const { env } = await testEnv({ RATE_LIMITER: limiter });
    const from = (ip: string, extra: Record<string, string> = {}) => signRequest(validBody, { headers: { "cf-connecting-ip": ip, ...extra } });
    const statuses: number[] = [];
    for (let i = 0; i < 4; i++) statuses.push((await handleRequest(from("203.0.113.7"), env)).status);
    expect(statuses).toEqual([200, 200, 200, 429]);
    const refused = await handleRequest(from("203.0.113.7"), env);
    expect(refused.status).toBe(429);
    expect(await refused.json()).toEqual({ error: "rate_limited" });
    expect(refused.headers.get("retry-after")).toBe("60");
    expect(refused.headers.get("cache-control")).toBe("no-store");
    expect((await handleRequest(from("198.51.100.9"), env)).status).toBe(200);
    expect(counts).toEqual({ "203.0.113.7": 5, "198.51.100.9": 1 });
    // A refused request does not read the body: the stream hands its bytes on the first pull and closes on the second,
    // so a worker that read it to the end pulls twice (the control from another address does), and Node's Request
    // may pre-read one chunk on its own.
    const streamed = (ip: string, counter: { pulled: number }) =>
      new Request(SIGN_URL, {
        method: "POST",
        headers: { "content-type": "application/json", "cf-connecting-ip": ip },
        body: new ReadableStream<Uint8Array>({
          pull(controller) {
            counter.pulled += 1;
            if (counter.pulled === 1) controller.enqueue(new TextEncoder().encode(JSON.stringify(validBody)));
            else controller.close();
          },
        }),
        duplex: "half",
      } as RequestInit);
    const refusedPulls = { pulled: 0 };
    expect((await handleRequest(streamed("203.0.113.7", refusedPulls), env)).status).toBe(429);
    expect(refusedPulls.pulled).toBeLessThanOrEqual(1);
    const controlPulls = { pulled: 0 };
    expect((await handleRequest(streamed("192.0.2.4", controlPulls), env)).status).toBe(200);
    expect(controlPulls.pulled).toBe(2);
    // No client address at all shares one key.
    expect((await handleRequest(signRequest(validBody), env)).status).toBe(200);
    expect(counts.unknown).toBe(1);
  });

  it("signs without a RATE_LIMITER binding, with no limit of its own", async () => {
    const { env } = await testEnv();
    expect(env.RATE_LIMITER).toBeUndefined();
    for (let i = 0; i < 5; i++) expect((await handleRequest(signRequest(validBody), env)).status).toBe(200);
  });

  it("validates the request before touching the configuration, and is 500 misconfigured after", async () => {
    const { env } = await testEnv({ APPLE_IAP_PRIVATE_KEY: undefined });
    const error = vi.spyOn(console, "error").mockImplementation(() => {});
    expect((await handleRequest(signRequest({}), env)).status).toBe(400);
    expect(error).not.toHaveBeenCalled();
    const response = await handleRequest(signRequest(validBody), env);
    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({ error: "misconfigured" });
    expect(error).toHaveBeenCalledOnce();
  });

  it("lets an unexpected error propagate to the runtime instead of masking it as misconfigured", async () => {
    const { env } = await testEnv();
    await expect(handleRequest(signRequest(validBody), env, { nonce: () => { throw new Error("entropy exhausted"); } })).rejects.toThrow(
      "entropy exhausted",
    );
  });
});
