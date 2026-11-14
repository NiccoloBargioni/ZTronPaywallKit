// The App Store Connect In-App Purchase key: a PEM PKCS#8 file (`SubscriptionKey_<KEYID>.p8`) holding an EC P-256
// private key. It is imported into WebCrypto once per isolate and never leaves it: the signing key is not extractable,
// and only the public point (`x`, `y`) is ever exported, for `/v1/keys`.

import { base64Decode } from "./jws";

export class KeyError extends Error {
  override readonly name = "KeyError";
}

/** PKCS#8 DER from the .p8 text, verbatim or with its newlines escaped as `\n` (a secret pasted on one line). */
export function pemToPkcs8(pem: string): Uint8Array {
  const normalized = pem.replace(/\\n/g, "\n").trim();
  if (/-----BEGIN EC PRIVATE KEY-----/.test(normalized)) {
    throw new KeyError(
      "the key is a SEC1 'EC PRIVATE KEY' PEM; use the .p8 from App Store Connect, or convert with `openssl pkcs8 -topk8 -nocrypt`",
    );
  }
  if (/-----BEGIN ENCRYPTED PRIVATE KEY-----/.test(normalized)) {
    throw new KeyError("the key is password-protected; App Store Connect keys are not, use the downloaded .p8");
  }
  const match = /-----BEGIN PRIVATE KEY-----([\s\S]+?)-----END PRIVATE KEY-----/.exec(normalized);
  if (!match) {
    throw new KeyError("expected a PKCS#8 PEM (`-----BEGIN PRIVATE KEY-----`): the contents of the .p8 file");
  }
  const body = match[1].replace(/\s+/g, "");
  if (body.length === 0 || !/^[A-Za-z0-9+/]+=*$/.test(body)) throw new KeyError("the PEM body is not base64");
  return base64Decode(body);
}

export interface ImportedKey {
  /** Non-extractable: signs and nothing else. */
  signingKey: CryptoKey;
  /** The public point, as a JWK without the private scalar. */
  publicJWK: JsonWebKey;
}

export async function importKey(pem: string): Promise<ImportedKey> {
  const der = pemToPkcs8(pem);
  const algorithm = { name: "ECDSA", namedCurve: "P-256" } as const;
  let signingKey: CryptoKey;
  let exportable: CryptoKey;
  try {
    signingKey = await crypto.subtle.importKey("pkcs8", der, algorithm, false, ["sign"]);
    // A second, extractable import exists only to read the public point; it is dropped once that is done.
    exportable = await crypto.subtle.importKey("pkcs8", der, algorithm, true, ["sign"]);
  } catch (error) {
    throw new KeyError(`not an EC P-256 private key: ${error instanceof Error ? error.message : String(error)}`);
  }
  // workers-types declares the union of exportKey's results; "jwk" always yields a JsonWebKey.
  const jwk = (await crypto.subtle.exportKey("jwk", exportable)) as JsonWebKey;
  if (!jwk.x || !jwk.y) throw new KeyError("the key has no public point");
  return { signingKey, publicJWK: { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y } };
}
