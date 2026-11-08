import { log } from "../log";
import type { AccessConfig } from "../entitlements";
import { hasSyncAccess } from "../sync";
import { type AssistantPurgeResult, deleteAssistantAccount, disableAssistantAfterAccessLoss, purgeAssistantPrefix } from "./store";

/**
 * Daily cleanup of the AI assistant copy (API Worker cron, `index.ts`):
 * - accounts are checked in rotation (`access_checked_at`): an account that no longer exists in the production database
 *   loses its whole copy; an enabled account without a subscription or running trial is marked, and its copy is
 *   deleted `accessLossDeleteDays` after the mark (the MCP Worker already refuses its calls at once, every call checks
 *   access), so the copy is gone within 7 days of access ending;
 * - queued R2 prefixes (`assistant_purges`) are deleted;
 * - expired sign-in nonces and old registration counters are removed.
 */

/** Days between noticing that access ended and deleting the copy (the check runs daily: deleted within 7 days). */
export const accessLossDeleteDays: number = 6;
const dayMs: number = 86_400_000;

/** Accounts checked and prefixes purged per run. */
export interface AssistantCleanupLimits {
  readonly accounts: number;
  readonly prefixes: number;
  readonly pagesPerPrefix: number;
}

export const scheduledAssistantCleanupLimits: AssistantCleanupLimits = { accounts: 500, prefixes: 20, pagesPerPrefix: 5 };

/** Cleanup report (counts only). */
export interface AssistantCleanupReport {
  readonly [step: string]: number;
  readonly checked: number;
  readonly orphansDeleted: number;
  readonly accessLostMarked: number;
  readonly copiesDeleted: number;
  readonly purgedPrefixes: number;
  readonly purgedObjects: number;
}

interface CheckedRow {
  readonly user_id: string;
  readonly enabled: number;
  readonly epoch: number;
  readonly access_lost_at: number | null;
}

export async function assistantCleanup(
  adb: D1Database,
  db: D1Database,
  bucket: R2Bucket,
  config: AccessConfig,
  now: Date,
  limits: AssistantCleanupLimits,
): Promise<AssistantCleanupReport> {
  const nowMs: number = now.getTime();
  const rows: D1Result<CheckedRow> = await adb
    .prepare("SELECT user_id, enabled, epoch, access_lost_at FROM assistant_settings ORDER BY access_checked_at LIMIT ?")
    .bind(limits.accounts)
    .all<CheckedRow>();
  let orphansDeleted: number = 0;
  let accessLostMarked: number = 0;
  let copiesDeleted: number = 0;
  for (const row of rows.results) {
    const exists: { found: number } | null = await db.prepare("SELECT EXISTS (SELECT 1 FROM users WHERE id = ?) AS found").bind(row.user_id).first<{ found: number }>();
    if (exists === null || exists.found === 0) {
      await deleteAssistantAccount(adb, bucket, row.user_id, now);
      orphansDeleted += 1;
      continue;
    }
    if (row.enabled === 1 && !(await hasSyncAccess(db, config, row.user_id, now))) {
      if (row.access_lost_at === null) {
        // Marked only while still on at the epoch read (a turn-off in between leaves no mark on a disabled row).
        const marked: D1Result = await adb
          .prepare("UPDATE assistant_settings SET access_lost_at = ?2, access_checked_at = ?2 WHERE user_id = ?1 AND enabled = 1 AND epoch = ?3 AND access_lost_at IS NULL")
          .bind(row.user_id, nowMs, row.epoch)
          .run();
        accessLostMarked += marked.meta.changes;
        continue;
      }
      if (row.access_lost_at <= nowMs - accessLossDeleteDays * dayMs && (await disableAssistantAfterAccessLoss(adb, bucket, row.user_id, row.epoch, row.access_lost_at, now))) {
        log("info", "assistant_access_ended_deleted", { userId: row.user_id });
        copiesDeleted += 1;
      }
      await adb.prepare("UPDATE assistant_settings SET access_checked_at = ? WHERE user_id = ?").bind(nowMs, row.user_id).run();
      continue;
    }
    await adb.prepare("UPDATE assistant_settings SET access_lost_at = NULL, access_checked_at = ? WHERE user_id = ?").bind(nowMs, row.user_id).run();
  }
  const prefixes: D1Result<{ prefix: string }> = await adb
    .prepare("SELECT prefix FROM assistant_purges ORDER BY requested_at LIMIT ?")
    .bind(limits.prefixes)
    .all<{ prefix: string }>();
  let purgedPrefixes: number = 0;
  let purgedObjects: number = 0;
  for (const { prefix } of prefixes.results) {
    const result: AssistantPurgeResult = await purgeAssistantPrefix(adb, bucket, prefix, limits.pagesPerPrefix);
    purgedPrefixes += result.complete ? 1 : 0;
    purgedObjects += result.deletedObjects;
  }
  await adb.batch([
    adb.prepare("DELETE FROM used_nonces WHERE expires_at < ?").bind(nowMs),
    adb.prepare("DELETE FROM assistant_registrations WHERE hour < ?").bind(Math.floor(nowMs / 3_600_000) - 48),
  ]);
  const report: AssistantCleanupReport = { checked: rows.results.length, orphansDeleted, accessLostMarked, copiesDeleted, purgedPrefixes, purgedObjects };
  log("info", "assistant_cleanup_done", report);
  return report;
}
