import { handleRequest } from "./app";
import { appleAppAttestationRootPem } from "./attest/appleRoot";
import { warnIfAccessCheckDisabled } from "./auth/access";
import { appleTokenIssuer } from "./auth/apple";
import { googleTokenIssuer } from "./auth/google";
import { refreshPersistedIssuerKeys } from "./auth/identityToken";
import { warnIfStripeTestMode } from "./billing";
import { cleanupExpiredRows, scheduledCleanupLimits } from "./cleanup";
import { type AssistantStorage, type Config, assistantStorageOf, parseConfig } from "./config";
import { recordDailyMetrics } from "./dailyMetrics";
import { settleDeepgramMeetings } from "./deepgram";
import { dailyElevenLabsCapacityCheck } from "./elevenLabsCapacity";
import type { Env } from "./env";
import { errorName, log } from "./log";
import { retryRecorder } from "./opsEvents";
import type { CachedJwks, Platform } from "./platform";
import { grantDueReferralRewards } from "./referralRewards";
import { phoneCleanup } from "./phone/calls";
import { sharedFolderCleanup } from "./sharedFolders";
import { scheduledSyncCleanupLimits, syncCleanup } from "./sync";
import { stubbedFetch, upstreamStubBase } from "./upstreamStub";
import { type AssistantCleanupReport, assistantCleanup, scheduledAssistantCleanupLimits } from "./assistant/cleanup";

/** Worker örneği ömrünce paylaşılan kimlik sağlayıcısı anahtarları önbelleği. */
const jwksCache: Map<string, CachedJwks> = new Map();

/**
 * Asistan kopyasının günlük temizliği; `ASSISTANT_POLICY` kapalıyken (bağlamalar yok) açıkça atlanır ve `info` loglanır
 * (null döner). Politika açılınca ilk çalışma, kapalıyken silinmiş hesapların kopyasını da siler (yetim denetimi).
 */
async function scheduledAssistantCleanup(env: Env, config: Config, now: Date): Promise<AssistantCleanupReport | null> {
  const storage: AssistantStorage | null = assistantStorageOf(env, config);
  if (storage === null) {
    log("info", "assistant_cleanup_skipped", { reason: "assistant_policy_off" });
    return null;
  }
  return assistantCleanup(storage.adb, env.DB, storage.bucket, config, now, scheduledAssistantCleanupLimits);
}

/**
 * Üretim platformu: gerçek fetch (yerel uçtan uca denemede üst servisler sahte yerel servise; bkz. `upstreamStubBase`),
 * saat, Apple App Attestation kökü, paylaşılan JWKS önbelleği ve ortamın D1'ine yazan yeniden deneme sayacı
 * (`retryRecorder`).
 */
