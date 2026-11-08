// İndirme sayfası: yayınlanmış en son sürümün numarası sunucudan okunur (DMG ile aynı GitHub sürümündeki appcast;
// bkz. server/src/downloads.ts), böylece yeni sürüm çıkınca numara elle değiştirilmeden DMG ile birlikte güncellenir.
// Sürüm satırının yeri sayfada baştan ayrılmıştır (görünmez); okunamazsa öyle kalır ve hata konsola yazılır; indirme
// düğmesi numaradan bağımsız çalışır.
import { parseLatestVersion, send } from "./api";
import { element } from "./dom";

const versionPath: string = "/v1/download/mac/version";

/**
 * İndirme düğmesine basıldıktan sonra kurulum adımlarını görünür alana kaydırır: DMG indiğinde "şimdi ne yapacağım?"
 * sorusunun yanıtı sayfada kalır (üç adım zaten var; tıklamadan önce çoğu kişi aşağı kaydırmıyor).
 */
function revealInstallSteps(): void {
  const steps: HTMLElement | null = document.getElementById("install-steps");
  if (steps === null) {
    return;
  }
  const reduce: boolean = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  steps.scrollIntoView({ behavior: reduce ? "auto" : "smooth", block: "start" });
  steps.focus({ preventScroll: true });
}

const downloadButton: HTMLAnchorElement | null = document.querySelector<HTMLAnchorElement>("[data-mac-download]");
downloadButton?.addEventListener("click", revealInstallSteps);

/** Sürüm numarasını okuyup satırın değerine yazar ve satırı gösterir. */
async function main(): Promise<void> {
  const label: HTMLElement = element("download-version", HTMLElement);
  const value: HTMLElement = element("download-version-number", HTMLElement);
  const version: string = parseLatestVersion(
    await send({ method: "GET", path: versionPath, body: null, accessToken: null, attempts: 2 }),
    versionPath,
  );
  value.textContent = version;
  label.classList.remove("download-platform__pending");
  value.classList.remove("download-platform__pending");
}

main().catch((error: unknown): void => {
  console.error("download_version_failed", { path: versionPath, error: error instanceof Error ? error.message : String(error) });
});
