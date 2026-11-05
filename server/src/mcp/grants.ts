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
 * - the code exchange checks the account again (`userGate`), then records the connection in `assistant_grants` with
 *   one conditional statement that inserts only while the feature is on at the consent's epoch (a turn-off between the
 *   check and the insert can never revive a connection), and replaces the props with `GrantProps` (user id and grant
 *   id only: "grant props in KV hold only the opaque user id");
 * - every refresh checks that the D1 row still exists at the current epoch with the feature on, and that the grant is
 *   younger than `grantMaxAgeMs`; the sliding idle lifetime is `refreshIdleSeconds`, cut so it never passes the maximum
 *   age. A refresh does not run the full `userGate` (account and access): every MCP call does, so a refreshed token of
 *   an account without access still reads nothing.
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

/** A connection to record at the code exchange. */
export interface NewGrant {
  readonly userId: string;
  readonly grantId: string;
  readonly clientId: string;
  readonly clientName: string;
  readonly redirectHost: string;
  readonly verified: boolean;
  /** The settings epoch the user consented under. */
  readonly epoch: number;
  readonly nowMs: number;
}

/**
 * Records a connection in one D1 transaction whose every statement runs only while the feature is on at the consent's
 * epoch: re-authorizing the same app replaces its earlier connection (queued KV revocation, row deleted), then the new
 * row is inserted with `INSERT … SELECT … FROM assistant_settings WHERE enabled = 1 AND epoch = ?`. False when nothing
 * was inserted (turned off, or off and on again, since the consent); then nothing else changed either.
 */
export async function recordGrant(adb: D1Database, grant: NewGrant): Promise<boolean> {
  const live: string = "EXISTS (SELECT 1 FROM assistant_settings WHERE user_id = ?1 AND enabled = 1 AND epoch = ?5)";
  const results: D1Result[] = await adb.batch([
    adb
      .prepare(
        `INSERT INTO assistant_revocations (user_id, grant_id, requested_at)
         SELECT user_id, grant_id, ?4 FROM assistant_grants WHERE user_id = ?1 AND client_id = ?2 AND redirect_host = ?3 AND ${live}
         ON CONFLICT(user_id, grant_id) DO NOTHING`,
      )
      .bind(grant.userId, grant.clientId, grant.redirectHost, grant.nowMs, grant.epoch),
    adb
      .prepare(`DELETE FROM assistant_grants WHERE user_id = ?1 AND client_id = ?2 AND redirect_host = ?3 AND ${live}`)
      .bind(grant.userId, grant.clientId, grant.redirectHost, grant.nowMs, grant.epoch),
    adb
      .prepare(
        `INSERT INTO assistant_grants (user_id, grant_id, client_id, client_name, redirect_host, verified, created_at, epoch)
         SELECT ?1, ?6, ?2, ?7, ?3, ?8, ?4, ?5 FROM assistant_settings WHERE user_id = ?1 AND enabled = 1 AND epoch = ?5`,
      )
      .bind(grant.userId, grant.clientId, grant.redirectHost, grant.nowMs, grant.epoch, grant.grantId, grant.clientName, grant.verified ? 1 : 0),
    adb
      .prepare(
        `INSERT INTO assistant_client_uses (client_id, last_used_at) SELECT ?2, ?4 WHERE ${live}
         ON CONFLICT(client_id) DO UPDATE SET last_used_at = excluded.last_used_at`,
      )
      .bind(grant.userId, grant.clientId, grant.redirectHost, grant.nowMs, grant.epoch),
  ]);
  return (results[2]?.meta.changes ?? 0) > 0;
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
    const recorded: boolean = await recordGrant(env.ASSISTANT_DB, {
      userId: props.userId,
      grantId: options.grantId,
      clientId: options.clientId,
      clientName: props.clientName,
      redirectHost: props.redirectHost,
      verified: props.verified,
      epoch: props.epoch,
      nowMs: now.getTime(),
    });
    if (!recorded) {
      throw invalidGrant("AI assistant access was turned off after you allowed this connection. Connect again.");
    }
    log("info", "assistant_grant_created", { userId: props.userId, grantId: options.grantId, verified: props.verified });
    const grantProps: GrantProps = { userId: props.userId, grantId: options.grantId };
    return { newProps: grantProps };
  }
  if (options.grantType === GrantType.REFRESH_TOKEN) {
    const props: GrantProps = grantPropsSchema.parse(options.props);
    const row: { created_at: number } | null = await env.ASSISTANT_DB.prepare(
      `SELECT g.created_at AS created_at FROM assistant_grants g
       JOIN assistant_settings s ON s.user_id = g.user_id AND s.enabled = 1 AND s.epoch = g.epoch
       WHERE g.user_id = ? AND g.grant_id = ?`,
    )
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

/**
 * Notes that a client completed a consent (`assistant_client_uses`), before the library stores the grant: from then on
 * `deleteUnusedClients` keeps it even while it has no connection row (code not yet exchanged, or disconnected and
 * about to reconnect with the same client id).
 */
export async function markClientUsed(adb: D1Database, clientId: string, now: Date): Promise<void> {
  await adb
    .prepare("INSERT INTO assistant_client_uses (client_id, last_used_at) VALUES (?, ?) ON CONFLICT(client_id) DO UPDATE SET last_used_at = excluded.last_used_at")
    .bind(clientId, now.getTime())
    .run();
}

/**
 * Deletes dynamically registered clients older than a day that never completed a consent and have no connection (spam
 * registrations; at most `maxPages` pages a run). A client that ever connected is left to the library's registration
 * lifetime, which every token exchange renews, so a client with live grants never loses its registration here.
 * Use records older than the longest connection life are pruned first.
 */
export async function deleteUnusedClients(env: McpEnv, oauth: OAuthHelpers, now: Date, pageLimit: number, maxPages: number): Promise<number> {
  await env.ASSISTANT_DB.prepare("DELETE FROM assistant_client_uses WHERE last_used_at < ?").bind(now.getTime() - grantMaxAgeMs).run();
  let deleted: number = 0;
  let cursor: string | undefined;
  for (let page: number = 0; page < maxPages; page += 1) {
    const listed = await oauth.listClients(cursor === undefined ? { limit: pageLimit } : { limit: pageLimit, cursor });
    for (const client of listed.items) {
      if (client.registrationDate === undefined || client.registrationDate * 1000 > now.getTime() - unusedClientMaxAgeMs) {
        continue;
      }
      const used: { found: number } | null = await env.ASSISTANT_DB.prepare(
        "SELECT EXISTS (SELECT 1 FROM assistant_grants WHERE client_id = ?1) OR EXISTS (SELECT 1 FROM assistant_client_uses WHERE client_id = ?1) AS found",
      )
        .bind(client.clientId)
        .first<{ found: number }>();
      if (used === null) {
        throw new Error("EXISTS over assistant_grants returned no row.");
      }
      if (used.found === 0) {
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
