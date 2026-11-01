// İndirme düğmesinin cihaz denetimi (src/components/MacOnlyDialog.astro). Sayfa açılınca cihaz sınıflanır; `data-mac-download`
// bağlantısına tıklanınca cihaz Mac değilse, Intel Mac ise ya da macOS 15'ten eskiyse indirme yerine pencere açılır.
// Sınıflama bitmeden tıklanırsa ya da cihaz bilinemiyorsa (Safari işlemciyi ve sürümü bildirmez) indirme olduğu gibi
// başlar: denetim yalnızca kesin bilinen durumda araya girer.
import { fill } from "./copy";
import { element } from "./dom";

/** Cihazın Gistsmith'i çalıştırıp çalıştıramayacağı. */
export type MacSupport =
  | { readonly kind: "supported" }
  | { readonly kind: "not-mac" }
  | { readonly kind: "intel" }
  | { readonly kind: "old-macos"; readonly version: string };

/** Uygulamanın istediği en eski macOS ana sürümü (project.yml `deploymentTarget`). */
const minimumMacosMajor: number = 15;

/**
 * Tarayıcının kimlik metnine ve dokunma noktası sayısına göre Mac mi. iPadOS Safari masaüstü kipinde kendini Mac olarak
 * tanıtır; dokunmatik ekranı (birden çok dokunma noktası) onu ayırır. Saf fonksiyondur.
 */
export function isMacBrowser(userAgent: string, maxTouchPoints: number): boolean {
  if (/iPhone|iPad|iPod|Android/i.test(userAgent)) {
    return false;
  }
  return /Macintosh|Mac OS X/.test(userAgent) && maxTouchPoints <= 1;
}

/**
 * Chromium'un bildirdiği işlemci ve macOS sürümünden destek durumu: "x86" Intel, ana sürümü 15'ten küçükse eski macOS.
 * Değer yoksa ya da okunamıyorsa desteklenir sayılır (bilinmeyen durumda indirme engellenmez). Saf fonksiyondur.
 */
export function macSupportFromHints(hints: NavigatorUAHighEntropy): MacSupport {
  if (hints.architecture === "x86") {
    return { kind: "intel" };
  }
  const major: number = Number.parseInt((hints.platformVersion ?? "").split(".")[0] ?? "", 10);
  if (Number.isInteger(major) && major > 0 && major < minimumMacosMajor) {
    return { kind: "old-macos", version: hints.platformVersion ?? String(major) };
  }
  return { kind: "supported" };
}

/** Bu cihazın destek durumu; Chromium dışında Mac'te her zaman `supported`. İpuçları okunamazsa hata konsola yazılır. */
async function detectSupport(): Promise<MacSupport> {
  if (!isMacBrowser(navigator.userAgent, navigator.maxTouchPoints)) {
    return { kind: "not-mac" };
  }
  const uaData: NavigatorUAData | undefined = navigator.userAgentData;
  if (uaData === undefined) {
    return { kind: "supported" };
  }
  try {
    return macSupportFromHints(await uaData.getHighEntropyValues(["architecture", "platformVersion"]));
  } catch (error: unknown) {
    console.error("mac_support_hints_failed", { error: error instanceof Error ? error.message : String(error) });
    return { kind: "supported" };
  }
}

/** Pencereyi cihazın durumuna göre doldurup açar; `href` "Yine de indir" bağlantısına yazılır. */
function openDialog(dialog: HTMLDialogElement, support: Exclude<MacSupport, { kind: "supported" }>, href: string): void {
  for (const part of dialog.querySelectorAll<HTMLElement>("[data-mac-only-show]")) {
    part.hidden = !(part.dataset["macOnlyShow"] ?? "").split(" ").includes(support.kind);
  }
  const template: HTMLElement | null = dialog.querySelector<HTMLElement>("[data-mac-only-template]");
  if (template !== null && support.kind === "old-macos") {
    template.textContent = fill(template.dataset["macOnlyTemplate"] ?? "", { version: support.version });
  }
  const anyway: HTMLAnchorElement | null = dialog.querySelector<HTMLAnchorElement>("[data-mac-only-anyway]");
  if (anyway !== null) {
    anyway.href = href;
  }
  const status: HTMLElement | null = dialog.querySelector<HTMLElement>(".mac-only__status");
  if (status !== null) {
    status.textContent = "";
  }
  dialog.showModal();
}

/** Kopyala ve paylaş düğmelerini bağlar; paylaşım yalnızca tarayıcı destekliyorsa görünür. */
function bindSendButtons(dialog: HTMLDialogElement, shareUrl: string): void {
  const status: HTMLElement | null = dialog.querySelector<HTMLElement>(".mac-only__status");
  const copyButton: HTMLButtonElement | null = dialog.querySelector<HTMLButtonElement>("[data-mac-only-copy]");
  copyButton?.addEventListener("click", (): void => {
    navigator.clipboard.writeText(shareUrl).then(
      (): void => {
        if (status !== null) {
          status.textContent = copyButton.dataset["copied"] ?? "";
        }
      },
      (error: unknown): void => {
        console.error("mac_only_copy_failed", { error: error instanceof Error ? error.message : String(error) });
        if (status !== null) {
          status.textContent = copyButton.dataset["copyFailed"] ?? "";
        }
      },
    );
  });
  const shareButton: HTMLButtonElement | null = dialog.querySelector<HTMLButtonElement>("[data-mac-only-share]");
  if (shareButton !== null && typeof navigator.share === "function") {
    shareButton.hidden = false;
    shareButton.addEventListener("click", (): void => {
      navigator.share({ url: shareUrl }).catch((error: unknown): void => {
        // Kullanıcı paylaşım sayfasını kapatırsa AbortError gelir; bu bir hata değildir.
        if (!(error instanceof DOMException && error.name === "AbortError")) {
          console.error("mac_only_share_failed", { error: error instanceof Error ? error.message : String(error) });
        }
      });
    });
  }
}

function main(): void {
  const dialog: HTMLDialogElement = element("mac-only", HTMLDialogElement);
  const shareUrl: string = dialog.dataset["shareUrl"] ?? "";
  bindSendButtons(dialog, shareUrl);
  let support: MacSupport = { kind: "supported" };
  detectSupport().then((detected: MacSupport): void => {
    support = detected;
  });
  for (const link of document.querySelectorAll<HTMLAnchorElement>("a[data-mac-download]")) {
    link.addEventListener("click", (event: MouseEvent): void => {
      if (support.kind === "supported") {
        return;
      }
      event.preventDefault();
      openDialog(dialog, support, link.href);
    });
  }
}

main();
