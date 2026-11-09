# Gistsmith conversion spec: paywall, trial reminders, upgrade moments, win-back, funnel telemetry

Status: design spec for one PR on top of `feat/pro-tier` (Personal $5.99/mo or $49/yr, 10 h/mo; Pro $12.99/mo or
$109/yr, server-configured hours, dark-launched behind `PRO_TIER_POLICY`). Trial: the first 3 meetings or 7 days from the
first meeting, whichever comes first, no card (server). Date: 2026-11-08.

Ground rules: no dark patterns, no invented numbers, nothing shown that we cannot back with data, never interrupt a
running meeting, Mac and iPhone parity (per the owner's rule), and web `/pricing` and `/account` aligned.

---

## 0. What already exists (read before building)

Most of the plumbing is already there. This PR mostly fixes, connects and measures it. It does not add a new system.

| Piece | Where | State |
|---|---|---|
| Upsell moments `trialNoteReady`, `trialEnding` (1 meeting left or 48 h left), `trialEnded`, `subscriptionRequired`, `planChoice` | `Packages/.../Hosted/HostedUsage.swift` (`HostedUpsellMoment`, `hostedUpsellMoment`, `isHostedTrialEnding`, `hostedTrialEndingWindowSec = 48h`) | Pure and tested |
| Strip vs sheet presentation | `hostedUpsellPresentation` | Auto moments use a strip; user-initiated moments use a sheet |
| Mac upsell sheet with trial-value tiles (meetings, tasks, hours) and tier and plan pickers, yearly preselected | `App/Hosted/HostedPlanViews.swift` (`HostedUpsellSheet`, `HostedTrialValueTiles`, `HostedTierPicker`, `HostedPlanPicker`) | Mac only. Tiles shown only for `trialEnding` and `trialEnded` |
| Trial value from local meetings | `Packages/.../Hosted/HostedPlans.swift` `hostedTrialValue(meetings:)` | **Bug:** counts the sample meeting (it does not filter with `realMeetings`). `App/MainWindow.swift:484` passes `model.meetings` |
| Mac trigger after a note is ready | `App/AppModel.swift:2451` → `HostedAccount.meetingNoteReady()` | **iPhone never calls it.** The iPhone has no `trialNoteReady` or `trialEnding` moment (parity gap) |
| iPhone paywall (RevenueCat): close X, restore, EULA, Privacy and Terms links, renewal text, yearly preselected, tier picker | `iOS/Purchases/PaywallView.swift`, `PaywallModel.swift`; state machine `paywallPhase` in `Hosted/HostedAppStore.swift` | Has no trial value and no outcome headline. Cover title is generic ("Her toplantın için tam erişim") |
| iPhone automatic paywall, once on `trialEnded` and once per ended period on `subscriptionEnded` | `iOS/Hosted/PhoneHosted.swift` `phoneAutoPaywallKey`, `iOS/AINotepadiOSApp.swift` `showAutoPaywallIfDue` | Waits while recording or onboarding |
| One-time usage notices `monthlyWarning` (80%), `monthlyFull`, `trialOneLeft`, `trialEnded` | `HostedUsage.swift` `hostedUsageNotice`, `hostedNoticeStorageKey`. Mac `HostedUsageBanner`, iPhone `PhoneUsageNotice` | The monthly notices only offer "See usage". **No Pro upsell** |
| Local notifications with a pure plan and stable IDs | `Packages/.../Meeting/EngagementNotifications.swift` (`plannedEngagementNotifications`), `App/EngagementNotifier.swift` (shared by Mac and iPhone) | Four kinds, each with a Settings toggle. No trial reminder |
| Telemetry (counts and durations per day and app version, not linked to accounts, governed by the opt-out toggle) | `server/src/telemetry.ts`, `Hosted/HostedTelemetry.swift`, `App/Hosted/HostedTelemetryCenter.swift`, `server/src/adminTelemetry.ts`, 400-day retention in `cleanup.ts` | No conversion events |
| First-run funnel (tokenless) | `server/src/funnel.ts`, `Hosted/HostedFunnel.swift` | Pattern to copy |
| Server-side conversion truth | `server/src/admin.ts` `ConversionStats` (trial started → paid, Stripe and App Store) | Exists |
| Social proof: App Store rating prompt, quote consent, `web/src/testimonials.ts` + `SocialProof.astro` (render nothing while empty) | PR **#338, OPEN, not merged** (`feat/social-proof-plumbing`, migration 0058) | This spec depends on it for the social-proof block only |
| Web `/pricing` (Pro card hidden until `GET /v1/pricing` offers it), `/account` checkout with `recommendedPlan = "yearly"` | `web/src/pages/pricing.astro`, `web/src/client/pricing.ts`, `web/src/client/account.ts`, `web/src/lib/plans.ts` | Monthly is listed before yearly. The trial-ended message has no value line |

Migrations on this branch: 0055, then `0062_pro_tier.sql`. 0058 is taken by #338. **The new migration is
`0063_conversion_events.sql`.** Check the number against `origin/main` and open branches before committing.

---

## 1. Findings with sources, each tied to a decision

| # | Finding | Source | Decision it drives |
|---|---|---|---|
| F1 | "The amount that will be billed must be the most prominent pricing element… an annual subscription should clearly display the total amount… a breakdown price… or a savings… should be displayed in a subordinate position and size." | Apple, Auto-renewable subscriptions: https://developer.apple.com/app-store/subscriptions/ | "$49/year" stays the big number. "About $4.08/mo" and "Save 32%" stay smaller. This applies on the Mac (Stripe) and the web too, for consistency |
| F2 | The sign-up screen must include the subscription name, duration and what is provided each period; the billing amount, localized; a way to sign in or restore; and Terms and Privacy links. | Apple HIG, Apple In-App Purchase, "Making signup effortless": https://developer.apple.com/design/human-interface-guidelines/apple-in-app-purchase ; App Review Guideline 3.1.2(c): https://developer.apple.com/app-store/review/guidelines/#subscriptions | Keep the iPhone `PaywallTerms`. **Add** Terms and Privacy links, a renewal sentence and an "Already subscribed?" check to the Mac sheet. That sheet has none of them today |
| F3 | "Let people experience your app before making a purchase." "Prompt people to subscribe at relevant times, like when they near their monthly limit." "Encourage a new subscription only when someone isn't already a subscriber." | HIG (same page) | Trigger only on outcomes (note ready, limit nearing or reached, trial ending). Never show a subscription upsell to a subscriber. Show subscribers a Pro **upgrade** only when they hit their limit |
| F4 | Apps must not "trick users into purchasing a subscription under false pretenses or engage in bait-and-switch". Apps should never "trick them into making unwanted purchases… or engage in any other manipulative practices." | Guidelines 3.1.2(a) and 5.6: https://developer.apple.com/app-store/review/guidelines/ | No fake urgency or countdown timers, no delayed or hidden close button, no confirm-shaming ("No, I don't want to save time"), no preselected Pro unless the trigger is "limit reached" |
| F5 | Promotional push notifications need explicit opt-in "via consent language displayed in your app's UI" and an in-app way to opt out. Apple also says notifications should be "timely, serve a clear purpose". | Guideline 4.5.4 (same URL); subscriptions page (F1 URL) | The trial-ending local notification is **opt-in only**, through a "Remind me" button with consent text. It is off by default and has its own Settings toggle |
| F6 | Blinkist added a reminder before the trial ends, with consent: trial sign-ups rose 23%, complaints fell 55%, and push opt-in rose from 6% to 74%. An independent copy of the idea (Slopes) saw fewer day-0 cancellations but **no** conversion lift. | https://uxplanet.org/how-solving-our-biggest-customer-complaint-at-blinkist-led-to-a-23-increase-in-conversion-b60ad514134b ; https://blog.curtisherbert.com/slopes-diaries-39-risky-business/ | Ship the reminder for trust, not as a promised lift. Measure it (`trial_reminder_*`). Our trial needs no card, so nothing is charged when it ends. The copy says so plainly, because that is our honesty advantage |
| F7 | Showing "(equivalent to XX/month)" next to the yearly price improved results. Hiding monthly behind "View all plans" raised yearly share. Placement and plan display matter more than value framing. | RevenueCat, Guide to mobile paywalls: https://www.revenuecat.com/blog/growth/guide-to-mobile-paywalls-subscription-apps | Keep the monthly equivalent (subordinate). Put yearly **first** and preselected everywhere. Keep monthly visible: hiding it is a choice we decline because it borders on a dark pattern |
| F8 | Defaulting to the longest plan: 82% of subscribers who did not dismiss the paywall chose the default yearly plan. This is vendor data and observational, not a controlled test. | Superwall newsletter: https://api.superwall.me/blog/the-superwall-newsletter-volume-1 ; base rates in https://www.lazyweb.com/research/what-percent-of-paywalls-preselect-the-annual-plan | Yearly preselected. This is already the owner's decision (`recommendedPlan = "yearly"`) |
| F9 | 2026: hard paywall D35 trial-to-paid median 10.7% vs 2.1% freemium. Value must land in the first session ("aha within 60 min"). 35% of annual cancellations happen in month 1. | RevenueCat, Subscription app trends 2026: https://www.revenuecat.com/blog/growth/subscription-app-trends-benchmarks-2026 ; SOSA 2025: https://www.revenuecat.com/state-of-subscription-apps-2025 | Our trial is meter-limited (3 meetings), which works like a soft hard-paywall. The outcome headline uses the user's own trial results (the "aha" they already had). Annual month-1 churn means telemetry must separate yearly and monthly outcomes |
| F10 | Adapty 2026: plan mix and anchoring drive LTV, and what works differs by category. | https://adapty.io/state-of-in-app-subscriptions-report/ | We do not copy weekly plans or extra decoys. Our traffic is too small for A/B tests, so measure before and after with the telemetry in section 6 |
| F11 | Apple shows win-back offers automatically to eligible **lapsed subscribers** once they are configured in App Store Connect, with no code. They do not apply to trial-only users. | Subscriptions page (F1 URL), "Win-back offers" | An App Store win-back offer is an owner decision (discount) and stays **out** of this PR. Trial-only win-back is in-app only |
| F12 | The US FTC's 2024 rule bans fake or misattributed reviews and testimonials. Guideline 5.6.3 forbids manipulating reviews. | https://www.ftc.gov/news-events/news/press-releases/2024/08/federal-trade-commission-announces-final-rule-banning-fake-reviews-testimonials ; Guideline 5.6.3 | Social proof only from #338 data (owner-curated, consented quotes and a real App Store rating), with thresholds. Render nothing when there is no data |
| F13 | "Display the total billing price… Use the default confirmation sheet… Don't modify or replicate this sheet." | HIG (F2 URL) | The iPhone keeps RevenueCat and StoreKit's sheet. The Mac keeps Stripe Checkout. No custom confirmation |

---

## 2. Paywall design (Mac sheet, iPhone paywall, web `/pricing`, web `/account`)

### 2.1 Structure (same order on every surface)

1. **Close** (always visible, always enabled except while an Apple or Stripe transaction is in flight, as today; never
   delayed or faded). Mac: "Not now" plus Esc. iPhone: the X (44 pt).
2. **Outcome headline** built from the user's own trial data (2.2), with a one-line reason under it (the existing
   `paywallReasonText` / `hostedUpsellSubtitle`).
