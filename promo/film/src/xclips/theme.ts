import { field } from "../keyboardai/theme";

/**
 * Film field of the X clips: the Ember dark palette (the same warm black, copper and sand as the Keyboard film and
 * web/src/styles/global.css), the apps' own Olive dark screens sit inside it as real screenshots.
 */
export { field };

export const X_FPS = 30;
/** 16 seconds: hook, the feature, the result, end card. */
export const X_TOTAL = 480;
export const END_START = 390;

export type Format = "square" | "portrait";

/** Eased 0…1 ramp between two frames. Pure function. */
export const ramp = (frame: number, from: number, length: number): number => Math.min(Math.max((frame - from) / length, 0), 1);

/** Smooth ease for ramps. */
export const ease = (t: number): number => 1 - Math.pow(1 - t, 3);

export type RevealStep = { readonly at: number; readonly y: number };

/**
 * Where a progressive reveal has got to: starts at `steps[0].y` and moves to each next step's `y` over 14 frames from
 * its `at` frame, so a live transcript grows line by line. Pure function.
 */
export const stepReveal = (frame: number, steps: readonly RevealStep[]): number =>
  steps.reduce((y: number, step: RevealStep, index: number): number => (index === 0 ? step.y : y + (step.y - (steps[index - 1]?.y ?? step.y)) * ease(ramp(frame, step.at, 14))), 0);
