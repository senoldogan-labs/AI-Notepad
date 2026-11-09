// Contour lines of the ember band (src/lib/contours.ts): the same seed draws the same band, the lines stay inside the
// band and never cross. Needs no build.
import { strict as assert } from "node:assert";
import { test } from "node:test";
import { type ContourPoint, contourLines, contourPaths } from "../src/lib/contours.ts";

test("the same seed gives the same paths, another seed other paths", () => {
  assert.deepEqual(contourPaths("gistsmith-hero", 640, 620, 6), contourPaths("gistsmith-hero", 640, 620, 6));
  assert.notDeepEqual(contourPaths("gistsmith-hero", 640, 620, 6), contourPaths("gistsmith-og", 640, 620, 6));
});

test("lines span the band's width, stay inside its height and never cross", () => {
  const width: number = 1200;
  const height: number = 210;
  const lines: ContourPoint[][] = contourLines("gistsmith-og", width, height, 5);
  assert.equal(lines.length, 5);
  lines.forEach((line: ContourPoint[], index: number): void => {
    assert.equal(line[0]?.x, 0);
    assert.equal(line.at(-1)?.x, width);
    for (const point of line) {
      assert.ok(point.y >= 0 && point.y <= height * 1.06, `line ${index} leaves the band at y ${point.y}`);
    }
    const above: ContourPoint[] | undefined = lines[index - 1];
    if (above !== undefined) {
      line.forEach((point: ContourPoint, sample: number): void => {
        assert.ok(point.y > (above[sample]?.y ?? Infinity), `line ${index} crosses the one above at sample ${sample}`);
      });
    }
  });
});

test("a band without size or lines is refused", () => {
  assert.throws(() => contourLines("seed", 0, 100, 3), RangeError);
  assert.throws(() => contourLines("seed", 100, 100, 0), RangeError);
});
