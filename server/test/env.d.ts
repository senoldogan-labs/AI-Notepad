import type { D1Migration } from "cloudflare:test";
import type { Env as AppEnv } from "../src/env";

declare global {
  namespace Cloudflare {
    /** Test Worker'ının bağlamaları: uygulama ortamı + göçler + isteğe bağlı gerçek servis anahtarları. */
    interface Env extends AppEnv {
      /** Present in the development configuration the tests run with (optional only in the production API Worker). */
      readonly ASSISTANT_DB: D1Database;
      readonly ASSISTANT_BUCKET: R2Bucket;
      readonly TEST_MIGRATIONS: D1Migration[];
      readonly TEST_ASSISTANT_MIGRATIONS: D1Migration[];
      /** The MCP Worker's OAuth store (only in the `mcp` test project, see vitest.config.ts). */
      readonly OAUTH_KV: KVNamespace;
      readonly LIVE_TESTS: string;
      readonly LIVE_ANTHROPIC_API_KEY?: string;
      readonly LIVE_STRIPE_SECRET_KEY?: string;
      readonly LIVE_STRIPE_PRICE_ID?: string;
    }
  }
}
