import { useId } from "react";
import { isStreak, PARTICLE_COUNT, particle, particleEnergy, type Particle, type ParticleMotion } from "./particles";
import type { KeyboardAccent } from "./theme";

/**
 * The dictation's voice field as KeyboardViews.swift `KeyboardParticleField` draws it: a capsule with a horizontal
 * gradient in the theme's tint and fill, a soft light beside Done that swells with the voice (no dark core), and the
 * particles (dots with a soft glow, streaks as tapered slivers) from `particle`. SVG in the field's own pixels.
 */
export const ParticleField: React.FC<{
  readonly width: number;
  readonly height: number;
  readonly accent: KeyboardAccent;
  readonly isDark: boolean;
  readonly level: number;
  readonly mode: ParticleMotion;
  readonly travel: number;
  readonly time: number;
}> = ({ width, height, accent, isDark, level, mode, travel, time }) => {
  const id: string = useId().replace(/:/g, "");
  const tint: string = isDark ? accent.tintDark : accent.tintLight;
  const fill: string = isDark ? accent.fillDark : accent.fillLight;
  const glow: number = mode === "processing" ? 0.55 : 0.75 + 0.25 * level;
  const pull: number = particleEnergy(level);
  const core = { x: width - height * 0.2, y: height / 2 };
  const reach: number = height * (0.8 + 0.35 * pull);
  const particles: readonly (Particle & { readonly index: number })[] = Array.from({ length: PARTICLE_COUNT }, (_: unknown, index: number) => ({
    ...particle(index, PARTICLE_COUNT, travel, level, time),
    index,
  })).filter((p: Particle): boolean => p.opacity > 0.02);
  const shapes = particles.map((p: Particle & { readonly index: number }) => {
    const radius: number = p.radius * height;
    const cx: number = p.x * width;
    const cy: number = p.y * height;
    if (isStreak(p)) {
      const tx: number = p.tailX * width;
      const ty: number = p.tailY * height;
      const dx: number = cx - tx;
      const dy: number = cy - ty;
      const length: number = Math.max(0.001, Math.hypot(dx, dy));
      const half: number = (radius * 1.3) / 2;
      const nx: number = (-dy / length) * half;
      const ny: number = (dx / length) * half;
      const tipX: number = cx + (dx / length) * radius * 1.3 * 0.6;
      const tipY: number = cy + (dy / length) * radius * 1.3 * 0.6;
      return { kind: "streak" as const, index: p.index, opacity: p.opacity, points: `${tx},${ty} ${cx + nx},${cy + ny} ${tipX},${tipY} ${cx - nx},${cy - ny}`, tx, ty, cx, cy };
    }
    return { kind: "dot" as const, index: p.index, opacity: p.opacity, cx, cy, radius };
  });
  return (
    <svg width={width} height={height} viewBox={`0 0 ${width} ${height}`} style={{ display: "block", overflow: "visible" }}>
      <defs>
        <clipPath id={`clip-${id}`}>
          <rect x={0} y={0} width={width} height={height} rx={height / 2} />
        </clipPath>
        <linearGradient id={`bg-${id}`} x1={0} y1={0} x2={1} y2={0}>
          <stop offset={0} stopColor={tint} stopOpacity={isDark ? 0.14 : 0.3} />
          <stop offset={0.55} stopColor={fill} stopOpacity={(isDark ? 0.42 : 0.6) * glow} />
          <stop offset={0.85} stopColor={fill} stopOpacity={(isDark ? 0.68 : 0.9) * glow} />
          <stop offset={1} stopColor={tint} stopOpacity={(isDark ? 0.5 : 0.6) * glow} />
        </linearGradient>
        <radialGradient id={`core-${id}`} cx={core.x} cy={core.y} r={reach} gradientUnits="userSpaceOnUse">
          <stop offset={0} stopColor="#ffffff" stopOpacity={0.18 + 0.3 * pull} />
          <stop offset={0.35} stopColor="#ffffff" stopOpacity={0.06 + 0.1 * pull} />
          <stop offset={1} stopColor="#ffffff" stopOpacity={0} />
        </radialGradient>
        <filter id={`blur-${id}`} x="-50%" y="-50%" width="200%" height="200%">
          <feGaussianBlur stdDeviation={2.5} />
        </filter>
        {shapes.map((shape) =>
          shape.kind === "streak" ? (
            <linearGradient key={shape.index} id={`s-${id}-${shape.index}`} x1={shape.tx} y1={shape.ty} x2={shape.cx} y2={shape.cy} gradientUnits="userSpaceOnUse">
              <stop offset={0} stopColor="#ffffff" stopOpacity={0} />
              <stop offset={1} stopColor="#ffffff" stopOpacity={shape.opacity * 0.95} />
            </linearGradient>
          ) : null,
        )}
      </defs>
      <g clipPath={`url(#clip-${id})`}>
        <rect x={0} y={0} width={width} height={height} fill={`url(#bg-${id})`} />
        <circle cx={core.x} cy={core.y} r={reach} fill={`url(#core-${id})`} />
        <g filter={`url(#blur-${id})`}>
          {shapes.map((shape) =>
            shape.kind === "streak" ? (
              <polygon key={shape.index} points={shape.points} fill={`url(#s-${id}-${shape.index})`} />
            ) : (
              <circle key={shape.index} cx={shape.cx} cy={shape.cy} r={shape.radius * 2} fill="#ffffff" fillOpacity={shape.opacity * 0.4} />
            ),
          )}
        </g>
        {shapes.map((shape) =>
          shape.kind === "streak" ? (
            <polygon key={shape.index} points={shape.points} fill={`url(#s-${id}-${shape.index})`} />
          ) : (
            <circle key={shape.index} cx={shape.cx} cy={shape.cy} r={shape.radius} fill="#ffffff" fillOpacity={shape.opacity * 0.95} />
          ),
        )}
      </g>
    </svg>
  );
};
