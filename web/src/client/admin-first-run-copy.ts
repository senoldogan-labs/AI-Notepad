// Yönetim panelinin ilk açılış hunisi metinleri (İngilizce; yalnızca yönetici görür): "Growth" görünümündeki tablo
// (indirmeden uygulamada girişe adımlar) ve iki günlük grafik. Sayfa (admin.astro) ve betik (admin-insights.ts) aynı
// nesneyi kullanır; DOM'a dokunmaz.
import type { FirstRunStep } from "./admin-api";

/** İlk açılış hunisi metinleri. `{ad}` yer tutucuları değerlerle doldurulur. */
export interface AdminFirstRunCopy {
  readonly title: string;
  readonly hint: string;
  readonly columns: { readonly step: string; readonly count: string; readonly rate: string };
  /** İndirme satırı (sunucunun indirme sayacı, ilk adım). */
  readonly downloads: string;
  readonly steps: Readonly<Record<FirstRunStep, string>>;
  /** Ayrıntının adı: sağlayıcı ya da başarısızlık aşaması. */
  readonly details: Readonly<Record<string, string>>;
  /** Ayrıntılı satırın adı (`{step}`, `{detail}`). */
  readonly stepWithDetail: string;
  readonly charts: { readonly firstLaunches: string; readonly signedIn: string };
}

export const adminFirstRunCopy: AdminFirstRunCopy = {
  title: "From download to sign-in, last 30 days",
  hint:
    "Sent by the Mac app only when anonymous usage statistics are on, so app counts are a floor. Rates: first launches against downloads, " +
    "sign-in starts against first launches, closed windows and sign-ins against starts with the same provider, failures against all starts.",
  columns: { step: "Step", count: "Count", rate: "Rate" },
  downloads: "Downloads",
  steps: {
    first_launch: "First launches",
    sign_in_started: "Sign-in started",
    sign_in_canceled: "Sign-in window closed",
    sign_in_failed: "Sign-in failed",
    signed_in: "Signed in",
  },
  details: {
    apple: "Apple",
    google: "Google",
    window: "window didn't open",
    callback: "return rejected",
    server: "server refused",
    network: "network error",
  },
  stepWithDetail: "{step} · {detail}",
  charts: { firstLaunches: "First launches per day", signedIn: "Sign-ins from the app per day" },
};