function productionPlatform(db: D1Database, stubBase: string | null): Platform {
  const now = (): Date => new Date();
  const outbound: typeof fetch = (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => fetch(input, init);
  return {
    fetch: stubBase === null ? outbound : stubbedFetch(outbound, stubBase),
    now,
    appAttestRootPem: appleAppAttestationRootPem,
    retryBaseDelayMs: 300,
    jwksCache,
    recordRetry: retryRecorder(db, now),
  };
}

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    return handleRequest(request, env, {
      platform: productionPlatform(env.DB, upstreamStubBase(env)),
      waitUntil: (promise: Promise<void>): void => ctx.waitUntil(promise),
      // Cloudflare her istekte bu başlığı koyar; yerel geliştirmede yoktur.
      clientIp: request.headers.get("cf-connecting-ip") ?? "local",
      clientCountry: typeof request.cf?.country === "string" ? request.cf.country : null,
    });
  },
  /**
   * Günlük Cron Trigger: ElevenLabs kapasite denetimi (eşik üstündeyse alarm), bitirilmeden kalan toplantıların Deepgram
   * tahmininin indirilmesi, biten günün anlık görüntüsü (`recordDailyMetrics`), süresi dolmuş satırların ve eşitleme
   * kopyalarının temizliği,
   * günü gelmiş davet ödülleri ve Apple/Google anahtarlarının tazelenmesi.
   */
  async scheduled(controller: ScheduledController, env: Env): Promise<void> {
    const now: Date = new Date(controller.scheduledTime);
    const platform: Platform = productionPlatform(env.DB, upstreamStubBase(env));
    const config: Config = parseConfig(env);
    warnIfStripeTestMode(config, "scheduled");
    warnIfAccessCheckDisabled(config.access);
    // Adımlar birbirinden bağımsız: biri başarısız olsa da diğerleri çalışır; her hata `alert` yazılır, sonunda hepsi
    // birlikte fırlatılır (Cron çalışması başarısız görünsün).
    const steps: ReadonlyArray<{ name: string; run: () => Promise<unknown> }> = [
      { name: "elevenlabs_capacity", run: () => dailyElevenLabsCapacityCheck(env.DB, config, now) },
      { name: "deepgram_settle", run: () => settleDeepgramMeetings(env.DB, now) },
      // Deepgram tahmini indirildikten sonra: biten günün toplamları ve gün sonundaki durum (bkz. `dailyMetrics.ts`).
      { name: "daily_metrics", run: () => recordDailyMetrics(env.DB, config, now) },
      { name: "cleanup", run: () => cleanupExpiredRows(env.DB, now, scheduledCleanupLimits) },
      // Eşitleme: erişimi 90 gün önce biten hesapların şifreli kopyası ve silme kuyruğundaki R2 önekleri (bkz. `sync.ts`).
      // Shared folders: expired invites and folders of owners without access for 90 days; their R2 prefixes are queued
      // for the sync purge step right after (see `sharedFolders.ts`).
      { name: "shared_folder_cleanup", run: () => sharedFolderCleanup(env.DB, config, now, 50) },
      { name: "sync_cleanup", run: () => syncCleanup(env.DB, env.SYNC_BUCKET, config, now, scheduledSyncCleanupLimits) },
      // Yapay zekâ asistanı kopyası: erişimi biten hesabın kopyası 7 gün içinde, silinmiş hesabınki hemen; R2 kuyruğu
      // (bkz. `assistant/cleanup.ts`).
      // `ASSISTANT_POLICY` kapalıyken (üretimde AB D1'i oluşturulana kadar bağlama yoktur) adım açıkça atlanır.
      { name: "assistant_cleanup", run: () => scheduledAssistantCleanup(env, config, now) },
      // In-app dialer: unsettled calls past their reservation, unfetched recordings and queued provider deletions
      // (see `phone/calls.ts`); the provider steps are skipped while `PHONE_CALLS_POLICY` is off.
      { name: "phone_cleanup", run: () => phoneCleanup(env.DB, platform, config, now) },
      // Bekleme süresi dolmuş davet ödülleri (davet edenin Stripe müşteri bakiyesi; bkz. `referralRewards.ts`).
      { name: "referral_rewards", run: () => grantDueReferralRewards(env.DB, platform, config, now) },
      // Apple ve Google anahtarları önceden alınır: girişler sağlayıcıyı beklemesin (bkz. `persistedIssuerKeys`).
      { name: "apple_jwks", run: () => refreshPersistedIssuerKeys(env.DB, platform, appleTokenIssuer(config)) },
      { name: "google_jwks", run: () => refreshPersistedIssuerKeys(env.DB, platform, googleTokenIssuer(config)) },
    ];
    const failures: unknown[] = [];
    for (const step of steps) {
      try {
        await step.run();
      } catch (error: unknown) {
        log("alert", "scheduled_step_failed", { step: step.name, error: errorName(error) });
        failures.push(error);
      }
    }
    if (failures.length > 0) {
      throw new AggregateError(failures, `Zamanlanmış görevde ${failures.length} adım başarısız.`);
    }
  },
} satisfies ExportedHandler<Env>;
