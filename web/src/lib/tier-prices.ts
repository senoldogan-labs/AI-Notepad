// Katmanların fiyatları (sent, ABD doları, vergiler dahil; sunucunun Stripe fiyatları ve uygulamalardaki
// `hostedPlanPriceCents` ile aynı). Ayrı bir dosyadadır: sitenin her sayfasının yüklediği ortak betik parçası
// (src/lib/plans.ts) Pro'nun fiyatını taşımasın. Yalnızca derleme (copy.ts), hesap sayfası ve Pro sunulunca yüklenen
// parça (src/lib/pro-copy.ts) içe aktarır.
import type { SubscriptionTier, TierPrices } from "./plans";

/** Katmanların fiyatları. */
export const tierPrices: Readonly<Record<SubscriptionTier, TierPrices>> = {
  personal: { monthlyCents: 599, yearlyCents: 4900 },
  pro: { monthlyCents: 1299, yearlyCents: 10900 },
};
