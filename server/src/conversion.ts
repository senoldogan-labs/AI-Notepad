import { z } from "zod";
import { type DownloadCampaign, downloadCampaignOf } from "./downloads";
import { dayKey } from "./usage";

/**
 * Subscription funnel telemetry (admin panel "Telemetry" › Conversion; migration 0063). The apps send these events with
 * the other client telemetry (`POST /v1/telemetry`) only while usage statistics are shared — on iPhone only after the
 * user turned sharing on explicitly. Every value comes from a fixed list; events are summed per UTC day, kind, platform,
 * dimensions and app version. Nothing links a row to an account: no user ID, product ID, price, country or free text.
 * Purchases and revenue stay server-authoritative (Stripe and RevenueCat webhooks); `purchase_completed` here only
 * measures that the app saw the subscription arrive, so the admin panel shows these as a lower bound.
 *
 * The Mac's onboarding asks once "Where did you hear about us?" (`heard_about`, one tap from `acquisitionSources`; stored
 * in `reason`), under the same consent and with the same daily, account-free sums.
 *
 * The server also counts every Stripe Checkout it opens (`checkout_created`, platform `server`, surface `app` or `web`)
 * and, from the Stripe webhooks, every one that finishes (`checkout_completed`) or lapses (`checkout_expired`; surface
 * `unknown` for sessions opened before the session metadata carried it). The same three stages are also counted per
 * campaign (`checkout_campaigns`, migration 0068).
 *
 * The lists match the apps' enums one to one (Swift `ServerParityTests` reads these arrays).
 */

export const conversionSurfaces = ["paywall", "sheet", "strip", "banner", "notification", "settings", "account", "confirmation"] as const;
export const conversionTriggers = [
  "trial_note_ready",
  "trial_ending",
  "trial_ended",
  "subscription_required",
  "plan_choice",
  "monthly_warning",
  "monthly_full",
  "win_back",
  "trial_reminder",
  "meeting_start",
] as const;
export const conversionTiersOffered = ["personal", "personal_pro"] as const;
export const conversionTiers = ["personal", "pro"] as const;
export const conversionPlans = ["monthly", "yearly"] as const;
export const conversionReasons = [
  "products_unavailable",
  "store_error",
  "payment_pending",
  "purchase_not_allowed",
  "network",
  "server",
  "entitlement_timeout",
  "not_signed_in",
  "configuration",
] as const;
export const conversionRestoreResults = ["restored", "nothing_found"] as const;
export const conversionChannels = ["in_app", "notification"] as const;
export const acquisitionSources = ["search", "app_store", "social", "friend", "ai_assistant", "video", "blog", "ad", "other"] as const;

/** Every event kind the apps send. */
export const conversionKinds = [
  "paywall_shown",
  "paywall_closed",
  "plan_selected",
  "purchase_started",
  "purchase_cancelled",
  "purchase_completed",
  "purchase_failed",
  "purchase_restored",
  "trial_reminder_shown",
  "trial_reminder_tapped",
  "trial_reminder_opt_in",
  "upsell_shown",
  "upsell_tapped",
  "heard_about",
] as const;

export type ConversionKind = (typeof conversionKinds)[number] | "checkout_created" | "checkout_completed" | "checkout_expired";

/** The platform a row is counted under: derived from `x-os-version` for app events; `server` for checkout counts. */
export type ConversionPlatform = "macos" | "ios" | "unknown" | "server";

const count = z.number().int().min(1).max(1000);
const surface = z.enum(conversionSurfaces);
const trigger = z.enum(conversionTriggers);
const tier = z.enum(conversionTiers);
const plan = z.enum(conversionPlans);
const channel = z.enum(conversionChannels);