3. **Value block**: the trial-value tiles when there is data, otherwise three outcome bullets.
4. **Social proof** (2.5), rendered only when gated data exists.
5. **Tier picker** (Personal or Pro), only when `hostedProOffer(entitlements:) != nil`, and on iPhone only when Pro
   packages are in the offering (the existing gate).
6. **Plan cards**: yearly first and preselected, then monthly (2.3).
7. **CTA** (2.6), then **Restore / Already subscribed?**, then the **terms** (2.4).

### 2.2 Outcome headline (pure function in core)

New file `Packages/AINotepadCore/Sources/AINotepadCore/Hosted/HostedPaywallCopy.swift`:

```swift
public enum HostedPaywallHeadline: Sendable, Equatable {
    case meetingsAndTasks(meetings: Int, tasks: Int)
    case meetingsAndTime(meetings: Int, minutes: Int)
    case outcomeOnly
}
/// Pure. Picks the headline from the trial value: tasks > 0 → meetingsAndTasks; meetings > 0 → meetingsAndTime;
/// otherwise outcomeOnly. `minutes` is rounded down from hours * 60.
public func hostedPaywallHeadline(value: HostedTrialValue) -> HostedPaywallHeadline
```

Fix `hostedTrialValue` to call `realMeetings(records:)` first, so the sample meeting is never counted. Synced meetings
from the other device *do* count. That is honest, because they are the user's meetings, but the tile label must change
from "Bu Mac'te şimdiye dek" ("On this Mac so far") to "In your trial so far", because the iPhone shows it too.

Copy (English is the catalog source of truth for review. Swift source strings stay Turkish per the repo's l10n rule, via
the `add-ui-strings` skill. Plurals use String Catalog plural variants):

| Case | English | Turkish source |
|---|---|---|
| meetingsAndTasks | "Your {meetings} meetings gave you {tasks} tasks. Keep every meeting this easy." | "{meetings} toplantından {tasks} görev çıktı. Her toplantın bu kadar kolay olsun." |
| meetingsAndTime (≥ 60 min) | "{hours} hours of meetings, already written up for you. Keep it going." | "{hours} saatlik toplantın senin için yazıldı. Böyle devam et." |
| meetingsAndTime (< 60 min) | "{minutes} minutes of meetings, already written up for you. Keep it going." | "{minutes} dakikalık toplantın senin için yazıldı. Böyle devam et." |
| outcomeOnly (zero data) | "Every meeting, written up for you." | "Her toplantın, senin için yazılı." |
| Tile caption (replaces "Bu Mac'te şimdiye dek") | "In your trial so far" | "Denemende şimdiye dek" |

