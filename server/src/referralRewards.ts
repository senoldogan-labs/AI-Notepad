import type Stripe from "stripe";
import { callStripe, paymentTargetOf, storedCustomerId, stripeClient } from "./billing";
import type { Config } from "./config";
import { type SubscriptionState, subscriptionState } from "./entitlements";
import { errorName, log } from "./log";
import type { Platform } from "./platform";
import { type RewardOutcome, referralClaimLeaseMs, rewardOutcomeStatus } from "./referralState";
import { type PaymentReversalReason, type ReferralStatus, recentRewardCount, referralRewardsPerYear, sharesDevice, usdCents } from "./referrals";

/**
 * Davet ödülü: davet edilenin ilk gerçek ödemesi `referralHoldMs` boyunca iade ya da itiraz almadıysa (`qualified`,
 * `reward_due_at` geçmiş) davet edenin Stripe müşterisine bir aylık fiyat kadar (USD) müşteri bakiyesi alacağı yazılır;
 * Stripe bunu sonraki faturalarından kendiliğinden düşer.
 *
 * Neden müşteri bakiyesi (tek seferlik %100 kupon değil): planı ne olursa olsun (aylıkta bir ay, yıllıkta yenilemeden
 * 5,99 $) aynı değeri verir; birden çok ödül üst üste birikir (aynı faturaya iki %100 kupon yalnızca bir ay eder);
 * aboneliği değiştirmez (abonelik olayı tetiklemez); tek bir idempotent çağrıdır ve Stripe'ta `metadata` ile
 * izlenebilir. Fiyatlar USD'dir; Adaptive Pricing yerel parayla ödetse de fatura para birimi USD kalır.
 *
 * Satır önce sahiplenilir (`reward_claimed_at`, durum makinesi `referralState.ts`): sahiplenilmiş satırı iade ya da
 * itiraz webhook'u düşüremez, nedenini `reward_void_pending`'e yazar; Cron onu ve ödül faturasının Stripe'taki iade ve
 * itirazını sahiplendikten sonra okur. Sonuç yalnızca kendi sahiplenmesi duran satıra yazılır; yazılamazsa alarm verilir.
 *
 * Çift ödül olmaz: satır `qualified` ve sahiplenilebilir değilse işlenmez, Stripe çağrısı ödül kimliğiyle idempotent'tir
 * ve çağrıdan önce müşterinin bakiye hareketlerinde aynı ödül (`metadata.referral_redemption_id`) aranır (yanıt yolda
 * kaybolup satır yazılamadıysa sonraki çalışma yeniden yaratmaz). Önceki sahiplenmesi süresi dolmuş (çökmüş) satırda bu
 * arama her denetimden önce yapılır: alacak yazılmışsa satır, sonradan gelen iadeye bakılmadan `granted` olur.
 */

/** Bir Cron çalışmasında en çok işlenen ödül (kalanlar ertesi gün). */
export const referralRewardBatchSize: number = 50;

/** Bakiye hareketinin işareti. */
const rewardPurpose: string = "referral_reward";

/** Ödül bekleyen satır. */
interface DueReward {
  readonly id: string;
  readonly referrer_user_id: string | null;
  readonly referred_user_id: string | null;
  readonly stripe_subscription_id: string;
  readonly qualifying_invoice_id: string;
  /** Önceki (süresi dolmuş) sahiplenme; yoksa null. */
  readonly reward_claimed_at: number | null;
}

/** Cron raporu: sonuç başına satır sayısı ve başarısız satırlar. */
export interface ReferralRewardReport {
  readonly processed: number;
  readonly granted: number;
  readonly capped: number;
  readonly voided: number;
  readonly failed: number;
}

/** Bir ya da daha çok ödül Stripe ya da D1 hatasıyla yazılamadı (ertesi gün yeniden denenir). */
export class ReferralRewardFailedError extends Error {
  override readonly name: string = "ReferralRewardFailedError";
  readonly failed: number;

  constructor(failed: number) {
    super(`${failed} davet ödülü yazılamadı; ertesi Cron çalışmasında yeniden denenecek.`);
    this.failed = failed;
  }
}

/**
 * Sonuç satıra yazılamadı: satır bu çalışmanın sahiplenmesinden sonra değişti (davet eden silindi ya da sahiplenme
 * süresi dolup başka bir çalışma aldı). Stripe'ta alacak yazılmışsa (`transactionId`) elle bakılmalıdır.
 */
export class ReferralRewardSettleMissedError extends Error {
  override readonly name: string = "ReferralRewardSettleMissedError";
  readonly rewardId: string;
  readonly outcome: RewardOutcome;
  readonly transactionId: string | null;

