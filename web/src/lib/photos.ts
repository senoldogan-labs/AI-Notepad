// The site's backdrops (src/assets/photos; sources and licences in CREDITS.md), behind app
// windows and cards: warm desert photographs (dunes, red rock, painted hills, pastel peaks) and soft 3D wave landscapes
// rendered for the site (`wave-*`). All are 3840 px wide so wide and Retina screens get a sharp 4K variant. Astro serves
// AVIF with a WebP fallback at several widths; only those variants ship. They are decorative: the content placed on
// them carries the meaning, so they have empty alt text.
import type { ImageMetadata } from "astro";
import dawnRange from "../assets/photos/dawn-range.jpg";
import duneBlush from "../assets/photos/dune-blush.jpg";
import duneCrest from "../assets/photos/dune-crest.jpg";
import dunePale from "../assets/photos/dune-pale.jpg";
import duneRidge from "../assets/photos/dune-ridge.jpg";
import duneSunset from "../assets/photos/dune-sunset.jpg";
import lilacPeaks from "../assets/photos/lilac-peaks.jpg";
import paintedHills from "../assets/photos/painted-hills.jpg";
import pastelRidges from "../assets/photos/pastel-ridges.jpg";
import pinkSands from "../assets/photos/pink-sands.jpg";
import redMountain from "../assets/photos/red-mountain.jpg";
import redRockGlow from "../assets/photos/red-rock-glow.jpg";
import waveCoral from "../assets/photos/wave-coral.jpg";
import waveDawn from "../assets/photos/wave-dawn.jpg";
import waveLilac from "../assets/photos/wave-lilac.jpg";
import waveOcean from "../assets/photos/wave-ocean.jpg";
import waveSunset from "../assets/photos/wave-sunset.jpg";
import whiteDunes from "../assets/photos/white-dunes.jpg";

/** A backdrop by its file name. */
export type PhotoName =
  | "dawn-range"
  | "dune-blush"
  | "dune-crest"
  | "dune-pale"
  | "dune-ridge"
  | "dune-sunset"
  | "lilac-peaks"
  | "painted-hills"
  | "pastel-ridges"
  | "pink-sands"
  | "red-mountain"
  | "red-rock-glow"
  | "wave-coral"
  | "wave-dawn"
  | "wave-lilac"
  | "wave-ocean"
  | "wave-sunset"
  | "white-dunes";

/** Where the crop keeps the subject when the panel's shape differs from the photograph's (a `.photo--<focus>` class). */
export type PhotoFocus = "center" | "top" | "bottom" | "left" | "right";

/** Widths generated for a photograph that spans the page (up to 4K for wide Retina screens). */
export const fullPhotoWidths: readonly number[] = [640, 960, 1280, 1920, 2560, 3840];

/** Widths generated for a photograph in half the page or less. */
export const halfPhotoWidths: readonly number[] = [480, 720, 960, 1440, 1920];

export const photos: Readonly<Record<PhotoName, ImageMetadata>> = {
  "dawn-range": dawnRange,
  "dune-blush": duneBlush,
  "dune-crest": duneCrest,
  "dune-pale": dunePale,
  "dune-ridge": duneRidge,
  "dune-sunset": duneSunset,
  "lilac-peaks": lilacPeaks,
  "painted-hills": paintedHills,
  "pastel-ridges": pastelRidges,
  "pink-sands": pinkSands,
  "red-mountain": redMountain,
  "red-rock-glow": redRockGlow,
  "wave-coral": waveCoral,
  "wave-dawn": waveDawn,
  "wave-lilac": waveLilac,
  "wave-ocean": waveOcean,
  "wave-sunset": waveSunset,
  "white-dunes": whiteDunes,
};
