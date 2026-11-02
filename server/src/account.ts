import { type AppStoreSubscription, appStoreAccess, appStoreManageUrl, appStorePaidSql, appStoreSubscriptionOf } from "./appStore";
import { closeStripeForDeletion } from "./billing";
import type { Config } from "./config";
import { log } from "./log";
import type { Platform } from "./platform";
import { paidSubscriptionSql } from "./admin";
import { referralDeletionStatements } from "./referrals";
import { revenueDeletionStatement } from "./revenue";
import { userReservationRemovalStatements } from "./reservations";
import { ledgerOnDeletionStatement, trialIdentityHash } from "./trialLedger";
import type { IdentityProvider } from "./auth/users";
import { dayKey } from "./usage";

/** Hesabın giriş kimliği. */
interface StoredIdentity {
  readonly provider: IdentityProvider;
  readonly subject: string;
}

/**
 * Hesap silme sayacı (`ops_events` türü `account_deleted`; hesap satırları silinmeden, aynı toplu işlemde): ayrıntı
 * hesabın kesimidir — ödenmiş aboneliği (Stripe ya da App Store) olduysa `subscriber`, denemeye başladıysa `trial`, değilse `signup`. Hesap
 * yoksa (yinelenen silme) yazılmaz. Kullanıcı tutmaz.
 */
function accountDeletedCounterStatement(db: D1Database, userId: string, now: Date): D1PreparedStatement {
  return db
    .prepare(
      `INSERT INTO ops_events (day, kind, detail, count)
       SELECT ?1, 'account_deleted',
         CASE WHEN EXISTS (SELECT 1 FROM subscriptions s WHERE s.user_id = u.id AND ${paidSubscriptionSql}) OR ${appStorePaidSql("u.id")} THEN 'subscriber'
           WHEN u.trial_started_at IS NOT NULL THEN 'trial' ELSE 'signup' END, 1
       FROM users u WHERE u.id = ?2
       ON CONFLICT(day, kind, detail) DO UPDATE SET count = count + 1`,
    )
    .bind(dayKey(now), userId);
}

/**
 * Hesabın tüm satırlarını tek D1 toplu işleminde (tek işlem; yarıda kalmaz) silen ifadeler. Sıra yabancı anahtarlara
 * göredir (önce çocuk satırlar). Oturum aileleri ve yenileme jetonları silinir: hesabın tüm erişim ve yenileme
 * jetonları hemen geçersizdir. Kötüye kullanım sayaçları hesap bağı olmadan kalır:
 * - her giriş kimliğinin deneme defteri satırına (`trial_identity_ledger`, kimliğin HMAC özeti `identityHashes`)
 *   hesabın harcadığı deneme sayısı ve cihaz doğrulaması yazılır (satırlar silinmeden önce, aynı işlemde): aynı
 *   kimlikle yeniden açılan hesap yeni deneme almaz. Hiç deneme harcamamış hesap için satır yazılmaz; satır son
 *   güncellemeden 730 gün sonra silinir (`cleanup.ts`);
 * - bugünkü deneme başlangıcı IP özeti başına günlük sayaca (`deleted_trial_starts`) eklenir; silip yeniden açarak IP
 *   başına günlük deneme sınırı aşılamaz;
 * - hesabın kaydettiği cihazları başka hesapların toplantıları da göstermiş olabilir: o toplantıların cihaz bağı
 *   kaldırılır (cihaz başına deneme sayacı App Attest anahtarı başınadır ve yeni anahtar her zaman üretilebilir; bu,
 *   o sınırı mevcut durumdan daha fazla zayıflatmaz).
 * Hesaba bağlı raporlar (geri bildirim, çökme) bağı kaldırılarak değil, silinerek gider: serbest metin, e-posta ve
 * çökme yükü kişisel veri taşıyabilir; silme hakkı bunları kapsar. Jetonsuz gönderilmiş raporlar (site iletişim formu)
 * hesaba bağlanamaz ve 180 günlük saklama süresiyle silinir. Abonelik iptal nedenleri (`subscription_cancellations`;
 * serbest yorum içerebilir) de silinir. Davet: kodu ve abonelik açmamış davet satırı silinir; davetle abone olduysa
 * satırın hesap bağı kaldırılır, kimlik özeti kalır (aynı kimlik ikinci kez davet indirimi alamaz; 730 gün); davet
 * ettiklerinin satırlarında davet eden bağı kaldırılır, bekleyen ödülleri düşer (`referralDeletionStatements`).
 * Süren ayırmaların tahmini maliyeti silinmeden günlük harcamaya yazılır (`userReservationRemovalStatements`): silme
 * sırasında süren çağrı kesinleşirken yabancı anahtar hatası almaz, harcama da kaybolmaz.
 * Silme, "Sorunlar" sayacına hesabın kesimiyle sayılır (`accountDeletedCounterStatement`). Gelir satırları
 * (`revenue_invoices`; muhasebe kaydı) kalır, hesap bağı kaldırılır (`revenueDeletionStatement`).
 * App Store aboneliğinin satırı (`app_store_subscriptions`) silinir; abonelik Apple'da sürer (bkz. `deleteAccount`).
 * `daily_spend` (toplam, kişisel değil), `downloads`, `download_sources`, `download_visitors`, `ops_events`,
 * `used_nonces`, `stripe_events` ve telemetri toplamları (`llm_purpose_usage`, `client_event_counts`,
 * `client_event_durations`, `feature_usage_daily`, `app_funnel_daily`) hesaba bağlı değildir; hesabın son uygulama ve
 * macOS sürümü ile telemetri sayaçları `users` satırıyla silinir.
 */