Zero-data bullets (outcomeOnly, replacing the Mac `benefits` and iPhone `PaywallIncluded` openers; keep the hours row):
- "Live transcript while people talk" / "Konuşulurken canlı metin"
- "Your tasks on top when the meeting ends" / "Toplantı bitince görevlerin en üstte"
- "Ask across all your meetings" / "Tüm toplantılarına soru sor"

Rules:
- Show the trial-data headline only to accounts **in trial or with an ended trial and no subscription ever**
  (`hostedPlanStatus` `.trial`, or `.expired` with `subscription == nil`). Subscribers and lapsed subscribers get
  outcomeOnly, with the existing reason line ("Your subscription ended…").
- Never show a number that is 0 next to a positive claim. The cases above guarantee that.
- iPhone: pass `trialValue: hostedTrialValue(meetings: store.meetings)` into `PhonePaywall` (new parameter). The iPhone
  cover title becomes the headline. The pastel cover is unchanged.

### 2.3 Plan layout

- **Order: yearly first, then monthly**, on the Mac `HostedPlanPicker` (today monthly is on the left), on the iPhone
  (already yearly first), and on web `/pricing` and the `/account` checkout choice (`billingPlans` order becomes
  `["yearly", "monthly"]`).
- **Preselected:** yearly on every surface (unchanged).
- **Most prominent element:** the billed total ("$49/year", "$5.99/month"). Subordinate (smaller and muted): "About
  $4.08 a month, billed yearly" and the savings pill "Save 32%" (Pro: "Save 30%"). The Mac and web use
  `hostedYearlySavingsPercent` and `hostedYearlyMonthlyEquivalentCents`. The iPhone uses App Store prices
  (`yearlySavings`, `monthlyEquivalentText`). No strike-through "$71.88" anchor: it is legal, but it reads as a fake
  discount next to a plan that was never sold at that price.
- **No "Most popular" badge** until telemetry shows it is true for yearly over a 30-day window (F12 spirit). Then it can
  be added as a separate change.

### 2.4 Personal vs Pro presentation (when Pro is offered)

- Keep the existing side-by-side tier cards: name, monthly price, "{hours} hours a month", "Up to {h} hours per
  meeting". Hours come only from the server (`offeredTiers`), never hard-coded.
- **Default tier: Personal**, except:
  - trigger `monthly_full` or `monthly_warning` on a Personal account → **preselect Pro** (the user asked for more
    hours by hitting the limit);
  - App Store subscriber switching plans → the existing `preselectForCurrentSubscription` logic.
- **Usage hint (honest projection, no preselection):** while in trial, if the user's trial minutes per elapsed trial day
  × 30 > 0.8 × the Personal cap, show one line under the tier cards:
  "At your trial pace you'd record about {hours} hours a month. Pro includes {proHours}." /
  "Deneme temponla ayda yaklaşık {hours} saat kaydedersin. Pro'da {proHours} saat var."
  Pure function `hostedProjectedMonthlyHours(value: HostedTrialValue, trialStartedAt: Date, now: Date) -> Double?`,
  which returns nil if fewer than 2 meetings or less than 1 day has elapsed (too noisy). Requires `trialStartedAt`:
  derive it as `trialEndsAt − trialDays`, or add the field to `/v1/me` if it is not exposed (check `HostedEntitlements`).
  **If neither is cheap, drop the hint**. It is optional.

### 2.5 Social proof (real data only)

Depends on #338. **If #338 is not merged when this PR starts, skip 2.5 entirely.** Nothing else depends on it.

- Single source: `web/src/testimonials.ts` (#338). Add an Astro endpoint `web/src/pages/social-proof.json.ts`, the same
  pattern as `llms.txt.ts`, built at deploy, that emits
  `{ rating: {average, count, asOf} | null, quotes: [{quote, firstName, language}] }`. No `reportId` or
  `consentedOn` in the public JSON.
- Apps fetch `GET {siteBase}/social-proof.json` at most once per 24 h (URLSession cache, no retry storm: retry with
  backoff ×2 and log a warning, then give up for this session; the paywall renders without the block).
- **Gating (pure function `hostedSocialProof(payload:interfaceLanguage:now:) -> HostedSocialProof?`):**
  - Rating shown only if `count >= 20` and `asOf` is no more than 120 days old. Text: "4.7 on the App Store · 52 ratings"
    / "App Store'da 4,7 · 52 değerlendirme". On the Mac it reads "4.7 on the App Store (iPhone) · 52 ratings", because
    the Mac app is not on the App Store.
  - Quote shown only if there is at least one for the interface language (`en` and `fi` exist on the web; other
    languages show none). Show one quote: the most recent `consentedOn`, deterministic, not random. Format:
    "“{quote}” — {firstName}".
  - Neither condition met → render nothing (no placeholder, no "Join thousands…").
- Web `/pricing`: include the #338 `SocialProof.astro` component above the plans, under the same thresholds. Put the
  thresholds in `testimonials.ts` so the web and the apps share the numbers.

### 2.6 CTA, restore, close

| Element | English | Turkish source |
|---|---|---|
| CTA, no subscription (iPhone and Mac) | "Subscribe · {billedTotal}" e.g. "Subscribe · $49/year" | "Abone ol · {billedTotal}" |
| CTA, App Store subscriber switching | "Change plan" (existing) | "Planı değiştir" |
| CTA, Mac Pro | "Subscribe to Pro · $109/year" | "Pro'ya abone ol · $109/yıl" |
| iPhone restore (existing) | "Restore Purchases" | "Satın Alımları Geri Yükle" |
| Mac "already subscribed" (new, replaces nothing) | "Subscribed on iPhone or the web? Check again" → `account.refresh()` | "iPhone'da ya da web'de abone misin? Yeniden denetle" |
| Mac close (existing) | "Not now" | "Şimdi değil" |

The iPhone CTA price comes from `PaywallPackage.priceText` (App Store, localized). The Mac price comes from
`hostedPlanPriceText`.

### 2.7 Terms and renewal disclosure

- **iPhone (keep, already compliant)**: the existing `PaywallTerms` text plus the EULA, Privacy and Terms links.
- **Mac sheet (new; replaces "Vergiler dahil. İstediğin zaman iptal edebilirsin; ödeme Stripe ile güvenle yapılır."):**
  - EN: "Renews automatically at {billedTotal} until you cancel. Cancel anytime in Settings › Account › Manage
    subscription. Taxes included; payment by Stripe."
  - TR: "İptal edene dek {billedTotal} ile kendiliğinden yenilenir. Ayarlar › Hesap › Aboneliği yönet'ten istediğin
    zaman iptal edebilirsin. Vergiler dahil; ödeme Stripe ile."
  - Links: "Terms" → `{siteBase}/terms`, "Privacy" → `{siteBase}/privacy`.
- **Web `/pricing`**: keep `common.renewalNote`. **`/account` checkout choice**: add the same one-line renewal sentence
  under the CTA, with links.

### 2.8 Web `/account` parity

- Trial active: keep the existing meter. Add the headline (2.2) built from server data only. The web has no local
  meetings and sync is end-to-end encrypted, so the web cannot count tasks. Use
  `meetingsUsed = trialMeetingsTotal − trialMeetingsLeft`:
  - `meetingsUsed > 0`: "You've recorded {n} meetings in your trial. Keep every meeting written up for you."
  - otherwise: "Every meeting, written up for you."
- Trial ended (`plan-status` `ended`): replace `trialEnded` copy with "Your free trial has ended. You recorded {n}
  meetings, and your notes stay in the app. Subscribe to start new meetings." (n = 0 → the existing sentence).
- Pro block: the same rule as 2.4 (Pro preselected only from `?trigger=limit`, which the apps never send; the web has
  no auto triggers).

---

## 3. Trial-ending reminders

### 3.1 In-app (banner or strip), Mac and iPhone

Use the existing machinery and close the iPhone gap:
- **iPhone parity:** call `HostedAccount.meetingNoteReady()` from the iPhone's processing → done transition (the same
  place `EngagementNotifier.meetingProcessed` is driven, `iOS/AINotepadiOSApp.swift:594`). On iPhone,
  `trialNoteReady`, `trialEnding` and `trialEnded` render as a **non-modal card** at the top of the home screen (the new
  `PhoneUpsellCard`, same look as `PhoneUsageNotice`), never as the full-screen cover. `phoneRootCover` must keep
  returning `.paywall` only for `.sheet` moments. That is a one-line change in `PhoneAppGate.swift`: map
  `hostedUpsellPresentation(moment:) == .strip` to no cover.
