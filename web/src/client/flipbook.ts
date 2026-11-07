// The footer's flip-book (FooterFlipbook.astro): as the band passes through the screen, scroll position picks a frame
// (late afternoon at the top, night at the bottom of the page) and the frame is drawn to the canvas.
// - Frames load only once the page has loaded and the band is within about a screen of the viewport.
// - Scroll is listened to only while the band is on screen; drawing happens at most once per animation frame and only
//   when the frame changes. Until a frame has loaded, the nearest loaded one is drawn.
// - With reduced motion nothing loads and the still frame stays (also when the preference turns on later).
import { element } from "./dom";

/** Start loading frames when the band is this close to the screen. */
const preloadMargin: string = "100% 0px";
/** The last frame shows when the band's top is this share of the screen height below the top (under the header). */
const endMarginShare: number = 0.12;
/** Canvas resolution cap (device pixels per CSS pixel). */
const maxPixelRatio: number = 2;

/** Part of a source image to draw so that it covers the target like `object-fit: cover`. */
interface SourceRect {
  readonly x: number;
  readonly y: number;
  readonly width: number;
  readonly height: number;
}

/** The centred crop of a `sourceWidth × sourceHeight` image that covers a target of the given aspect ratio. Pure function. */
function coverRect(sourceWidth: number, sourceHeight: number, targetAspect: number): SourceRect {
  const sourceAspect: number = sourceWidth / sourceHeight;
  if (sourceAspect > targetAspect) {
    const width: number = sourceHeight * targetAspect;
    return { x: (sourceWidth - width) / 2, y: 0, width, height: sourceHeight };
  }
  const height: number = sourceWidth / targetAspect;
  return { x: 0, y: (sourceHeight - height) / 2, width: sourceWidth, height };
}

/**
 * Scroll progress of the band (0…1): 0 when its top enters the bottom of the screen, 1 when its top is near the top of
 * the screen (the whole band still in view) or the page can scroll no further, whichever comes first (the footer is the
 * last thing on the page). Pure function.
 */
function scrollProgress(bandTop: number, scrollY: number, viewportHeight: number, maxScroll: number): number {
  const start: number = bandTop - viewportHeight;
  const end: number = Math.min(bandTop - viewportHeight * endMarginShare, maxScroll);
  if (end <= start) {
    return 1;
  }
  return Math.min(1, Math.max(0, (scrollY - start) / (end - start)));
}

/** Index of the loaded frame closest to `wanted`, or -1 if none has loaded. Pure function. */
function nearestLoaded(loaded: readonly boolean[], wanted: number): number {
  for (let distance: number = 0; distance < loaded.length; distance += 1) {
    if (loaded[wanted - distance] === true) {
      return wanted - distance;
    }
    if (loaded[wanted + distance] === true) {
      return wanted + distance;
    }
  }
  return -1;
}

/** Resolves once the page's `load` event has fired (frames never compete with the page's own resources). */
function afterLoad(): Promise<void> {
  if (document.readyState === "complete") {
    return Promise.resolve();
  }
  return new Promise<void>((resolve: () => void): void => {
    window.addEventListener("load", (): void => resolve(), { once: true });
  });
}

/** Binds the behaviour. */
function main(): void {
  const band: HTMLElement = element("flipbook", HTMLElement);
  const canvas: HTMLCanvasElement = element("flipbook-canvas", HTMLCanvasElement);
  const context: CanvasRenderingContext2D | null = canvas.getContext("2d", { alpha: false });
  const reducedMotion: MediaQueryList = window.matchMedia("(prefers-reduced-motion: reduce)");
  const urls: readonly string[] = (band.dataset["frames"] ?? "").split(" ").filter((url: string): boolean => url !== "");
  if (context === null || urls.length === 0 || reducedMotion.matches) {
    return;
  }
  const images: HTMLImageElement[] = [];
  const loaded: boolean[] = urls.map((): boolean => false);
  let drawnIndex: number = -1;
  let scheduled: boolean = false;
  let listening: boolean = false;
  let stopped: boolean = false;

  const resize = (): void => {
    const ratio: number = Math.min(window.devicePixelRatio || 1, maxPixelRatio);
    const width: number = Math.round(band.clientWidth * ratio);
    const height: number = Math.round(band.clientHeight * ratio);
    if (canvas.width !== width || canvas.height !== height) {
      canvas.width = width;
      canvas.height = height;
      drawnIndex = -1;
    }
  };

  const draw = (): void => {
    scheduled = false;
    if (stopped) {
      return;
    }
    const rect: DOMRect = band.getBoundingClientRect();
    const maxScroll: number = document.documentElement.scrollHeight - window.innerHeight;
    const progress: number = scrollProgress(rect.top + window.scrollY, window.scrollY, window.innerHeight, maxScroll);
    const index: number = nearestLoaded(loaded, Math.round(progress * (urls.length - 1)));
    const image: HTMLImageElement | undefined = images[index];
    if (index === drawnIndex || image === undefined) {
      return;
    }
    const source: SourceRect = coverRect(image.naturalWidth, image.naturalHeight, canvas.width / canvas.height);
    context.drawImage(image, source.x, source.y, source.width, source.height, 0, 0, canvas.width, canvas.height);
    drawnIndex = index;
    band.toggleAttribute("data-ready", true);
  };

  const schedule = (): void => {
    if (!scheduled) {
      scheduled = true;
      window.requestAnimationFrame(draw);
    }
  };

  const onResize = (): void => {
    resize();
    schedule();
  };

  const listen = (on: boolean): void => {
    if (on === listening) {
      return;
    }
    listening = on;
    if (on) {
      window.addEventListener("scroll", schedule, { passive: true });
      window.addEventListener("resize", onResize, { passive: true });
      onResize();
    } else {
      window.removeEventListener("scroll", schedule);
      window.removeEventListener("resize", onResize);
    }
  };

  const load = (): void => {
    urls.forEach((url: string, index: number): void => {
      const image: HTMLImageElement = new Image();
      image.decoding = "async";
      image.fetchPriority = "low";
      image.src = url;
      images[index] = image;
      image
        .decode()
        .then((): void => {
          loaded[index] = true;
          if (listening) {
            schedule();
          }
        })
        .catch((error: unknown): void => {
          console.warn("flipbook_frame_failed", { url, error: error instanceof Error ? error.message : String(error) });
        });
    });
  };

  // Loading: once, after the page's load event, when the band nears the screen.
  const nearby: IntersectionObserver = new IntersectionObserver(
    (entries: IntersectionObserverEntry[]): void => {
      if (entries.some((entry: IntersectionObserverEntry): boolean => entry.isIntersecting)) {
        nearby.disconnect();
        void afterLoad().then(load);
      }
    },
    { rootMargin: preloadMargin },
  );
  nearby.observe(band);

  // Drawing: only while the band is on screen.
  const visible: IntersectionObserver = new IntersectionObserver((entries: IntersectionObserverEntry[]): void => {
    for (const entry of entries) {
      listen(entry.isIntersecting && !stopped);
    }
  });
  visible.observe(band);

  // Reduced motion turned on later: stop and show the still frame again.
  reducedMotion.addEventListener("change", (event: MediaQueryListEvent): void => {
    if (event.matches) {
      stopped = true;
      listen(false);
      nearby.disconnect();
      visible.disconnect();
      band.toggleAttribute("data-ready", false);
    }
  });
}

main();
