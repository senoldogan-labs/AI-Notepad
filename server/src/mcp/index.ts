import {
  type OAuthHelpers,
  OAuthProvider,
  type OAuthProviderOptions,
  type OAuthResourceAuth,
  getOAuthApi,
  insufficientScope,
} from "@cloudflare/workers-oauth-provider";
import { createMcpHandler } from "agents/mcp/server";
import { z } from "zod";
import { clientIpKey } from "../ip";
import { errorName, log } from "../log";
import type { CachedJwks, OutboundPlatform } from "../platform";
import { handleAuthorizePages } from "./authorize";
import { isAllowedRegistrationRedirect, maxRegisteredRedirectUris } from "./clients";
import { type McpConfig, McpConfigError, mcpHostname, mcpOrigin, mcpResource, notesReadScope, parseMcpConfig } from "./config";
import type { McpEnv } from "./env";
import { hmacHex, purposeKey } from "./gate";
import {
  type GrantProps,
  accessTokenSeconds,
  countAssistantEvent,
  deleteUnusedClients,
  grantPropsSchema,
  onTokenExchange,
  processRevocations,
  refreshIdleSeconds,
  registrationsPerIpPerHour,
} from "./grants";
import { buildMcpServer } from "./tools";

/**
 * The `gistsmith-mcp` Worker on mcp.gistsmith.com (design: docs/superpowers/specs/2026-11-05-remote-mcp.md): the
 * OAuth 2.1 authorization server and the MCP resource `https://mcp.gistsmith.com/mcp` in one Worker
 * (`OAuthProvider`). Client ID Metadata Documents are enabled (with `global_fetch_strictly_public`, set for this Worker
 * only), dynamic registration is kept for older clients, PKCE S256 is required, access tokens live 1 hour, refresh
 * 30 days idle and 180 days at most. App tokens of the API Worker are never accepted: the only bearer tokens here are
 * the library's, looked up in `OAUTH_KV`.
 */

const registrationBodyMaxBytes: number = 16 * 1024;
const jwksCache: Map<string, CachedJwks> = new Map();

