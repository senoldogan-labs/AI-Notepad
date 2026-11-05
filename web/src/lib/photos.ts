// The site's photographs (src/assets/photos; licences and photographers in CREDITS.md). They are backdrops for app
// windows and cards, graded in CSS (`.photo` in global.css), and decorative: the content placed on them carries the
// meaning, so they have empty alt text.
import type { ImageMetadata } from "astro";
import archipelagoAerial from "../assets/photos/archipelago-aerial.jpg";
import birchGrove from "../assets/photos/birch-grove.jpg";
import deskLamp from "../assets/photos/desk-lamp.jpg";
import duskArchipelago from "../assets/photos/dusk-archipelago.jpg";
import duskLake from "../assets/photos/dusk-lake.jpg";
import lakeIslands from "../assets/photos/lake-islands.jpg";
import lakePier from "../assets/photos/lake-pier.jpg";
import mistySpruce from "../assets/photos/misty-spruce.jpg";

/** A photograph by its file name. */
export type PhotoName =
  | "archipelago-aerial"
  | "birch-grove"
  | "desk-lamp"
  | "dusk-archipelago"
  | "dusk-lake"
  | "lake-islands"
  | "lake-pier"
  | "misty-spruce";

/** Where the crop keeps the subject when the panel's shape differs from the photograph's (a `.photo--<focus>` class). */
export type PhotoFocus = "center" | "top" | "bottom" | "left" | "right";

export const photos: Readonly<Record<PhotoName, ImageMetadata>> = {
  "archipelago-aerial": archipelagoAerial,
  "birch-grove": birchGrove,
  "desk-lamp": deskLamp,
  "dusk-archipelago": duskArchipelago,
  "dusk-lake": duskLake,
  "lake-islands": lakeIslands,
  "lake-pier": lakePier,
  "misty-spruce": mistySpruce,
};
