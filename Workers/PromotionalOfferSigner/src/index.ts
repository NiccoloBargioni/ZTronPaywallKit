// Cloudflare Workers entry point. Everything else is runtime-neutral (src/app.ts).
import { handleRequest } from "./app";
import type { Env } from "./config";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    return handleRequest(request, env);
  },
} satisfies ExportedHandler<Env>;
