// The iPhone voice typing demo (PhoneVoiceTypingDemo.astro) is a pure CSS animation. This script, for every demo on the
// page:
// - pauses the animations while the demo is off screen or the tab is hidden (`data-paused`), so it starts where the
//   visitor first sees it and does no work out of view;
// - shows the button beside the phone: pause (`data-user-paused`), resume and, after the three loops (it rests on the
//   finished reply: `data-finished`), replay (WCAG 2.2.2). With reduced motion the button is hidden by CSS and the demo
//   shows the finished reply.
import { MissingElementError, dataValue } from "./dom";

/** The button's state: the demo plays, the visitor paused it, or it finished. */
type DemoState = "playing" | "paused" | "finished";

/** The last burst of words (`@keyframes pvt-burst-6`); its end ends the demo. */
const finishingAnimation: string = "pvt-burst-6";

/** Shows a state on the button: icon (`data-state`), accessible name and tooltip. */
function renderToggle(toggle: HTMLButtonElement, state: DemoState): void {
  const label: string = dataValue(toggle, state === "playing" ? "labelPause" : state === "paused" ? "labelPlay" : "labelReplay");
  toggle.dataset["state"] = state;
  toggle.setAttribute("aria-label", label);
  toggle.title = label;
}

/** Starts the animations over: they are dropped for one frame (`data-restart`). */
function restart(demo: HTMLElement): void {
  demo.toggleAttribute("data-restart", true);
  // Reading layout applies the removal; when the attribute goes, the animations start from zero.
  void demo.offsetWidth;
  demo.toggleAttribute("data-restart", false);
}

/** Binds one demo and its button. */
function bindDemo(demo: HTMLElement): void {
  const toggle: HTMLButtonElement | null | undefined = demo.parentElement?.querySelector<HTMLButtonElement>("[data-pvt-toggle]");
  if (toggle === null || toggle === undefined) {
    throw new MissingElementError("The iPhone voice typing demo needs its [data-pvt-toggle] button beside it.");
  }
  let onScreen: boolean = false;
  let state: DemoState = "playing";

  const updateVisibility = (): void => {
    demo.toggleAttribute("data-paused", !onScreen || document.hidden);
  };
  const setState = (next: DemoState): void => {
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
    if (event.animationName === finishingAnimation) {
      setState("finished");
    }
  });
  toggle.addEventListener("click", (): void => {
    if (state === "playing") {
      setState("paused");
    } else if (state === "paused") {
      setState("playing");
    } else {
      setState("playing");
      restart(demo);
    }
  });

  updateVisibility();
  setState("playing");
  toggle.hidden = false;
}

/** Binds every demo on the page; with reduced motion they stay on the finished reply. */
function main(): void {
  if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
    return;
  }
  for (const demo of document.querySelectorAll<HTMLElement>("[data-pvt-demo]")) {
    bindDemo(demo);
  }
}

main();