- `trialEnding` copy (strip title and subtitle; keep the existing title "Denemen bitmek üzere" / "Your trial is almost
  over"):
  - 1 meeting left: "1 trial meeting left. Your notes stay yours either way." / "Denemende 1 toplantı kaldı. Notların
    her durumda sende kalır."
  - Time-based: "Your trial ends {relativeDay}, with {left} meetings left to try." / "Denemen {relativeDay} bitiyor;
    denenecek {left} toplantın var." (`relativeDay` = "tomorrow" or "on {weekday}", formatted with `interfaceLocale()`)
  - Strip buttons: "See plans" (existing) plus **"Remind me a day before"** (3.2), shown only when the trial is
    time-bound (`trialEndsAt != nil`), more than 24 h are left, the reminder is not already on, and notification
    permission is not `denied`.

### 3.2 Local notification (opt-in)

- New `EngagementKind.trialEnding` in `EngagementNotifications.swift`, with the setting key
  `EngagementSettingKey.trialReminder`, **default false** (the other four default to true; this one is promotional,
  see F5).
- Turned on only by the user: the "Remind me a day before" button sets the key to true and, if permission is
  `notDetermined`, calls `requestAuthorizationIfUndetermined()`. The button's consent text sits directly under it:
  "We'll send one notification before your trial ends. Turn it off in Settings › Notifications." / "Denemen bitmeden bir
  bildirim göndeririz. Ayarlar › Bildirimler'den kapatabilirsin."
- Settings › Notifications: the row "Trial reminder" / "Deneme hatırlatması" is shown only while in trial.
- Planning (pure; add to `EngagementPlanInput`: `trialEndsAt: Date?`, `trialMeetingsLeft: Int`,
  `isTrial: Bool`):
  `trialEndingNotification(trialEndsAt:meetingsLeft:now:calendar:) -> EngagementNotification?`
  - Fire time = `trialEndsAt − 24h`, moved into the 09:00–20:00 local window: earlier than 09:00 → 09:00 the same day;
    later than 20:00 → 20:00. If the result is in the past, or `trialEndsAt − now < 2h`, return nil.
  - nil if not in trial, `meetingsLeft == 0`, or the setting is off.
  - Stable ID `engagement.trialEnding`. The existing stale-ID cleanup removes it when the plan drops it (subscribed,
    trial ended, signed out).
  - Content (no meeting content on the lock screen): title "Your Gistsmith trial ends tomorrow" / "Gistsmith denemen
    yarın bitiyor"; body "{left} meetings left to try. Nothing is charged; your notes stay. Tap to see plans." /
    "Denenecek {left} toplantın var. Ücret alınmaz; notların kalır. Planlar için dokun."
  - Tap → route `.plans` (new `EngagementRoute` case) → `account.showPlans()` with trigger `trial_reminder`.
- Meeting-count expiry ("last meeting left") gets **no** notification. The user is in the app when it happens, and the
  in-app strip covers it.

### 3.3 Anti-spam rules (pure function, enforced in one place)

New pure function `hostedAutoPromptAllowed(lastAutoPromptAt: Date?, now: Date, isMeetingActive: Bool, isOnboarding: Bool) -> Bool`:
- At most **one automatic** (not user-initiated) upsell or paywall surface per **24 h** per account, across all
  triggers (`hosted.upsell.lastAutoShownAt.{userId}`). User-initiated `planChoice` and `subscriptionRequired` (the
  user tapped Start) are always allowed.
- Never while a meeting is recording or processing (`currentMeeting != nil`, recorder not idle). Defer to the next
  `meetingNoteReady` or app activation.
- Never over onboarding, the rating prompt (#338 `ReviewPrompt` already refuses over the paywall; add the reverse:
  no automatic paywall in the same session the rating sheet was shown), or another sheet.
- Per-account caps: `trialEnding` once, `trialEnded` once, trial notification once (all exist or are added above).

---

## 4. Upgrade moments (monthly limit)

Applies to accounts with access (`subscribed`, `ending`, `grace`; not `complimentary`), Personal tier, and
`hostedProOffer != nil`. Never shown to Pro accounts. A Pro account at its cap gets today's notice unchanged.

| Moment | Trigger | Surface | Copy (EN / TR) | CTA |
|---|---|---|---|---|
| Nearing | `monthlyWarning` (≥ 80%, once per month, existing) | Mac `HostedUsageBanner`, iPhone `PhoneUsageNotice` | Title unchanged ("You're close to this month's limit: 84%"). Detail: "{used} of {cap} hours used; resets {resetDay}. Pro gives you {proHours} hours a month." / "{cap} saatin {used} saati kullanıldı; {resetDay} sıfırlanır. Pro'da ayda {proHours} saat var." | Secondary "See Pro" / "Pro'yu gör" next to "See usage" → `showPlans(trigger: .monthlyWarning)`, Pro preselected |
| Reached | `monthlyFull` (once per month, existing) | Same | Detail adds: "Upgrade to Pro to keep recording this month: {proHours − cap} more hours, starting now." / "Bu ay kayda devam etmek için Pro'ya geç: hemen {proHours − cap} saat daha." | Primary "Upgrade to Pro" / "Pro'ya geç" |
| Reached mid-meeting | Server shortens a meeting near the cap (`HostedMeetingLimitStrip`, minutes left) | **No upsell during recording.** The minutes-left strip stays informational | — | After the meeting ends and its note is ready, the normal `monthlyFull` notice shows (3.3 defers it) |

- "Starting now" must be true. App Store Personal → Pro is an upgrade and takes effect immediately
  (`hostedAppStoreChangeTiming` → `.immediate`). Stripe change-plan must also apply immediately; check `billing.ts`
  `change-plan`. If the Stripe upgrade is not immediate, drop "starting now" for Stripe accounts.
- The updated `updateNotice` must not raise `monthlyWarning` or `monthlyFull` while `currentMeeting != nil`. It should
  leave the "shown" key unset so the notice appears on the post-meeting refresh, the same way `trialEnded` is already
  handled.

---

## 5. Win-back

### 5.1 Expired trials (never subscribed)

- Existing: once-only `trialEnded` (Mac strip → sheet; iPhone auto paywall `phone.paywall.auto.trialEnded.{userId}`).
- **New, a gentle follow-up strip on app open** (`trigger = win_back`): non-modal strip or card (Mac `HostedUpsellStrip`,
  iPhone `PhoneUpsellCard`), shown on app activation **3, 10 and 30 days** after the trial ended (needs
  `trialEndedAt`: use `trialEndsAt` if the trial ended by time; otherwise store the local date when `trialEnded` was
  first observed, `hosted.trialEndedObservedAt.{userId}`). At most 3 times, never after day 45, never after a purchase,
  and subject to 3.3.
  - Copy: "Your {n} meeting notes are still here. Pick up where you left off." / "{n} toplantı notun hâlâ burada.
    Kaldığın yerden devam et." (n from `realMeetings` with a note; n = 0 → "Pick up where you left off with Gistsmith." /
    "Gistsmith'le kaldığın yerden devam et.")
  - Buttons: "See plans" / "Planları gör", plus × (dismiss counts as shown).