/** The conversion members of `telemetryEventsSchema`'s union (strict: each kind carries exactly its fields). */
export const conversionEventSchemas = [
  z.strictObject({ kind: z.literal("paywall_shown"), surface, trigger, tiersOffered: z.enum(conversionTiersOffered), count }),
  z.strictObject({ kind: z.literal("paywall_closed"), surface, trigger, count }),
  z.strictObject({ kind: z.literal("plan_selected"), surface, trigger, tier, plan, count }),
  z.strictObject({ kind: z.literal("purchase_started"), surface, trigger, tier, plan, count }),
  z.strictObject({ kind: z.literal("purchase_cancelled"), surface, trigger, tier, plan, count }),
  z.strictObject({ kind: z.literal("purchase_completed"), surface, trigger, tier, plan, count }),
  z.strictObject({ kind: z.literal("purchase_failed"), surface, trigger, reason: z.enum(conversionReasons), count }),
  z.strictObject({ kind: z.literal("purchase_restored"), surface, result: z.enum(conversionRestoreResults), count }),
  z.strictObject({ kind: z.literal("trial_reminder_shown"), channel, count }),
  z.strictObject({ kind: z.literal("trial_reminder_tapped"), channel, count }),
  z.strictObject({ kind: z.literal("trial_reminder_opt_in"), count }),
  z.strictObject({ kind: z.literal("upsell_shown"), trigger, count }),
  z.strictObject({ kind: z.literal("upsell_tapped"), trigger, count }),
  z.strictObject({ kind: z.literal("heard_about"), source: z.enum(acquisitionSources), count }),
] as const;

/** A validated conversion event. */
export type ConversionEvent = z.output<(typeof conversionEventSchemas)[number]>;

/** The stored key of an event: every dimension, `""` where the kind has none. */
export interface ConversionKey {
  readonly kind: ConversionKind;
  readonly surface: string;
  readonly trigger: string;
  readonly tiers: string;
  readonly tier: string;
  readonly plan: string;
  readonly reason: string;
}

/** A summed row of one request. */
export interface ConversionAggregate extends ConversionKey {
  readonly count: number;
}

/** Whether a telemetry event is a conversion event. Pure function. */
export function isConversionEvent(event: { readonly kind: string }): event is ConversionEvent {
  return (conversionKinds as readonly string[]).includes(event.kind);
}

/** The stored key of an event. Pure function. */
export function conversionKeyOf(event: ConversionEvent): ConversionKey {
  return {
    kind: event.kind,
    surface: "surface" in event ? event.surface : "",
    trigger: "trigger" in event ? event.trigger : "",
    tiers: "tiersOffered" in event ? event.tiersOffered : "",
    tier: "tier" in event ? event.tier : "",
    plan: "plan" in event ? event.plan : "",
    reason:
      "reason" in event
        ? event.reason
        : "result" in event
          ? event.result
          : "channel" in event
            ? event.channel
            : "source" in event
              ? event.source
              : "",
  };
}

/** Sums the request's events by stored key (each key is written once per batch). Pure function. */
export function aggregateConversions(events: readonly ConversionEvent[]): ConversionAggregate[] {
  const sums: Map<string, ConversionAggregate> = new Map();
  for (const event of events) {
    const key: ConversionKey = conversionKeyOf(event);
    const id: string = [key.kind, key.surface, key.trigger, key.tiers, key.tier, key.plan, key.reason].join("|");
    const previous: ConversionAggregate | undefined = sums.get(id);
    sums.set(id, { ...key, count: (previous?.count ?? 0) + event.count });
  }
  return [...sums.values()];
}

/** The platform of an `x-os-version` value (`macOS …`, `iOS …`); `unknown` when absent or other. Pure function. */
export function conversionPlatformOf(osVersion: string | null): ConversionPlatform {
  if (osVersion === null) {
    return "unknown";
  }
  if (osVersion.startsWith("macOS ")) {
    return "macos";
  }
  return osVersion.startsWith("iOS ") ? "ios" : "unknown";
}

