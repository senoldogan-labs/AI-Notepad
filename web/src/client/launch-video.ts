// Ana sayfadaki tanıtım videosu bir ürün çekimi gibi durur: oynatıcı düğmesi yok, sessiz ve döngülü. Bu betik videoyu
// yalnızca görünür alana girince oynatır, çıkınca ya da sekme gizlenince duraklatır (ekranda değilken çözümleme ve
// indirme yapılmaz). Hareket azaltılmışsa hiç oynatılmaz, kapak karesi görünür; tercih sonradan açılırsa video durur.
// Betik çalışmazsa da video kendiliğinden oynamaz (`autoplay` yok) ve kapak karesi kalır.
import { MissingElementError, element } from "./dom";

/** Videonun en az bu oranı görünürken oynar. */
const visibleRatio: number = 0.35;

/** Videoyu oynatır; tarayıcı kendiliğinden oynatmayı engellerse (ör. düşük güç kipi) kapak karesi kalır ve uyarı yazılır. */
function play(video: HTMLVideoElement): void {
  video.play().catch((error: unknown): void => {
    console.warn("launch_video_play_blocked", { error: error instanceof Error ? error.message : String(error) });
  });
}

/** Shows the pause/play button's state: "paused" after the visitor stopped the video, "playing" otherwise. */
function showToggleState(toggle: HTMLButtonElement, paused: boolean): void {
  const label: string | undefined = paused ? toggle.dataset["labelPlay"] : toggle.dataset["labelPause"];
  if (label === undefined) {
    throw new MissingElementError("#launch-video-toggle needs data-label-play and data-label-pause.");
  }
  toggle.dataset["state"] = paused ? "paused" : "playing";
  toggle.setAttribute("aria-label", label);
  toggle.title = label;
}

/** Davranışı bağlar. The pause/play button (shown unless motion is reduced) stops the video until pressed again. */
function main(): void {
  const video: HTMLVideoElement = element("launch-video", HTMLVideoElement);
  const toggle: HTMLButtonElement = element("launch-video-toggle", HTMLButtonElement);
  const reducedMotion: MediaQueryList = window.matchMedia("(prefers-reduced-motion: reduce)");
  // `muted` özniteliği yalnızca başlangıç değerini verir; sessiz oynatma kuralları özelliğe bakar.
  video.muted = true;
  let onScreen: boolean = false;
  let pausedByVisitor: boolean = false;

  const update = (): void => {
    toggle.hidden = reducedMotion.matches;
    if (onScreen && !document.hidden && !reducedMotion.matches && !pausedByVisitor) {
      play(video);
      return;
    }
    video.pause();
  };

  toggle.addEventListener("click", (): void => {
    pausedByVisitor = !pausedByVisitor;
    showToggleState(toggle, pausedByVisitor);
    update();
  });
  showToggleState(toggle, false);

  const observer: IntersectionObserver = new IntersectionObserver(
    (entries: IntersectionObserverEntry[]): void => {
      for (const entry of entries) {
        onScreen = entry.isIntersecting && entry.intersectionRatio >= visibleRatio;
      }
      update();
    },
    { threshold: [0, visibleRatio] },
  );
  observer.observe(video);
  document.addEventListener("visibilitychange", update);
  reducedMotion.addEventListener("change", update);
}

main();
