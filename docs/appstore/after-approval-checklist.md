# Gistsmith for iPhone: after-approval checklist (App Store Connect)

Run these in order once 0.1.15 (28) is approved. Paths start at **App Store Connect › Apps › Gistsmith**. Copy comes
from `metadata.md` and `custom-product-pages.md`. Images come from the marketing renderer. `make` captures every raw
screen it needs (the main set and the custom product pages, each with its own seeded data) into
`.build/appstore-screenshots/raw`:

```bash
npm --prefix scripts/appstore-screenshots run make
npm --prefix scripts/appstore-screenshots run marketing -- --raw-dir "$PWD/.build/appstore-screenshots/raw" --out <absolute output folder>
```

| File | Use |
|------|-----|
| `header-3840x1646.png` | Product page header (21:9) |
| `search-3840x2560.png` | Search results asset (3:2) |
| `subscription-monthly-1024.png` | Monthly subscription promotional image |
| `subscription-yearly-1024.png` | Yearly subscription promotional image |
| `event-card-3840x2160.png` | In-App Event card (16:9) |
| `event-details-2160x3840.png` | In-App Event details page (9:16) |
| `6.9/*.png`, `6.5/*.png`, `6.3/*.png` | Default page screenshots (6.3" rendered, not resized) |
| `cpp-*/6.9/*.png`, `cpp-*/6.3/*.png` | Custom product page screenshots, in page order |
| `cpp-*/header-3840x1646.png` | Custom product page header (students and interviews; team uses the main header) |
| `previews/*-safe-area.jpg` | Headers with the centred 3:2 area and the top navigation band marked |
| `previews/event-*-overlay.jpg` | Event images with the bottom band kept free for Apple's text marked |

Anything that changes what users pay or can buy (offer codes, win-back offers, promotion) is the owner's call. Check
amounts and timing before saving.

---

## 1. Release 0.1.15 and confirm the live page

- **App Store › iOS App › 0.1.15**: if the release is manual, press **Release This Version**.
- Open the live page on an iPhone and check the screenshots, the promotional text and the subscription list.
- **Promotional Text** can be edited on the live version at any time, without review. Everything else below needs an
  editable version, a separate review, or both.

## 2. Localizations: Turkish, Finnish, English (U.K.)

Name, subtitle, description and keywords can't change on a live version, so add the localizations to the next one.

1. **App Store › iOS App › "+"** → create **0.1.16** (it can wait for the next build; metadata can be prepared now).
2. **App Store › General › App Information › Localizable Information**: in the language pop-up (top right), add
   **English (U.K.)**, **Finnish** and **Turkish**. For each, paste **Name**, **Subtitle** and the **Privacy Policy
   URL** (`https://gistsmith.com/privacy`).
3. **App Store › iOS App › 0.1.16**: for each new language in the same pop-up, paste **Promotional Text**,
   **Description**, **Keywords**, **What's New**, **Support URL** and **Marketing URL** (copy them from the U.S.
   page).
4. Screenshots: if a localization has none, it shows the U.S. set. That is fine for the U.K., and acceptable for TR
   and FI while the interface is English/Turkish.
5. Subscriptions need localized names too: **Monetization › Subscriptions › Gistsmith (group) › Localization** and
   each subscription's **Localization** section. Add the same three languages:

   | Locale | Group name | Monthly name | Yearly name | Description (both) |
   |--------|-----------|--------------|-------------|--------------------|
   | en-GB | Gistsmith Pro | Gistsmith Pro Monthly | Gistsmith Pro Yearly | Mac and iPhone, 10 hours of recording a month |
   | tr | Gistsmith Pro | Gistsmith Pro Aylık | Gistsmith Pro Yıllık | Mac ve iPhone, ayda 10 saat kayıt |
   | fi | Gistsmith Pro | Gistsmith Pro kuukausi | Gistsmith Pro vuosi | Mac ja iPhone, 10 h tallennusta kuukaudessa |

6. Run `node scripts/appstore-screenshots/metadata-check.ts docs/appstore/metadata.md` before pasting, if the copy
   was edited.

## 3. Header and Search Results assets (iOS 27 and later)

- **Where:** App Store › iOS App › version page › **Product Page Information › Header and Search Results**. To skip
  waiting for a version, use **Asset Library** ("+" in the sidebar › **Upload Creative Assets**): Apple reviews the
  assets against the live version, and once they are approved you can attach them without another review.
- **Header:** `header-3840x1646.png` (21:9, exactly 3840 × 1646). On iPhone the sides are cropped and the navigation
  buttons sit over the top. The headline and phones stay inside the centred 3:2 area (2469 px wide), and the top
  190 px holds no content (see `previews/header-safe-area.jpg`).
- **Search results:** `search-3840x2560.png` (3:2, allowed range 1920 × 1280 to 3840 × 2560). Alternatively, one
  5244 × 2950 PNG can fill both slots; we use two dedicated files because each crop is under our control.
- **Rules:** no prices or discounts, no URLs, no awards, no other platforms' logos, 4+ content, no transparency.
  Assets are set per localization: upload them to en-US first and, once the localizations are live, to en-GB.
- Use the **Preview** in App Store Connect on iPhone and iPad, in both orientations, before submitting.
- These assets only show on iOS/iPadOS 27 and later. Older systems still show the screenshots.

## 4. Custom product pages

