// The HTTP surface. Pure: a `Request` and an `Env` in, a `Response` out, so it runs unchanged under the Workers
// runtime (src/index.ts) and under vitest in Node.
//
//   GET  /v1/health                        {"ok": true}
//   GET  /v1/keys                          JWKS with the public point of the signing key (to verify what this worker mints)
//   POST /v1/promotional-offers/sign       {"bundleId", "productId", "offerId", "transactionId"?}
//                                          -> {"compactJWS", "bundleId", "productId", "offerId", "keyId", "nonce", "issuedAt"}
//
// Errors are JSON `{"error": <code>, "detail"?: ...}`: 400 invalid_request, 403 bundle_not_allowed / offer_not_allowed,
// 404 not_found, 405 method_not_allowed, 413 payload_too_large, 415 unsupported_media_type, 429 rate_limited (with a
// retry-after header; only from a worker deployed with a RATE_LIMITER binding, see config.ts), 500 misconfigured.
//
// Volume: without the binding nothing here bounds it; see README.md, "Security model".

import { ConfigError, configFor, type Env } from "./config";
import { KeyError } from "./key";
import { signPromotionalOffer, type SignOptions } from "./signer";
import { validateSigningRequest } from "./validate";

/** The largest body accepted, in bytes; a valid request is well under 1 KB. */
export const MAX_BODY_BYTES = 4096;

export function json(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", ...headers },
  });
}

function methodNotAllowed(allowed: string): Response {
  return json({ error: "method_not_allowed" }, 405, { allow: allowed });
}

export async function handleRequest(request: Request, env: Env, options: SignOptions = {}): Promise<Response> {
  const url = new URL(request.url);
  switch (url.pathname) {
    case "/v1/health":
      return request.method === "GET" ? json({ ok: true }) : methodNotAllowed("GET");
    case "/v1/keys":
      return request.method === "GET" ? withConfig(env, (config) => json({ keys: [config.publicJWK] })) : methodNotAllowed("GET");
    case "/v1/promotional-offers/sign":
      return request.method === "POST" ? sign(request, env, options) : methodNotAllowed("POST");
    default:
      return json({ error: "not_found" }, 404);
  }
}

async function withConfig(env: Env, body: (config: Awaited<ReturnType<typeof configFor>>) => Promise<Response> | Response): Promise<Response> {
  try {
    return await body(await configFor(env));
  } catch (error) {
    if (error instanceof ConfigError || error instanceof KeyError) {
      // The message names the secret at fault, never its value.
      console.error(JSON.stringify({ event: "misconfigured", detail: error.message }));
      return json({ error: "misconfigured" }, 500);
    }
    throw error;
  }
}

/**
 * Reads at most `maxBytes` of the body, counting bytes as they arrive and cancelling the stream past the limit, then
 * decodes it as UTF-8 with a fatal decoder: invalid UTF-8 is a 400, not a replacement character.
 */
export async function readBody(request: Request, maxBytes: number): Promise<{ ok: true; text: string } | { ok: false; status: 400 | 413 }> {
  const reader = request.body?.getReader();
  if (reader === undefined) return { ok: true, text: "" };
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maxBytes) {
      await reader.cancel();
      return { ok: false, status: 413 };
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    return { ok: true, text: new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes) };
  } catch {
    return { ok: false, status: 400 };
  }
}

async function sign(request: Request, env: Env, options: SignOptions): Promise<Response> {
  if (env.RATE_LIMITER !== undefined) {
    // Keyed on the client IP, before a byte of the body is read. Carrier-grade NAT puts many customers behind one
    // address, so the deployed limit should be generous. The binding's periods are 10 or 60 seconds: a minute is
    // always past the window.
    const { success } = await env.RATE_LIMITER.limit({ key: request.headers.get("cf-connecting-ip") ?? "unknown" });
    if (!success) return json({ error: "rate_limited" }, 429, { "retry-after": "60" });
  }
  const contentType = request.headers.get("content-type") ?? "";
  if (!/^application\/json\b/i.test(contentType)) return json({ error: "unsupported_media_type" }, 415);
  const declared = Number(request.headers.get("content-length") ?? "0");
  if (declared > MAX_BODY_BYTES) return json({ error: "payload_too_large" }, 413);
  const read = await readBody(request, MAX_BODY_BYTES);
  if (!read.ok) {
    return read.status === 413
      ? json({ error: "payload_too_large" }, 413)
      : json({ error: "invalid_request", detail: ["the body is not UTF-8"] }, 400);
  }
  let body: unknown;
  try {
    body = JSON.parse(read.text);
  } catch {
    return json({ error: "invalid_request", detail: ["the body is not JSON"] }, 400);
  }
  const validated = validateSigningRequest(body);
  if (!validated.ok) return json({ error: "invalid_request", detail: validated.problems }, 400);
  const offer = validated.value;
  return withConfig(env, async (config) => {
    if (!config.bundleIds.has(offer.bundleId)) return json({ error: "bundle_not_allowed" }, 403);
    if (config.allowedOffers !== null && !config.allowedOffers.get(offer.productId)?.has(offer.offerId)) {
      return json({ error: "offer_not_allowed" }, 403);
    }
    const signature = await signPromotionalOffer(config.key, offer, options);
    return json({
      compactJWS: signature.compactJWS,
      bundleId: offer.bundleId,
      productId: offer.productId,
      offerId: offer.offerId,
      keyId: config.key.keyId,
      nonce: signature.nonce,
      issuedAt: signature.issuedAt,
    });
  });
}
