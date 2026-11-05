import path from "node:path";
import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

/** Sahte test gizli değerleri: gerçek anahtar değildir, yalnızca biçim doğrulamasını geçer. */
const fakeSecrets: Record<string, string> = {
  ACCESS_TOKEN_SECRET: "test-access-token-secret-0123456789abcdef",
  TRIAL_HASH_SECRET: "test-trial-hash-secret-0123456789abcdef00",
  ANTHROPIC_API_KEY: "test-anthropic-key-000000",
  ELEVENLABS_API_KEY: "test-elevenlabs-key-00000",
  STRIPE_SECRET_KEY: "sk_test_fake_0000000000000",
  STRIPE_WEBHOOK_SECRET: "whsec_test_fake_000000000",
  TURNSTILE_SECRET_KEY: "test-turnstile-secret-000",
  REVENUECAT_WEBHOOK_AUTH: "Bearer test-revenuecat-webhook-auth-000",
  REVENUECAT_SECRET_API_KEY: "sk_test_revenuecat_fake_000000",
  // Assistant copy keyring (two fake 32-byte keys; key 2 is current, key 1 exercises rotation).
  ASSISTANT_DATA_KEY: "2:AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI=,1:AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=",
};

/**
 * Gerçek servis testleri yalnızca `AINOTEPAD_SERVER_LIVE_TESTS=1` ve ilgili test anahtarları ortamda varsa açılır;
 * anahtarlar dosyaya yazılmaz, yalnızca test Worker'ına bağlama olarak geçer.
 */
function liveBindings(): Record<string, string> {
  if (process.env["AINOTEPAD_SERVER_LIVE_TESTS"] !== "1") {
    return { LIVE_TESTS: "0" };
  }
  const names: string[] = ["LIVE_ANTHROPIC_API_KEY", "LIVE_STRIPE_SECRET_KEY", "LIVE_STRIPE_PRICE_ID"];
  const bindings: Record<string, string> = { LIVE_TESTS: "1" };
  for (const name of names) {
    const value: string | undefined = process.env[name];
    if (value !== undefined && value.length > 0) {
      bindings[name] = value;
    }
  }
  return bindings;
}

/** Test files of the `gistsmith-mcp` Worker: they run with that Worker's KV namespace and compatibility flags. */
const mcpTestFiles: string[] = ["test/mcp*.test.ts", "test/assistantUnits.test.ts"];

export default defineConfig(async () => {
  const migrations = await readD1Migrations(path.join(import.meta.dirname, "migrations"));
  const assistantMigrations = await readD1Migrations(path.join(import.meta.dirname, "migrations-assistant"));
  const bindings = { ...fakeSecrets, ...liveBindings(), TEST_MIGRATIONS: migrations, TEST_ASSISTANT_MIGRATIONS: assistantMigrations };
  const shared = { setupFiles: ["./test/setup.ts"], testTimeout: 60_000 };
  return {
    test: {
      projects: [
        {
          // The API Worker exactly as wrangler.jsonc configures it: no flags or bindings it does not have in production.
          plugins: [cloudflareTest({ wrangler: { configPath: "./wrangler.jsonc" }, miniflare: { bindings } })],
          test: { ...shared, name: "api", include: ["test/**/*.test.ts"], exclude: mcpTestFiles },
        },
        {
          // The MCP Worker (wrangler.mcp.jsonc) is tested in a runtime with its KV namespace and its two compatibility
          // flags; its tests also drive the API Worker (the apps' side), whose configuration provides the shared bindings.
          plugins: [
            cloudflareTest({
              wrangler: { configPath: "./wrangler.jsonc" },
              miniflare: { bindings, kvNamespaces: ["OAUTH_KV"], compatibilityFlags: ["global_fetch_strictly_public", "nodejs_compat"] },
            }),
          ],
          test: { ...shared, name: "mcp", include: mcpTestFiles },
        },
      ],
    },
  };
});
