// Hesap sayfasındaki ödeme eylemlerinin durumu (saf; DOM src/client/account.ts'te). Aynı anda tek eylem yürür: davet
// kodu doğrulanırken ya da Stripe oturumu (Checkout veya Portal) açılırken yeni eylem başlamaz, böylece iki Checkout
// oturumu açılamaz. Yönlendirme başlayınca sayfa kapanana kadar kilitli kalır; tarayıcı sayfayı geri/ileri önbellekten
// geri getirirse (`pageshow`, `persisted`) kilit açılır.

/** Ödeme eylemlerinin durumu. */
export type CheckoutState =
  | { readonly kind: "idle" }
  | { readonly kind: "validatingInvite" }
  /** Checkout ya da Portal oturumu isteniyor (abone olmadan önceki davet kodu doğrulaması da bu sürede yapılır). */
  | { readonly kind: "openingBilling" }
  | { readonly kind: "redirecting" };

/** Durumu değiştiren olay. */
export type CheckoutEvent =
  | { readonly type: "validateInvite" }
  | { readonly type: "openBilling" }
  /** Eylem yönlendirmeden bitti (başarılı doğrulama, hata ya da geçersiz kod). */
  | { readonly type: "settled" }
  | { readonly type: "redirect" }
  | { readonly type: "pageRestored" };

/** Sayfa açılınca. */
export const idleCheckout: CheckoutState = { kind: "idle" };

/** Olayın durumu nasıl değiştirdiği; olay bu durumda geçersizse null (eylem başlamaz). Saf fonksiyondur. */
export function checkoutTransition(state: CheckoutState, event: CheckoutEvent): CheckoutState | null {
  switch (event.type) {
    case "validateInvite":
      return state.kind === "idle" ? { kind: "validatingInvite" } : null;
    case "openBilling":
      return state.kind === "idle" ? { kind: "openingBilling" } : null;
    case "settled":
      return state.kind === "validatingInvite" || state.kind === "openingBilling" ? idleCheckout : null;
    case "redirect":
      return state.kind === "openingBilling" ? { kind: "redirecting" } : null;
    case "pageRestored":
      return idleCheckout;
  }
}

/** Ödeme düğmeleri (abone ol, davet kodu, abonelik yönetimi) kapalı mı. Saf fonksiyondur. */
export function checkoutControlsLocked(state: CheckoutState): boolean {
  return state.kind !== "idle";
}
