import { describe, expect, it } from "vitest";
import { ConfigError, configFor, loadConfig, parseAllowedOffers, parseBundleIds } from "../src/config";
import { TEST_ISSUER_ID, TEST_KEY_ID, generateTestKey, testEnv, type EnvOverrides } from "./support";

describe("parseBundleIds", () => {
  it("splits on commas and trims", () => {
    expect([...parseBundleIds(" com.example.app ,com.example.app.beta,, ")]).toEqual(["com.example.app", "com.example.app.beta"]);
  });

  it("refuses an empty or malformed list", () => {
    expect(() => parseBundleIds("")).toThrow(ConfigError);
    expect(() => parseBundleIds(" , ")).toThrow(/names no bundle id/);
    expect(() => parseBundleIds("com.example.app,bad id")).toThrow(/malformed bundle id "bad id"/);
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

  it("names the secret at fault, never its value", async () => {
    const cases: [EnvOverrides, RegExp][] = [
      [{ APPLE_IAP_PRIVATE_KEY: undefined }, /APPLE_IAP_PRIVATE_KEY is not set/],
      [{ APPLE_IAP_PRIVATE_KEY: "   " }, /APPLE_IAP_PRIVATE_KEY is not set/],
      [{ APPLE_IAP_KEY_ID: undefined }, /APPLE_IAP_KEY_ID is not set/],
      [{ APPLE_IAP_KEY_ID: "short" }, /APPLE_IAP_KEY_ID is not a 10-character/],
      [{ APPLE_IAP_KEY_ID: "abcde12345" }, /APPLE_IAP_KEY_ID is not a 10-character/],
      [{ APPLE_IAP_ISSUER_ID: undefined }, /APPLE_IAP_ISSUER_ID is not set/],
      [{ APPLE_IAP_ISSUER_ID: "57246542-96fe-1a63e053-0824d011072a" }, /APPLE_IAP_ISSUER_ID is not a UUID/],
      [{ APPLE_BUNDLE_IDS: undefined }, /APPLE_BUNDLE_IDS is not set/],
      [{ APPLE_BUNDLE_IDS: "bad id" }, /malformed bundle id/],
      [{ ALLOWED_OFFERS: "{" }, /ALLOWED_OFFERS is not JSON/],
      [{ APPLE_IAP_PRIVATE_KEY: "-----BEGIN EC PRIVATE KEY-----\nAAAA\n-----END EC PRIVATE KEY-----" }, /SEC1/],
    ];
    for (const [overrides, message] of cases) {
      const { env } = await testEnv(overrides);
      await expect(loadConfig(env), JSON.stringify(overrides)).rejects.toThrow(message);
    }
    const { env, key } = await testEnv();
    const { APPLE_IAP_PRIVATE_KEY: _dropped, ...withoutKey } = env;
    await expect(loadConfig(withoutKey)).rejects.not.toThrow(new RegExp(key.pem.slice(30, 60)));
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
