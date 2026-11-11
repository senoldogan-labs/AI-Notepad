// Builds the press kit's logo pack (`public/press/gistsmith-logo-pack.zip`, linked from /press): the app icon at 1024,
// 512 and 256 px (resized from the app's own icon with `sips`), the mark (the site's Logo.astro tile and bars) and the
// wordmark (the mark beside the product name, set like the site header: Inter 600, -0.02em) as SVG and PNG for light
// and dark backgrounds, and USAGE.txt. The wordmark's letters are outlined from the app's Inter (App/Fonts), so the SVG
// needs no font. The output is committed; the build does not run this. Run it again when the icon, the logo or the
// product name changes. macOS only (`sips`, `zip`).
//
// Usage (from web/): node scripts/make-press-kit.ts
import { execFileSync } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { type Font, type Glyph, create } from "fontkitten";
import sharp from "sharp";
import { makerName, productName } from "../src/config.ts";
import { operator } from "../src/legal/operator.ts";
import { pressKit } from "../src/lib/press-kit.ts";

/** The pack could not be built from its sources. */
class PressKitError extends Error {
  override readonly name: string = "PressKitError";
}

const repoRoot: string = join(import.meta.dirname, "../..");
const appIconPath: string = join(repoRoot, "App/Assets.xcassets/AppIcon.appiconset/icon_1024.png");
const interPath: string = join(repoRoot, "App/Fonts/InterVariable.ttf");
const outputPath: string = join(import.meta.dirname, "../public", pressKit.logoPackPath);
/** The folder inside the zip. */
const packFolder: string = "gistsmith-logo-pack";

/** The wordmark as the site header draws it (CSS px): a 28 px mark, a 10 px gap, the name at 17 px. */
const markSize: number = 28;
const markGap: number = 10;
const nameSize: number = 17;
const nameWeight: number = 600;
const nameTracking: number = -0.02;

/** Colours of one background variant. */
interface Variant {
  readonly id: "on-light" | "on-dark";
  /** The name's colour (the site's Ember ink in that theme). */
  readonly ink: string;
  /** The mark tile's edge: none on light, a faint ring on dark (as Logo.astro). */
  readonly tileStroke: string;
}

const variants: readonly Variant[] = [
  { id: "on-light", ink: "#1c1714", tileStroke: "none" },
  { id: "on-dark", ink: "#f5ede4", tileStroke: "#3a3a3a" },
];

/** The mark's tile and bars in its 32-unit box (Logo.astro). Pure function. */
function markElements(tileStroke: string): string {
  return [
    `<rect x="0.5" y="0.5" width="31" height="31" rx="8.5" fill="#0a0a0a" stroke="${tileStroke}"/>`,
    `<g fill="#fafafa"><rect x="7.4" y="12" width="2.6" height="8" rx="1.3"/><rect x="11.4" y="8.2" width="2.6" height="15.6" rx="1.3"/><rect x="15.4" y="10.6" width="2.6" height="10.8" rx="1.3"/><rect x="19.6" y="14.7" width="5.6" height="2.6" rx="1.3"/></g>`,
  ].join("");
}

/** The mark alone as an SVG at the given pixel size. Pure function. */
function markSvg(size: number): string {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 32 32" role="img" aria-label="${productName}">${markElements("none")}</svg>\n`;
}

/** The outlined name: its glyph paths and its width in CSS px. */
interface OutlinedName {
  readonly paths: string;
  readonly width: number;
}

/** Outlines the name in Inter at the header's size, weight and tracking; the baseline centres the capitals on the mark. Pure function. */
function outlineName(font: Font, name: string): OutlinedName {
  const scale: number = nameSize / font.unitsPerEm;
  const baseline: number = markSize / 2 + (font.capHeight * scale) / 2;
  const tracking: number = nameTracking * nameSize;
  const glyphs: Glyph[] = font.glyphsForString(name);
  let x: number = markSize + markGap;
  const paths: string[] = glyphs.map((glyph: Glyph, index: number): string => {
    const path: string = `<path transform="translate(${x.toFixed(3)} ${baseline.toFixed(3)}) scale(${scale.toFixed(6)} ${(-scale).toFixed(6)})" d="${glyph.path.toSVG()}"/>`;
    x += glyph.advanceWidth * scale + (index < glyphs.length - 1 ? tracking : 0);
    return path;
  });
  return { paths: paths.join(""), width: x };
}

