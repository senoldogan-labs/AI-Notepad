# Site design language: paper, photographs and the horizon (gistsmith.com)

Status: current. First built 2026-11-05 ("Nordic dusk"); reworked 2026-11-07 into the paper-and-photograph layout
below (white page with warm paper bands, big serif headings, warm desert photographs and our own wave renders behind
the product, dark bands, a closing photograph · paper · photograph band). Owner request throughout: a design language
in the spirit of granola.ai's calm, editorial pages, but with nothing a visitor could mistake for Granola.

Scope: every public page of `web/` (home, `/fi`, pricing, compare and `/vs/*`, blog index and posts, legal pages,
MCP, languages, integrations, download, contact, invite, sign-in, 404). The admin panel and the account page's
operating UI keep their layout and only inherit the shared tokens.

## 1. Research: what granola.ai does

Pages read on 2026-11-05 (desktop 1440 px and mobile 390 px, computed CSS measured in the browser): home, pricing,
enterprise, the Chat feature page, integrations, customers, a use-case page (sales), blog index, one blog post,
updates (the changelog is a blog category), careers, security, the help centre (docs.granola.ai, a Mintlify theme)
and `/download` (a redirect stub). Nothing was copied; the values below are measurements used to abstract principles.

| Topic | What they do (measured) | Principle we take |
|---|---|---|
| Type pairing | A text serif for every heading, always weight 400, tracking about -1 % to -2 %; a grotesque sans for body and UI. Home H1 86/80 px, section H2 48/48, inner H1 68, card H3 24; mobile H1 48, H2 36. Lead 24/32 in light grey. | One serif voice at a single regular weight; hierarchy by size, not boldness. The sans does all UI work. |
| Spacing | 1280 px container, 40 px gutters (16 on mobile); 112–128 px section padding (80 on mobile); hairline → title left / text right → full-width media. | Generous, regular section rhythm; one container width; hairline-led rows. |
| Navigation | Fixed pill 56 px tall, 8 px from the top; transparent at the top, solid white with hairline and soft shadow after scrolling; "Talk to sales" outline pill + filled "Download" pill. Mobile: full-width bar and a frosted full-screen menu. | The navigation is an object floating over the page, with one primary pill action. |
| Panels and images | Nature or texture photographs with the product UI composited into the image; tint and texture baked into the files; images at 4 px corners, everything clickable a full pill. | Photography is the stage, the product sits on it. Clear contrast between image shapes and pill controls. |
| Colour | Warm cream greys, charcoal bands, one olive/lime accent reserved for the main CTA. | Neutral paper, one dark band, a single accent used sparingly. |
| Components | App-window mock (traffic lights, 12 px radius, layered shadow), small white chips floating over windows, 3-up pricing cards, compare table with sticky headers, serif FAQ questions with hairline separators, centred CTA card on a photo. | Window + chip vocabulary; FAQ as a typographic list; final CTA as a card over a photograph. |
| Motion | 150–300 ms colour transitions; a pinned hero window and scroll-progress tabs; many ambient loops that keep running under `prefers-reduced-motion`. | Few, short transitions; one authored moment; honour reduced motion completely (they do not). |
| Page templates | Home: hero → product window → statement → feature rows → testimonials → features → MCP → CTA card. Pricing: centred H1 → plans → compare table → FAQ. Blog index: sticky sidebar + featured post + rows. Post: centred H1, 624 px article at 18/32. Security: label column + link-card grid. | Each page type gets one recognisable template (below). |
| Mobile | Single column, H1 48, media bleeds to the content width, nav collapses to a bar + overlay. | Same, with the pill kept as a pill. |

**Their trade dress we must not imitate:** the spiral "G" mark and the giant footer wordmark; the olive/lime CTA and
band colours with the cream "oats" greys; their serif/sans pairing or a typewriter-flavoured look-alike serif; hand-drawn
icons and the handwritten word in headlines; riso/halftone/torn-poster collages and graph-paper portraits; the ruled
"notepad page" background; their rainbow "enhancing" text sweep and note-taking UI motifs.

## 2. Gistsmith's expression

Calm, competent and warm. The page is white with warm paper bands; the photographs and wave renders carry the colour;
the interface stays precise. Our own marks: the orange accent, the horizon waveform (the logo's sound crossing still
water), two-tone headings and the footer's Finnish-lake flip-book ("Made in Oulu, Finland").

### Type

- **Display: Newsreader** (Production Type, SIL OFL 1.1), self-hosted as one static cut (weight 400, optical size 48),
  subset to Latin + Latin Extended-A like Inter: `web/public/fonts/Newsreader-display-latin.woff2`, about 28 KB,
  produced by `web/scripts/subset-serif.sh`; licence text at `/fonts/Newsreader-OFL.txt` (linked in the footer).
  Newsreader is an editorial news serif with high contrast at display sizes; it reads "publication" and
  "institution", not "typewriter", so it cannot be mistaken for their face.