  constructor(rewardId: string, outcome: RewardOutcome, transactionId: string | null) {
    super(`Davet ödülü ${rewardId} için sonuç (${outcome}) yazılamadı: satır artık bu çalışmanın sahiplendiği qualified satır değil.`);
    this.rewardId = rewardId;
    this.outcome = outcome;
    this.transactionId = transactionId;
  }
}

/** Sahiplenilmiş satır sonuçlanmadan silindi (beklenmez: `qualified` satırı yalnızca 730 günlük temizlik siler). */
export class ReferralRewardRowMissingError extends Error {
  override readonly name: string = "ReferralRewardRowMissingError";
  readonly rewardId: string;

  constructor(rewardId: string) {
    super(`Davet ödülü ${rewardId} sahiplenildikten sonra satırı bulunamadı.`);
    this.rewardId = rewardId;
  }
}

/** Faturanın ödemelerinden biri iade (kısmi dahil) ya da itiraz almış mı. */
async function invoiceRefundedOrDisputed(stripe: Stripe, platform: Platform, invoiceId: string, userId: string | null): Promise<boolean> {
  const payments: Stripe.ApiList<Stripe.InvoicePayment> = await callStripe(platform, "invoicePayments.list", userId, () =>
    stripe.invoicePayments.list({ invoice: invoiceId, limit: 100 }),
  );
  for (const payment of payments.data) {
    const target: { payment_intent: string } | { charge: string } | null = paymentTargetOf(payment);
    if (target === null) {
      continue;
    }
    const charges: Stripe.Charge[] =
      "payment_intent" in target
        ? (await callStripe(platform, "charges.list", userId, () => stripe.charges.list({ payment_intent: target.payment_intent, limit: 100 }))).data
        : [await callStripe(platform, "charges.retrieve", userId, () => stripe.charges.retrieve(target.charge))];
    if (charges.some((charge: Stripe.Charge): boolean => charge.amount_refunded > 0 || charge.disputed)) {
      return true;
    }
  }
  return false;
}

/**
 * Müşterinin bu ödül için zaten yazılmış bakiye hareketi; yoksa null. Bütün sayfalar okunur: Stripe idempotency
 * anahtarını 24 saat tutar, ertesi günkü yeniden denemede çift alacağı yalnızca bu arama önler.
 */
async function existingRewardTransaction(stripe: Stripe, platform: Platform, customer: string, rewardId: string, userId: string): Promise<string | null> {
  let startingAfter: string | null = null;
  for (;;) {
    const after: string | null = startingAfter;
    const page: Stripe.ApiList<Stripe.CustomerBalanceTransaction> = await callStripe(platform, "customers.listBalanceTransactions", userId, () =>
      stripe.customers.listBalanceTransactions(customer, after === null ? { limit: 100 } : { limit: 100, starting_after: after }),
    );
    const found: Stripe.CustomerBalanceTransaction | undefined = page.data.find(
      (transaction: Stripe.CustomerBalanceTransaction): boolean => transaction.metadata?.["referral_redemption_id"] === rewardId,
    );
    if (found !== undefined) {
      return found.id;
    }
    const last: Stripe.CustomerBalanceTransaction | undefined = page.data.at(-1);
    if (!page.has_more || last === undefined) {
      return null;
    }
    startingAfter = last.id;
  }
}

/** Sahiplenilmiş satırın bekleyen düşmesi (`reward_void_pending`; sahiplenmeden sonra gelen iade ya da itiraz). */
async function pendingVoidReason(db: D1Database, rewardId: string): Promise<PaymentReversalReason | null> {
  const row: { reward_void_pending: PaymentReversalReason | null } | null = await db
    .prepare("SELECT reward_void_pending FROM referral_redemptions WHERE id = ?")
    .bind(rewardId)
    .first<{ reward_void_pending: PaymentReversalReason | null }>();
  if (row === null) {
    throw new ReferralRewardRowMissingError(rewardId);
  }
  return row.reward_void_pending;
}

/**
 * Satırı bu çalışma için sahiplenir (`referralState.ts`, `reward_claimed`): yalnızca hâlâ `qualified` ve
 * sahiplenilebilirse. Başka bir çalışma ya da webhook önce davrandıysa false.
 */
async function claimReward(db: D1Database, reward: DueReward, claimedAtMs: number): Promise<boolean> {
  const result: D1Result = await db
    .prepare(
      `UPDATE referral_redemptions SET reward_claimed_at = ?1
       WHERE id = ?2 AND status = 'qualified' AND (reward_claimed_at IS NULL OR reward_claimed_at <= ?3)`,
    )
    .bind(claimedAtMs, reward.id, claimedAtMs - referralClaimLeaseMs)
    .run();
  return result.meta.changes === 1;
}