/** Real outbound fetch and clock; retries are counted in the EU database (no user ids). */
export function productionPlatform(env: McpEnv): OutboundPlatform {
  const now = (): Date => new Date();
  return {
    fetch: (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => fetch(input, init),
    now,
    retryBaseDelayMs: 300,
    jwksCache,
    recordRetry: async (service: string): Promise<void> => {
      try {
        await countAssistantEvent(env.ASSISTANT_DB, `retry:${service}`, now());
      } catch (error: unknown) {
        log("warn", "assistant_retry_count_failed", { service, error: errorName(error) });
      }
    },
  };
}

const resourceAuthSchema = z.object({
  token: z.string(),
  audience: z.string(),
  expiresAt: z.number().optional(),
  scope: z.array(z.string()),
  userId: z.string().optional(),
  clientId: z.string().optional(),
});

/** The verified token the provider puts on the protected handler's context. */
function resourceAuth(ctx: ExecutionContext): OAuthResourceAuth {
  const parsed = resourceAuthSchema.parse(Reflect.get(ctx, "auth"));
  return {
    token: parsed.token,
    audience: parsed.audience,
    scope: parsed.scope,
    ...(parsed.expiresAt === undefined ? {} : { expiresAt: parsed.expiresAt }),
    ...(parsed.userId === undefined ? {} : { userId: parsed.userId }),
    ...(parsed.clientId === undefined ? {} : { clientId: parsed.clientId }),
  };
}

function configResponse(error: McpConfigError): Response {
  log("alert", "mcp_config_invalid", { fields: error.fields.join(",") });
  return new Response("Server configuration is incomplete.", { status: 500, headers: { "content-type": "text/plain; charset=utf-8" } });
}

/** RFC 7591 error response. Pure function. */
function registrationError(status: number, code: string, description: string): Response {
  return Response.json({ error: code, error_description: description }, { status, headers: { "cache-control": "no-store" } });
}

/**
 * Policy for `POST /oauth/register` before the library sees it: 1 to `maxRegisteredRedirectUris` redirect URIs, none
 * of them remote http, and at most `registrationsPerIpPerHour` registrations per IP (HMAC) and hour. Null: allowed.
 */
export async function registrationRefusal(request: Request, env: McpEnv, config: McpConfig, now: Date): Promise<Response | null> {
  const text: string = await request.clone().text();
  if (text.length > registrationBodyMaxBytes) {
    return registrationError(413, "invalid_client_metadata", "The registration is too large.");
  }
  let body: unknown;
  try {
    body = JSON.parse(text);
  } catch (error: unknown) {
    if (error instanceof SyntaxError) {
      return registrationError(400, "invalid_client_metadata", "The registration must be JSON.");
    }
    throw error;
  }
  const uris = z.object({ redirect_uris: z.array(z.string().max(2000)).min(1).max(maxRegisteredRedirectUris) }).safeParse(body);
  if (!uris.success) {
    return registrationError(400, "invalid_redirect_uri", `Register between 1 and ${maxRegisteredRedirectUris} redirect URIs.`);
  }
  if (!uris.data.redirect_uris.every(isAllowedRegistrationRedirect)) {
    return registrationError(400, "invalid_redirect_uri", "Redirect URIs must use https, or http on a loopback address.");
  }
  const ipHash: string = await hmacHex(await purposeKey(config.keyring, "registration-ip"), clientIpKey(request.headers.get("cf-connecting-ip") ?? "local"));
  const hour: number = Math.floor(now.getTime() / 3_600_000);
  const counted: { count: number } | null = await env.ASSISTANT_DB.prepare(
    `INSERT INTO assistant_registrations (ip_hash, hour, count) VALUES (?1, ?2, 1)
     ON CONFLICT(ip_hash, hour) DO UPDATE SET count = count + 1 WHERE count < ?3
     RETURNING count`,
  )
    .bind(ipHash, hour, registrationsPerIpPerHour)
    .first<{ count: number }>();
  if (counted === null) {
    log("warn", "assistant_registration_limited", { hour });
    return registrationError(429, "access_denied", "Too many registrations from this network; try again later.");
  }
  return null;
}

/** The provider's options; `platformOf` gives the clock and outbound fetch (tests replace it). */
export function mcpProviderOptions(platformOf: (env: McpEnv) => OutboundPlatform): OAuthProviderOptions<McpEnv> {
  return {
    apiRoute: "/mcp",
    apiHandler: {
      async fetch(request: Request, env: McpEnv, ctx: ExecutionContext): Promise<Response> {
        const auth: OAuthResourceAuth = resourceAuth(ctx);
        if (!auth.scope.includes(notesReadScope)) {
          return insufficientScope(auth, [notesReadScope]);
        }
        let config: McpConfig;
        try {
          config = parseMcpConfig(env);
        } catch (error: unknown) {
          if (error instanceof McpConfigError) {
            return configResponse(error);
          }
          throw error;
        }
        const props: GrantProps = grantPropsSchema.parse(ctx.props);
        const platform: OutboundPlatform = platformOf(env);
        const hostnames: string[] = config.environment === "development" ? [mcpHostname, "localhost", "127.0.0.1"] : [mcpHostname];
        const handler = createMcpHandler(() => buildMcpServer({ env, config, props, now: platform.now }), {
          route: "/mcp",
          allowedHostnames: hostnames,
          corsOptions: false,
          onerror: (error: Error): void => log("error", "mcp_transport_failed", { error: errorName(error) }),
        });
        return handler.fetch(request);
      },
    },
    defaultHandler: {
      async fetch(request: Request, env: McpEnv): Promise<Response> {
        let config: McpConfig;
        try {
          config = parseMcpConfig(env);
        } catch (error: unknown) {
          if (error instanceof McpConfigError) {
            return configResponse(error);
          }
          throw error;
        }
        const oauth: OAuthHelpers = Reflect.get(env, "OAUTH_PROVIDER");
        return handleAuthorizePages(request, { env, oauth, config, platform: platformOf(env) }, request.headers.get("cf-connecting-ip") ?? "local");
      },
    },
    authorizeEndpoint: "/authorize",
    tokenEndpoint: "/oauth/token",
    clientRegistrationEndpoint: "/oauth/register",
    accessTokenTTL: accessTokenSeconds,
    refreshTokenTTL: refreshIdleSeconds,
    refreshTokenIdleTTL: refreshIdleSeconds,
    clientRegistrationTTL: 90 * 86_400,
    scopesSupported: [notesReadScope],
    requiredScopes: [notesReadScope],
    clientIdMetadataDocumentEnabled: true,
    allowPrivateUseRedirectUris: false,
    allowTokenExchangeGrant: false,
    resourceMetadata: {
      resource: mcpResource,
      authorization_servers: [mcpOrigin],
      resource_name: "Gistsmith",
    },
    tokenExchangeCallback: async (options) => {
      const env: McpEnv = options.env;
      return onTokenExchange(options, parseMcpConfig(env), platformOf(env).now());
    },
    onError: ({ code, status, internal }): void => {
      // Never the description or detail: they can echo client-supplied values.
      log("warn", "mcp_oauth_error", { code, status, category: internal.category, reason: internal.reason });
    },
  };
}

/** The Worker: registration policy in front of the provider, then the provider (OAuth endpoints, /mcp, pages). */
export function createMcpWorker(platformOf: (env: McpEnv) => OutboundPlatform): {
  readonly fetch: (request: Request, env: McpEnv, ctx: ExecutionContext) => Promise<Response>;
  readonly scheduled: (controller: ScheduledController, env: McpEnv) => Promise<void>;
} {
  const options: OAuthProviderOptions<McpEnv> = mcpProviderOptions(platformOf);
  const provider: OAuthProvider<McpEnv> = new OAuthProvider<McpEnv>(options);
  return {
    async fetch(request: Request, env: McpEnv, ctx: ExecutionContext): Promise<Response> {
      const url: URL = new URL(request.url);
      if (url.pathname === "/oauth/register" && request.method === "POST") {
        let config: McpConfig;
        try {
          config = parseMcpConfig(env);
        } catch (error: unknown) {
          if (error instanceof McpConfigError) {
            return configResponse(error);
          }
          throw error;
        }
        const refusal: Response | null = await registrationRefusal(request, env, config, platformOf(env).now());
        if (refusal !== null) {
          return refusal;
        }
      }
      return provider.fetch(request, env, ctx);
    },
    async scheduled(controller: ScheduledController, env: McpEnv): Promise<void> {
      const oauth: OAuthHelpers = getOAuthApi(options, env);
      const now: Date = new Date(controller.scheduledTime);
      const steps: ReadonlyArray<{ name: string; run: () => Promise<unknown> }> = [
        { name: "revocations", run: () => processRevocations(env, oauth, 500) },
        { name: "unused_clients", run: () => deleteUnusedClients(env, oauth, now, 100, 10) },
        { name: "kv_purge", run: () => oauth.purgeExpiredData({ batchSize: 100 }) },
      ];
      const failures: unknown[] = [];
      for (const step of steps) {
        try {
          const result: unknown = await step.run();
          log("info", "mcp_scheduled_step_done", { step: step.name, count: typeof result === "number" ? result : null });
        } catch (error: unknown) {
          log("alert", "mcp_scheduled_step_failed", { step: step.name, error: errorName(error) });
          failures.push(error);
        }
      }
      if (failures.length > 0) {
        throw new AggregateError(failures, `${failures.length} MCP cleanup steps failed.`);
      }
    },
  };
}

const worker = createMcpWorker(productionPlatform);

export default {
  fetch: (request: Request, env: McpEnv, ctx: ExecutionContext): Promise<Response> => worker.fetch(request, env, ctx),
  scheduled: (controller: ScheduledController, env: McpEnv): Promise<void> => worker.scheduled(controller, env),
} satisfies ExportedHandler<McpEnv>;
