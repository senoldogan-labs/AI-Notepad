// Paylaşılan klasör daveti sayfası (`/j#<davet>.<sır>`): parça geçerliyse "Open in Gistsmith" düğmesi uygulamadaki
// katılma ekranını açan adrese (`gistsmith://join#<davet>.<sır>`) gider ve "Copy invite link" bağlantıyı kopyalar. Parça
// yoksa ya da bozuksa düğmeler gizli kalır ve sayfa bağlantının eksik olduğunu söyler. Sayfa hiçbir sunucuya istek atmaz;
// parça zaten tarayıcıdan çıkmaz.
import { element } from "./dom";
import { appJoinLink } from "../lib/app-links";

/** Sayfayı başlatır. */
function main(): void {
  const link: string | null = appJoinLink(window.location.hash);
  if (link === null) {
    element("join-incomplete", HTMLElement).classList.remove("hidden");
    return;
  }
  element("join-open", HTMLAnchorElement).href = link;
  element("join-open-box", HTMLElement).classList.remove("hidden");
  const copyButton: HTMLButtonElement = element("join-copy", HTMLButtonElement);
  copyButton.addEventListener("click", (): void => {
    void navigator.clipboard.writeText(window.location.href).then((): void => {
      copyButton.textContent = copyButton.dataset.copied ?? "";
    });
  });
}

main();
