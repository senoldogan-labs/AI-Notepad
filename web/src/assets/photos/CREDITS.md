# Backdrop credits

The site's backdrops are of two kinds. All files are 3840 px wide (4K; the largest width the site serves). Astro turns
them into AVIF and WebP at several widths at build time (src/lib/photos.ts); only those variants ship.

## Photographs

Standard Unsplash photos under the [Unsplash License](https://unsplash.com/license): free for commercial and
non-commercial use, modification allowed, attribution not required. Each photo page was checked on 2026-11-07 and showed
"Free to use under the Unsplash License"; none is an Unsplash+ photo. No people, logos or brands are visible. Each
original is the file behind the photo page's own Download button (4608 to 8192 px wide); the files here are those
originals scaled down to 3840 px with a Lanczos filter and saved as JPEG quality 92 (4:4:4, sRGB).

| File | Subject | Photographer | Source | Licence | Downloaded |
|---|---|---|---|---|---|
| `dawn-range.jpg` | Sunlit mountain range at dawn | Royce Fonseca | https://unsplash.com/photos/sunlit-mountain-range-at-dawn-or-dusk-K5Frw34P1XI | Unsplash License | 2026-11-07 |
| `dune-blush.jpg` | Rolling dunes under a pale sky | Wolfgang Hasselmann | https://unsplash.com/photos/rolling-sand-dunes-in-desert-landscape-pVr6wvUneMk | Unsplash License | 2026-11-07 |
| `dune-crest.jpg` | One sand dune against the sky | Mike Iukhtenko | https://unsplash.com/photos/sand-dune-zuueig1w8WI | Unsplash License | 2026-11-07 |
| `dune-pale.jpg` | Soft dunes under a white sky | Ze Paulo | https://unsplash.com/photos/brown-sand-dunes-under-white-sky-during-daytime-GeReAnOMiZ8 | Unsplash License | 2026-11-07 |
| `dune-ridge.jpg` | Golden dune ridge, blue sky | Dylan Jenkinson | https://unsplash.com/photos/brown-sand-under-blue-sky-during-daytime-NZy-F0JNbXc | Unsplash License | 2026-11-07 |
| `dune-sunset.jpg` | Dunes under a pink sunset | Vlad D | https://unsplash.com/photos/a-desert-landscape-with-mountains-in-the-distance-Ag9cWC8-eY8 | Unsplash License | 2026-11-07 |
| `lilac-peaks.jpg` | Rock peaks under a lilac sky | Jason Pofahl | https://unsplash.com/photos/brown-rocky-mountain-under-white-cloudy-sky-during-daytime-YU82HZASi6E | Unsplash License | 2026-11-07 |
| `painted-hills.jpg` | Banded painted hills | Adrian Newell | https://unsplash.com/photos/a-large-group-of-hills-with-a-sky-in-the-background-Jim9MN4E_P8 | Unsplash License | 2026-11-07 |
| `pastel-ridges.jpg` | Layered ridges at sunset | simon (simon_berger) | https://unsplash.com/photos/landscape-photography-of-mountains-twukN12EN7c | Unsplash License | 2026-11-07 |
| `pink-sands.jpg` | White dunes under a pink sky, moon | John Fowler | https://unsplash.com/photos/moon-over-white-sand-dunes-RsRTIofe0HE | Unsplash License | 2026-11-07 |
| `red-mountain.jpg` | Red rock mountain face | Austin Anderson | https://unsplash.com/photos/brown-rocky-mountain-under-gray-sky-during-daytime-YrYeghM0OgE | Unsplash License | 2026-11-07 |
| `red-rock-glow.jpg` | Red rocks in evening light | Halie West | https://unsplash.com/photos/brown-rocky-mountain-under-blue-sky-during-daytime-mcL6RsmE8WA | Unsplash License | 2026-11-07 |
| `white-dunes.jpg` | Pale dunes, blue sky | Willian Justen de Vasconcellos | https://unsplash.com/photos/landscape-photography-of-desert-jOF2TFSNxQI | Unsplash License | 2026-11-07 |

## Wave landscapes

`wave-coral.jpg`, `wave-dawn.jpg`, `wave-lilac.jpg`, `wave-ocean.jpg` and `wave-sunset.jpg` are original renders made for
this site on 2026-11-07 (layered dune shapes lit from the upper left, with haze and fine grain), rendered directly at
3840 × 2560 and saved as JPEG quality 95. They contain no third-party material.
They are made by `scripts/make-wave-backdrops.ts` (`node scripts/make-wave-backdrops.ts src/assets/photos`; same bytes for the
same settings).
