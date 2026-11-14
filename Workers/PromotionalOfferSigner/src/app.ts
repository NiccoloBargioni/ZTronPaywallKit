// The HTTP surface. Pure: a `Request` and an `Env` in, a `Response` out, so it runs unchanged under the Workers
// runtime (src/index.ts) and under vitest in Node.
//
//   GET  /v1/health                        {"ok": true}
//   GET  /v1/keys                          JWKS with the public point of the signing key (to verify what this worker mints)
//   POST /v1/promotional-offers/sign       {"bundleId", "productId", "offerId", "transactionId"?}
//                                          -> {"compactJWS", "bundleId", "productId", "offerId", "keyId", "nonce", "issuedAt"}
//
// Errors are JSON `{"error": <code>, "detail"?: ...}`: 400 invalid_request, 403 bundle_not_allowed / offer_not_allowed,
// 404 not_found, 405 method_not_allowed, 413 payload_too_large, 415 unsupported_media_type, 500 misconfigured.

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

async function sign(request: Request, env: Env, options: SignOptions): Promise<Response> {
  const contentType = request.headers.get("content-type") ?? "";
  if (!/^application\/json\b/i.test(contentType)) return json({ error: "unsupported_media_type" }, 415);
  const declared = Number(request.headers.get("content-length") ?? "0");
  if (declared > MAX_BODY_BYTES) return json({ error: "payload_too_large" }, 413);
  const text = await request.text();
  if (text.length > MAX_BODY_BYTES) return json({ error: "payload_too_large" }, 413);
  let body: unknown;
  try {
    body = JSON.parse(text);
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