- Pure function: `hostedWinBackDue(trialEndedAt: Date, shownCount: Int, lastShownAt: Date?, now: Date) -> Bool`.

### 5.2 Lapsed subscribers

- Existing once-per-ended-period `subscriptionRequired` (iPhone auto paywall; Mac on Start). No discount in this PR.
- **Owner decision (not in this PR):** App Store win-back offers, configured in App Store Connect (F11), and a Stripe
  coupon for lapsed web subscribers. Both cost money, so per the owner's rule they need explicit approval.

### 5.3 Web and email

- Web `/account`: trial-ended copy with the meeting count (2.8). That is the only web win-back.
- **Email: none.** We do not send marketing email and have no email consent flow. No email win-back is possible or
  planned. Adding it would mean new consent, privacy-policy and unsubscribe work, which is out of scope.

---

## 6. Funnel telemetry

### 6.1 Principles

- Rides the **existing** `POST /v1/telemetry` (authenticated, `TELEMETRY_USER_LIMITER`, 200/day cap) and is governed
  by the **existing** "Share anonymous usage statistics" toggle (`telemetrySendingAllowed`). It is off in the developer
  edition.
- Values are fixed enums only. Stored as daily counts per (day, kind, platform, dimensions, app_version). **Not linked
  to accounts**: no user ID, no product ID string, no price, no country, no free text, no error messages. Retention is
  400 days (an `aggregateCounterRetentionMs` entry in `cleanup.ts`).
- Purchases and revenue stay **server-authoritative** (Stripe and RevenueCat webhooks → `admin.ts` `ConversionStats`,
  `revenue.ts`). The client `purchase_completed` only measures the in-app confirmation step (entitlement arrived),
  which drives the per-surface funnel. The admin panel labels it "app-observed (sharing-on users, lower bound)".
- `platform` is **derived server-side** from `x-os-version` (`macOS` or `iOS`, `clientVersions.ts`), not sent.
- Web pages send no client events: the web has no consent toggle, and Cloudflare Web Analytics already counts
  `/pricing` and `/account?checkout=1` page views. Optional, recommended because it is tiny: count
  `POST /v1/billing/checkout` server-side per day, source (`app` if `x-app-version` is present, else `web`), tier and
  plan, in the same new table with `kind = "checkout_created"` and `platform = "server"`. This is operational
  aggregate data; mention it in the privacy policy.

### 6.2 Events (new discriminated-union members of `telemetryEventsSchema`, keyed by `kind`)

All carry `count` (1–1000, aggregated on the client by identical key). Enums:

- `surface`: `paywall` (iPhone full screen), `sheet` (Mac upsell sheet), `strip` (Mac strip or iPhone card), `banner`
  (usage notice), `notification`, `settings`, `account` (account screen "Subscribe" / "Change plan").
- `trigger`: `trial_note_ready`, `trial_ending`, `trial_ended`, `subscription_required`, `plan_choice`,
  `monthly_warning`, `monthly_full`, `win_back`, `trial_reminder`. The first five are `HostedUpsellMoment` raw values
  in snake_case.
- `tiers_offered`: `personal`, `personal_pro`.
- `tier`: `personal`, `pro`. `plan`: `monthly`, `yearly`.
- `reason_code` (purchase_failed): `products_unavailable`, `store_error`, `payment_pending`, `purchase_not_allowed`,
  `network`, `server`, `entitlement_timeout`, `not_signed_in`, `configuration`. This is an exhaustive mapping of
  `AppStorePurchaseError`, RevenueCat `ErrorCode` (`paymentPendingError` → `payment_pending`,
  `purchaseNotAllowedError` → `purchase_not_allowed`, `networkError` → `network`, `offlineConnectionError` →
  `network`, all other store codes → `store_error`), `HostedClientError.network` → `network`, `HostedAPIError` →
  `server`, `HostedAppStoreEntitlementMissing` → `entitlement_timeout`, `notConfigured`/`apiKeyMissing`/
  `packageMissing`/`packagesNotLoaded`/`noWindowScene` → `configuration`. The mapping is a pure function with an
  exhaustive switch and no default branch.
- `channel` (reminders): `in_app`, `notification`.

| kind | fields | Emitted when |
|---|---|---|
| `paywall_shown` | surface, trigger, tiers_offered | Mac sheet appears; iPhone `PhonePaywall.onAppear`; once per presentation |
| `paywall_closed` | surface, trigger | Close or "Not now" without a purchase |
| `plan_selected` | surface, tier, plan | User changes the tier or plan card (not the initial preselection) |
| `purchase_started` | surface, tier, plan | iPhone `.purchaseTapped`; Mac checkout URL opened |
| `purchase_cancelled` | surface, tier, plan | iPhone `.purchaseCancelled`; Mac `watchCheckout` gave up with no subscription (abandoned) |
| `purchase_completed` | surface, tier, plan | `.entitlementArrived` (iPhone); subscription seen after checkout (Mac) |
| `purchase_failed` | surface, reason_code | `.productsFailed`, `.storeFailed`, `.entitlementTimedOut`; Mac checkout URL error |
| `purchase_restored` | surface, result (`restored`, `nothing_found`) | iPhone restore outcome; Mac "Check again" outcome |
| `trial_reminder_shown` | channel | In-app strip with `trial_ending` shown; notification delivered (counted when the app next opens and the ID is gone from pending, or on `willPresent`) |
| `trial_reminder_tapped` | channel | "See plans" on the strip; notification tap |
| `trial_reminder_opt_in` | — | "Remind me a day before" tapped and the setting turned on |
| `upsell_shown` | trigger (`monthly_warning`, `monthly_full`, `win_back`) | Pro or win-back notice shown |
| `upsell_tapped` | trigger | Its CTA tapped |

