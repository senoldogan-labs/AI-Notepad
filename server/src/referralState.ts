import type { PaymentReversalReason, ReferralStatus, ReferralVoidReason } from "./referrals";

/**
 * Davet satırının (`referral_redemptions`) durum makinesi; tek kaynaktır. SQL ifadeleri (`referrals.ts`,
 * `referralRewards.ts`) aynı koşulları `WHERE` ile atomik uygular, göç `0064_referral_reward_claim.sql`'deki
 * tetikleyiciler durum geçişlerini (`allowedReferralStatusChanges`) veritabanında zorlar; `test/referralState.test.ts`
 * üçünün uyuştuğunu sınar.
 *
 * Ödül sahiplenmesi (`reward_claimed_at`): Cron, Stripe'a gitmeden önce `qualified` satırı sahiplenir. Sahiplenilmiş
 * satırı iade ya da itiraz webhook'u düşüremez, yalnızca nedenini bekleyen düşme olarak yazar (`reward_void_pending`);
 * Cron bekleyen düşmeyi ve ödül faturasının iade ve itirazını sahiplendikten sonra okur. Böylece iade ya sahiplenmeden
 * önce gelir (webhook satırı düşürür, sahiplenme başarısız olur, Stripe çağrılmaz) ya da sonra (Cron bekleyen düşmeyi
 * ya da Stripe'taki iadeyi görür ve satırı düşürür, ya da iade ödül yazıldıktan sonra gelmiş sayılır:
 * `granted` satır gibi ödül geri alınmaz, koruma 30 günlük bekleme süresidir). Stripe'ta alacak yazılmış ama satırı
 * `void` olan bir durum oluşamaz. Sahiplenme `referralClaimLeaseMs` sonra düşer: arada çöken çalışmanın satırı
 * sonraki Cron'da yeniden sahiplenilir (önce Stripe'ta yazılmış ödül aranır; idempotency anahtarı ödül kimliğidir).
 */

/** Ödül çalışmasının satırı sonuçlandırması: verildi, yıllık sınır ya da düşme nedeni. */
export type RewardOutcome = "granted" | "capped" | ReferralVoidReason;

/** Satırın durumu: `status` ve ödülün sahiplenildiği an (yoksa null). */
export interface ReferralState {
  readonly status: ReferralStatus;
  readonly rewardClaimedAtMs: number | null;
  /** Sahiplenilmiş satıra gelen iade ya da itirazın nedeni (`reward_void_pending`); yoksa null. */
  readonly pendingVoidReason: PaymentReversalReason | null;
}

/** Satırı değiştiren olaylar. */
export type ReferralEvent =
  /** Kodla açılan aboneliğin ilk faturası ödendi, kart engeli yok. */
  | { readonly kind: "joined" }
  /** İlk fatura ödendi ama kart davet edenin ya da başka davetin (`self_card`, `card_reused`). */
  | { readonly kind: "join_rejected" }
  /** İlk sıfırdan büyük ödeme alındı. */
  | { readonly kind: "qualified" }
  /** Ücretsiz aydaki aboneliğin bitmesi ya da arkadaşın hesabını silmesi. */
  | { readonly kind: "canceled_before_payment" }
  /** İade ya da itiraz webhook'u. */
  | { readonly kind: "payment_reversed"; readonly reason: PaymentReversalReason }
  /** Davet edenin hesabı silindi. */
  | { readonly kind: "referrer_deleted" }
  /** Ödül Cron'u satırı sahipleniyor. */
  | { readonly kind: "reward_claimed"; readonly nowMs: number }
  /** Ödül Cron'u sahiplendiği satırı sonuçlandırıyor (`claimedAtMs` kendi sahiplenme anı). */
  | { readonly kind: "reward_settled"; readonly outcome: RewardOutcome; readonly claimedAtMs: number };

/** Sahiplenmenin geçerli kaldığı süre: Cron çalışması (en çok 15 dakika) bundan kısa, günlük aralıktan çok kısa. */
export const referralClaimLeaseMs: number = 3_600_000;

/** Veritabanının izin verdiği durum değişimleri (aynı durumda kalan güncellemeler hep serbest). */
export const allowedReferralStatusChanges: readonly (readonly [ReferralStatus, ReferralStatus])[] = [
  ["checkout", "joined"],
  ["checkout", "void"],
  ["joined", "qualified"],
  ["joined", "void"],
  ["qualified", "granted"],
  ["qualified", "capped"],
  ["qualified", "void"],
];

/** Sahiplenme alınabilir mi: hiç sahiplenilmemiş ya da önceki sahiplenmenin süresi dolmuş. */
export function rewardClaimable(rewardClaimedAtMs: number | null, nowMs: number): boolean {
  return rewardClaimedAtMs === null || rewardClaimedAtMs <= nowMs - referralClaimLeaseMs;
}

/** Ödül sonucunun yazılacağı durum. */
export function rewardOutcomeStatus(outcome: RewardOutcome): ReferralStatus {
  return outcome === "granted" || outcome === "capped" ? outcome : "void";
}

/** Olayın satırı götürdüğü durum; olay bu durumda geçerli değilse null (satır değişmez). */
export function referralTransition(state: ReferralState, event: ReferralEvent): ReferralState | null {
  const { status, rewardClaimedAtMs, pendingVoidReason } = state;
  switch (event.kind) {
    case "joined":
      return status === "checkout" ? { status: "joined", rewardClaimedAtMs, pendingVoidReason } : null;
    case "join_rejected":
      return status === "checkout" ? { status: "void", rewardClaimedAtMs, pendingVoidReason } : null;
    case "qualified":
      return status === "joined" ? { status: "qualified", rewardClaimedAtMs, pendingVoidReason } : null;
    case "canceled_before_payment":
      return status === "joined" ? { status: "void", rewardClaimedAtMs, pendingVoidReason } : null;
    case "payment_reversed":
      if (status === "qualified" && rewardClaimedAtMs !== null) {
        return { status, rewardClaimedAtMs, pendingVoidReason: pendingVoidReason ?? event.reason };
      }
      return status === "joined" || status === "qualified" ? { status: "void", rewardClaimedAtMs, pendingVoidReason } : null;
    case "referrer_deleted":
      return status === "checkout" || status === "joined" || status === "qualified" ? { status: "void", rewardClaimedAtMs, pendingVoidReason } : null;
    case "reward_claimed":
      return status === "qualified" && rewardClaimable(rewardClaimedAtMs, event.nowMs) ? { status, rewardClaimedAtMs: event.nowMs, pendingVoidReason } : null;
    case "reward_settled":
      return status === "qualified" && rewardClaimedAtMs === event.claimedAtMs ? { status: rewardOutcomeStatus(event.outcome), rewardClaimedAtMs, pendingVoidReason } : null;
  }
}
