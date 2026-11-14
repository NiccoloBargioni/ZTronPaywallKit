// The request body `POST /v1/promotional-offers/sign` accepts. Strict on purpose: the only client is the app, and a
// malformed field is a bug there, not something to sign.

import type { PromotionalOfferRequest } from "./signer";

/** Bundle ids: alphanumerics, periods and hyphens (Apple), up to 155 characters. */
export const BUNDLE_ID = /^[A-Za-z0-9][A-Za-z0-9.-]{0,154}$/;
/** Product ids: alphanumerics, periods, underscores and hyphens, up to 100 characters. */
export const PRODUCT_ID = /^[A-Za-z0-9._-]{1,100}$/;
/** Promotional offer ids: alphanumerics, periods, underscores and hyphens, up to 64 characters. */
export const OFFER_ID = /^[A-Za-z0-9._-]{1,64}$/;
/** Transaction and app transaction ids are decimal strings. */
export const TRANSACTION_ID = /^[0-9]{1,40}$/;

export type ValidationResult = { ok: true; value: PromotionalOfferRequest } | { ok: false; problems: string[] };

export function validateSigningRequest(body: unknown): ValidationResult {
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    return { ok: false, problems: ["the body must be a JSON object"] };
  }
  const record = body as Record<string, unknown>;
  const problems: string[] = [];
  const field = (name: string, pattern: RegExp, required: boolean): string | undefined => {
    const value = record[name];
    if (value === undefined || value === null) {
      if (required) problems.push(`${name} is required`);
      return undefined;
    }
    if (typeof value !== "string") {
      problems.push(`${name} must be a string`);
      return undefined;
    }
    if (!pattern.test(value)) {
      problems.push(`${name} is malformed`);
      return undefined;
    }
    return value;
  };
  const bundleId = field("bundleId", BUNDLE_ID, true);
  const productId = field("productId", PRODUCT_ID, true);
  const offerId = field("offerId", OFFER_ID, true);
  const transactionId = field("transactionId", TRANSACTION_ID, false);
  const known = new Set(["bundleId", "productId", "offerId", "transactionId"]);
  for (const key of Object.keys(record)) {
    if (!known.has(key)) problems.push(`unknown field ${key}`);
  }
  if (problems.length > 0 || bundleId === undefined || productId === undefined || offerId === undefined) {
    return { ok: false, problems };
  }
  const value: PromotionalOfferRequest = { bundleId, productId, offerId };
  if (transactionId !== undefined) value.transactionId = transactionId;
  return { ok: true, value };
}