Example body: `{"events":[{"kind":"paywall_shown","surface":"paywall","trigger":"trial_ended","tiers_offered":"personal","count":1}]}`.

### 6.3 Server

- `server/src/telemetry.ts`: export the enum arrays (`conversionKinds`, `conversionSurfaces`, `conversionTriggers`,
  `conversionReasons`, …). Add `z.strictObject` members to the union (per-kind field sets; absent dimensions are
  stored as `""`). Add `recordConversionEvents(db, events, platform, appVersion, now)` as one `db.batch` upsert,
  following the `recordTelemetryEvents` pattern. `aggregateEvents` gains a third bucket (pure).
- Migration `0063_conversion_events.sql` (additive):
  ```sql
  CREATE TABLE conversion_events_daily (
    day TEXT NOT NULL, kind TEXT NOT NULL, platform TEXT NOT NULL, surface TEXT NOT NULL, trigger TEXT NOT NULL,
    tiers TEXT NOT NULL, tier TEXT NOT NULL, plan TEXT NOT NULL, reason TEXT NOT NULL, app_version TEXT NOT NULL,
    count INTEGER NOT NULL,
    PRIMARY KEY (day, kind, platform, surface, trigger, tiers, tier, plan, reason, app_version)
  );
  ```
  The row count is bounded by the enum product per day; the existing `funnelMaxVersionsPerDay` style cap is not needed,
  because the route is authenticated and rate-limited.
- `cleanup.ts`: add `conversion_events_daily` with `aggregateCounterRetentionMs`.
- `adminTelemetry.ts`: add `conversion` to the 30-day payload:
  `{ funnel: [{platform, trigger, shown, selected, started, completed}], failures: [{platform, reason, count}],
  reminders: {optIn, shownInApp, shownNotification, tappedInApp, tappedNotification}, upsells: [{trigger, shown,
  tapped}], planMix: [{platform, tier, plan, started, completed}] }`. All are sums, with no IDs.
- `web/src/client/admin-telemetry.ts` (+ `admin-telemetry-copy.ts`): a "Conversion" card showing the funnel table per
  platform × trigger with step rates, a failure-reason table, reminder and upsell rows, and next to them the existing
  server truth (`ConversionStats`) so app-observed and billed numbers can be compared. The heading notes "Only apps with
  usage statistics on; lower bound."

### 6.4 Client

- `Hosted/HostedTelemetry.swift`: the enums `ConversionEventKind`, `ConversionSurface`, `ConversionTrigger`,
  `ConversionReason`, `ConversionTiersOffered`, a struct `ConversionEvent` (typed fields, no dictionaries), and
  `TelemetryPendingEvents.conversions: [ConversionCount]`. Decode old stored state with an empty default via a
  `Codable` migration in the decoder (the existing stored JSON has no field). Pure helpers: `addingConversion`,
  `conversionBodies(batchMax: 50)`.
- `App/Hosted/HostedTelemetryCenter.swift`: `record(conversion: ConversionEvent)`, flushed with the existing events.
- `ServerParityTests.swift`: add the new arrays.

### 6.5 Privacy policy wording (add a fourth bullet under "Usage statistics" in `web/src/pages/privacy.astro`)