- **Where:** App Store › **Growth & Marketing › Custom Product Pages › "+"**. A page needs an approved version.
- Create the three pages in `custom-product-pages.md` (`cpp-students-lectures`, `cpp-interviews-research`,
  `cpp-team-meetings`). For each, add the promotional text, the screenshots in the listed order, a header if there is
  one, and the keywords. Each page has its own URL (`?ppid=…`). Use it in Apple Ads ad variations and in links from
  the site, blog and social posts.
- Each page goes through review on its own. Up to 70 pages are allowed.

## 5. Product Page Optimization: one test, one variable

- **Where:** App Store › **Growth & Marketing › Product Page Optimization › "+" (Create Test)**.
- **Variable: the first screenshot only.** Everything else stays identical.
  - Control: current order (1. "Every word, as it's spoken": live transcript).
  - Treatment A: the note first (1. "Notes that write themselves"). The others shift down one place.
- Traffic: 50 % to the treatment, en-US only. Run until App Store Connect reports at least 90 % confidence, or for
  about 4 weeks, whichever comes first. Don't change screenshots on the default page while the test runs.
- If the treatment wins, use **Apply Treatment** to make it the default page, and copy that order to the 6.5" set.

## 6. In-App Event for the iPhone launch

- **Where:** App Store › **Growth & Marketing › In-App Events › "+"**. Events can now be submitted on their own,
  without a new app version.
- **Idea: "Meeting notes, now on iPhone"**, badge **Premiere**, running for 2 weeks from release.
  - Event name (≤ 30): `Meeting notes, now on iPhone`
  - Short description (≤ 50): `Record in person. Your note is ready when it ends.`
  - Long description (≤ 120): `Record in person. When it ends, get a summary, decisions and tasks. First 3 meetings or 7 days free.`
  - Purpose: Attract new users. Priority: High. Deep link: none (opens the app).
- Event media: `event-card-3840x2160.png` (16:9; Apple accepts 1920 × 1080 to 3840 × 2160) and
  `event-details-2160x3840.png` (9:16; 1080 × 1920 to 2160 × 3840), PNG or JPEG. Apple asks for no text or logos in
  the media and overlays the badge, event name and short description itself, so the images have no text and keep the
  phones out of the bottom 30 % (card) and 40 % (details). Check both in the ASC preview before submitting. Apple shows events only if they are
  time-limited and match what's in the app, so this must run around the real launch window.
- Later events that fit: **Major Update** for a significant feature release, and a **Special Event** for a
  "back to lectures" week in September.

## 7. Subscription promotional images

- **Where:** **Monetization › Subscriptions › Gistsmith › Gistsmith Monthly › App Store Promotion › Promotional
  Image**: upload `subscription-monthly-1024.png`. Then the same path for **Gistsmith Yearly** with
  `subscription-yearly-1024.png`.
- The two images differ from each other (one note card on coral vs a stack of notes on violet). Both differ from the
  app icon (white waveform on black) and contain no text and no price, which avoids the common rejections for
  look-alike images and small text.
- ⚠️ **Don't turn on promotion yet** (**Monetization › In-App Purchases and Subscriptions › Promoted** / "Promote
  in App Store"). The app doesn't implement RevenueCat's
  `purchases(_:readyForPromotedProduct:purchase:)`, so a purchase started from the product page would open the app
  and stop there. Gistsmith also needs a signed-in account before buying. Promotion needs an app change first: keep
  the start-purchase block until the user is signed in, show the paywall, then call the block. The images can be
  uploaded now. They are reviewed with the subscription.

## 8. Offer codes (promo codes are gone for in-app purchases)

- Since 26 March 2026, App Store Connect no longer creates promo codes for in-app purchases. Promo codes for the free
  app download still exist but are pointless here. Use **offer codes**.
- **Where:** **Monetization › Subscriptions › Gistsmith Monthly (or Yearly) › Offer Codes › "+"**.
- Suggested campaigns:
  - **Press and reviewers:** one-time codes, 1 month free on Monthly, small batch (e.g. 50).
  - **Mac users moving to iPhone:** not needed. The same account and subscription already cover both devices.
  - **Community and partners:** a custom code (for example `LECTURES`) for 1 month free on Monthly, for new
    subscribers only, with an end date.
- The app has no in-app redeem sheet. Share the redemption link instead:
  `https://apps.apple.com/redeem?ctx=offercodes&id=<Apple ID>&code=<CODE>`. RevenueCat records the transaction the
  next time the app opens on the signed-in account.

## 9. Win-back offer

- **Where:** **Monetization › Subscriptions › Gistsmith Monthly (and Yearly) › Win-Back Offers › "+"** (iOS 18+).
- Suggestion, to start once there are lapsed subscribers (no earlier than ~2 months after launch):
  - **Monthly:** 50 % off for 2 months. Eligibility: paid for at least 2 months, lapsed 1 to 6 months ago. Wait at
    least 6 months between offers.
  - **Yearly:** 30 % off the first year back. Eligibility: paid for at least 1 year, lapsed 1 to 12 months ago.
  - Display: let the App Store show it (streamlined purchase), so no app change is needed.
- Mirror the offers in `iOS/Purchases/Products.storekit` (`winbackOffers`) to test them locally in Xcode.

## 10. Afterwards

- **Growth & Marketing › Featuring Nominations › "+"**: nominate **App Launch** (iPhone) with the launch date and the
  in-person-meetings angle.
- **Analytics › Acquisition**: watch conversion by page (default, the three CPPs, and the PPO treatment) and by
  source. Revisit keywords after 4 weeks: drop words with impressions but no installs, and move strong en-GB words
  into en-US only if en-US has a weaker word to replace.
- When the iPhone app is live, update gistsmith.com: iPhone screenshots, the App Store link and the new features.
