import { describe, expect, it, vi } from "vitest";
import { handleRequest } from "../src/app";
import { ConfigError, configFor, loadConfig, parseAllowedOffers, parseBundleIds } from "../src/config";
import { TEST_ISSUER_ID, TEST_KEY_ID, generateTestKey, testEnv, type EnvOverrides } from "./support";

describe("parseBundleIds", () => {
  it("splits on commas and trims", () => {
    expect([...parseBundleIds(" com.example.app ,com.example.app.beta,, ")]).toEqual(["com.example.app", "com.example.app.beta"]);
  });

  it("refuses an empty or malformed list", () => {
    expect(() => parseBundleIds("")).toThrow(ConfigError);
    expect(() => parseBundleIds(" , ")).toThrow(/names no bundle id/);
    // B11: the position, never the value.
    expect(() => parseBundleIds("com.example.app,bad id")).toThrow(/^APPLE_BUNDLE_IDS: malformed bundle id \(entry 2\)$/);
    expect(() => parseBundleIds("com.example.app,,bad id")).toThrow(/\(entry 3\)$/);
    expect(() => parseBundleIds("bad id")).not.toThrow(/bad id/);
  });
});

describe("parseAllowedOffers", () => {
  it("is null when unset, so any offer of an allowed app is signed", () => {
    expect(parseAllowedOffers(undefined)).toBeNull();
    expect(parseAllowedOffers("  ")).toBeNull();
  });

  it("maps product ids to offer ids", () => {
    const map = parseAllowedOffers('{"pro.monthly": ["comeback", "winter"], "pro.yearly": ["comeback"]}');
    expect(map).not.toBeNull();
    expect([...map!.get("pro.monthly")!]).toEqual(["comeback", "winter"]);
    expect(map!.get("pro.weekly")).toBeUndefined();
  });

  it("refuses anything that is not product id to offer ids", () => {
    expect(() => parseAllowedOffers("nope")).toThrow(/not JSON/);
    expect(() => parseAllowedOffers("[]")).toThrow(/object/);
    expect(() => parseAllowedOffers('"x"')).toThrow(/object/);
    expect(() => parseAllowedOffers("{}")).toThrow(/empty/);
    expect(() => parseAllowedOffers('{"pro.monthly": []}')).toThrow(/must list offer ids/);
    expect(() => parseAllowedOffers('{"pro.monthly": "comeback"}')).toThrow(/must list offer ids/);
    expect(() => parseAllowedOffers('{"pro.monthly": ["has space"]}')).toThrow(/must list offer ids/);
    expect(() => parseAllowedOffers('{"bad product": ["comeback"]}')).toThrow(/malformed product id/);
  });
});