/** The wordmark as an SVG `height` px tall (its width follows). Pure function. */
function wordmarkSvg(outlined: OutlinedName, variant: Variant, height: number): string {
  const width: number = (outlined.width / markSize) * height;
  const mark: string = `<g transform="scale(${markSize / 32})">${markElements(variant.tileStroke)}</g>`;
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${width.toFixed(1)}" height="${height}" viewBox="0 0 ${outlined.width.toFixed(3)} ${markSize}" role="img" aria-label="${productName}">${mark}<g fill="${variant.ink}">${outlined.paths}</g></svg>\n`;
}

/** USAGE.txt: what is in the pack and how to use it. Pure function. */
function usageText(): string {
  return [
    `${productName} logo pack`,
    "",
    "Contents",
    "- app-icon/: the app icon at 1024, 512 and 256 px (PNG).",
    "- mark/: the mark alone (SVG, and PNG at 1024 px).",
    "- wordmark/: the mark with the name, for light backgrounds (on-light) and dark backgrounds (on-dark), as SVG and PNG.",
    "",
    "Clear space",
    "Keep empty space around the mark and the wordmark at least half the mark's height on every side. Don't place text,",
    "other logos or busy parts of a photo inside that space.",
    "",
    "Size",
    "Show the mark at 16 px or larger, and the wordmark at 24 px tall or larger.",
    "",
    "Don't recolor",
    "Use the files as they are: don't recolor, add effects or outlines, stretch, rotate or crop them, and don't redraw the",
    "name in another typeface. Use the on-light wordmark on light backgrounds and the on-dark one on dark backgrounds.",
    "",
    "Name",
    `Write the name as ${productName}: one word, capital G.`,
    "",
    `Questions: ${operator.email}`,
    `© 2026 ${productName} · Made by ${makerName}`,
    "",
  ].join("\n");
}

/** Resizes the app icon with sips. */
function resizeIcon(size: number, target: string): void {
  execFileSync("sips", ["-z", String(size), String(size), appIconPath, "--out", target], { stdio: "ignore" });
}

/** Renders an SVG to a PNG at the size its width and height attributes give. */
async function writePng(svg: string, target: string): Promise<void> {
  await sharp(Buffer.from(svg)).png({ compressionLevel: 9 }).toFile(target);
}

async function main(): Promise<void> {
  const loaded: ReturnType<typeof create> = create(await readFile(interPath));
  if ("fonts" in loaded) {
    throw new PressKitError(`Expected a single font, got a collection: ${interPath}`);
  }
  const inter: Font = loaded.getVariation({ wght: nameWeight, opsz: nameSize });
  const outlined: OutlinedName = outlineName(inter, productName);

  const stage: string = await mkdtemp(join(tmpdir(), "gistsmith-press-"));
  try {
    const root: string = join(stage, packFolder);
    for (const folder of ["app-icon", "mark", "wordmark"]) {
      await mkdir(join(root, folder), { recursive: true });
    }
    for (const size of pressKit.appIconSizes) {
      resizeIcon(size, join(root, "app-icon", `gistsmith-app-icon-${size}.png`));
    }
    await writeFile(join(root, "mark", "gistsmith-mark.svg"), markSvg(32));
    await writePng(markSvg(1024), join(root, "mark", "gistsmith-mark-1024.png"));
    for (const variant of variants) {
      await writeFile(join(root, "wordmark", `gistsmith-wordmark-${variant.id}.svg`), wordmarkSvg(outlined, variant, markSize));
      await writePng(wordmarkSvg(outlined, variant, 280), join(root, "wordmark", `gistsmith-wordmark-${variant.id}.png`));
    }
    await writeFile(join(root, "USAGE.txt"), usageText());

    await mkdir(join(outputPath, ".."), { recursive: true });
    await rm(outputPath, { force: true });
    // -X: no extended attributes or macOS metadata in the archive.
    execFileSync("zip", ["-X", "-r", "-q", outputPath, packFolder], { cwd: stage, stdio: "inherit" });
  } finally {
    await rm(stage, { recursive: true, force: true });
  }
  process.stdout.write(`${outputPath}\n`);
}

await main();
