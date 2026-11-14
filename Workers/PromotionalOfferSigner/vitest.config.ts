import { defineConfig } from "vitest/config";

// The worker uses Web platform APIs only (fetch types, WebCrypto, TextEncoder, base64), all of which Node 20+
// provides as globals, so the handler runs under plain vitest with no Workers runtime: `handleRequest` is called
// with a `Request` and an `Env` object exactly as the Workers runtime would call it.
export default defineConfig({
  test: {
    include: ["test/**/*.test.ts"],
  },
});
