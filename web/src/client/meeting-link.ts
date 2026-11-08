// Toplantı bağlantısı sayfası (`/m/<kimlik>`): adresteki kimlik geçerliyse "Open in Gistsmith" düğmesi uygulamadaki
// toplantıyı açan adrese (`gistsmith://meeting/<kimlik>`) gider ve görünür. Kimlik yoksa ya da geçersizse düğme gizli
// kalır; sayfa toplantıyı uygulamada nasıl bulacağını söyler. Sunucuya istek atılmaz.
import { element } from "./dom";
import { appMeetingLink } from "../lib/app-links";

/** Sayfayı başlatır. */
function main(): void {
  const link: string | null = appMeetingLink(window.location.pathname);
  if (link === null) {
    return;
  }
  element("meeting-open", HTMLAnchorElement).href = link;
  element("meeting-open-box", HTMLElement).classList.remove("hidden");
}

main();