function accountDeletionStatements(db: D1Database, userId: string, identityHashes: readonly string[], now: Date): D1PreparedStatement[] {
  return [
    accountDeletedCounterStatement(db, userId, now),
    revenueDeletionStatement(db, userId),
    ...identityHashes.map((identityHash: string): D1PreparedStatement => ledgerOnDeletionStatement(db, identityHash, userId, now)),
    db
      .prepare(
        `INSERT INTO deleted_trial_starts (ip_hash, day, accounts)
         SELECT ip_hash, day, 1 FROM trial_starts WHERE user_id = ? AND day = ?
         ON CONFLICT(ip_hash, day) DO UPDATE SET accounts = accounts + 1`,
      )
      .bind(userId, dayKey(now)),
    db.prepare("DELETE FROM trial_starts WHERE user_id = ?").bind(userId),
    db.prepare("DELETE FROM reports WHERE user_id = ?").bind(userId),
    db.prepare("DELETE FROM subscription_cancellations WHERE user_id = ?").bind(userId),
    ...referralDeletionStatements(db, userId, now.getTime()),
    db.prepare("DELETE FROM auth_identities WHERE user_id = ?").bind(userId),
    db.prepare("DELETE FROM refresh_tokens WHERE family_id IN (SELECT id FROM refresh_families WHERE user_id = ?)").bind(userId),
    db.prepare("DELETE FROM refresh_families WHERE user_id = ?").bind(userId),
    db.prepare("DELETE FROM device_challenges WHERE user_id = ?").bind(userId),
    db.prepare("DELETE FROM transcription_results WHERE user_id = ?").bind(userId),
    ...userReservationRemovalStatements(db, userId),
    db.prepare("DELETE FROM meeting_sessions WHERE user_id = ?").bind(userId),
    db
      .prepare("UPDATE meeting_sessions SET device_id = NULL WHERE device_id IN (SELECT id FROM devices WHERE attested_by_user_id = ?)")
      .bind(userId),
    db.prepare("DELETE FROM devices WHERE attested_by_user_id = ?").bind(userId),
    db.prepare("DELETE FROM monthly_usage WHERE user_id = ?").bind(userId),
    db.prepare("DELETE FROM daily_usage WHERE user_id = ?").bind(userId),
    db.prepare("DELETE FROM subscriptions WHERE user_id = ?").bind(userId),
    db.prepare("DELETE FROM app_store_subscriptions WHERE user_id = ?").bind(userId),
    db.prepare("DELETE FROM stripe_customers WHERE user_id = ?").bind(userId),
    db.prepare("DELETE FROM users WHERE id = ?").bind(userId),
  ];
}

