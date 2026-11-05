import {
  GrantType,
  type OAuthHelpers,
  OAuthError,
  type TokenExchangeCallbackOptions,
  type TokenExchangeCallbackResult,
} from "@cloudflare/workers-oauth-provider";
import { z } from "zod";
import { log } from "../log";
import { dayKey } from "../usage";
import type { McpConfig } from "./config";
import type { McpEnv } from "./env";
import { type UserGate, gateMessage, userGate } from "./gate";

/**
 * Connection lifecycle on the OAuth side:
 * - consent stores `ConsentProps` in the grant (`completeAuthorization`);
 * - the code exchange checks the account again, records the connection in `assistant_grants` and replaces the props
 *   with `GrantProps` (user id and grant id only: "grant props in KV hold only the opaque user id");
 * - every refresh checks that the D1 row still exists and that the grant is younger than `grantMaxAgeMs`; the sliding
 *   idle lifetime is `refreshIdleSeconds`, cut so it never passes the maximum age.
 */

/** Access token lifetime. */
export const accessTokenSeconds: number = 3600;
/** Refresh idle lifetime (sliding). */
export const refreshIdleSeconds: number = 30 * 86_400;
/** Maximum age of a connection; consent again afterwards. */
export const grantMaxAgeMs: number = 180 * 86_400_000;
/** Dynamic registrations per IP and hour. */
export const registrationsPerIpPerHour: number = 10;
/** Grantless dynamically registered clients are deleted after this age. */
export const unusedClientMaxAgeMs: number = 86_400_000;

export const consentPropsSchema = z.strictObject({
  userId: z.uuid(),
  epoch: z.number().int().min(1),
  clientName: z.string().min(1).max(120),
  redirectHost: z.string().min(1).max(300),
  verified: z.boolean(),
});
export type ConsentProps = z.output<typeof consentPropsSchema>;

export const grantPropsSchema = z.strictObject({ userId: z.uuid(), grantId: z.string().min(1).max(128) });
export type GrantProps = z.output<typeof grantPropsSchema>;

/** Seconds of idle lifetime to grant at a refresh; null when the connection is too old. Pure function. */
export function refreshLifetimeSeconds(createdAtMs: number, nowMs: number): number | null {
  const remainingSeconds: number = Math.floor((createdAtMs + grantMaxAgeMs - nowMs) / 1000);
  return remainingSeconds < 60 ? null : Math.min(refreshIdleSeconds, remainingSeconds);
}

function invalidGrant(description: string): OAuthError {
  return new OAuthError("invalid_grant", { description });
}