- **Text and UI: Inter** (self-hosted from `App/Fonts`, SIL OFL 1.1), cut by `web/scripts/subset-font.sh` to weights
  400–700 at optical size 16, the body size (38 KB).
- Scale (desktop → 360 px, one weight for the serif): display 108 → 44 px (line height 0.96, tracking -0.025em), page
  title (H1) 64 → 40, section title 52 → 32, row title 32 → 26. The home page uses three serif steps only: display,
  section title and row title. Text blocks keep to a reading measure of 800 px (`--measure`); photographs and windows
  use the 1240 px page width. The serif is used only from about 26 px up (its optical size is 48); card titles
  (`.title-m`) are Inter 600 at 20 px. Line height 1.02–1.12, tracking -0.022em to -0.01em. Lead 21 → 18 px
  Inter 400 in the muted ink. Body 16/1.6, long-form posts 18/1.75 at a 68ch measure.
- **Signature move 1: two-tone headings.** Where other sites put a kicker/eyebrow above a heading, we set the context
  as the first, muted phrase of the heading itself: "*Inside the app.* Quiet while you talk." It is one sentence (a
  plain `<span class="tone">` with a real full stop), reads naturally to screen readers, and is used on the home page's
  section and row titles only. Inner-page H1s carry no kicker at all (the active navigation item already names the
  page); comparison pages keep a small "← Compare" breadcrumb link. On the home hero the category becomes the bold
  lead-in of the lead paragraph.

### Colour

Tokens live once in `web/src/styles/global.css` (`light-dark()` pairs; `src/client/theme.js` picks the theme).