> **Plan screen steps:** when the plans screen or an upgrade notice is shown or closed, which plan and billing period
> was selected, whether a purchase was started, cancelled, completed, restored or failed (with a fixed failure category,
> such as a network or App Store error), and whether you turned on or opened the trial reminder. Each step is sent with
> where it appeared (for example the plans screen or a notice) and why (for example "trial ended" or "monthly limit
> reached"), and summed per day, device type and app version. It never includes prices, payment details, your App Store
> or Stripe identity, or anything you typed.

If the optional server checkout counter ships, also add under the account or billing section: "We count, per day, how
many checkout pages were opened from the apps and from the website, by plan, without linking the count to you." Update
the retention list line (`privacy.astro:956`) to name "plan screen totals" among the 400-day daily totals.

---

## 7. Files to change and test plan

### 7.1 Core (`Packages/AINotepadCore`)
- `Sources/.../Hosted/HostedPlans.swift`: `hostedTrialValue` filters `realMeetings`. Add `hostedProjectedMonthlyHours`
  (optional, 2.4).
- `Sources/.../Hosted/HostedPaywallCopy.swift` (new): `HostedPaywallHeadline`, `hostedPaywallHeadline`,
  `hostedAutoPromptAllowed`, `hostedWinBackDue`, `hostedSocialProof` (only if #338 is merged), the purchase-failure
  `ConversionReason` mapping (store-agnostic parts).
- `Sources/.../Hosted/HostedUsage.swift`: `HostedUsageNotice` gains Pro awareness via the helper
  `hostedProUpsell(entitlements:) -> HostedTierOffer?` (Personal, has access, Pro offered). The `trialEnding` variant
  text uses data (left meetings, relative day).
- `Sources/.../Hosted/PhoneAppGate.swift`: strip moments never produce the `.paywall` cover.
- `Sources/.../Meeting/EngagementNotifications.swift`: `EngagementKind.trialEnding`,
  `EngagementSettingKey.trialReminder`, `trialEndingNotification`, the `EngagementRoute.plans` case, and new plan
  input fields.
- `Sources/.../Hosted/HostedTelemetry.swift`: conversion enums, pending-store extension and bodies.
- Tests (`Tests/AINotepadCoreTests/`): `HostedTests.swift` (headline cases incl. zero data and the sample meeting
  excluded; auto-prompt 24 h cap and meeting-active block; win-back days 3/10/30 and the cap; Pro upsell gating
  Personal, Pro, complimentary and no-offer cases), `EngagementNotificationsTests` (fire time window clamping,
  < 2 h → nil, off by default, removed when subscribed), `PhoneAppGateTests` (strip → no cover),
  `HostedTelemetryTests` (body encoding, batching, decoding old pending JSON), `ServerParityTests` (new arrays),
  `LocalizationCompletenessTests` (runs as usual).

### 7.2 Mac (`App/`)
- `App/Hosted/HostedPlanViews.swift`: headline (2.2), tile caption, yearly-first `HostedPlanPicker`, Pro preselection
  by trigger, CTA with price, renewal text plus Terms and Privacy links, "Check again", usage hint (optional), social
  proof block (optional), telemetry calls (`paywall_shown`, `paywall_closed`, `plan_selected`, `purchase_started`).
- `App/Hosted/HostedAccount.swift`: `showPlans(trigger:)`; record the trigger on `upsell`; wire
  `hostedAutoPromptAllowed`; defer monthly notices during a meeting; `purchase_completed`, `purchase_cancelled` and
  `purchase_failed` from `subscribe` / `watchCheckout`; win-back on activation.
- `App/Hosted/HostedUsageViews.swift`: `HostedUsageBanner` "See Pro" / "Upgrade to Pro" and the strip "Remind me a
  day before" with its consent line.
- `App/EngagementNotifier.swift`: settings plumbing for `trialReminder`; route `.plans`.
- `App/MainWindow.swift`: pass `realMeetings` and the trigger; handle the `.plans` route in the notification delegate.
- `App/SettingsPage.swift` (Notifications section): "Trial reminder" toggle while in trial.
- `App/DemoData.swift`: demo scenes `paywall-zero` and `paywall-trial-value` for visual QA.
- `App/Localizable.xcstrings`: all new strings (EN plus the `TARGET_LANGUAGES`) through `scripts/l10n.py`.

### 7.3 iPhone (`iOS/`)
- `iOS/Purchases/PaywallView.swift`: headline cover, value tiles (port `HostedTrialValueTiles` into a shared view or
  write a phone version), CTA with price, social proof (optional), telemetry.
- `iOS/Purchases/PaywallModel.swift`: `trigger` and `surface` stored; record `plan_selected` (user changes only),
  `purchase_*`, `purchase_restored`; reason mapping for `AppStorePurchaseError` (iOS-only part).
- `iOS/AINotepadiOSApp.swift`: call `account.meetingNoteReady()` on processing → done; pass `trialValue`; route
  `.plans`; win-back on activation.
- `iOS/RecordTab.swift`: `PhoneUsageNotice` Pro CTA; new `PhoneUpsellCard` for strip moments and win-back.
- `iOS/PhoneNotifications.swift`: `.plans` route.
- `iOS/SettingsTab.swift`: "Trial reminder" toggle.
- `iOS/Hosted/PhoneHosted.swift`: no change to `phoneAutoPaywallKey`; the global 24 h cap is checked by the caller.
- Launch args for visual QA: `--paywall-ornek <deger|bos>` (paywall with sample trial value or zero data),
  `--ornek-sinir-pro` (monthly-full notice with Pro offered).

### 7.4 Server (`server/`)
- `src/telemetry.ts`, `src/app.ts` (pass platform from `x-os-version` into `recordConversionEvents`; optional checkout
  counter in the `/v1/billing/checkout` branch), `src/adminTelemetry.ts`, `src/cleanup.ts`,
  `migrations/0063_conversion_events.sql`, `README.md` (table list).
- Tests: `test/telemetry.test.ts` (accepts each kind with the right fields, rejects unknown enums or extra fields or
  missing dimensions, aggregates duplicate keys, the daily cap still applies), `test/admin.test.ts` (conversion payload
  sums with no IDs), `test/cleanup.test.ts` (400-day deletion).
- Deploy order: server first (main merge triggers `deploy-server.yml`, additive migration), apps later. An old server
  would reject the new kinds with 400; clients drop the batch the same way they handle today's 400s. Check that
  `HostedTelemetryCenter` does not retry 400 forever.

### 7.5 Web (`web/`)
- `src/lib/plans.ts`: `billingPlans = ["yearly", "monthly"]`.
- `src/pages/pricing.astro` + `src/copy.ts`: yearly first (and Pro yearly first); `SocialProof` (if #338 is merged).
- `src/client/account.ts` + `src/client/copy.ts`: trial headline and trial-ended copy with the count (2.8); renewal
  line and links on the checkout choice.
- `src/pages/social-proof.json.ts` (optional, needs #338).
- `src/pages/privacy.astro`: section 6.5 wording plus the retention line.
- `src/client/admin-telemetry.ts`, `admin-telemetry-copy.ts`: Conversion card.
- Tests: `web/scripts/*.test.ts` for the account copy selection (`meetingsUsed` 0 and > 0) and the admin conversion
  parser; `npm run build` and typecheck.

### 7.6 Checks before shipping (repo rules)
1. `swift test --package-path Packages/AINotepadCore` and the iOS-simulator core tests; `cd server && npm test`; web
   tests and typecheck; the three Debug builds (AINotepad, AINotepadHosted, AINotepadiOS).
2. `scripts/l10n.py check`.
3. `hosted-e2e` skill: telemetry POST with the new kinds against the local wrangler with `migrate:local`.
4. `visual-qa` skill: Mac demo screenshots (paywall zero, trial value, Pro preselected at monthly-full) in light and
   dark; iPhone Simulator `--paywall`, `--paywall-ornek deger`, `--ornek-sinir-pro`, iPhone SE size, and accessibility
   text size (the price must stay the largest pricing element; CTA and close visible without scrolling).
5. Manual (owner, at the end per the memory rule): one StoreKit sandbox purchase in Xcode Run (`Products.storekit`).
   UI tests do not work under `xcodebuild` (Apple FB22237318).

---

## 8. Risks, dissent and open questions

- **No A/B testing.** Volume is too low to power tests. We ship one design and compare 30 days before and after on the
  admin funnel. Accept that attribution will be noisy.
- **The trial reminder may not lift conversion** (the Slopes replication). It is kept for trust and lower complaints;
  if `trial_reminder_opt_in` stays below 5% of `trial_ending` strips after 60 days, remove the button.
- **The usage hint (2.4) projects from at most 3 meetings.** It is optional and guarded (≥ 2 meetings, ≥ 1 day). Cut it
  if review finds it misleading.
- **Social proof depends on #338 and real data.** The thresholds mean it will render nothing for a while. That is
  intended.
- **Pro is dark-launched.** Every Pro element is gated by `hostedProOffer`, so with `PRO_TIER_POLICY` off this PR
  changes only Personal surfaces.
- **"Starting now" on the Stripe Personal → Pro upgrade** must be verified in `billing.ts` before the copy ships (4).
- **Scope check:** this is a large PR (four platforms). If it has to be split, ship in this order: (a) server and
  telemetry plus the privacy policy, (b) core plus Mac and iPhone paywall and notices, (c) web copy and order. (a) has to
  be in production before the apps ship.
- Per the owner's global rule, the non-trivial decisions here (opt-in default for the reminder, yearly-first order,
  no "Most popular" badge, no web client events) should get the independent red-team, domain and practicality subagent
  review before implementation. That review was not run as part of this spec.
## 9. Review outcome and decisions (2026-11-08)

Two independent reviews were run on this spec before building: a conversion/UX review (impeccable method;
`review-ux` verdict **approve with changes**) and an App Review / consumer-law compliance review (verdict **approve with
changes**). Decisions taken, with the dissent each settles:

**Adopted from the UX review**
1. Outcome headline describes a gain, not chores: "3 meetings. 7 action items caught. Written up for you." (zero-data
   fallback keeps the outcome sentence). The value tiles are not repeated under the headline.
2. Savings shown rounded **down** and identical on every surface ("Save 31% vs monthly"; computed by one pure
   function), as plain text next to the yearly plan, not a filled pill.
3. Plan names on the iPhone paywall come from our localized strings ("Personal · Yearly"), never the App Store
   product title (which showed English "Gistsmith Pro Yearly" on a Turkish screen).
4. Tier cards show their price for the selected billing period; only one price is shown per choice.
5. One renewal line directly under the subscribe button (iPhone sticky footer, Mac sheet, web), price on the button.
6. iPhone paywall trimmed: 3 feature rows, "up to 4 h per meeting" stated once, fits an iPhone SE and the largest
   text size with close, plans and CTA reachable.
7. Mac: "Have an invite code?" moves below "Not now"; selection uses the user's accent colour; the Stripe hand-off is
   announced ("Opens secure checkout in your browser").
8. A post-purchase confirmation with one next step (connect the calendar) on Mac and iPhone.
9. Monthly-limit upsell preselects Pro with the subscriber's **current** billing period.
10. `trigger` is carried on every purchase event so the selling moment is measurable.
11. Win-back strip shown on days 3 and 14 after the trial ends (not 3/10/30).
12. "Check again" becomes "Refresh my plan". The trial-ending strip also says "Nothing is charged automatically."

**Adopted from the compliance review**
1. Conversion telemetry on iPhone is sent only after the user **explicitly** turns usage statistics on (a stored
   explicit opt-in; the default-on toggle is not consent under 5.1.1(ii)). The Mac app keeps its existing toggle
   (distributed outside the Mac App Store; same events). No user ID is stored with an event.
2. Mac and web checkout disclosure next to the button: price and period, automatic renewal until cancelled, how to
   cancel (account page / Customer Portal), access until the end of the paid period, seller Link; Pro upgrades say
   "You'll pay the prorated difference today."
3. No usage-projection hint in v1 (both reviewers).
4. iPhone never says "Start free trial" (the trial is not an App Store introductory offer) and never links to web
   purchase.

**Rejected / deferred (owner decisions, recorded with dissent)**
- "Record now, subscribe after" at the start-with-no-trial moment (UX reviewer's #1): stores audio on the device for an
  unpaid meeting and holds the note until purchase — product and storage call for the owner. Built instead: a dedicated
  headline for that trigger ("Your meeting is starting. Subscribe and this one gets a note too.").
- 14-day refund on Stripe yearly, discount win-back offers: cost money, owner decision.
- Social proof: the rating/quote infrastructure (#338) is not merged; nothing is shown until real data exists.
- Legal follow-ups (owner): EU online withdrawal function (CRD Art. 11a, since 19 June 2026) for Link purchases; the
  California annual-renewal reminder for yearly Stripe plans (check Link's emails); lowering Pro hours applies to new
  subscribers or after the notice in the terms; App Store Connect privacy label adds "Purchases → Purchase history, not
  linked to you, analytics" before this ships.

## 10. Telemetry contract (final)

`POST /v1/telemetry` gains these `kind`s; every event has `count` (1–1000). Fields per kind (strict; absent fields are
not sent):

| kind | fields |
|---|---|
| `paywall_shown` | `surface`, `trigger`, `tiersOffered` |
| `paywall_closed` | `surface`, `trigger` |
| `plan_selected` | `surface`, `trigger`, `tier`, `plan` |
| `purchase_started`, `purchase_cancelled`, `purchase_completed` | `surface`, `trigger`, `tier`, `plan` |
| `purchase_failed` | `surface`, `trigger`, `reason` |
| `purchase_restored` | `surface`, `result` |
| `trial_reminder_shown`, `trial_reminder_tapped` | `channel` |
| `trial_reminder_opt_in` | — |
| `upsell_shown`, `upsell_tapped` | `trigger` |
| `heard_about` | `source` (Mac onboarding's one-tap "Where did you hear about us?") |

Enums: `surface` = `paywall`, `sheet`, `strip`, `banner`, `notification`, `settings`, `account`, `confirmation`;
`trigger` = `trial_note_ready`, `trial_ending`, `trial_ended`, `subscription_required`, `plan_choice`,
`monthly_warning`, `monthly_full`, `win_back`, `trial_reminder`, `meeting_start`; `tiersOffered` = `personal`,
`personal_pro`; `tier` = `personal`, `pro`; `plan` = `monthly`, `yearly`; `reason` = `products_unavailable`,
`store_error`, `payment_pending`, `purchase_not_allowed`, `network`, `server`, `entitlement_timeout`, `not_signed_in`,
`configuration`; `result` = `restored`, `nothing_found`; `channel` = `in_app`, `notification`; `source` = `search`,
`app_store`, `social`, `friend`, `ai_assistant`, `video`, `blog`, `ad`, `other` (stored in `reason`).
Platform is derived on the server from `x-os-version`. Stored in `conversion_events_daily` (migration 0063), 400 days.
Server also counts `POST /v1/billing/checkout` per day by source (`app`/`web`), tier and plan (`kind =
"checkout_created"`, `platform = "server"`).

## 11. Owner decisions (2026-11-08) and follow-ups

- All review recommendations accepted. Turkish plan name: "Gistsmith Kişisel".
- EU online withdrawal function: built for Stripe/Link purchases (`POST /v1/billing/withdraw`, `/account`), 14 days from
  the subscription start, pro-rata refund, on-screen acknowledgement; Link emails the refund receipt. The refund is
  computed over the whole subscription (every invoice line by the unused share of its own period; a plan change's
  balance credit is paid out and taken off the balance), so a downgrade can't be refunded twice. Until every refund
  has succeeded the withdrawal stays pending (`/v1/me` `withdrawalPending`, retry on `/account`, daily Cron retry).
- Apple Ads attribution: the iPhone app turns on RevenueCat's AdServices token collection (no IDFA, no tracking
  prompt) for the Apple Ads test; App Privacy declares Advertising Data (developer advertising, analytics).
- Mac onboarding asks once "Where did you hear about us?" (one tap, fixed list, daily totals, hidden while usage
  statistics are off); admin Telemetry › Conversion shows the counts.
- Yearly renewal reminder (California ARL): Managed Payments already emails before every 12-month anniversary from
  Link, even with "Upcoming renewals" off (default 15 days; Stripe › Settings › Billing › Subscriptions and emails ›
  Upcoming renewal events). No server email needed; the owner keeps that timing at 15–45 days.

### 0.2.4: "Record now, subscribe after" (spec item, not built)

When a trial-ended user taps Start, offer "Record now, subscribe after": before recording starts the app says that the
recording stays only on this device and gets its note once they subscribe, and "Delete recording" is as visible as
"Subscribe". At most one pending unpaid recording per account; it is kept on the device for 7 days, then deleted
(with a notice the day before). Nothing is uploaded until the account has access; then the normal deferred-meeting path
(`deferred: true`) processes it. Measure with a `meeting_start` trigger split (`record_later_chosen`,
`record_later_converted`). Open questions for the owner: storage cap per pending recording, and whether it applies on
both Mac and iPhone (it should, for parity).