/**
 * Sahiplenilmiş satırı sonuçlandırır (`referralState.ts`, `reward_settled`): yalnızca hâlâ bu çalışmanın sahiplendiği
 * `qualified` satırsa. Değişen satır yoksa alarm ve `ReferralRewardSettleMissedError`.
 */
async function settle(db: D1Database, reward: DueReward, claimedAtMs: number, outcome: RewardOutcome, transactionId: string | null): Promise<void> {
  const status: ReferralStatus = rewardOutcomeStatus(outcome);
  const result: D1Result = await db
    .prepare(
      `UPDATE referral_redemptions SET status = ?1, void_reason = ?2, rewarded_at = ?3, stripe_balance_transaction_id = ?4, updated_at = ?5
       WHERE id = ?6 AND status = 'qualified' AND reward_claimed_at = ?7`,
    )
    .bind(status, status === "void" ? outcome : null, outcome === "granted" ? claimedAtMs : null, transactionId, claimedAtMs, reward.id, claimedAtMs)
    .run();
  if (result.meta.changes !== 1) {
    log("alert", "referral_reward_settle_missed", {
      rewardId: reward.id,
      referrerUserId: reward.referrer_user_id,
      outcome,
      transactionId,
      claimedAtMs,
      changes: result.meta.changes,
    });
    throw new ReferralRewardSettleMissedError(reward.id, outcome, transactionId);
  }
}

/**
 * Ödülü engelleyen durum (sırayla: aynı cihaz, ödül faturasının Stripe'taki iadesi ya da itirazı, yıllık sınır); engel
 * yoksa null.
 */
async function rewardRefusal(db: D1Database, stripe: Stripe, platform: Platform, reward: DueReward, referrer: string, nowMs: number): Promise<RewardOutcome | null> {
  if (reward.referred_user_id !== null && (await sharesDevice(db, referrer, reward.referred_user_id))) {
    return "self_referral";
  }
  if (await invoiceRefundedOrDisputed(stripe, platform, reward.qualifying_invoice_id, referrer)) {
    return "refunded";
  }
  return (await recentRewardCount(db, referrer, nowMs)) >= referralRewardsPerYear ? "capped" : null;
}

/**
 * Önceki sahiplenmesi süresi dolmuş satırın Stripe'ta zaten yazılmış alacağı (çalışma Stripe çağrısından sonra
 * çöktü); yoksa ya da davet edenin müşterisi yoksa null.
 */
async function recoveredRewardTransaction(db: D1Database, stripe: Stripe, platform: Platform, reward: DueReward, referrer: string): Promise<string | null> {
  if (reward.reward_claimed_at === null) {
    return null;
  }
  const customer: string | null = await storedCustomerId(db, referrer);
  return customer === null ? null : existingRewardTransaction(stripe, platform, customer, reward.id, referrer);
}

/**
 * Sahiplenilmiş tek ödülü sonuçlandırır. Sıra: davet eden silinmiş → `referrer_deleted`; önceki çökmüş çalışmanın
 * Stripe'ta yazdığı alacak → `granted`; davet edenin ücretsiz erişimi var (`complimentary.ts`; bakiye yazılacak bir
 * Stripe aboneliği yok) → `referrer_complimentary`, Stripe çağrılmaz; iki hesap aynı cihazı paylaşıyor →
 * `self_referral`; ödül faturası Stripe'ta iade ya da itiraz almış → `refunded`; son 365 günde 12 ödül → `capped`;
 * davet edenin Stripe müşterisi yok → `referrer_no_customer`; sahiplenmeden beri iade ya da itiraz webhook'u geldi
 * (`reward_void_pending`; Stripe çağrısından hemen önce, bütün Stripe okumalarından sonra okunur) →
 * `refunded`/`disputed`; değilse bakiye alacağı yazılır → `granted`.
 */
