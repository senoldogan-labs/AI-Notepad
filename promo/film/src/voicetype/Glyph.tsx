/** SF Symbol stand-ins on a 24-unit grid, the same paths as the website's demo (web/src/components/PhoneVoiceTypingDemo.astro). */
const PATHS = {
  textBadgePlus: '<path d="M3 6.5h12M3 11.5h8M3 16.5h5"/><path d="M17.5 12.5v8M13.5 16.5h8"/>',
  sparkles:
    '<path d="M10 3l1.9 5.1L17 10l-5.1 1.9L10 17l-1.9-5.1L3 10l5.1-1.9z"/><path d="M18.5 14l.8 2.2 2.2.8-2.2.8-.8 2.2-.8-2.2-2.2-.8 2.2-.8z"/><path d="M18 2.5l.6 1.4 1.4.6-1.4.6-.6 1.4-.6-1.4-1.4-.6 1.4-.6z"/>',
  waveform: '<path d="M3 10.5v3M6.5 8v8M10 4.5v15M13.5 7.5v9M17 9.5v5M20.5 11v2"/>',
  xmark: '<path d="M6.5 6.5l11 11M17.5 6.5l-11 11"/>',
  checkmark: '<path d="M5 12.5l4.5 4.5L19 7.5"/>',
  textCursor: '<path d="M8.5 4.5c2 0 3.5.6 3.5 2v11c0 1.4-1.5 2-3.5 2M15.5 4.5c-2 0-3.5.6-3.5 2v11c0 1.4 1.5 2 3.5 2M9.5 12h5"/>',
  shiftFill: '<path d="M12 3.5l8.5 8.5h-4.8v8.5H8.3V12H3.5z"/>',
  deleteLeft: '<path d="M9 5h10.5A1.5 1.5 0 0121 6.5v11a1.5 1.5 0 01-1.5 1.5H9l-6.5-7z"/><path d="M12 9.2l5.6 5.6M17.6 9.2L12 14.8"/>',
  faceSmiling: '<circle cx="12" cy="12" r="8.6"/><path d="M8.3 14.2c1.9 2.5 5.5 2.5 7.4 0"/><path d="M9.3 9.4v1.4M14.7 9.4v1.4"/>',
  mic: '<rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5.5 11a6.5 6.5 0 0013 0M12 17.5V21"/>',
  returnKey: '<path d="M19.5 5.5v5a2.5 2.5 0 01-2.5 2.5H5.5"/><path d="M9.5 9L5.5 13l4 4"/>',
  globe: '<circle cx="12" cy="12" r="8.6"/><path d="M3.4 12h17.2M12 3.4c2.4 2.4 3.6 5.3 3.6 8.6s-1.2 6.2-3.6 8.6c-2.4-2.4-3.6-5.3-3.6-8.6S9.6 5.8 12 3.4z"/>',
  keyboardFill:
    '<path d="M4.5 6h15A2.5 2.5 0 0122 8.5v7a2.5 2.5 0 01-2.5 2.5h-15A2.5 2.5 0 012 15.5v-7A2.5 2.5 0 014.5 6zM5 9v1.6h1.6V9zm3.1 0v1.6h1.6V9zm3.1 0v1.6h1.6V9zm3.1 0v1.6h1.6V9zm3.1 0v1.6H19V9zM5 12v1.6h1.6V12zm12.4 0v1.6H19V12zM8.1 14.9v1.4h7.8v-1.4z" fill-rule="evenodd"/>',
  chevronLeft: '<path d="M15 4.5L7.5 12l7.5 7.5"/>',
  chevronRight: '<path d="M9.5 6.5L15 12l-5.5 5.5"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  arrowUp: '<path d="M12 19V5.5M6 11l6-6 6 6"/>',
  backTriangle: '<path d="M16 5L7 12l9 7z"/>',
  signal:
    '<rect x="2" y="15" width="3.6" height="5" rx="1"/><rect x="7.2" y="11.5" width="3.6" height="8.5" rx="1"/><rect x="12.4" y="8" width="3.6" height="12" rx="1"/><rect x="17.6" y="4" width="3.6" height="16" rx="1"/>',
  wifi: '<path d="M12 20.2l3.1-3.4a4.6 4.6 0 00-6.2 0zM5.6 13.5a9.4 9.4 0 0112.8 0l1.9-2.1a12.3 12.3 0 00-16.6 0zM2.1 9.6a14.6 14.6 0 0119.8 0L23.8 7.5a17.5 17.5 0 00-23.6 0z"/>',
} as const;

export type GlyphName = keyof typeof PATHS;

const FILLED: ReadonlySet<GlyphName> = new Set<GlyphName>(["sparkles", "shiftFill", "keyboardFill", "signal", "wifi", "backTriangle"]);

export const Glyph: React.FC<{
  readonly name: GlyphName;
  readonly size: number;
  readonly color: string;
  readonly strokeWidth: number;
}> = ({ name, size, color, strokeWidth }) => {
  const filled: boolean = FILLED.has(name);
  return (
    <svg
      viewBox="0 0 24 24"
      width={size}
      height={size}
      style={{ display: "block", color }}
      fill={filled ? "currentColor" : "none"}
      stroke={filled ? "none" : "currentColor"}
      strokeWidth={strokeWidth}
      strokeLinecap="round"
      strokeLinejoin="round"
      dangerouslySetInnerHTML={{ __html: PATHS[name] }}
    />
  );
};
