/**
 * The keyboard's voice field, ported line for line from KeyboardCore's KeyboardParticles.swift (the black-hole field:
 * particles fall toward a singularity beside Done, accelerate, and about a third stretch into streaks with the voice),
 * so the film draws exactly what the app draws (including the longer streaks of fix/keyboard-field-glow). Pure functions.
 */
export const PARTICLE_COUNT = 84;

export type Particle = {
  readonly x: number;
  readonly y: number;
  readonly tailX: number;
  readonly tailY: number;
  /** Radius relative to the field's height. */
  readonly radius: number;
  readonly opacity: number;
};

export type ParticleMotion = "listening" | "processing";

const clamp01 = (value: number): number => Math.min(1, Math.max(0, value));

/** `keyboardParticleEnergy`: normal speech already reads as strong. */
export const particleEnergy = (level: number): number => Math.pow(clamp01(level), 0.7);

/** `keyboardParticleSpeed`: cycles per second. */
export const particleSpeed = (motion: ParticleMotion, level: number): number =>
  motion === "listening" ? 0.08 + 1.5 * particleEnergy(level) : 0.035;

/** `keyboardParticleNoise`: a stable pseudo-random value in 0..<1. */
const noise = (index: number, salt: number): number => {
  const value: number = Math.sin(index * 12.9898 + salt * 78.233) * 43758.5453;
  return value - Math.floor(value);
};

/** `keyboardParticlePath`. */
const path = (progress: number, startY: number, swirl: number): { readonly x: number; readonly y: number } => {
  const x: number = Math.pow(progress, 1.9);
  const closeness: number = Math.pow(1 - x, 1.3);
  const y: number = 0.5 + (startY - 0.5) * closeness + 0.05 * closeness * Math.sin(progress * 9 + swirl * 6.283);
  return { x, y };
};

/** `keyboardParticle`. */
export const particle = (index: number, count: number, travel: number, level: number, time: number): Particle => {
  const seedX: number = noise(index, 1);
  const seedY: number = noise(index, 2);
  const seedSpeed: number = noise(index, 3);
  const seedSize: number = noise(index, 4);
  const seedTwinkle: number = noise(index, 5);
  const seedKind: number = noise(index, 6);
  const energy: number = particleEnergy(level);
  const cycle: number = (seedX + travel * (0.6 + 0.8 * seedSpeed)) % 1;
  const progress: number = cycle < 0 ? cycle + 1 : cycle;
  const startY: number = 0.1 + 0.8 * seedY;
  const head = path(progress, startY, seedTwinkle);
  const lag: number = seedKind > 0.6 ? (0.06 + 0.16 * energy) * Math.min(1, energy * 1.6) * (0.7 + 0.6 * seedSpeed) : 0;
  const tail = lag > 0 ? path(Math.max(0, progress - lag), startY, seedTwinkle) : head;
  const envelope: number = Math.sin(Math.PI * progress);
  const twinkle: number = 0.7 + 0.3 * Math.sin(time * (1.6 + 2.4 * seedTwinkle) + seedTwinkle * 6.283);
  const isShown: boolean = index < count * (0.35 + 0.65 * energy);
  const opacity: number = isShown ? envelope * twinkle * (0.4 + 0.6 * energy) : 0;
  const radius: number = (0.025 + 0.04 * seedSize) * (0.85 + 0.55 * energy);
  return { x: head.x, y: head.y, tailX: tail.x, tailY: tail.y, radius, opacity: clamp01(opacity) };
};

export const isStreak = (p: Particle): boolean => Math.abs(p.x - p.tailX) > 0.004;

/**
 * The running travel at every frame (`keyboardParticleTravel` integrated frame by frame, gaps capped at a quarter
 * second), from a per-frame level and motion. Pure function.
 */
export const travelTable = (frames: number, fps: number, at: (frame: number) => { readonly motion: ParticleMotion; readonly level: number }): readonly number[] => {
  const table: number[] = [0];
  for (let frame = 1; frame < frames; frame += 1) {
    const { motion, level } = at(frame - 1);
    table.push((table[frame - 1] ?? 0) + Math.min(0.25, 1 / fps) * particleSpeed(motion, level));
  }
  return table;
};