describe("loadConfig", () => {
  it("imports the key and reads the identifiers and the allowlists", async () => {
    const { env } = await testEnv({ ALLOWED_OFFERS: '{"pro.monthly": ["comeback"]}' });
    const config = await loadConfig(env);
    expect(config.key.keyId).toBe(TEST_KEY_ID);
    expect(config.key.issuerId).toBe(TEST_ISSUER_ID);
    expect(config.key.signingKey.extractable).toBe(false);
    expect(config.publicJWK).toMatchObject({ kty: "EC", crv: "P-256", kid: TEST_KEY_ID, use: "sig", alg: "ES256" });
    expect(config.publicJWK).not.toHaveProperty("d");
    expect([...config.bundleIds]).toEqual(["com.example.app", "com.example.app.beta"]);
    expect([...config.allowedOffers!.get("pro.monthly")!]).toEqual(["comeback"]);
  });

  /**
   * B11: every message names the secret at fault, and at most the position of the bad entry; no part of the value
   * ever appears, in the rejection or in the line the worker logs. Each case carries a marker, and the key cases are
   * checked against every 16-character window of the key's own base64 body past its fixed 48-character prefix.
   */
  it("names the secret at fault and never any part of its value, in the error and in the log", async () => {
    const m = "zq7MARKERzq7";
    const { key: own } = await testEnv();
    const body = own.pem.replace(/-----[A-Z ]+-----/g, "").replace(/\s+/g, "");
    const windows = Array.from({ length: Math.floor((body.length - 48) / 16) }, (_, i) => body.slice(48 + 16 * i, 64 + 16 * i));
    expect(windows.length).toBeGreaterThan(3);
    const cases: [EnvOverrides, RegExp][] = [
      [{ APPLE_IAP_PRIVATE_KEY: undefined }, /^APPLE_IAP_PRIVATE_KEY is not set$/],
      [{ APPLE_IAP_PRIVATE_KEY: "   " }, /^APPLE_IAP_PRIVATE_KEY is not set$/],
      [{ APPLE_IAP_KEY_ID: undefined }, /^APPLE_IAP_KEY_ID is not set$/],
      [{ APPLE_IAP_KEY_ID: `K${m}` }, /^APPLE_IAP_KEY_ID is not a 10-character/],
      [{ APPLE_IAP_KEY_ID: "abcde12345" }, /^APPLE_IAP_KEY_ID is not a 10-character/],
      [{ APPLE_IAP_ISSUER_ID: undefined }, /^APPLE_IAP_ISSUER_ID is not set$/],
      [{ APPLE_IAP_ISSUER_ID: `I${m}` }, /^APPLE_IAP_ISSUER_ID is not a UUID$/],
      [{ APPLE_BUNDLE_IDS: undefined }, /^APPLE_BUNDLE_IDS is not set$/],
      [{ APPLE_BUNDLE_IDS: `com.example.app, com.${m}_x` }, /^APPLE_BUNDLE_IDS: malformed bundle id \(entry 2\)$/],
      [{ APPLE_BUNDLE_IDS: `com.${m}.app;com.example.app` }, /^APPLE_BUNDLE_IDS: malformed bundle id \(entry 1\)$/],
      [{ APPLE_BUNDLE_IDS: own.pem }, /^APPLE_BUNDLE_IDS: malformed bundle id \(entry 1\)$/],
      [{ ALLOWED_OFFERS: "{" }, /^ALLOWED_OFFERS is not JSON$/],
      [{ ALLOWED_OFFERS: `{"pro ${m}": ["comeback"]}` }, /^ALLOWED_OFFERS: malformed product id$/],
      [{ ALLOWED_OFFERS: `{"pro.${m}": ["has space"]}` }, /^ALLOWED_OFFERS: a product must list offer ids$/],
      [{ APPLE_IAP_PRIVATE_KEY: own.pem.replace(/PRIVATE KEY/g, "EC PRIVATE KEY") }, /SEC1/],
      [{ APPLE_IAP_PRIVATE_KEY: own.pem.replace(body.slice(8, 16), "AAAAAAAA") }, /^not an EC P-256 private key in PKCS#8 form$/],
    ];
    for (const [overrides, message] of cases) {
      const label = JSON.stringify(Object.keys(overrides));
      const { env } = await testEnv(overrides);
      let thrown: unknown;
      try {
        await loadConfig(env);
      } catch (error) {
        thrown = error;
      }
      expect(thrown, label).toBeInstanceOf(Error);
      const text = (thrown as Error).message;
      expect(text, label).toMatch(message);
      expect(text, label).not.toContain(m);
      for (const window of windows) expect(text, label).not.toContain(window);
      // At the sink: the worker logs that message, and nothing of the value, while answering 500 misconfigured.
      const logged = vi.spyOn(console, "error").mockImplementation(() => {});
      const response = await handleRequest(new Request("https://signer.example/v1/keys"), env);
      expect(response.status, label).toBe(500);
      expect(await response.json()).toEqual({ error: "misconfigured" });
      const lines = logged.mock.calls.map((call) => String(call[0])).join("\n");
      expect(lines, label).toContain(JSON.stringify(text));
      expect(lines, label).not.toContain(m);
      for (const window of windows) expect(lines, label).not.toContain(window);
      logged.mockRestore();
    }
  });

  it("accepts the key with its newlines escaped and the issuer id in upper case", async () => {
    const { env, key } = await testEnv({ APPLE_IAP_ISSUER_ID: TEST_ISSUER_ID.toUpperCase() });
    env.APPLE_IAP_PRIVATE_KEY = key.pem.replace(/\n/g, "\\n");
    const config = await loadConfig(env);
    expect(config.key.issuerId).toBe(TEST_ISSUER_ID.toUpperCase());
  });
});

describe("configFor", () => {
  it("loads once per env object and shares the promise", async () => {
    const { env } = await testEnv();
    const first = configFor(env);
    const second = configFor(env);
    expect(second).toBe(first);
    expect((await first).key.keyId).toBe(TEST_KEY_ID);
    const { env: another } = await testEnv();
    expect(configFor(another)).not.toBe(first);
  });

  it("does not remember a failure, so fixed secrets take effect on the next request", async () => {
    const { env, key } = await testEnv({ APPLE_IAP_PRIVATE_KEY: undefined });
    await expect(configFor(env)).rejects.toThrow(ConfigError);
    env.APPLE_IAP_PRIVATE_KEY = key.pem;
    expect((await configFor(env)).key.keyId).toBe(TEST_KEY_ID);
    const fresh = await generateTestKey();
    env.APPLE_IAP_PRIVATE_KEY = fresh.pem;
    // A success is cached for the life of the env object (the isolate): the first key stays in use.
    expect((await configFor(env)).publicJWK.x).toBe(key.publicJWK.x);
  });
});