/**
 * Silinen hesabın App Store aboneliği (`DELETE /v1/me` yanıtı): Apple aboneliği hesapla birlikte iptal edilemez (yalnızca
 * kullanıcı Apple'da iptal edebilir); erişimi süren abonelik yenilenmeye devam eder. İstemci kullanıcıya iptal etmesini
 * söyler ve `manageUrl`'yi açabilir. Erişimi süren App Store aboneliği yoksa null.
 */
export interface DeletedAppStoreSubscription {
  /** Dönem sonunda Apple yeniden ücretlendirecek mi (kullanıcı iptal etmediyse true). */
  readonly willRenew: boolean;
  /** Dönem sonu (ISO 8601). */
  readonly expiresAt: string;
  readonly manageUrl: string;
}

/** `DELETE /v1/me` yanıtı. */
export interface AccountDeletion {
  readonly deleted: true;
  readonly appStoreSubscription: DeletedAppStoreSubscription | null;
  /** Kullanıcıya gösterilecek İngilizce uyarı (App Store aboneliği sürüyorsa); yoksa null. */
  readonly notice: string | null;
}

/** App Store aboneliği süren hesabın silme uyarısı. */
export const appStoreDeletionNotice: string =
  "Your account is deleted, but your App Store subscription isn't canceled. Apple keeps billing it until you cancel it on your iPhone in Settings › your name › Subscriptions.";

/** Silme yanıtı: erişimi süren App Store aboneliği varsa iptal uyarısıyla. Saf fonksiyondur. */
export function accountDeletionResult(subscription: AppStoreSubscription | null, acceptSandbox: boolean, now: Date): AccountDeletion {
  if (subscription === null || appStoreAccess(subscription, acceptSandbox, now) === "none") {
    return { deleted: true, appStoreSubscription: null, notice: null };
  }
  return {
    deleted: true,
    appStoreSubscription: { willRenew: subscription.status === "active", expiresAt: new Date(subscription.expiresAt).toISOString(), manageUrl: appStoreManageUrl },
    notice: appStoreDeletionNotice,
  };
}

/**
 * Hesabı siler (GDPR silme hakkı). Önce Stripe'taki açık Checkout oturumları sona erdirilir ve bitmemiş abonelikler
 * hemen iptal edilir (yeniden denemeyle; `closeStripeForDeletion`);
 * Stripe başarısız olursa hiçbir satır silinmez ve istemci yeniden dener. Sonra hesabın tüm satırları tek işlemde
 * silinir; kimliklerin deneme defteri aynı işlemde önce yazılır. Tekrar çağrı güvenlidir: iptal edilmiş abonelik atlanır, olmayan satır silinmez. Stripe'taki müşteri ve
 * faturalar vergi kayıtları için Stripe'ta kalır; sunucuda onları bu hesaba bağlayan satır kalmaz. App Store aboneliği
 * iptal edilemez (Apple yalnızca kullanıcıya izin verir): silme yine yapılır, yanıt kullanıcıya iptal etmesini söyler
 * (`accountDeletionResult`). RevenueCat'teki satın alma kaydı (bu hesap kimliğiyle) Apple aboneliği sürdükçe orada
 * kalır; sonraki yenilemeler webhook'ta bilinmeyen hesap olarak sayılır.
 */
export async function deleteAccount(db: D1Database, platform: Platform, config: Config, userId: string, now: Date): Promise<AccountDeletion> {
  const canceledSubscriptions: number = await closeStripeForDeletion(db, platform, config, userId);
  const appStore: AppStoreSubscription | null = await appStoreSubscriptionOf(db, userId);
  const result: AccountDeletion = accountDeletionResult(appStore, config.appStore.acceptSandbox, now);
  const identities: D1Result<StoredIdentity> = await db
    .prepare("SELECT provider, subject FROM auth_identities WHERE user_id = ?")
    .bind(userId)
    .all<StoredIdentity>();
  const identityHashes: string[] = await Promise.all(
    identities.results.map((identity: StoredIdentity): Promise<string> => trialIdentityHash(config.secrets.trialHash, identity.provider, identity.subject)),
  );
  await db.batch(accountDeletionStatements(db, userId, identityHashes, now));
  log("info", "account_deleted", { userId, canceledSubscriptions, appStoreSubscriptionActive: result.appStoreSubscription !== null });
  return result;
}