/** The provider's token exchange callback (authorization code and refresh). */
export async function onTokenExchange(
  options: TokenExchangeCallbackOptions<McpEnv>,
  config: McpConfig,
  now: Date,
): Promise<TokenExchangeCallbackResult> {
  const env: McpEnv = options.env;
  if (options.grantType === GrantType.AUTHORIZATION_CODE) {
    const props: ConsentProps = consentPropsSchema.parse(options.props);
    const gate: UserGate = await userGate(env.DB, env.ASSISTANT_DB, config.access, props.userId, now);
    if (gate.kind !== "ready") {
      throw invalidGrant(gateMessage(gate));
    }
    if (gate.epoch !== props.epoch) {
      throw invalidGrant("AI assistant access was turned off after you allowed this connection. Connect again.");
    }
    const nowMs: number = now.getTime();
    // Re-authorizing the same app replaces its earlier connection (the library revokes the old grant in KV).
    await env.ASSISTANT_DB.batch([
      env.ASSISTANT_DB.prepare(
        `INSERT INTO assistant_revocations (user_id, grant_id, requested_at)
         SELECT user_id, grant_id, ?4 FROM assistant_grants WHERE user_id = ?1 AND client_id = ?2 AND redirect_host = ?3
         ON CONFLICT(user_id, grant_id) DO NOTHING`,
      ).bind(props.userId, options.clientId, props.redirectHost, nowMs),
      env.ASSISTANT_DB.prepare("DELETE FROM assistant_grants WHERE user_id = ? AND client_id = ? AND redirect_host = ?").bind(
        props.userId,
        options.clientId,
        props.redirectHost,
      ),
      env.ASSISTANT_DB.prepare(
        `INSERT INTO assistant_grants (user_id, grant_id, client_id, client_name, redirect_host, verified, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)`,
      ).bind(props.userId, options.grantId, options.clientId, props.clientName, props.redirectHost, props.verified ? 1 : 0, nowMs),
    ]);
    log("info", "assistant_grant_created", { userId: props.userId, grantId: options.grantId, verified: props.verified });
    const grantProps: GrantProps = { userId: props.userId, grantId: options.grantId };
    return { newProps: grantProps };
  }
  if (options.grantType === GrantType.REFRESH_TOKEN) {
    const props: GrantProps = grantPropsSchema.parse(options.props);
    const row: { created_at: number } | null = await env.ASSISTANT_DB.prepare("SELECT created_at FROM assistant_grants WHERE user_id = ? AND grant_id = ?")
      .bind(props.userId, props.grantId)
      .first<{ created_at: number }>();
    if (row === null) {
      throw invalidGrant("This connection was removed. Connect Gistsmith again from your assistant.");
    }
    const lifetime: number | null = refreshLifetimeSeconds(row.created_at, now.getTime());
    if (lifetime === null) {
      throw invalidGrant("This connection is 180 days old. Connect Gistsmith again from your assistant.");
    }
    return { refreshTokenIdleTTL: lifetime };
  }
  throw new OAuthError("unsupported_grant_type", { description: "This grant type is not supported." });
}

/** KV revocations queued by the apps' disconnects, turning off and account deletion (MCP Worker cron). */
export async function processRevocations(env: McpEnv, oauth: OAuthHelpers, limit: number): Promise<number> {
  const rows: D1Result<{ user_id: string; grant_id: string }> = await env.ASSISTANT_DB.prepare(
    "SELECT user_id, grant_id FROM assistant_revocations ORDER BY requested_at LIMIT ?",
  )
    .bind(limit)
    .all<{ user_id: string; grant_id: string }>();
  for (const row of rows.results) {
    await oauth.revokeGrant(row.grant_id, row.user_id);
    await env.ASSISTANT_DB.prepare("DELETE FROM assistant_revocations WHERE user_id = ? AND grant_id = ?").bind(row.user_id, row.grant_id).run();
  }
  return rows.results.length;
}

/** Deletes dynamically registered clients older than a day that have no connection (at most `maxPages` pages a run). */
export async function deleteUnusedClients(env: McpEnv, oauth: OAuthHelpers, now: Date, pageLimit: number, maxPages: number): Promise<number> {
  let deleted: number = 0;
  let cursor: string | undefined;
  for (let page: number = 0; page < maxPages; page += 1) {
    const listed = await oauth.listClients(cursor === undefined ? { limit: pageLimit } : { limit: pageLimit, cursor });
    for (const client of listed.items) {
      if (client.registrationDate === undefined || client.registrationDate * 1000 > now.getTime() - unusedClientMaxAgeMs) {
        continue;
      }
      const used: { found: number } | null = await env.ASSISTANT_DB.prepare("SELECT EXISTS (SELECT 1 FROM assistant_grants WHERE client_id = ?) AS found")
        .bind(client.clientId)
        .first<{ found: number }>();
      if (used !== null && used.found === 0) {
        await oauth.deleteClient(client.clientId);
        deleted += 1;
      }
    }
    if (listed.cursor === undefined) {
      break;
    }
    cursor = listed.cursor;
  }
  return deleted;
}

/** Counts a daily ops event (no user ids). */
export async function countAssistantEvent(adb: D1Database, kind: string, now: Date): Promise<void> {
  await adb
    .prepare("INSERT INTO assistant_ops_events (day, kind, count) VALUES (?, ?, 1) ON CONFLICT(day, kind) DO UPDATE SET count = count + 1")
    .bind(dayKey(now), kind)
    .run();
}
