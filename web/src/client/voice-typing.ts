// The voice typing page (src/pages/voice-typing.astro):
// - Hero demo (VoiceTypingDemo.astro, pure CSS animation): paused while off screen or in a hidden tab; the corner button
//   pauses, resumes and, after the three loops, replays it (WCAG 2.2.2).
// - Speed comparison: the same passage written at a typical speaking and a typical typing rate, sped up. It starts
//   when it scrolls into view, runs only while on screen, and its button pauses, resumes or replays it. Without the
//   script, or with reduced motion, the finished state shows (all words, final times) and nothing moves.
import { MissingElementError, dataValue, element } from "./dom";

/** A demo's button state. */
type PlayState = "playing" | "paused" | "finished";

/** The hero demo's longest animation (VoiceTypingDemo.astro `@keyframes vt-typed`); its end ends the demo. */
const demoFinishingAnimation: string = "vt-typed";
/** Share of the comparison that must be visible before it starts. */
const raceStartRatio: number = 0.4;

/** Shows a play state on a toggle button: icon (`data-state`), accessible name and tooltip. */
function renderToggle(toggle: HTMLButtonElement, state: PlayState): void {
  const label: string = dataValue(toggle, state === "playing" ? "labelPause" : state === "paused" ? "labelPlay" : "labelReplay");
  toggle.dataset["state"] = state;
  toggle.setAttribute("aria-label", label);
  toggle.title = label;
}

/** `m:ss` for a number of seconds (rounded down). Pure function. */
function clock(seconds: number): string {
  const whole: number = Math.floor(seconds);
  return `${Math.floor(whole / 60)}:${String(whole % 60).padStart(2, "0")}`;
}

/** Binds the hero demo. */
function bindDemo(): void {
  const demo: HTMLElement = element("vt-demo", HTMLElement);
  const toggle: HTMLButtonElement = element("vt-demo-toggle", HTMLButtonElement);
  let onScreen: boolean = true;
  let state: PlayState = "playing";
  const updateVisibility = (): void => {
    demo.toggleAttribute("data-paused", !onScreen || document.hidden);
  };
  const setState = (next: PlayState): void => {
    state = next;
    demo.toggleAttribute("data-user-paused", next === "paused");
    demo.toggleAttribute("data-finished", next === "finished");
    renderToggle(toggle, next);
  };
  new IntersectionObserver((entries: IntersectionObserverEntry[]): void => {
    for (const entry of entries) {
      onScreen = entry.isIntersecting;
    }
    updateVisibility();
  }).observe(demo);
  document.addEventListener("visibilitychange", updateVisibility);
  demo.addEventListener("animationend", (event: AnimationEvent): void => {
    if (event.animationName === demoFinishingAnimation) {
      setState("finished");
    }
  });
  toggle.addEventListener("click", (): void => {
    if (state === "playing") {
      setState("paused");
      return;
    }
    if (state === "finished") {
      // Restart: drop the animations for one frame (reading layout applies the removal).
      demo.toggleAttribute("data-restart", true);
      void demo.offsetWidth;
      demo.toggleAttribute("data-restart", false);
    }
    setState("playing");
  });
  updateVisibility();
  setState("playing");
  toggle.hidden = false;
}

/** One lane of the comparison. */
interface Lane {
  /** Seconds the passage takes at this lane's rate. */
  readonly seconds: number;
  readonly words: readonly HTMLElement[];
  readonly time: HTMLElement;
  readonly fill: HTMLElement;
  /** Words currently shown. */
  shown: number;
}

/** Reads a lane from the page. */
function readLane(node: HTMLElement): Lane {
  const seconds: number = Number(dataValue(node, "seconds"));
  const time: HTMLElement | null = node.querySelector<HTMLElement>("[data-time]");
  const fill: HTMLElement | null = node.querySelector<HTMLElement>("[data-fill]");
  if (!Number.isFinite(seconds) || seconds <= 0 || time === null || fill === null) {
    throw new MissingElementError("A comparison lane needs data-seconds, [data-time] and [data-fill].");
  }
  return { seconds, words: [...node.querySelectorAll<HTMLElement>("[data-word]")], time, fill, shown: -1 };
}

/** Draws a lane at `elapsed` simulated seconds. */
function drawLane(lane: Lane, elapsed: number): void {
  const progress: number = Math.min(1, elapsed / lane.seconds);
  const shown: number = Math.floor(progress * lane.words.length);
  if (shown !== lane.shown) {
    lane.words.forEach((word: HTMLElement, index: number): void => {
      word.classList.toggle("is-pending", index >= shown);
    });
    lane.shown = shown;
  }
  lane.time.textContent = clock(Math.min(elapsed, lane.seconds));
  lane.fill.style.transform = `scaleX(${progress})`;
}

/** Binds the speed comparison. */
function bindRace(): void {
  const race: HTMLElement = element("vt-race", HTMLElement);
  const toggle: HTMLButtonElement = element("vt-race-toggle", HTMLButtonElement);
  const speed: number = Number(dataValue(race, "speed"));
  const lanes: readonly Lane[] = [...race.querySelectorAll<HTMLElement>("[data-lane]")].map(readLane);
  const total: number = Math.max(...lanes.map((lane: Lane): number => lane.seconds));
  let elapsed: number = 0;
  let state: PlayState = "paused";
  let started: boolean = false;
  let onScreen: boolean = false;
  let lastTick: number | null = null;
  let frame: number | null = null;

  const draw = (): void => {
    for (const lane of lanes) {
      drawLane(lane, elapsed);
    }
  };
  const stop = (): void => {
    if (frame !== null) {
      window.cancelAnimationFrame(frame);
      frame = null;
    }
    lastTick = null;
  };
  const tick = (now: number): void => {
    elapsed = Math.min(total, elapsed + (lastTick === null ? 0 : ((now - lastTick) / 1000) * speed));
    lastTick = now;
    draw();
    if (elapsed >= total) {
      frame = null;
      setState("finished");
      return;
    }
    frame = window.requestAnimationFrame(tick);
  };
  const run = (): void => {
    if (frame === null && state === "playing" && onScreen && !document.hidden) {
      frame = window.requestAnimationFrame(tick);
    }
  };
  function setState(next: PlayState): void {
    state = next;
    race.toggleAttribute("data-running", next === "playing");
    renderToggle(toggle, next);
    if (next === "playing") {
      run();
    } else {
      stop();
    }
  }

  new IntersectionObserver(
    (entries: IntersectionObserverEntry[]): void => {
      let visibleEnough: boolean = false;
      for (const entry of entries) {
        onScreen = entry.isIntersecting;
        visibleEnough = entry.intersectionRatio >= raceStartRatio;
      }
      if (visibleEnough && !started) {
        started = true;
        elapsed = 0;
        draw();
        setState("playing");
      } else if (onScreen && started) {
        run();
      } else {
        stop();
      }
    },
    { threshold: raceStartRatio },
  ).observe(race);
  document.addEventListener("visibilitychange", (): void => {
    if (document.hidden) {
      stop();
    } else {
      run();
    }
  });
  toggle.addEventListener("click", (): void => {
    if (state === "playing") {
      setState("paused");
      return;
    }
    if (state === "finished" || !started) {
      started = true;
      elapsed = 0;
      draw();
    }
    setState("playing");
  });
  renderToggle(toggle, "paused");
  toggle.hidden = false;
}

/** Binds the page's behaviour; with reduced motion everything stays in its finished state. */
function main(): void {
  if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
    return;
  }
  bindDemo();
  bindRace();
}

main();
