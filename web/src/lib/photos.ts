// The site's photographs (src/assets/photos; licences and photographers in CREDITS.md). They are backdrops for app
// windows and cards, shown in their own colours (`.photo` in global.css), and decorative: the content placed on them
// carries the meaning, so they have empty alt text.
import type { ImageMetadata } from "astro";
import archipelagoAerial from "../assets/photos/archipelago-aerial.jpg";
import auroraLake from "../assets/photos/aurora-lake.jpg";
import autumnBirches from "../assets/photos/autumn-birches.jpg";
import lakePier from "../assets/photos/lake-pier.jpg";
import midsummerSunset from "../assets/photos/midsummer-sunset.jpg";
import summerLake from "../assets/photos/summer-lake.jpg";
import sunlitPines from "../assets/photos/sunlit-pines.jpg";
import sunsetArchipelago from "../assets/photos/sunset-archipelago.jpg";

/** A photograph by its file name. */
export type PhotoName =
  | "archipelago-aerial"
  | "aurora-lake"
  | "autumn-birches"
  | "lake-pier"
  | "midsummer-sunset"
  | "summer-lake"
  | "sunlit-pines"
  | "sunset-archipelago";

/** Where the crop keeps the subject when the panel's shape differs from the photograph's (a `.photo--<focus>` class). */
export type PhotoFocus = "center" | "top" | "bottom" | "left" | "right";

export const photos: Readonly<Record<PhotoName, ImageMetadata>> = {
  "archipelago-aerial": archipelagoAerial,
  "aurora-lake": auroraLake,
  "autumn-birches": autumnBirches,
  "lake-pier": lakePier,
  "midsummer-sunset": midsummerSunset,
  "summer-lake": summerLake,
  "sunlit-pines": sunlitPines,
  "sunset-archipelago": sunsetArchipelago,
};