| Token | Light | Dark | Use |
|---|---|---|---|
| `--bg` | `#ffffff` | `#0f0f0e` | page |
| `--card` (paper) | `#f7f7f2` | `#171715` | paper bands, cards, the closing band's paper panel |
| `--soft` | `#f2f2ec` | `#1c1c1a` | chips, photo placeholders while they load |
| `--line` | `#e4e3dc` | `#2b2b28` | hairlines |
| `--ink` | `#292929` | `#f2f2ee` | text |
| `--muted` | `#72726e` | `#a6a6a0` | secondary text |
| `--primary`, `--accent` | `#c4470a` | `#f0874f` | the Download button, step numbers, kickers, the horizon waveform |
| `--night` | `#292929` | `#222220` | dark bands (feature cards, privacy, pricing's "Everything included") |

One saturated colour: the orange. No green anywhere in the chrome.

### Photography

- Two kinds of backdrop, listed with sources and licences in `web/src/assets/photos/CREDITS.md`: 13 warm-lit desert
  and red-rock photographs from Unsplash (standard Unsplash License, each checked on its photo page as free, not
  Unsplash+; no people, logos or brands) and five soft 3D wave landscapes rendered for the site by
  `web/scripts/make-wave-backdrops.ts`. Sources are 3840 px wide; only AVIF (quality 74 for panels, 72 for blog
  covers) and WebP variants ship, at widths from 480 px up to 3840 px for full-width panels on wide Retina screens.
- Shown in their own colours: no filter, tint or grain. In dark mode a panel is only dimmed.
- Text never sits directly on a photograph: copy goes on a paper card or a chip.
- A photograph and a wave render sit side by side wherever two images meet (hero collage, closing band), so the
  page alternates between the real and the rendered.

### Shapes, depth, spacing

- Radii: photo panels 8 px (`--radius-panel`; the closing band's full-bleed photographs are square), cards 14–16 px,
  app windows keep the screenshot's own macOS corners, controls and chips are full pills.
- Depth: app windows get a layered, offset shadow in neutral black; chips a short soft shadow. No glow halos.
- Spacing: 8 px base; sections `clamp(88px, 11vw, 152px)`; content width 1240 px, gutters 20–40 px.

### Signature move 2: the horizon waveform

Our logo is a waveform. On the site the waveform becomes a horizon: a hairline with a short, mirrored, seeded
waveform burst in the accent orange, like a sound crossing still water. It opens the home page's brand line and marks
sign-in, 404 and shared notes. It is drawn from `Waveform`'s seeded heights (deterministic per label), static, and
`aria-hidden`.

### Signature move 3: the footer flip-book

Every page ends on a Finnish lake: a wide band under the footer links (`FooterFlipbook.astro`, frames from
`web/scripts/make-flipbook.ts`) goes from late afternoon to a night with northern lights as the visitor scrolls to
the end; the sun's reflection is the horizon waveform. Frames load only after `load` and near the footer, scroll is
read only while the band is on screen, and reduced motion keeps one still frame.

### Navigation and footer

- **Header:** at the top of the page the logo, Features / Pricing / Compare / Blog, the theme switch, an outline
  "Sign in" pill and the orange "Download" pill sit on the page itself; once the page scrolls the bar becomes a
  floating pill. Below 860 px the links fold into a `<details>` sheet; Download stays visible.
- **Footer:** the brand line in the serif with "Made in Oulu, Finland.", the link columns (column titles in the
  serif), the flip-book band, then copyright and the language choice. No giant wordmark.

### Components

- `PhotoPanel`: a photograph (Astro `<Picture>`, AVIF + WebP from 480 px wide, `sizes` matched to the rendered width)
  with a slot for floating content. The page's largest photo (`priority="lcp"`: pricing, sign-in, download, MCP) is
  preloaded with `fetchpriority="high"`; every other panel is lazy.
- `AppShot`: a real Mac screenshot (`scripts/make-screenshots.sh`) floating in a `PhotoPanel`, cut by the panel's
  bottom edge on wide windows. Screenshots are lazy everywhere; the home hero's, the largest paint on wide screens, is
  preloaded only above 640 px (`media`), because on phones the headline is the largest paint. Only Mac screenshots
  appear (the iPhone app is not on the App Store yet).
- Chips: white pills with a brand tile and a name (Notion, Slack, Linear, Obsidian, Calendar), only on the
  integrations photograph and only for integrations the product really has; the existing two callouts on the hero note
  window use the same chip. No status chips ("processing…") over windows. The former moving logo marquee is a still,
  wrapped logo row (nothing on the page moves on its own except the product demo, which stops after three loops and
  has a pause button).
- CTA card: a centred paper card over a photograph (home and every page's closing `CtaBand`).
- Buttons: dark primary pill, outline secondary pill, 48 px tall (44 px small).

### Motion

Colour/background transitions 160–200 ms; the existing scroll-linked reveal (CSS `animation-timeline: view()`) stays
the one authored moment; the hero product demo keeps its own three-loop limit and pause button. Everything is off
under `prefers-reduced-motion`. Nothing blurred or filtered animates.

### Page templates

- **Home (`/`, `/fi`):** hero in two columns (display headline, one line with the category as its bold lead-in, one
  Download button, assurances; a collage of a desert photograph and a wave render, offset so each shows about a third
  of itself, with the Mac note window and the live panel in front) → a factual trust strip (made in Oulu, EU company,
  notarized by Apple, no bot; never testimonials, ratings or logos we do not have) → the brand line "Quiet while you
  talk. Yours when you're done." on the paper band, opened by the horizon, with the three steps and the product demo
  on a photograph → the launch video on a wave render → feature rows with real screens → the small things as dark
  cards on the night band → the iPhone app → integrations (MCP chat window and chips) → privacy on the night band →
  price and a centred FAQ → closing band (photograph · paper · wave render).
- **Pricing:** centred title, Monthly and Yearly side by side, a wide dark "Everything included" card, the limits,
  a centred FAQ, closing band.
- **Blog index:** the newest post featured with a big cover and its text beside it ("Latest"), then "All posts" in
  three columns. Covers are a photograph or wave render with the title on a paper card (`BlogCover.astro`; spread by
  publish order, or by the front matter's colour family); the share image is drawn from the same cover.
- **Inner marketing pages (compare, `/vs/*`, MCP, languages, integrations, download, invite, contact, voice typing):**
  serif H1 + lead, content in hairline-separated sections, the closing band (`CtaBand`).
- **Legal (privacy, terms):** pure typography, no photographs.
- **404:** a large muted serif "404" over the horizon mark (no photograph: the same view guards the admin address).

### Mobile (360–430 px)

Single column, 16–20 px gutters, the pill header stays a pill, panels run the full content width with the app window
cropped to its readable part (as before), chips hidden below 640 px where they would cover the screenshot, display
44 px. No horizontal scroll (checked by `npm run screenshots` and our own capture script).

### Performance

Target: Lighthouse 100 for performance, accessibility, best practices and SEO on mobile and desktop (Lighthouse's
simulated slow 4G for mobile). What the measurements showed and what the site does:

- On a phone the largest paint is the headline or lead text, and Lighthouse counts every request that finishes before
  it. So the first screen requests as little as possible: one site-wide stylesheet (`cssCodeSplit: false`; the admin
  panel's styles are a separate file loaded only on `/admin`), one shared script module (`Base.astro`) plus one per page,
  fonts preloaded and small (Inter 38 KB, Newsreader 28 KB), the grain tile as a 7 KB WebP.
- Photographs ship as AVIF/WebP from 480 px wide with `sizes` matching the rendered width (for `object-fit: cover`
  panels, the covered width), so a 2× screen gets at least about 1.5 image pixels per screen pixel; the 3840 px
  sources never ship as such. All images are lazy except the page's LCP image, which is
  preloaded with `fetchpriority="high"` (`priority="lcp"` on `PhotoPanel`, `"wide-lcp"` on the home hero window).
- The launch video's cover frame is a lazy AVIF/WebP image under the video, not a `poster` attribute (which would load
  with the first screen).
- Every image has width and height; CLS stays at 0.

## 3. Licences

| Asset | Licence | Record |
|---|---|---|
| Newsreader | SIL Open Font License 1.1 (embedding allowed) | `web/public/fonts/Newsreader-OFL.txt` |
| Inter | SIL Open Font License 1.1 | `App/Fonts/Inter-OFL.txt` (copied at build) |
| Photographs | Unsplash License (commercial use, modification allowed, no attribution required) | `web/src/assets/photos/CREDITS.md` |
| Wave renders, flip-book frames | Made for the site (`web/scripts/make-wave-backdrops.ts`, `web/scripts/make-flipbook.ts`) | `web/src/assets/photos/CREDITS.md` |

## 4. Review record

An independent review (one agent, three angles: red team / trade dress, brand and visual design, practicality) read
this document, the research notes and the screenshots on 2026-11-05. Outcome:

| Finding | Decision |
|---|---|
| The *combination* (regular-weight serif + pill nav + photo panels with windows + chips + title-left/text-right rows + serif FAQ + CTA card) reads as a Granola clone even if each part is generic. | Accepted in part. Our rows are not title-left/text-right hairline rows: a horizon-waveform mark and a two-tone heading beside a photo panel, the panels alternating sides, and one full-width demo row. FAQ questions stay in Inter. No status chips over windows; chips only on the integrations photograph. The pill nav stays a pill on phones, solid, with an outline Sign in instead of "Talk to sales". Pill nav, photo panels, chips and the CTA card stay because the owner asked for them by name. |
| Grade photos at build time instead of CSS (double-tinting, blend cost). | Superseded 2026-11-06: the owner asked for more colourful photos, so there is no grade at all; vivid photographs are chosen instead. |
| Grain on photos reads artsy. | Superseded 2026-11-06: no grain on photographs; it stays on the pastel covers (served as a 7 KB WebP tile). |
| Display cut too thin below ~26 px. | Accepted: card titles are Inter. |
| Two-tone headings become a tic. | Accepted: home sections only; inner H1s plain. |
| Dark night band disappears. | Accepted: lifted to `#15212b`. |
| Always-on frosted header is decorative glass. | Accepted: solid, no blur. |
| Mobile pill too cramped at 360 px; menu dismissal. | Accepted: theme switch moves into the sheet; Escape/outside click already close it. |
| Long Finnish/Turkish words at 44 px. | Accepted: `hyphens: auto` and balanced wrapping on the display style; `/fi` checked at 360 px. |
| Marquee motion needs a pause control. | Accepted by removing the motion: still logo row. |
| Font/LCP: preload, metric-matched fallback, image priorities. | Accepted, then tuned on 2026-11-06 by measurement (see Performance): both fonts are preloaded (removing either preload measured worse), Inter is cut to 400–700 at optical size 16 (38 KB), a size-adjusted Georgia fallback limits the swap; only the real LCP image is preloaded at high priority. |
| CREDITS.md missing. | Written (it was being created while the review ran). |

Second review, 2026-11-07, of the paper-and-photograph rework (one independent agent: trade dress, visual design,
practicality; it read this document and before/after screenshots of every page in both themes and at 390 px):

| Finding | Decision |
|---|---|
| The giant footer wordmark is Granola's mark. | Accepted: removed; the Finnish-lake flip-book closes every page instead. |
| The ruled notepad background is Granola's. | Accepted: a plain paper band opened by the horizon waveform. |
| "Small things that make busy days easier." echoes Granola's "busy days" line. | Accepted: "The details, handled before you ask." |
| Serif, centred FAQ questions with "+" match Granola's pricing FAQ; this document already said questions stay in Inter. | Accepted in part: questions in Inter 500 with an orange plus; the centred column stays (owner's layout). |
| The dark band is barely lighter than the dark page. | Accepted: `--night` dark lifted to `#222220`. |
| The dark card link's arrow wraps alone. | Fixed. |
| Big serif hero headline, dark serif-quote cards, closing band right above the flip-book. | Dissent kept for the owner: these are the owner's chosen layout; listed in the pull request for his visual decision. |
| Flip-book frames are 1600 px for a 1240 px band (0.65 of 2×). | Kept: the scene is soft vector gradients that scale cleanly, and 2400 px frames would roughly double the 524 KB the band costs. |
