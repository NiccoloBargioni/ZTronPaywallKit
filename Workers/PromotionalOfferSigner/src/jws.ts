// Compact JWS plumbing on Web platform APIs only (TextEncoder, btoa/atob), so it runs in Workers, Node and Deno.

const encoder = new TextEncoder();

export function utf8(text: string): Uint8Array {
  return encoder.encode(text);
}

/** RFC 7515 base64url: the standard alphabet with `-` and `_`, no padding. */
export function base64UrlEncode(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function base64UrlDecode(text: string): Uint8Array {
  const padded = text.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (text.length % 4)) % 4);
  return base64Decode(padded);
}

export function base64Decode(text: string): Uint8Array {
  const binary = atob(text);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

export function base64UrlEncodeJSON(value: unknown): string {
  return base64UrlEncode(utf8(JSON.stringify(value)));
}

/** The three segments of a compact JWS, or null when the string is not one. */
export function splitCompactJWS(compactJWS: string): { header: string; payload: string; signature: string } | null {
  const parts = compactJWS.split(".");
  if (parts.length !== 3 || parts.some((part) => part.length === 0)) return null;
  return { header: parts[0], payload: parts[1], signature: parts[2] };
}
