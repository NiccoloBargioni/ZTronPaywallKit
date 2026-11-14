import { describe, expect, it } from "vitest";
import { validateSigningRequest } from "../src/validate";
import { validBody } from "./support";

describe("validateSigningRequest", () => {
  it("accepts the four fields, with transactionId optional", () => {
    expect(validateSigningRequest(validBody)).toEqual({ ok: true, value: validBody });
    const { transactionId: _omitted, ...bare } = validBody;
    expect(validateSigningRequest(bare)).toEqual({ ok: true, value: bare });
    expect(validateSigningRequest({ ...bare, transactionId: null })).toEqual({ ok: true, value: bare });
  });

  it("lists every problem of a bad body", () => {
    const result = validateSigningRequest({ bundleId: 7, offerId: "has space", transactionId: "abc", extra: 1 });
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.problems).toEqual([
        "bundleId must be a string",
        "productId is required",
        "offerId is malformed",
        "transactionId is malformed",
        "unknown field extra",
      ]);
    }
  });

  it("refuses anything but an object", () => {
    for (const body of [null, undefined, "text", 3, true, [validBody]]) {
      expect(validateSigningRequest(body)).toEqual({ ok: false, problems: ["the body must be a JSON object"] });
    }
  });

  it("bounds every identifier by Apple's rules", () => {
    const bad = (patch: Record<string, unknown>) => validateSigningRequest({ ...validBody, ...patch }).ok;
    expect(bad({ bundleId: "" })).toBe(false);
    expect(bad({ bundleId: ".leading.dot" })).toBe(false);
    expect(bad({ bundleId: "a".repeat(156) })).toBe(false);
    expect(bad({ bundleId: "com.example.app-beta" })).toBe(true);
    expect(bad({ productId: "a".repeat(101) })).toBe(false);
    expect(bad({ productId: "pro_monthly-2.0" })).toBe(true);
    expect(bad({ offerId: "a".repeat(65) })).toBe(false);
    expect(bad({ offerId: "a".repeat(64) })).toBe(true);
    expect(bad({ transactionId: "" })).toBe(false);
    expect(bad({ transactionId: "1".repeat(41) })).toBe(false);
    expect(bad({ transactionId: "1".repeat(40) })).toBe(true);
    expect(bad({ transactionId: "2000000123456789" })).toBe(true);
  });
});