/** Upsert statements adding the aggregates to today's (UTC) rows. */
export function conversionStatements(db: D1Database, rows: readonly ConversionAggregate[], platform: ConversionPlatform, appVersion: string, now: Date): D1PreparedStatement[] {
  const day: string = dayKey(now);
  return rows.map(
    (row: ConversionAggregate): D1PreparedStatement =>
      db
        .prepare(
          `INSERT INTO conversion_events_daily (day, kind, platform, surface, trigger, tiers, tier, plan, reason, app_version, count)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
           ON CONFLICT(day, kind, platform, surface, trigger, tiers, tier, plan, reason, app_version)
           DO UPDATE SET count = count + excluded.count`,
        )
        .bind(day, row.kind, platform, row.surface, row.trigger, row.tiers, row.tier, row.plan, row.reason, appVersion, row.count),
  );
}

/** The checkout stages counted per campaign (`checkout_campaigns.stage`). */
export type CheckoutStage = "created" | "completed" | "expired";

/** Where a Stripe Checkout was opened from: the app, the website, or `unknown` (session without metadata). */
export type CheckoutSurface = "app" | "web" | "unknown";

/** Upsert statement adding one to the campaign's count of a checkout stage (today, UTC). */
export function checkoutCampaignStatement(db: D1Database, stage: CheckoutStage, campaign: DownloadCampaign, now: Date): D1PreparedStatement {
  return db
    .prepare(
      `INSERT INTO checkout_campaigns (day, stage, utm_source, utm_campaign, count) VALUES (?, ?, ?, ?, 1)
       ON CONFLICT(day, stage, utm_source, utm_campaign) DO UPDATE SET count = count + 1`,
    )
    .bind(dayKey(now), stage, campaign.source, campaign.campaign);
}

/** Counts a Stripe Checkout the server opened: source `app` (the request carried `x-app-version`) or `web`. */
export async function recordCheckoutCreated(
  db: D1Database,
  source: "app" | "web",
  tierValue: string,
  planValue: string,
  campaign: DownloadCampaign | null,
  now: Date,
): Promise<void> {
  await db.batch([
    ...conversionStatements(db, [{ kind: "checkout_created", surface: source, trigger: "", tiers: "", tier: tierValue, plan: planValue, reason: "", count: 1 }], "server", "", now),
    ...(campaign === null ? [] : [checkoutCampaignStatement(db, "created", campaign, now)]),
  ]);
}

/** The Stripe session metadata the server writes when it opens a Checkout (`checkoutMetadata`). */
export type CheckoutMetadata = Readonly<Record<string, string>>;

/** The metadata the server writes on a Checkout session so the webhooks can count its outcome. Pure function. */
export function checkoutMetadata(surface: "app" | "web", tierValue: string, planValue: string, campaign: DownloadCampaign | null): Record<string, string> {
  return {
    surface,
    tier: tierValue,
    plan: planValue,
    ...(campaign === null ? {} : { utm_source: campaign.source, utm_campaign: campaign.campaign }),
  };
}

/**
 * Statements counting a finished (`completed`) or lapsed (`expired`) Checkout from the Stripe webhook, by the session's
 * metadata. Values outside the fixed lists (and sessions without metadata) count as `unknown`/empty, never as free
 * text, so the table stays bounded. Pure function over the metadata.
 */
export function checkoutOutcomeStatements(db: D1Database, stage: "completed" | "expired", metadata: CheckoutMetadata | null, now: Date): D1PreparedStatement[] {
  const meta: CheckoutMetadata = metadata ?? {};
  const surface: CheckoutSurface = meta["surface"] === "app" || meta["surface"] === "web" ? meta["surface"] : "unknown";
  const tierValue: string = (conversionTiers as readonly string[]).includes(meta["tier"] ?? "") ? (meta["tier"] ?? "") : "";
  const planValue: string = (conversionPlans as readonly string[]).includes(meta["plan"] ?? "") ? (meta["plan"] ?? "") : "";
  const campaign: DownloadCampaign | null = downloadCampaignOf(meta["utm_source"] ?? null, meta["utm_campaign"] ?? null);
  return [
    ...conversionStatements(db, [{ kind: `checkout_${stage}`, surface, trigger: "", tiers: "", tier: tierValue, plan: planValue, reason: "", count: 1 }], "server", "", now),
    ...(campaign === null ? [] : [checkoutCampaignStatement(db, stage, campaign, now)]),
  ];
}