async function settleReward(db: D1Database, stripe: Stripe, platform: Platform, config: Config, reward: DueReward, claimedAtMs: number): Promise<RewardOutcome> {
  const referrer: string | null = reward.referrer_user_id;
  if (referrer === null) {
    await settle(db, reward, claimedAtMs, "referrer_deleted", null);
    return "referrer_deleted";
  }
  const recovered: string | null = await recoveredRewardTransaction(db, stripe, platform, reward, referrer);
  if (recovered !== null) {
    await settle(db, reward, claimedAtMs, "granted", recovered);
    log("warn", "referral_reward_recovered", { rewardId: reward.id, referrerUserId: referrer, transactionId: recovered });
    return "granted";
  }
  const referrerSubscription: SubscriptionState | null = await subscriptionState(db, referrer);
  if (referrerSubscription !== null && referrerSubscription.complimentary) {
    await settle(db, reward, claimedAtMs, "referrer_complimentary", null);
    log("info", "referral_reward_skipped_complimentary", { rewardId: reward.id, referrerUserId: referrer });
    return "referrer_complimentary";
  }
  const refusal: RewardOutcome | null = await rewardRefusal(db, stripe, platform, reward, referrer, claimedAtMs);
  if (refusal !== null) {
    await settle(db, reward, claimedAtMs, refusal, null);
    return refusal;
  }
  const customer: string | null = await storedCustomerId(db, referrer);
  if (customer === null) {
    await settle(db, reward, claimedAtMs, "referrer_no_customer", null);
    return "referrer_no_customer";
  }
  const pending: PaymentReversalReason | null = await pendingVoidReason(db, reward.id);
  if (pending !== null) {
    await settle(db, reward, claimedAtMs, pending, null);
    return pending;
  }
  const transactionId: string =
    (await existingRewardTransaction(stripe, platform, customer, reward.id, referrer)) ??
    (
      await callStripe(platform, "customers.createBalanceTransaction", referrer, () =>
        stripe.customers.createBalanceTransaction(
          customer,
          {
            amount: -usdCents(config.priceUsdMonthly),
            currency: "usd",
            description: "Gistsmith invite reward: one month free",
            metadata: { purpose: rewardPurpose, referral_redemption_id: reward.id, referred_subscription_id: reward.stripe_subscription_id },
          },
          { idempotencyKey: `referral-reward-${reward.id}` },
        ),
      )
    ).id;
  await settle(db, reward, claimedAtMs, "granted", transactionId);
  return "granted";
}

/**
 * Günü gelmiş ödülleri (`qualified`, `reward_due_at <= now`, sahiplenilebilir; en çok `referralRewardBatchSize`)
 * sahiplenip sonuçlandırır. Sahiplenemediği satırı (araya giren webhook ya da başka çalışma) atlar ve saymaz. Satırlar
 * birbirinden bağımsızdır: biri başarısız olursa alarm yazılır, diğerleri sürer; sonunda başarısız varsa
 * `ReferralRewardFailedError` (satır `qualified` kalır, sahiplenme süresi dolunca yeniden denenir). Program kapalıyken
 * (`REFERRAL_POLICY=off`) de hak kazanılmış ödüller verilir.
 */
export async function grantDueReferralRewards(db: D1Database, platform: Platform, config: Config, now: Date): Promise<ReferralRewardReport> {
  const nowMs: number = now.getTime();
  const due: D1Result<DueReward> = await db
    .prepare(
      `SELECT id, referrer_user_id, referred_user_id, stripe_subscription_id, qualifying_invoice_id, reward_claimed_at FROM referral_redemptions
       WHERE status = 'qualified' AND reward_due_at <= ?1 AND (reward_claimed_at IS NULL OR reward_claimed_at <= ?2)
       ORDER BY reward_due_at LIMIT ?3`,
    )
    .bind(nowMs, nowMs - referralClaimLeaseMs, referralRewardBatchSize)
    .all<DueReward>();
  const counts: Record<"processed" | "granted" | "capped" | "voided" | "failed", number> = { processed: 0, granted: 0, capped: 0, voided: 0, failed: 0 };
  if (due.results.length === 0) {
    return counts;
  }
  const stripe: Stripe = stripeClient(platform, config);
  for (const reward of due.results) {
    try {
      if (!(await claimReward(db, reward, nowMs))) {
        log("info", "referral_reward_claim_lost", { rewardId: reward.id, referrerUserId: reward.referrer_user_id });
        continue;
      }
      counts.processed += 1;
      const outcome: RewardOutcome = await settleReward(db, stripe, platform, config, reward, nowMs);
      if (outcome === "granted" || outcome === "capped") {
        counts[outcome] += 1;
      } else {
        counts.voided += 1;
      }
      log("info", "referral_reward_settled", { rewardId: reward.id, referrerUserId: reward.referrer_user_id, outcome });
    } catch (error: unknown) {
      counts.failed += 1;
      log("alert", "referral_reward_failed", { rewardId: reward.id, referrerUserId: reward.referrer_user_id, error: errorName(error) });
    }
  }
  const report: ReferralRewardReport = { ...counts };
  log("info", "referral_rewards_done", { ...report });
  if (counts.failed > 0) {
    throw new ReferralRewardFailedError(counts.failed);
  }
  return report;
}
