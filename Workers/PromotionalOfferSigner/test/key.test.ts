import { describe, expect, it } from "vitest";
import { KeyError, importKey, pemToPkcs8 } from "../src/key";
import { generateTestKey, toPEM } from "./support";

describe("pemToPkcs8", () => {
  it("decodes the .p8 verbatim, with escaped newlines, and with stray whitespace", async () => {
    const { pem } = await generateTestKey();
    const verbatim = pemToPkcs8(pem);
    expect(verbatim.length).toBeGreaterThan(100);
    expect(pemToPkcs8(pem.replace(/\n/g, "\\n"))).toEqual(verbatim);
    expect(pemToPkcs8(`\n\n  ${pem}  \n`)).toEqual(verbatim);
    expect(pemToPkcs8(pem.replace(/\n/g, "\r\n"))).toEqual(verbatim);
  });

  it("names what is wrong with a key that is not a PKCS#8 PEM", () => {
    expect(() => pemToPkcs8(`-----BEGIN EC PRIVATE KEY-----\nAAAA\n-----END EC PRIVATE KEY-----`)).toThrow(/SEC1/);
    expect(() => pemToPkcs8(`-----BEGIN ENCRYPTED PRIVATE KEY-----\nAAAA\n-----END ENCRYPTED PRIVATE KEY-----`)).toThrow(/password/);
    expect(() => pemToPkcs8("MIGHAgEAMBMGByqGSM49")).toThrow(/BEGIN PRIVATE KEY/);
    expect(() => pemToPkcs8(`-----BEGIN PRIVATE KEY-----\n!!!!\n-----END PRIVATE KEY-----`)).toThrow(/base64/);
    expect(() => pemToPkcs8(`-----BEGIN PRIVATE KEY-----\n\n-----END PRIVATE KEY-----`)).toThrow(/base64/);
    expect(() => pemToPkcs8("")).toThrow(KeyError);
  });
});

describe("importKey", () => {
  it("yields a non-extractable signing key and the public point without the private scalar", async () => {
    const { pem, publicJWK } = await generateTestKey();
    const imported = await importKey(pem);
    expect(imported.signingKey.extractable).toBe(false);
    expect(imported.signingKey.usages).toEqual(["sign"]);
    expect(imported.publicJWK).toEqual({ kty: "EC", crv: "P-256", x: publicJWK.x, y: publicJWK.y });
    expect(imported.publicJWK).not.toHaveProperty("d");
  });

  it("refuses a key that is not EC P-256", async () => {
    const rsa = await crypto.subtle.generateKey(
      { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
      true,
      ["sign", "verify"],
    );
    const pem = toPEM(new Uint8Array((await crypto.subtle.exportKey("pkcs8", (rsa as CryptoKeyPair).privateKey)) as ArrayBuffer));
    await expect(importKey(pem)).rejects.toThrow(KeyError);
    await expect(importKey(pem)).rejects.toThrow(/not an EC P-256 private key/);
    await expect(importKey(`-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----`)).rejects.toThrow(KeyError);
  });
});
