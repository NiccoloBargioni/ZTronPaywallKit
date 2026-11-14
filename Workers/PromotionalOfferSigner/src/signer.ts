// Apple's JWS for promotional offers ("Generating JWS to sign App Store requests"):
//
//   header   {"alg": "ES256", "kid": <In-App Purchase key id>, "typ": "JWT"}
//   payload  iss  issuer id (App Store Connect, Users and Access > Integrations > In-App Purchase)
//            iat  issued at, UNIX seconds; the App Store derives the expiry from it (no `exp`: it makes the request fail)
//            aud  "promotional-offer"
//            bid  the app's bundle id
//            nonce  a one-time UUID
//            productId, offerIdentifier  the subscription and the offer configured in App Store Connect
//            transactionId  optional, recommended: the customer's `AppTransaction.appTransactionID`
//
// The app passes the compact JWS to `Product.PurchaseOption.promotionalOffer(_:compactJWS:)`. Every signature is
// good for one buy request.

import { base64UrlEncode, base64UrlEncodeJSON, utf8 } from "./jws";

export const PROMOTIONAL_OFFER_AUDIENCE = "promotional-offer";

export interface SigningKey {
  keyId: string;
  issuerId: string;
  signingKey: CryptoKey;
}

export interface PromotionalOfferRequest {
  bundleId: string;
  productId: string;
  offerId: string;
  transactionId?: string;
}

export interface PromotionalOfferSignature {
  compactJWS: string;
  nonce: string;
  /** `iat`, UNIX seconds. */
  issuedAt: number;
}

export interface SignOptions {
  /** Milliseconds since the epoch; `Date.now` by default. */
  now?: () => number;
  /** A fresh UUID per call; `crypto.randomUUID` by default. */
  nonce?: () => string;
}

export interface PromotionalOfferClaims {
  iss: string;
  iat: number;
  aud: typeof PROMOTIONAL_OFFER_AUDIENCE;
  bid: string;
  nonce: string;
  productId: string;
  offerIdentifier: string;
  transactionId?: string;
}

export async function signPromotionalOffer(
  key: SigningKey,
  request: PromotionalOfferRequest,
  options: SignOptions = {},
): Promise<PromotionalOfferSignature> {
  const issuedAt = Math.floor((options.now ?? Date.now)() / 1000);
  const nonce = (options.nonce ?? (() => crypto.randomUUID()))().toLowerCase();
  const header = { alg: "ES256", kid: key.keyId, typ: "JWT" };
  const claims: PromotionalOfferClaims = {
    iss: key.issuerId,
    iat: issuedAt,
    aud: PROMOTIONAL_OFFER_AUDIENCE,
    bid: request.bundleId,
    nonce,
    productId: request.productId,
    offerIdentifier: request.offerId,
  };
  if (request.transactionId !== undefined) claims.transactionId = request.transactionId;
  const signingInput = `${base64UrlEncodeJSON(header)}.${base64UrlEncodeJSON(claims)}`;
  // WebCrypto ECDSA signatures are the raw r || s pair (64 bytes for P-256): exactly what JWS ES256 carries.
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key.signingKey, utf8(signingInput));
  return { compactJWS: `${signingInput}.${base64UrlEncode(new Uint8Array(signature))}`, nonce, issuedAt };
}
