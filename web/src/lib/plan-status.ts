// Hesabın plan durumu: `GET /v1/me` yanıtından tek saf fonksiyonla çıkarılan birleşik tip. Uygulamalardaki
// `HostedPlanStatus` ve `HostedTrialState`'in (Packages/AINotepadCore/.../Hosted/HostedModels.swift) karşılığıdır:
// deneme şimdiki ana göre yorumlanır (süresi dolan deneme, sunucu toplantı kalmış dese de biter). Hesap sayfası
// (src/client/account.ts) plan adını, etiketi, durum satırlarını ve ölçerleri yalnızca bu durumdan yazar.
import type { Entitlements, SubscriptionInfo } from "../client/api";

/** Ücretsiz denemenin bitme nedeni: toplantıların hepsi kullanıldı ya da deneme süresi (`trialEndsAt`) doldu. */
export type TrialEndReason = "meetingsUsed" | "timeExpired";

/**
 * Ücretsiz denemenin durumu. Başlamamış deneme ilk deneme toplantısıyla başlar (sunucu o zaman `trialEndsAt` yazar);
 * kalan toplantı (en az 1) önceki hesaptan devralınan deneme toplantıları yüzünden toplamdan az olabilir. Süren denemede
 * kalan toplantı en az 1'dir.
 */
export type TrialState =
  | { readonly kind: "notStarted"; readonly left: number; readonly total: number }
  | { readonly kind: "running"; readonly left: number; readonly total: number; readonly endsAt: string }
  | { readonly kind: "ended"; readonly reason: TrialEndReason; readonly total: number };

/**
 * Hesabın plan durumu. Erişimi olan abonelik denemeden önce gelir; erişimi kapanmış abonelikte deneme hâlâ sürüyorsa
 * (ya da başlamadıysa) deneme anlatılır. `subscription` durumu üreten aboneliktir (ödeme kaynağı ve plan adı için).
 *
 * - `complimentary`: yöneticinin verdiği ücretsiz tam erişim; `until` bitiş anı (süresizse null).
 * - `complimentaryEnded`: ücretsiz erişim bitti ve deneme de bitti (hiç ödeme yapılmadı: "abonelik bitti" değil).
 * - `subscribed`: etkin, `renewsAt`'te yenilenir. `ending`: iptal edildi, erişim `endsAt`'e dek sürer.
 * - `grace`: yenileme ödemesi alınamadı, erişim `endsAt`'e dek sürer.
 * - `paymentOverdue`: ek süre bitti ama abonelik Stripe'ta sürüyor (`past_due`/`unpaid`); kart güncellenince erişim
 *   döner (yeni abonelik açılamaz). Denemeden önce gelir: denemeyi hiç kullanmadan abone olan hesabın deneme hakkı
 *   durur, ama kullanıcıya önce kartını güncellemesi söylenmelidir. `trial` o anki denemedir (sürüyorsa gösterilir).
 * - `expired`: abonelik bitti ve deneme de bitti; yeni kayıt için yeniden abone olunmalı.
 */
export type PlanState =
  | { readonly kind: "trial"; readonly trial: TrialState }
  | { readonly kind: "complimentary"; readonly subscription: SubscriptionInfo; readonly until: string | null }
  | { readonly kind: "complimentaryEnded"; readonly subscription: SubscriptionInfo }
  | { readonly kind: "subscribed"; readonly subscription: SubscriptionInfo; readonly renewsAt: string }
  | { readonly kind: "ending"; readonly subscription: SubscriptionInfo; readonly endsAt: string }
  | { readonly kind: "grace"; readonly subscription: SubscriptionInfo; readonly endsAt: string }
  | { readonly kind: "paymentOverdue"; readonly subscription: SubscriptionInfo; readonly trial: TrialState }
  | { readonly kind: "expired"; readonly subscription: SubscriptionInfo };

/** Ödemesi alınamamış ama Stripe'ta süren aboneliğin durumları: erişim ek süreden sonra kapanır, abonelik bitmez. */
const unpaidSubscriptionStatuses: ReadonlySet<string> = new Set(["past_due", "unpaid"]);

/**
 * Denemenin şimdiki durumu: süresi dolduysa (`trialEndsAt <= now`) toplantı kalmış olsa da biter; toplantı kalmadıysa
 * biter; bitiş anı yoksa başlamamıştır. Saf fonksiyondur.
 */
export function trialState(me: Entitlements, now: Date): TrialState {
  const total: number = me.trialMeetingsTotal;
  if (me.trialEndsAt !== null && new Date(me.trialEndsAt).getTime() <= now.getTime()) {
    return { kind: "ended", reason: "timeExpired", total };
  }
  if (me.trialMeetingsLeft <= 0) {
    return { kind: "ended", reason: "meetingsUsed", total };
  }
  if (me.trialEndsAt === null) {
    return { kind: "notStarted", left: me.trialMeetingsLeft, total };
  }
  return { kind: "running", left: me.trialMeetingsLeft, total, endsAt: me.trialEndsAt };
}

/**
 * Hak yanıtından plan durumu (bkz. `PlanState`). Ücretsiz erişimde ödeme olmadığından ek süre ya da iptal uyarısı
 * yoktur. Ödemesi alınamamış abonelik deneme kalmış olsa da anlatılır; erişimi kapanmış başka abonelik yalnızca deneme
 * bittiyse. Saf fonksiyondur.
 */
export function planState(me: Entitlements, now: Date): PlanState {
  const trial: TrialState = trialState(me, now);
  const subscription: SubscriptionInfo | null = me.subscription;
  if (subscription === null) {
    return { kind: "trial", trial };
  }
  if (subscription.access !== "none") {
    if (subscription.complimentary) {
      return { kind: "complimentary", subscription, until: subscription.cancelAt };
    }
    if (subscription.access === "grace") {
      return { kind: "grace", subscription, endsAt: subscription.graceEndsAt };
    }
    if (subscription.cancelAt !== null) {
      return { kind: "ending", subscription, endsAt: subscription.cancelAt };
    }
    return { kind: "subscribed", subscription, renewsAt: subscription.currentPeriodEnd };
  }
  if (!subscription.complimentary && unpaidSubscriptionStatuses.has(subscription.status)) {
    return { kind: "paymentOverdue", subscription, trial };
  }
  if (trial.kind !== "ended") {
    return { kind: "trial", trial };
  }
  return subscription.complimentary ? { kind: "complimentaryEnded", subscription } : { kind: "expired", subscription };
}

/** Durum abonelik erişimi veriyor mu (aylık saat ve yapay zekâ ölçerleri yalnızca bunda görünür). Saf fonksiyondur. */
export function hasSubscriptionAccess(state: PlanState): boolean {
  switch (state.kind) {
    case "complimentary":
    case "subscribed":
    case "ending":
    case "grace":
      return true;
    case "trial":
    case "complimentaryEnded":
    case "paymentOverdue":
    case "expired":
      return false;
  }
}
