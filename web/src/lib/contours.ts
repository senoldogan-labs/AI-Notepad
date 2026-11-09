// Contour lines for the ember band (EmberBand.astro, scripts/make-og.ts): the nested outlines of a spoken phrase's
// envelope, a "topography of a voice". A seed gives a few syllable-like bumps; each line follows their envelope a step
// lower and a little wider than the one above and never crosses it. Everything here is pure and runs at build time, so
// the page ships fixed SVG paths and no script.

/** A point in the band's coordinates (pixels of the `viewBox`). */
export interface ContourPoint {
  readonly x: number;
  readonly y: number;
}

/** One syllable-like bump of the envelope: centre and width as fractions of the band's width, height 0–1. */
interface Bump {
  readonly centre: number;
  readonly width: number;
  readonly height: number;
}

/** Samples per line: smooth at any band width once joined with quadratic curves. */
const steps: number = 96;

/** Bumps per envelope. */
const bumpCount: number = 6;

/** Deterministic 0–1 generator from a text seed (FNV-1a for the state, then an LCG). Pure. */
function seededRandom(seed: string): () => number {
  let state: number = 0x811c9dc5;
  for (const char of seed) {
    state ^= char.codePointAt(0) ?? 0;
    state = Math.imul(state, 0x01000193) >>> 0;
  }
  return (): number => {
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
    return state / 4294967296;
  };
}

/** The envelope's bumps for a seed. Pure. */
function bumpsFor(seed: string): Bump[] {
  const next: () => number = seededRandom(seed);
  return Array.from({ length: bumpCount }, (_: unknown, index: number): Bump => ({
    centre: 0.08 + ((index + next() * 0.8) / bumpCount) * 0.86,
    width: 0.05 + next() * 0.07,
    height: 0.25 + next() * 0.75,
  }));
}

/** The envelope's raw height at `x` (0–1); `spread` widens and flattens every bump. Pure. */
function envelope(bumps: readonly Bump[], x: number, spread: number): number {
  return bumps.reduce(
    (sum: number, bump: Bump): number => sum + (bump.height / Math.sqrt(spread)) * Math.exp(-(((x - bump.centre) / (bump.width * spread)) ** 2)),
    0,
  );
}

/**
 * The contour lines' points, top line first. Each line sits lower than the one before at every sample (by at least
 * 2.2 % of the height), so lines never cross. Pure.
 */
export function contourLines(seed: string, width: number, height: number, count: number): ContourPoint[][] {
  if (width <= 0 || height <= 0 || count < 1) {
    throw new RangeError(`contourLines needs a positive size and at least one line (width ${width}, height ${height}, count ${count}).`);
  }
  const bumps: Bump[] = bumpsFor(seed);
  const peak: number = Math.max(...Array.from({ length: 201 }, (_: unknown, index: number): number => envelope(bumps, index / 200, 1)));
  const lines: ContourPoint[][] = [];
  for (let line: number = 0; line < count; line += 1) {
    const base: number = height * (0.42 + (line * 0.62) / count);
    const amplitude: number = height * 0.34;
    const spread: number = 1 + line * 0.45;
    const above: ContourPoint[] | undefined = lines[line - 1];
    const points: ContourPoint[] = Array.from({ length: steps + 1 }, (_: unknown, index: number): ContourPoint => {
      const x: number = index / steps;
      const y: number = base - (amplitude * envelope(bumps, x, spread)) / peak;
      const floor: number = above === undefined ? -Infinity : (above[index]?.y ?? -Infinity) + height * 0.022;
      return { x: x * width, y: Math.max(y, floor) };
    });
    lines.push(points);
  }
  return lines;
}

/** An SVG path (`d`) through the points, smoothed with quadratic curves through the midpoints. Pure. */
export function contourPath(points: readonly ContourPoint[]): string {
  const first: ContourPoint | undefined = points[0];
  if (first === undefined) {
    throw new RangeError("contourPath needs at least one point.");
  }
  const segments: string[] = [];
  for (let index: number = 1; index < points.length - 1; index += 1) {
    const point: ContourPoint = points[index] as ContourPoint;
    const following: ContourPoint = points[index + 1] as ContourPoint;
    segments.push(
      `Q${point.x.toFixed(1)} ${point.y.toFixed(1)} ${((point.x + following.x) / 2).toFixed(1)} ${((point.y + following.y) / 2).toFixed(1)}`,
    );
  }
  return [`M${first.x.toFixed(1)} ${first.y.toFixed(1)}`, ...segments].join(" ");
}

/** The band's contour paths for a seed and size. Pure. */
export function contourPaths(seed: string, width: number, height: number, count: number): string[] {
  return contourLines(seed, width, height, count).map(contourPath);
}
