import type { Config, StripePrices, SubscriptionPlan, SubscriptionTier, UsageLimits } from "./config";
import { ApiError } from "./errors";

/**
 * Subscription tiers (migration 0062). Personal is the original product; Pro sells more meeting hours. A tier is a
 * product with two billing plans (monthly, yearly): Stripe has one price per tier and plan (`STRIPE_*PRICE_ID`), the App
 * Store one product per tier and plan in a single subscription group (`APP_STORE_PRODUCT_*`).
 *
 * The tier only picks usage limits (`tierLimits`): every limit is server configuration (`MONTHLY_CAP_HOURS`, … for
 * Personal; `PRO_*` for Pro) so it can be tuned without a release. Access itself does not depend on the tier. An account
 * with paid access from both sources (Stripe and App Store) gets the higher tier (`strongerTier`). Trial accounts and
 * accounts without access use Personal's limits.
 *
 * `PRO_TIER_POLICY` only controls selling: when `off`, Pro is not offered (`offeredTiers`) and a Pro checkout or plan
 * change is refused (`requireTierOffered`), but an account that already has a Pro subscription keeps Pro limits.
 */

/** A tier the account can buy now and its limits, as the apps and the site show them (`GET /v1/me`, `GET /v1/pricing`). */
export interface TierOffer {
  readonly tier: SubscriptionTier;
  /** Recorded meeting hours per month. */
  readonly monthlyHours: number;
  /** Longest meeting (minutes). */
  readonly meetingMaxMinutes: number;
}

/** Personal's limits: the original (flat) settings. Saf fonksiyondur. */
export function personalLimits(config: Config): UsageLimits {
  return {
    monthlyCapSeconds: config.monthlyCapSeconds,
    maxMeetingMinutes: config.subscriberMaxMeetingMinutes,
    meetingTokenBudget: config.subscriberMeetingTokenBudget,
    monthlyTokenCap: config.monthlyTokenCap,
    monthlyAccountTokenCap: config.monthlyAccountTokenCap,
    dailyTokenCap: config.dailyTokenCap,
  };
}

/** The tier's limits. Saf fonksiyondur. */
export function tierLimits(config: Config, tier: SubscriptionTier): UsageLimits {
  return tier === "pro" ? config.proTier.limits : personalLimits(config);
}

/** Limits of an account whose paid tier is `tier` (null: trial or no access → Personal's). Saf fonksiyondur. */
export function accountLimits(config: Config, tier: SubscriptionTier | null): UsageLimits {
  return tierLimits(config, tier ?? "personal");
}

/** Whether the tier is on sale (`PRO_TIER_POLICY` for Pro; Personal always). Saf fonksiyondur. */
export function isTierOffered(config: Config, tier: SubscriptionTier): boolean {
  return tier === "personal" || config.proTier.policy === "on";
}

/** The tiers on sale, in display order, with their limits. Saf fonksiyondur. */
export function offeredTiers(config: Config): TierOffer[] {
  const tiers: readonly SubscriptionTier[] = ["personal", "pro"];
  return tiers
    .filter((tier: SubscriptionTier): boolean => isTierOffered(config, tier))
    .map((tier: SubscriptionTier): TierOffer => {
      const limits: UsageLimits = tierLimits(config, tier);
      return { tier, monthlyHours: limits.monthlyCapSeconds / 3600, meetingMaxMinutes: limits.maxMeetingMinutes };
    });
}

/** Refuses a tier that is not on sale (`503 pro_unavailable`). */
export function requireTierOffered(config: Config, tier: SubscriptionTier): void {
  if (!isTierOffered(config, tier)) {
    throw new ApiError("pro_unavailable", "Gistsmith Pro isn't available yet.");
  }
}

/** The higher of two tiers (Pro over Personal); null when both are null. Saf fonksiyondur. */
export function strongerTier(left: SubscriptionTier | null, right: SubscriptionTier | null): SubscriptionTier | null {
  if (left === "pro" || right === "pro") {
    return "pro";
  }
  return left ?? right;
}

/** The Stripe price of a tier and plan. Saf fonksiyondur. */
export function stripePriceOf(prices: StripePrices, tier: SubscriptionTier, plan: SubscriptionPlan): string {
  if (tier === "pro") {
    return plan === "monthly" ? prices.proMonthly : prices.proYearly;
  }
  return plan === "monthly" ? prices.monthly : prices.yearly;
}

/** List price per month of a tier and plan (USD; yearly counts 1/12). Saf fonksiyondur. */
export function monthlyListPriceUsd(prices: TierPrices, tier: SubscriptionTier, plan: SubscriptionPlan): number {
  const price: number = prices[tier][plan];
  return plan === "monthly" ? price : price / 12;
}

/** List prices (USD) per tier and plan. */
export type TierPrices = Readonly<Record<SubscriptionTier, Readonly<Record<SubscriptionPlan, number>>>>;

/** Stripe list prices of the configuration. Saf fonksiyondur. */
export function stripeListPrices(config: Config): TierPrices {
  return {
    personal: { monthly: config.priceUsdMonthly, yearly: config.priceUsdYearly },
    pro: { monthly: config.proPriceUsdMonthly, yearly: config.proPriceUsdYearly },
  };
}

/** App Store list prices of the configuration (before Apple's commission). Saf fonksiyondur. */
export function appStoreListPrices(config: Config): TierPrices {
  return {
    personal: { monthly: config.appStore.priceUsdMonthly, yearly: config.appStore.priceUsdYearly },
    pro: { monthly: config.appStore.proPriceUsdMonthly, yearly: config.appStore.proPriceUsdYearly },
  };
}
