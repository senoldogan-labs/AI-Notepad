/**
 * Bindings of the `gistsmith-mcp` Worker (`wrangler.mcp.jsonc`). It never gets the API Worker's secrets: no
 * `ACCESS_TOKEN_SECRET` (app tokens are never accepted here), no payment or AI provider keys.
 */
export interface McpEnv {
  /** Production database, read only: users, sign-in identities and entitlements (`hasSyncAccess`). */
  readonly DB: D1Database;
  /** EU database `gistsmith-assistant` (settings, meeting index, connections; see `migrations-assistant/`). */
  readonly ASSISTANT_DB: D1Database;
  /** EU R2 sync bucket; this Worker reads `a/<user>/<epoch>/<meeting>` objects only. */
  readonly ASSISTANT_BUCKET: R2Bucket;
  /** OAuth grants, tokens and clients (`@cloudflare/workers-oauth-provider`). */
  readonly OAUTH_KV: KVNamespace;
  /** MCP calls: 60 a minute per connection. */
  readonly MCP_GRANT_LIMITER: RateLimit;
  /** Sign-in and consent pages: per IP. */
  readonly MCP_IP_LIMITER: RateLimit;
  /** Reviewer password sign-in: per IP. */
  readonly MCP_REVIEWER_LIMITER: RateLimit;

  readonly ENVIRONMENT: string;
  /** Services ID the site signs in with (must also be in the API Worker's `APPLE_CLIENT_IDS`). */
  readonly APPLE_SIGNIN_CLIENT_ID: string;
  /** Google web client id (must also be in the API Worker's `GOOGLE_CLIENT_IDS`). */
  readonly GOOGLE_SIGNIN_CLIENT_ID: string;
  /** Entitlement settings; must equal the API Worker's values (same names in `wrangler.jsonc`). */
  readonly TRIAL_MEETINGS: string;
  readonly TRIAL_DAYS: string;
  readonly PAST_DUE_GRACE_DAYS: string;
  readonly REVENUECAT_ACCEPT_SANDBOX: string;
  readonly DEVICECHECK_POLICY: string;

  /** Same value as the API Worker's (see `assistant/crypto.ts`). */
  readonly ASSISTANT_DATA_KEY?: string;
  /**
   * Directory reviewer accounts (JSON array of `{email, password, userId}`): reviewers cannot use Apple or Google
   * sign-in with MFA. Unset: no reviewer sign-in.
   */
  readonly REVIEWER_LOGINS?: string;
}
