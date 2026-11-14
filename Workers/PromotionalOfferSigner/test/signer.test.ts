import { describe, expect, it } from "vitest";
import { importKey } from "../src/key";
import { splitCompactJWS } from "../src/jws";
import { PROMOTIONAL_OFFER_AUDIENCE, signPromotionalOffer, type SigningKey } from "../src/signer";
import { TEST_ISSUER_ID, TEST_KEY_ID, UUID, decodeSegment, generateTestKey, verifyCompactJWS } from "./support";

async function signingKey(): Promise<{ key: SigningKey; publicKey: CryptoKey }> {
  const test = await generateTestKey();
  const imported = await importKey(test.pem);
  return { key: { keyId: TEST_KEY_ID, issuerId: TEST_ISSUER_ID, signingKey: imported.signingKey }, publicKey: test.publicKey };
}

const request = { bundleId: "com.example.app", productId: "pro.monthly", offerId: "comeback", transactionId: "2000000123456789" };

describe("signPromotionalOffer", () => {
  it("mints Apple's JWS: ES256 header with the key id, the promotional-offer claims, no exp", async () => {
    const { key, publicKey } = await signingKey();
    const now = 1_763_100_000_123;
    const signature = await signPromotionalOffer(key, request, { now: () => now });

    const parts = splitCompactJWS(signature.compactJWS);
    expect(parts).not.toBeNull();
    expect(decodeSegment(parts!.header)).toEqual({ alg: "ES256", kid: TEST_KEY_ID, typ: "JWT" });
    const claims = decodeSegment(parts!.payload);
    expect(claims).toEqual({
      iss: TEST_ISSUER_ID,
      iat: 1_763_100_000,
      aud: PROMOTIONAL_OFFER_AUDIENCE,
      bid: "com.example.app",
      nonce: signature.nonce,
      productId: "pro.monthly",
      offerIdentifier: "comeback",
      transactionId: "2000000123456789",
    });
    expect(claims).not.toHaveProperty("exp");
    expect(signature.issuedAt).toBe(1_763_100_000);
    expect(signature.nonce).toMatch(UUID);
    expect(await verifyCompactJWS(signature.compactJWS, publicKey)).toBe(true);
  });

  it("leaves transactionId out when the request has none", async () => {
    const { key } = await signingKey();
    const { transactionId: _omitted, ...bare } = request;
    const signature = await signPromotionalOffer(key, bare);
    const claims = decodeSegment(splitCompactJWS(signature.compactJWS)!.payload);
    expect(claims).not.toHaveProperty("transactionId");
    expect(Object.keys(claims).sort()).toEqual(["aud", "bid", "iat", "iss", "nonce", "offerIdentifier", "productId"]);
  });

  it("uses a fresh nonce for every signature, so each is good for one buy request", async () => {
    const { key } = await signingKey();
    const first = await signPromotionalOffer(key, request);
    const second = await signPromotionalOffer(key, request);
    expect(first.nonce).not.toBe(second.nonce);
    expect(first.compactJWS).not.toBe(second.compactJWS);
  });

  it("takes an injected clock and nonce, lowercasing the nonce as Apple requires", async () => {
    const { key } = await signingKey();
    const signature = await signPromotionalOffer(key, request, {
      now: () => 1_700_000_000_999,
      nonce: () => "0F6E2B1A-4C3D-4E5F-8A9B-0C1D2E3F4A5B",
    });
    expect(signature.issuedAt).toBe(1_700_000_000);
    expect(signature.nonce).toBe("0f6e2b1a-4c3d-4e5f-8a9b-0c1d2e3f4a5b");
    expect(decodeSegment(splitCompactJWS(signature.compactJWS)!.payload).nonce).toBe(signature.nonce);
  });

  it("does not verify once a claim is altered or under another key", async () => {
    const { key, publicKey } = await signingKey();
    const other = await generateTestKey();
    const signature = await signPromotionalOffer(key, request);
    const parts = splitCompactJWS(signature.compactJWS)!;
    const forgedPayload = parts.payload.slice(0, -2) + (parts.payload.endsWith("A") ? "BB" : "AA");
    expect(await verifyCompactJWS(`${parts.header}.${forgedPayload}.${parts.signature}`, publicKey)).toBe(false);
    expect(await verifyCompactJWS(signature.compactJWS, other.publicKey)).toBe(false);
    expect(await verifyCompactJWS("not.a.jws", publicKey)).toBe(false);
    expect(await verifyCompactJWS("two.parts", publicKey)).toBe(false);
  });
});
