// The press kit's downloadable files: shared by the /press page and the script that builds the logo pack
// (scripts/make-press-kit.ts), so the link and the file cannot drift apart.

/** The press kit's files. */
export interface PressKitFiles {
  /** The logo pack, relative to `public/` (served at `/<path>`). */
  readonly logoPackPath: string;
  /** The app icon sizes in the pack (pixels, square). */
  readonly appIconSizes: readonly number[];
  /** The product film, relative to `public/` (the same file the home page plays, LaunchFilm.astro). */
  readonly filmPath: string;
}

export const pressKit: PressKitFiles = {
  logoPackPath: "press/gistsmith-logo-pack.zip",
  appIconSizes: [1024, 512, 256],
  filmPath: "video/gistsmith-film-1080p.mp4",
};