/** One summed row of the admin window. */
export interface ConversionRow {
  readonly kind: string;
  readonly platform: string;
  readonly surface: string;
  readonly trigger: string;
  readonly tiers: string;
  readonly tier: string;
  readonly plan: string;
  readonly reason: string;
  readonly count: number;
}

/** Funnel steps per platform and trigger. */
export interface ConversionFunnelRow {
  readonly platform: string;
  readonly trigger: string;
  readonly shown: number;
  readonly selected: number;
  readonly started: number;
  readonly completed: number;
  readonly cancelled: number;
  readonly failed: number;
}

/** The admin panel's conversion section (sums of the window; no identifiers). */
export interface AdminConversion {
  readonly funnel: readonly ConversionFunnelRow[];
  readonly failures: ReadonlyArray<{ readonly platform: string; readonly reason: string; readonly count: number }>;
  readonly restores: ReadonlyArray<{ readonly platform: string; readonly result: string; readonly count: number }>;
  readonly planMix: ReadonlyArray<{ readonly platform: string; readonly tier: string; readonly plan: string; readonly started: number; readonly completed: number }>;
  readonly reminders: ReadonlyArray<{ readonly kind: string; readonly channel: string; readonly count: number }>;
  readonly upsells: ReadonlyArray<{ readonly trigger: string; readonly shown: number; readonly tapped: number }>;
  /** Checkouts per surface, tier and plan: opened (`count`), finished (`completed`) and lapsed (`expired`). */
  readonly checkouts: ReadonlyArray<{
    readonly source: string;
    readonly tier: string;
    readonly plan: string;
    readonly count: number;
    readonly completed: number;
    readonly expired: number;
  }>;
  /** "Where did you hear about us?" answers per platform and source. */
  readonly heardAbout: ReadonlyArray<{ readonly platform: string; readonly source: string; readonly count: number }>;
}

/** Sum of the rows matching a predicate. Pure function. */
function sumWhere(rows: readonly ConversionRow[], match: (row: ConversionRow) => boolean): number {
  return rows.filter(match).reduce((total: number, row: ConversionRow): number => total + row.count, 0);
}

/** Distinct values of a key, sorted. Pure function. */
function distinct<T>(values: readonly T[]): T[] {
  return [...new Set(values)].sort();
}

/** A count per platform and one dimension value (stored in `reason`). */
interface PairCount {
  readonly platform: string;
  readonly value: string;
  readonly count: number;
}

/** Sums of one kind per platform and `reason` value. Pure function. */
function pairCounts(rows: readonly ConversionRow[], kind: string): PairCount[] {
  const matching: ConversionRow[] = rows.filter((row: ConversionRow): boolean => row.kind === kind);
  const keys: string[] = distinct(matching.map((row: ConversionRow): string => `${row.platform}|${row.reason}`));
  return keys.map((key: string): PairCount => {
    const [platform = "", value = ""] = key.split("|");
    return { platform, value, count: sumWhere(matching, (row: ConversionRow): boolean => row.platform === platform && row.reason === value) };
  });
}

