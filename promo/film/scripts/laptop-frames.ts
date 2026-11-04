/**
 * Prints how many laptop frames promo/blender/render.sh must render: the length of the "meet" scene, taken from the
 * same timeline the film uses. Run with Node's built-in TypeScript support: `node scripts/laptop-frames.ts`.
 */
import { laptopFrames } from "../src/timeline.ts";

console.log(laptopFrames());