/** The admin summary of the window's rows. Pure function. */
export function adminConversionOf(rows: readonly ConversionRow[]): AdminConversion {
  const app: ConversionRow[] = rows.filter((row: ConversionRow): boolean => row.platform !== "server");
  const funnelKeys: string[] = distinct(
    app.filter((row: ConversionRow): boolean => row.trigger !== "" && row.kind !== "upsell_shown" && row.kind !== "upsell_tapped").map(
      (row: ConversionRow): string => `${row.platform}|${row.trigger}`,
    ),
  );
  const funnel: ConversionFunnelRow[] = funnelKeys.map((key: string): ConversionFunnelRow => {
    const [platform = "", trigger = ""] = key.split("|");
    const of = (kind: string): number => sumWhere(app, (row: ConversionRow): boolean => row.kind === kind && row.platform === platform && row.trigger === trigger);
    return {
      platform,
      trigger,
      shown: of("paywall_shown"),
      selected: of("plan_selected"),
      started: of("purchase_started"),
      completed: of("purchase_completed"),
      cancelled: of("purchase_cancelled"),
      failed: of("purchase_failed"),
    };
  });
  const planKeys: string[] = distinct(
    app.filter((row: ConversionRow): boolean => row.tier !== "" && row.plan !== "").map((row: ConversionRow): string => `${row.platform}|${row.tier}|${row.plan}`),
  );
  const upsellTriggers: string[] = distinct(app.filter((row: ConversionRow): boolean => row.kind === "upsell_shown" || row.kind === "upsell_tapped").map((row: ConversionRow): string => row.trigger));
  return {
    funnel,
    failures: pairCounts(app, "purchase_failed").map((pair: PairCount) => ({ platform: pair.platform, reason: pair.value, count: pair.count })),
    restores: pairCounts(app, "purchase_restored").map((pair: PairCount) => ({ platform: pair.platform, result: pair.value, count: pair.count })),
    heardAbout: pairCounts(app, "heard_about").map((pair: PairCount) => ({ platform: pair.platform, source: pair.value, count: pair.count })),
    planMix: planKeys.map((key: string) => {
      const [platform = "", tierValue = "", planValue = ""] = key.split("|");
      const of = (kind: string): number =>
        sumWhere(app, (row: ConversionRow): boolean => row.kind === kind && row.platform === platform && row.tier === tierValue && row.plan === planValue);
      return { platform, tier: tierValue, plan: planValue, started: of("purchase_started"), completed: of("purchase_completed") };
    }),
    reminders: (["trial_reminder_shown", "trial_reminder_tapped", "trial_reminder_opt_in"] as const).flatMap((kind) =>
      distinct(app.filter((row: ConversionRow): boolean => row.kind === kind).map((row: ConversionRow): string => row.reason)).map((channelValue: string) => ({
        kind: kind.replace("trial_reminder_", ""),
        channel: channelValue,
        count: sumWhere(app, (row: ConversionRow): boolean => row.kind === kind && row.reason === channelValue),
      })),
    ),
    upsells: upsellTriggers.map((triggerValue: string) => ({
      trigger: triggerValue,
      shown: sumWhere(app, (row: ConversionRow): boolean => row.kind === "upsell_shown" && row.trigger === triggerValue),
      tapped: sumWhere(app, (row: ConversionRow): boolean => row.kind === "upsell_tapped" && row.trigger === triggerValue),
    })),
    checkouts: (() => {
      const kinds: readonly string[] = ["checkout_created", "checkout_completed", "checkout_expired"];
      const server: ConversionRow[] = rows.filter((row: ConversionRow): boolean => row.platform === "server" && kinds.includes(row.kind));
      const keys: string[] = distinct(server.map((row: ConversionRow): string => `${row.surface}|${row.tier}|${row.plan}`));
      return keys.map((key: string) => {
        const [source = "", tierValue = "", planValue = ""] = key.split("|");
        const of = (kind: string): number =>
          sumWhere(server, (row: ConversionRow): boolean => row.kind === kind && row.surface === source && row.tier === tierValue && row.plan === planValue);
        return { source, tier: tierValue, plan: planValue, count: of("checkout_created"), completed: of("checkout_completed"), expired: of("checkout_expired") };
      });
    })(),
  };
}

/** The window's rows, summed over days and app versions. */
export async function conversionRows(db: D1Database, sinceDay: string): Promise<ConversionRow[]> {
  const result: D1Result<ConversionRow> = await db
    .prepare(
      `SELECT kind, platform, surface, trigger, tiers, tier, plan, reason, SUM(count) AS count FROM conversion_events_daily
       WHERE day >= ? GROUP BY kind, platform, surface, trigger, tiers, tier, plan, reason`,
    )
    .bind(sinceDay)
    .all<ConversionRow>();
  return result.results;
}
