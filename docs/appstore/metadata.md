# Gistsmith for iPhone: localized product page metadata

Paste-ready App Store Connect metadata for 14 localizations: English (U.S.), English (U.K.), Turkish, Finnish,
German, French, Spanish (Spain), Spanish (Mexico), Italian, Portuguese (Brazil), Dutch, Japanese, Korean and Chinese
(Simplified). The app's interface ships in all of these languages (Spanish uses one `es` translation for both
storefronts). Every claim matches the iPhone app as of 0.2.1: it records only the conversation around the iPhone with
its microphone. It never records phone calls or online meetings, and it never joins a meeting. Share links and AI
assistant access arrive with 0.2.1, so this copy goes on the first editable version after it (0.2.2).

Limits: App Name and Subtitle ≤ 30 characters, Promotional Text ≤ 170, Description ≤ 4000, Keywords ≤ 100 bytes
(UTF-8, so Turkish, Finnish and accented letters count 2 bytes and Japanese, Korean and Chinese 3; comma-separated,
no spaces after commas), What's New ≤ 4000. `node scripts/appstore-screenshots/metadata-check.ts
docs/appstore/metadata.md docs/appstore/custom-product-pages.md` checks every block in this file against those
limits and against the keyword rules below. Run it after each edit.

Meetings can be held in 35 languages and notes, translations and answers can be written in 37. The copy never says
"unlimited" and states the trial as "first 3 meetings or 7 days, whichever comes first". Prices are written only in
the U.S. description; the other storefronts show their own price and currency in the app and on the subscription
list. Feature names are the ones the app shows in that language (`App/Localizable.xcstrings`: Ask, My tasks, the
template names, "What did I miss?").

## App Privacy label and App Review notes: AI assistant access

AI assistant access (Mac: Settings › Connections › AI assistant access; iPhone: Settings › AI assistant access; off by default) uploads an encrypted copy of each
meeting's notes (title, date, length, folder, attendee names, the AI note and the user's own notes; never audio,
transcripts, screen snapshots or voice profiles) so that AI assistants the user connects through
https://mcp.gistsmith.com/mcp can read them. The server can read this copy (encrypted at rest, not end to end).

- **App Privacy label** (App Store Connect › App Privacy): declare **User Content › Other User Content** (meeting
  notes), **Linked to You**, purpose **App Functionality**, not used for tracking. It is collected only when the user
  turns AI assistant access on; the label has no "optional" flag, so declare it, and the privacy policy (section 3)
  explains that it is off by default. The label must be in place before the PRIVACY paragraphs below go live, because
  they describe this copy.
- **App Review notes** (App Review Information › Notes), one line:
  `AI assistant access (iPhone: Settings › AI assistant access) is off by default; when turned on, an encrypted copy of meeting notes (no audio or transcripts) is stored in the EU so AI assistants the user connects via OAuth at https://mcp.gistsmith.com/mcp can read them; turning it off deletes the copy at once.`

## App Privacy label: the full answer set for the iPhone app

Derived from what the iPhone app and the server do on `main`. Apple counts data as collected when it leaves the device
and is kept longer than it takes to answer the request, by us or by a provider (ElevenLabs and Anthropic keep request
data for a time, so meeting audio and text count even though our server keeps none of it). A type collected only
behind an off-by-default setting is still declared. Tracking: **No** for every type (no ads, no data brokers, no
cross-app linking). "Linked" means stored with or sent under the account ID.

| Apple category › type | Linked to you | Purposes | What it is in Gistsmith (code) |
| --- | --- | --- | --- |
| Contact Info › Email Address | Yes | App Functionality | Optional reply address in feedback (`iOS/PhoneFeedback.swift`, `server/src/reports.ts`). The sign-in token's email is not stored. |
| Contact Info › Name | Yes | App Functionality | The user's name sent with a follow-up email draft and for "your tasks" in notes (`follow_up_email`, note prompts) to Anthropic. |
| User Content › Audio Data | Yes | App Functionality | Meeting audio and imported recordings: live stream to Deepgram, final pass through our server to ElevenLabs. |
| User Content › Photos or Videos | Yes | App Functionality | Meeting photos sent to Anthropic only with "Use photos in notes" on (`iOS/MeetingPhotos.swift`); imported videos' audio. |
| User Content › Customer Support | Yes | App Functionality | Feedback messages and their optional diagnostics (`server/src/reports.ts`, 180 days). |
| User Content › Other User Content | Yes | App Functionality | Transcripts, notes, Ask questions, attendee and speaker names, profile fields (job title, company), shared-link notes and the sync copy (both end-to-end encrypted), the AI assistant copy. |
| Search History | Yes | App Functionality | Ask questions and the web search queries Claude writes from them (Anthropic keeps them up to 30 days). |
| Identifiers › User ID | Yes | App Functionality | Account ID; it is also the RevenueCat app user ID (`iOS/Purchases/AppStorePurchases.swift`). |
| Identifiers › Device ID | Yes | App Functionality | The app-generated random device ID used by sync and the AI assistant copy (no IDFA, no IDFV sent by us). |
| Purchases › Purchase History | Yes | App Functionality | App Store subscription product, status and period through RevenueCat (`server/src/appStore.ts`). |
| Usage Data › Product Interaction | No | Analytics | "Share anonymous usage statistics" (on by default): daily feature flags, first launch and sign-in steps, daily totals without an account (`server/src/telemetry.ts`, `funnel.ts`). |
| Usage Data › Advertising Data | Yes | Developer's Advertising or Marketing, Analytics | The Apple Ads attribution token (AdServices; no IDFA, no tracking prompt) that the RevenueCat SDK sends under the account ID so RevenueCat can ask Apple which Apple Ads campaign led to the install (`iOS/Purchases/AppStorePurchases.swift`). |
| Usage Data › Other Usage Data | Yes | App Functionality | Meeting session times, audio duration, AI tokens and web search counts per account for the plan limits (13 months). |
| Diagnostics › Crash Data | Yes | App Functionality | Crash reports, sent only when the user taps Send, linked to the account (`iOS/CrashReportsSection.swift`). |
| Diagnostics › Performance Data | No | App Functionality, Analytics | Reliability counts and final-pass and note durations in the anonymous statistics. |
| Diagnostics › Other Diagnostic Data | Yes | App Functionality | App and iOS version kept on the account; the optional diagnostics text in feedback. |

Not collected: Health and Fitness, Financial Info (Apple handles payment), Location (the IP address is used only for
rate limits and kept as a keyed hash until the end of the day), Sensitive Info (voiceprints for speaker recognition stay
on the iPhone and are excluded from device backups), Contacts (calendar attendee names are meeting content, above),
Browsing History, Emails or Text Messages, Gameplay Content. RevenueCat's SDK runs in the app: check
its current App Privacy guidance when you submit and add any type it lists that is missing here.

Types that open pull requests add before they ship: the dialer pilot adds Contact Info › Phone Number (the verified
caller number) and the called numbers as Other User Content, with Twilio as a processor; quote consent in feedback adds
nothing new (Name and Customer Support are declared).

## Pro tier (dark until launch): App Store Connect and App Review

The second tier (server `PRO_TIER_POLICY`, `server/README.md` › "Pro katmanı") sells
`com.senoldogan.gistsmith.pro.monthly` and `.pro.yearly` in the same subscription group as the existing products.
Until the owner launches it, the copy on this page stays as it is.

- **Naming.** In App Store Connect the subscription group's display name is already "Gistsmith" and the existing
  products are "Gistsmith Monthly/Yearly"; only the Description's PRICING paragraph called the existing plan "Gistsmith
  Pro". It now names it "Gistsmith Personal" ("Gistsmith Kişisel" in Turkish, the plan name the Turkish app shows),
  which is the copy for 0.2.3 while Pro stays off. At 0.2.3 submission the owner pushes this store metadata and renames
  the existing products to the Personal names, and names the Pro products, through the App Store Connect API, using the
  table in `after-approval-checklist.md` (§2 step 5).
- **PRICING at Pro launch.** Each locale below has a "PRICING — when Pro is on" block after its Description: at launch
  it replaces the PRICING heading and paragraph inside that Description (every Description stays ≤ 4000 characters
  with a two-digit hour count). Replace `{PRO_HOURS}` with the production `PRO_MONTHLY_CAP_HOURS` value
  (`server/wrangler.jsonc`, production vars) before pasting; prices stay in the U.S. description only.
- **Group levels.** Pro above Personal (level 1 Pro, level 2 Personal): Personal → Pro is then an immediate upgrade with a
  prorated refund, Pro → Personal starts at the next renewal.
- **Review screenshot** (each new in-app purchase › App Review Information › Screenshot): the iPhone paywall with the
  Pro option visible. Debug build in the iPhone 6.9″ Simulator with `--tanitim --paywall` (demo data offers Pro; local
  server not needed); 1320×2868 PNG. Review note for each product, one line:
  `Gistsmith Pro is the same app with more meeting hours per month than Gistsmith Personal; open the subscription screen (Subscribe on the home screen, or Account › Change plan when subscribed) and choose Pro. The reviewer account from the app's review notes can buy it in the sandbox.`
- **RevenueCat.** Attach both Pro products to the access entitlement used by the app and to `pro_tier`; the
  `pro_preview` offering holds the Personal and Pro packages. Make `pro_preview` the current offering only when the server
  switch goes on: the iPhone shows Pro only when both the server offers it and the current offering contains it.

## Keyword strategy

### Which localizations each storefront searches

Apple's table [App Store localizations](https://developer.apple.com/help/app-store-connect/reference/app-store-localizations/)
(App Store Connect Help › Reference, checked 2026-11-07) lists a default language and additional languages for every
storefront. The App Store searches the name, subtitle and keywords of every listed localization the app has, so one
storefront can read two or more of our 100-byte keyword sets. Rows for the storefronts we target, with the
localizations from this file that each one reads:

| Storefront | Apple: default + additional languages | Our localizations it reads |
|------------|---------------------------------------|----------------------------|
| United States | English (US) + Arabic, Chinese (Simplified), Chinese (Traditional), French, Korean, Portuguese (Brazil), Russian, Spanish (Mexico), Vietnamese | en-US, es-MX, fr, ko, pt-BR, zh-Hans |
| United Kingdom | English (U.K.) | en-GB |
| Ireland | English (U.K.) | en-GB |
| Australia | English (Australia) + English (U.K.) | en-GB |
| Canada | English (Canada) + French (Canada) | none (shows the primary, en-US) |
| Mexico, Argentina, Colombia, Chile | Spanish (Mexico) + English (U.K.) | es-MX, en-GB |
| Spain | Spanish (Spain) + Catalan, English (U.K.) | es-ES, en-GB |
| Germany, Austria | German + English (U.K.) | de, en-GB |
| Switzerland | German + English (U.K.), French, Italian | de, en-GB, fr, it |
| France | French + English (U.K.) | fr, en-GB |
| Belgium | English (U.K.) + Dutch, French | en-GB, nl, fr |
| Italy | Italian + English (U.K.) | it, en-GB |
| Brazil | Portuguese (Brazil) + English (U.K.) | pt-BR, en-GB |
| Netherlands | Dutch + English (U.K.) | nl, en-GB |
| Japan | Japanese + English (US) | ja, en-US |
| Republic of Korea | Korean + English (U.K.) | ko, en-GB |
| China mainland | Simplified Chinese + English (U.K.) | zh-Hans, en-GB |
| Singapore | English (U.K.) + Chinese (Simplified) | en-GB, zh-Hans |
| Finland | English (U.K.) + Finnish | en-GB, fi |
| Türkiye | English (U.K.) + Turkish | en-GB, tr |

What follows from the table:

- **en-US and en-GB are never read together.** The U.S. storefront doesn't read en-GB and the U.K. storefront reads
  only en-GB (Australia reads en-GB too, not the other way round). So both English sets are complete on their own and
  may share words.
- **en-GB is the English set for most of the world.** It is the second localization in Mexico, Spain, Germany, France,
  Italy, Brazil, the Netherlands, Korea, China, Finland and Türkiye. A local set never repeats an en-GB keyword
  (German users typing "interview" already match en-GB), which frees bytes for words only that language uses.
  Japan reads en-US instead, so the Japanese set avoids en-US words.
- **The U.S. storefront reads six sets.** en-US carries English and es-MX carries Spanish for U.S. Spanish speakers,
  as well as Mexico and Latin America. fr, ko, pt-BR and zh-Hans add their own words in the U.S. too. en-US repeats
  none of their keywords.
- **Overlaps between two non-English sets are kept on purpose** when each set's home storefront doesn't read the
  other one (es-MX and pt-BR both have "entrevista" and "texto": Brazil doesn't read es-MX and Mexico doesn't read
  pt-BR). The duplicate costs bytes only in the U.S.
- The checker enforces this: a keyword is a problem when another localization read by the same home storefront
  already has it as a keyword (home storefront: U.S. for en-US, U.K. for en-GB, Mexico for es-MX, Spain for es-ES,
  and each language's own country for the rest).

### Rules for every set

- **Name + subtitle + keywords make one index per localization.** A word already in the name or subtitle gains
  nothing when repeated in keywords. The App Store combines words across fields ("meeting" + "notes" + "summary"), so
  single words beat phrases, and a compound phrase is split into its words ("compte,rendu").
- **Singular forms only**, no "free", no "app", no competitor or platform names (Otter, Granola, Plaud, Fireflies,
  Notta, Zoom, Teams, …) and no "call" terms: the iPhone app records in-person conversations only.
- **Fill the 100 bytes** (the checker wants at least 95; a 3-byte script can land on 96–99).
- **Each language is written for how people search, not translated.** Finnish compounds don't match their parts
  ("kokousmuistiinpanot" doesn't match "muistiinpano"), so the base words are listed separately. Turkish users type
  "ses kaydı", "deşifre" and "tutanak"; Germans "Protokoll", "Besprechung" and "Diktiergerät"; French "compte rendu"
  and "PV"; Spaniards "grabadora", "acta" and "dictáfono"; Mexicans "junta" and "minuta"; Italians "verbale" and
  "registratore"; Brazilians "ata" and "gravador"; Dutch "notulen" and "verslag"; Japanese 議事録 and 文字起こし;
  Koreans 회의록 and 녹취; Chinese 会议纪要 and 录音转文字.
- **The name adds a keyword phrase after "Gistsmith"** ("Gistsmith: AI Meeting Notes"). The name is the
  heaviest-weighted field, and the phrase tells a searcher what the brand does. "Gistsmith" stays first and exact.

### Later

- Add **English (Australia)** (copy of en-GB with a different keyword set: Australia reads en-AU and en-GB) and
  **English (Canada)** / **French (Canada)** (Canada reads neither en-US nor en-GB keywords today).
- Revisit after 4 weeks in **Analytics › Acquisition › Search**: drop words with impressions but no installs, and
  try a stronger word in their place.

---

## English (U.S.) — `en-US`

Primary localization. It replaces the launch copy (name "Gistsmith", subtitle "AI meeting notes & tasks").

### Name

```text
Gistsmith: AI Meeting Notes
```

### Subtitle

```text
Record, transcribe & summarize
```

### Promotional Text

```text
Put your iPhone on the table. When the meeting ends, your note is ready: summary, decisions and tasks. Ask anything about past meetings. First 3 meetings or 7 days free.
```

### Keywords

```text
transcription,recorder,voice,memo,minute,summary,notetaker,lecture,interview,audio,speech,text,task
```

### Description

```text
Gistsmith turns the conversation around your iPhone into clear meeting notes. Put your phone on the table, tap record and keep talking. When the meeting ends, your note is ready: a summary, the decisions made and everyone's tasks.

Made for meetings in the room: one-on-ones, team meetings, client visits, interviews, lectures and workshops. Gistsmith listens through your iPhone's microphone. It doesn't record phone calls or online meetings, and there's no bot to invite.

RECORD
• Live transcript as you talk, with speakers separated
• Live translation when the meeting is in another language
• "What did I miss?" sums up the last few minutes while you're still recording
• Keeps recording in the background, with progress on the Lock Screen and in the Dynamic Island
• Start from Control Center, the Action button, a widget, Siri or Shortcuts
• Import audio or video recordings from Files or Photos

YOUR NOTE, READY WHEN THE MEETING ENDS
• A summary, the decisions, open questions and every task with its owner and due date
• The topics in order with timestamps, and a glossary of names and terms
• Templates for one-on-ones, daily stand-ups, sprint planning, retrospectives, client meetings, job interviews, user research and lectures, or write your own
• Notes you type during the meeting shape the final note
• Edit with a plain instruction such as "shorten the summary"
• Share as PDF, Markdown, plain text or SRT subtitles, or send an end-to-end encrypted link that expires

ASK YOUR MEETINGS
• Ask questions across all your meetings; each answer shows the meetings it came from
• Ready-made prompts such as Follow-up email, Prep my day, and Risks and open questions
• Before a meeting, a briefing on earlier meetings with the same people: decisions and open tasks

STAY ON TOP OF IT
• My tasks: the tasks from every meeting in one list; add any of them to Reminders
• Today's meetings from your calendar, with an optional reminder before they start
• People and companies: name speakers once, then see each person's meetings, talk time and tasks
• Search titles, people and transcripts

MAC AND IPHONE
One account and one subscription for Gistsmith on Mac and iPhone. Turn on sync to see your meetings, notes, tasks and people on both. Sync is end-to-end encrypted, and audio stays on the device that recorded it.

YOUR AI ASSISTANT
If you like, connect Claude or ChatGPT to your meeting notes in Settings › AI assistant access, so your assistant can search and read them. It never gets your audio or transcripts.

LANGUAGES
Meetings in 35 languages. Notes, translations and answers in 37. The app itself is in 12 languages.

PRIVACY
Your meetings are not used to train AI models. Audio is sent only to make the transcript and the note, and our servers don't keep it. Sync stores only an end-to-end encrypted copy. AI assistant access is off by default; when you turn it on, an encrypted copy of your notes (never audio) is kept in the EU so the assistants you connect can read it, and turning it off deletes it at once. You choose how long recordings stay on your iPhone, from 7 to 365 days. Tell the people in the room before you record.

PRICING
Your first 3 meetings or 7 days are free, whichever comes first (sign-in required; trial meetings up to 90 minutes each). After that, Gistsmith Personal is a monthly ($5.99) or yearly ($49) auto-renewing subscription with 10 hours of recording a month (fair use) and up to 4 hours per meeting. Prices are in U.S. dollars; the app shows the price for your country before you buy. Payment is charged to your Apple Account when you confirm. The subscription renews automatically unless you turn it off at least 24 hours before the end of the current period. Manage or cancel it in your Apple Account settings.

Terms of Use: https://gistsmith.com/terms
Privacy Policy: https://gistsmith.com/privacy
```

### PRICING — when Pro is on (replace the paragraph above at Pro launch)

```text
PRICING
Your first 3 meetings or 7 days are free, whichever comes first (sign-in required; trial meetings up to 90 minutes each). After that, choose an auto-renewing subscription: Gistsmith Personal, monthly ($5.99) or yearly ($49), with 10 hours of recording a month, or Gistsmith Pro, monthly ($12.99) or yearly ($109), with {PRO_HOURS} hours of recording a month. Both are fair use, with up to 4 hours per meeting. Prices are in U.S. dollars; the app shows the price for your country before you buy. Payment is charged to your Apple Account when you confirm. The subscription renews automatically unless you turn it off at least 24 hours before the end of the current period. Manage or cancel it in your Apple Account settings.
```

---

## English (U.K.) — `en-GB`

### Name

```text
Gistsmith: AI Meeting Notes
```

### Subtitle

```text
Record, transcribe & summarise
```

### Promotional Text

```text
Put your iPhone on the table. When the meeting ends, your note is ready: summary, decisions and to-dos. Ask anything about past meetings. First 3 meetings or 7 days free.
```

### Keywords

```text
transcription,dictaphone,recorder,voice,memo,minute,summary,notetaker,lecture,interview,speech,text
```

### Description

```text
Gistsmith turns the conversation around your iPhone into clear meeting notes. Put your phone on the table, tap record and keep talking. When the meeting ends, your note is ready: a summary, the decisions made and everyone's tasks.

Made for meetings in the room: one-to-ones, team meetings, client visits, interviews, lectures and workshops. Gistsmith listens through your iPhone's microphone. It doesn't record phone calls or online meetings, and there's no bot to invite.

RECORD
• Live transcript as you talk, with speakers separated
• Live translation when the meeting is in another language
• "What did I miss?" sums up the last few minutes while you're still recording
• Keeps recording in the background, with progress on the Lock Screen and in the Dynamic Island
• Start from Control Centre, the Action button, a widget, Siri or Shortcuts
• Import audio or video recordings from Files or Photos

YOUR NOTE, READY WHEN THE MEETING ENDS
• A summary, the decisions, open questions and every task with its owner and due date
• The topics in order with timestamps, and a glossary of names and terms
• Templates for one-to-ones, daily stand-ups, sprint planning, retrospectives, client meetings, job interviews, user research and lectures, or write your own
• Notes you type during the meeting shape the final note
• Edit with a plain instruction such as "shorten the summary"
• Share as PDF, Markdown, plain text or SRT subtitles, or send an end-to-end encrypted link that expires

ASK YOUR MEETINGS
• Ask questions across all your meetings; each answer shows the meetings it came from
• Ready-made prompts such as Follow-up email, Prep my day, and Risks and open questions
• Before a meeting, a briefing on earlier meetings with the same people: decisions and open tasks

STAY ON TOP OF IT
• My tasks: the tasks from every meeting in one list; add any of them to Reminders
• Today's meetings from your calendar, with an optional reminder before they start
• People and companies: name speakers once, then see each person's meetings, talk time and tasks
• Search titles, people and transcripts

MAC AND IPHONE
One account and one subscription for Gistsmith on Mac and iPhone. Turn on sync to see your meetings, notes, tasks and people on both. Sync is end-to-end encrypted, and audio stays on the device that recorded it.

YOUR AI ASSISTANT
If you like, connect Claude or ChatGPT to your meeting notes in Settings › AI assistant access, so your assistant can search and read them. It never gets your audio or transcripts.

LANGUAGES
Meetings in 35 languages. Notes, translations and answers in 37. The app itself is in 12 languages.

PRIVACY
Your meetings are not used to train AI models. Audio is sent only to make the transcript and the note, and our servers don't keep it. Sync stores only an end-to-end encrypted copy. AI assistant access is off by default; when you turn it on, an encrypted copy of your notes (never audio) is kept in the EU so the assistants you connect can read it, and turning it off deletes it at once. You choose how long recordings stay on your iPhone, from 7 to 365 days. Tell the people in the room before you record.

PRICING
Your first 3 meetings or 7 days are free, whichever comes first (sign-in required; trial meetings up to 90 minutes each). After that, Gistsmith Personal is a monthly or yearly auto-renewing subscription with 10 hours of recording a month (fair use) and up to 4 hours per meeting. The price for your country is shown in the app before you buy. Payment is charged to your Apple Account when you confirm. The subscription renews automatically unless you turn it off at least 24 hours before the end of the current period. Manage or cancel it in your Apple Account settings.

Terms of Use: https://gistsmith.com/terms
Privacy Policy: https://gistsmith.com/privacy
```

### PRICING — when Pro is on (replace the paragraph above at Pro launch)

```text
PRICING
Your first 3 meetings or 7 days are free, whichever comes first (sign-in required; trial meetings up to 90 minutes each). After that, choose a monthly or yearly auto-renewing subscription: Gistsmith Personal, with 10 hours of recording a month, or Gistsmith Pro, with {PRO_HOURS} hours of recording a month. Both are fair use, with up to 4 hours per meeting. The price for your country is shown in the app before you buy. Payment is charged to your Apple Account when you confirm. The subscription renews automatically unless you turn it off at least 24 hours before the end of the current period. Manage or cancel it in your Apple Account settings.
```

### What's New (template for feature updates)

Feature update: replace the bracketed lines with real, user-facing changes (see `docs/release-notes/`).

```text
Gistsmith [version] [one sentence: the main benefit of this update].

New
• [Feature]: [what you can do now, in one sentence].

Improvements
• [What works better for you].
• Fixes and reliability improvements.
```

Maintenance update:

```text
This update makes recording and note writing more reliable and fixes a few issues. Thanks for your feedback. Write to us from Settings › Send feedback.
```

---

## Turkish — `tr`

### Name

```text
Gistsmith: AI Toplantı Notları
```

### Subtitle

```text
Ses kaydı, deşifre ve özet
```

### Promotional Text

```text
iPhone'unu masaya koy; toplantı bittiğinde notun hazır: özet, kararlar ve görevler. Geçmiş toplantılarına soru sor. İlk 3 toplantı ya da 7 gün ücretsiz.
```

### Keywords

```text
transkript,tutanak,yazıya,çevirme,kaydedici,kayıt,ders,mülakat,görüşme,görev,sesli,not,metin
```

### Description

```text
Gistsmith, iPhone'unun çevresindeki konuşmayı net toplantı notlarına dönüştürür. Telefonunu masaya koy, kayda bas ve konuşmaya devam et. Toplantı bittiğinde notun hazır: özet, alınan kararlar ve herkesin görevleri.

Yüz yüze toplantılar için: birebir görüşmeler, ekip toplantıları, müşteri ziyaretleri, mülakatlar, dersler ve atölyeler. Gistsmith iPhone'unun mikrofonuyla dinler. Telefon görüşmelerini ya da çevrim içi toplantıları kaydetmez; davet edilecek bir bot da yok.

KAYIT
• Konuşurken canlı metin; konuşmacılar ayrı ayrı
• Toplantı başka bir dildeyse canlı çeviri
• "Ne kaçırdım?" kayıt sürerken son birkaç dakikayı özetler
• Arka planda kayda devam eder; ilerleme kilit ekranında ve Dynamic Island'da
• Denetim Merkezi'nden, Eylem düğmesinden, widget'tan, Siri'yle ya da Kestirmeler'le başlat
• Dosyalar'dan ya da Fotoğraflar'dan ses ve video kayıtlarını içe aktar

TOPLANTI BİTTİĞİNDE NOTUN HAZIR
• Özet, kararlar, açık konular ve sahibi ile tarihi belli her görev
• Zaman damgalı konu akışı; adlar ve terimler için sözlük
• Şablonlar: birebir görüşme, günlük durum (stand-up), sprint planlama, retrospektif, müşteri görüşmesi, iş mülakatı, kullanıcı araştırması, ders / eğitim ya da kendi şablonun
• Toplantı sırasında yazdığın notlar son nota yansır
• "Özeti kısalt" gibi düz bir yönergeyle düzenle
• PDF, Markdown, düz metin ya da SRT altyazı olarak paylaş; ya da süresi dolan, uçtan uca şifreli bir bağlantı gönder

SOR
• Tüm toplantılarına soru sor; her cevap dayandığı toplantıları gösterir
• Hazır istemler: Takip e-postası, Bugüne hazırlan, Riskler ve açık sorular ve daha fazlası
• Toplantıdan önce aynı kişilerle yaptığın önceki toplantıların brifingi: kararlar ve açık görevler

HİÇBİR ŞEY KAÇMASIN
• Görevlerim: tüm toplantılardaki görevlerin tek listede; istediğini Anımsatıcılar'a ekle
• Takviminden bugünün toplantıları; istersen başlamadan önce hatırlatma
• Kişiler ve şirketler: konuşmacılara bir kez ad ver; her kişinin toplantılarını, konuşma süresini ve görevlerini gör
• Başlıklarda, kişilerde ve transkriptlerde ara

MAC VE IPHONE
Mac ve iPhone'da Gistsmith için tek hesap ve tek abonelik. Eşitlemeyi açınca toplantıların, notların, görevlerin ve kişilerin iki cihazda da görünür. Eşitleme uçtan uca şifrelidir; ses, kaydedildiği cihazda kalır.

YAPAY ZEKÂ ASİSTANIN
İstersen Ayarlar › Yapay zekâ asistanı erişimi'nden Claude'u ya da ChatGPT'yi toplantı notlarına bağla; asistanın notlarında arama yapıp onları okuyabilsin. Sesine ve transkriptlerine hiçbir zaman erişemez.

DİLLER
Toplantılar 35 dilde; notlar, çeviriler ve cevaplar 37 dilde, Türkçe dahil. Uygulamanın arayüzü Türkçe dahil 12 dilde.

GİZLİLİK
Toplantıların yapay zekâ modellerini eğitmek için kullanılmaz. Ses yalnızca transkript ve not üretmek için gönderilir; sunucularımız sesini saklamaz. Eşitleme yalnızca uçtan uca şifreli bir kopya tutar. Yapay zekâ asistanı erişimi varsayılan olarak kapalıdır; açarsan notlarının şifreli bir kopyası (ses asla) bağladığın asistanlar okuyabilsin diye AB'de saklanır, kapatınca hemen silinir. Kayıtların iPhone'unda ne kadar kalacağını sen seçersin: 7 ile 365 gün arası. Kayda başlamadan önce odadakilere söyle.

FİYAT
İlk 3 toplantı ya da 7 gün ücretsiz, hangisi önce dolarsa (giriş gerekir; deneme toplantıları en çok 90 dakika). Sonrasında Gistsmith Kişisel, aylık ya da yıllık otomatik yenilenen bir aboneliktir: ayda 10 saat kayıt (adil kullanım) ve toplantı başına en çok 4 saat. Ülkendeki fiyat satın almadan önce uygulamada gösterilir. Ödeme, onayladığında Apple Hesabı'ndan alınır. Abonelik, dönem bitmeden en az 24 saat önce kapatılmazsa kendiliğinden yenilenir. Apple Hesabı ayarlarından yönetebilir ya da iptal edebilirsin.

Kullanım Koşulları: https://gistsmith.com/terms
Gizlilik Politikası: https://gistsmith.com/privacy
```

### PRICING — when Pro is on (replace the paragraph above at Pro launch)

```text
FİYAT
İlk 3 toplantı ya da 7 gün ücretsiz, hangisi önce dolarsa (giriş gerekir; deneme toplantıları en çok 90 dakika). Sonrasında aylık ya da yıllık otomatik yenilenen iki abonelikten birini seçersin: ayda 10 saat kayıtla Gistsmith Kişisel ya da ayda {PRO_HOURS} saat kayıtla Gistsmith Pro. İkisinde de adil kullanım geçerlidir ve toplantı başına en çok 4 saat kaydedilir. Ülkendeki fiyat satın almadan önce uygulamada gösterilir. Ödeme, onayladığında Apple Hesabı'ndan alınır. Abonelik, dönem bitmeden en az 24 saat önce kapatılmazsa kendiliğinden yenilenir. Apple Hesabı ayarlarından yönetebilir ya da iptal edebilirsin.
```

### What's New (template)

```text
Gistsmith [sürüm] [bu güncellemenin tek cümlelik asıl faydası].

Yeni
• [Özellik]: [artık ne yapabildiğin, tek cümle].

İyileştirmeler
• [Senin için daha iyi çalışan şey].
• Hata düzeltmeleri ve kararlılık iyileştirmeleri.
```

Maintenance update:

```text
Bu güncelleme kaydı ve not yazımını daha güvenilir hale getiriyor ve birkaç hatayı düzeltiyor. Geri bildirimin için teşekkürler; bize Ayarlar › Geri bildirim gönder'den yazabilirsin.
```

---

## Finnish — `fi`

### Name

```text
Gistsmith: Kokousmuistiinpanot
```

### Subtitle

```text
Litterointi, muistio, tehtävät
```

### Promotional Text

```text
Laita iPhone pöydälle. Kun kokous päättyy, muistiinpano on valmis: yhteenveto, päätökset ja tehtävät. Kysy aiemmista kokouksista. 3 kokousta tai 7 päivää ilmaiseksi.
```

### Keywords

```text
muistiinpano,palaveri,kokous,pöytäkirja,nauhuri,sanelin,äänite,luento,haastattelu,puhe,tekstiksi
```

### Description

```text
Gistsmith tekee iPhonesi ympärillä käydystä keskustelusta selkeät kokousmuistiinpanot. Laita puhelin pöydälle, aloita nauhoitus ja jatka keskustelua. Kun kokous päättyy, muistiinpano on valmis: yhteenveto, tehdyt päätökset ja jokaisen tehtävät.

Tehty kasvokkain pidettäviin kokouksiin: kahdenkeskisiin keskusteluihin, tiimikokouksiin, asiakastapaamisiin, haastatteluihin, luentoihin ja työpajoihin. Gistsmith kuuntelee iPhonesi mikrofonilla. Se ei nauhoita puheluita eikä verkkokokouksia, eikä kokoukseen kutsuta bottia.

SUOMI TOIMII TÄYSIN
Litterointi, muistiinpanot, käännökset, vastaukset ja koko sovellus suomeksi.

NAUHOITUS
• Litterointi reaaliajassa puhuessanne, puhujat eroteltuina
• Reaaliaikainen käännös, jos kokous käydään toisella kielellä
• ”Mitä jäi välistä?” tiivistää viimeiset minuutit, kun nauhoitus on vielä käynnissä
• Nauhoitus jatkuu taustalla, ja sen eteneminen näkyy lukitusnäytöllä ja Dynamic Islandissa
• Aloita Ohjauskeskuksesta, Toimintopainikkeella, widgetistä, Sirillä tai Pikakomennoilla
• Tuo ääni- ja videotiedostoja Tiedostoista tai Kuvista

MUISTIINPANO ON VALMIS, KUN KOKOUS PÄÄTTYY
• Yhteenveto, päätökset, avoimet kysymykset ja jokainen tehtävä tekijöineen ja määräaikoineen
• Aiheiden kulku aikaleimoineen sekä nimien ja termien sanasto
• Pohjat: kahden kesken, päiväpalaveri, sprintin suunnittelu, retrospektiivi, asiakastapaaminen, työhaastattelu, käyttäjätutkimus ja luento / koulutus, tai oma pohjasi
• Muokkaa muistiinpanoa omin sanoin, esimerkiksi ”lyhennä yhteenvetoa”
• Jaa PDF:nä, Markdownina, tekstinä tai SRT-tekstityksenä, tai lähetä päästä päähän salattu linkki, joka vanhenee

KYSY
• Kysy kaikista kokouksistasi; jokainen vastaus näyttää, mistä kokouksista se on peräisin
• Valmiit kehotteet, kuten Jatkosähköposti, Valmistele päiväni sekä Riskit ja avoimet kysymykset
• Ennen kokousta taustakatsaus aiemmista kokouksista samojen ihmisten kanssa: päätökset ja avoimet tehtävät

PYSY AJAN TASALLA
• Omat tehtävät: kaikkien kokousten tehtävät yhdessä luettelossa; lisää haluamasi Muistutuksiin
• Päivän kokoukset kalenteristasi ja halutessasi muistutus ennen alkua
• Henkilöt ja yritykset: nimeä puhujat kerran ja näe jokaisen kokoukset, puheaika ja tehtävät

MAC JA IPHONE
Yksi tili ja yksi tilaus Gistsmithille Macissa ja iPhonessa. Kun otat synkronoinnin käyttöön, kokoukset, muistiinpanot, tehtävät ja henkilöt näkyvät molemmissa. Synkronointi on päästä päähän salattu, ja ääni jää laitteelle, jolla se nauhoitettiin.

TEKOÄLYAVUSTAJASI
Voit yhdistää Clauden tai ChatGPT:n muistiinpanoihisi kohdassa Asetukset › Tekoälyavustajien pääsy, jolloin avustaja voi hakea ja lukea niitä. Toiminto on oletuksena pois päältä. Muistiinpanoistasi säilytetään salattu kopio EU:ssa (ei koskaan ääntä eikä litterointeja), ja se poistetaan heti, kun poistat toiminnon käytöstä.

KIELET
Kokoukset 35 kielellä, myös suomeksi. Muistiinpanot, käännökset ja vastaukset 37 kielellä. Sovellus on käytettävissä 12 kielellä, myös suomeksi.

TIETOSUOJA
Kokouksiasi ei käytetä tekoälymallien kouluttamiseen. Ääni lähetetään vain litterointia ja muistiinpanoa varten, eivätkä palvelimemme säilytä sitä. Synkronointi säilyttää vain päästä päähän salatun kopion. Valitset itse, kuinka kauan nauhoitteet säilyvät iPhonessasi: 7–365 päivää. Kerro huoneessa oleville ennen nauhoitusta.

HINNOITTELU
3 ensimmäistä kokousta tai 7 päivää ilmaiseksi, kumpi täyttyy ensin (vaatii kirjautumisen; kokeilukokous enintään 90 minuuttia). Sen jälkeen Gistsmith Personal on kuukausittain tai vuosittain automaattisesti uusiutuva tilaus: 10 tuntia nauhoitusta kuukaudessa (kohtuullinen käyttö) ja enintään 4 tuntia kokousta kohden. Maasi hinta näytetään sovelluksessa ennen ostoa. Maksu veloitetaan Apple-tililtäsi, kun vahvistat oston. Tilaus uusiutuu automaattisesti, ellet peru sitä viimeistään 24 tuntia ennen kauden päättymistä. Voit hallita tai perua tilauksen Apple-tilisi asetuksissa.

Käyttöehdot: https://gistsmith.com/terms
Tietosuojaseloste: https://gistsmith.com/privacy
```

### PRICING — when Pro is on (replace the paragraph above at Pro launch)

```text
HINNOITTELU
3 ensimmäistä kokousta tai 7 päivää ilmaiseksi, kumpi täyttyy ensin (vaatii kirjautumisen; kokeilukokous enintään 90 min). Sen jälkeen valitse automaattisesti uusiutuva kuukausi- tai vuositilaus: Gistsmith Personal (10 h nauhoitusta kuukaudessa) tai Gistsmith Pro ({PRO_HOURS} h kuukaudessa), kummassakin kohtuullinen käyttö ja enintään 4 h kokousta kohden. Hinta näkyy sovelluksessa ennen ostoa. Maksu veloitetaan Apple-tililtäsi vahvistaessasi. Tilaus uusiutuu automaattisesti, ellet peru sitä viimeistään 24 tuntia ennen kauden loppua. Hallitse tai peru tilaus Apple-tilisi asetuksissa.
```

### What's New (template)

```text
Gistsmith [versio] [päivityksen tärkein hyöty yhdellä lauseella].

Uutta
• [Ominaisuus]: [mitä voit nyt tehdä, yhdellä lauseella].

Parannuksia
• [Mikä toimii nyt paremmin].
• Korjauksia ja luotettavuusparannuksia.
```

Maintenance update:

```text
Tämä päivitys tekee nauhoituksesta ja muistiinpanojen kirjoittamisesta luotettavampaa ja korjaa muutaman virheen. Kiitos palautteestasi; kirjoita meille kohdassa Asetukset › Lähetä palautetta.
```

---

## German — `de`

### Name

```text
Gistsmith: KI-Protokoll
```

### Subtitle

```text
Transkription, Notizen, To-dos
```

### Promotional Text

```text
Leg dein iPhone auf den Tisch. Wenn das Meeting endet, steht dein Protokoll: Zusammenfassung, Entscheidungen, Aufgaben. Die ersten 3 Meetings oder 7 Tage sind kostenlos.
```

### Keywords

```text
besprechung,mitschrift,diktiergerät,sprachaufnahme,zusammenfassung,vorlesung,aufgabe,übersetzung
```

### Description

```text
Gistsmith macht aus dem Gespräch rund um dein iPhone klare Meeting-Notizen. Leg das Handy auf den Tisch, tipp auf Aufnehmen und sprich einfach weiter. Wenn das Meeting endet, steht dein Protokoll: eine Zusammenfassung, die getroffenen Entscheidungen und die Aufgaben aller Beteiligten.

Gemacht für Besprechungen vor Ort: Einzelgespräche, Teammeetings, Kundentermine, Interviews, Vorlesungen und Workshops. Gistsmith hört über das Mikrofon deines iPhone mit. Es zeichnet keine Telefonate und keine Online-Meetings auf, und du musst keinen Bot einladen.

AUFNEHMEN
• Live-Transkript, während ihr sprecht, nach Sprechern getrennt
• Live-Übersetzung, wenn das Meeting in einer anderen Sprache läuft
• „Was habe ich verpasst?“ fasst die letzten Minuten zusammen, während die Aufnahme noch läuft
• Nimmt im Hintergrund weiter auf, mit Fortschritt auf dem Sperrbildschirm und in der Dynamic Island
• Starten über das Kontrollzentrum, die Aktionstaste, ein Widget, Siri oder Kurzbefehle
• Audio- und Videoaufnahmen aus Dateien oder Fotos importieren

DEIN PROTOKOLL, FERTIG ZUM MEETING-ENDE
• Zusammenfassung, Entscheidungen, offene Fragen und jede Aufgabe mit verantwortlicher Person und Fälligkeit
• Die Themen mit Zeitstempeln und ein Glossar mit Namen und Fachbegriffen
• Vorlagen für Einzelgespräch, Daily Stand-up, Sprint-Planung, Retrospektive, Kundenmeeting, Vorstellungsgespräch, Nutzerforschung und Vortrag / Schulung, oder deine eigene
• Als PDF, Markdown, reinen Text oder SRT-Untertitel teilen, oder einen Ende-zu-Ende-verschlüsselten Link senden, der abläuft

FRAGEN
• Stell Fragen über alle deine Meetings hinweg; jede Antwort zeigt, aus welchen Meetings sie stammt
• Fertige Vorlagen wie Follow-up-E-Mail, Meinen Tag vorbereiten sowie Risiken und offene Fragen
• Vor einem Meeting ein Briefing zu früheren Meetings mit denselben Personen

ALLES IM BLICK
• Meine Aufgaben: die Aufgaben aus allen Meetings in einer Liste; jede davon lässt sich zu Erinnerungen hinzufügen
• Die heutigen Termine aus deinem Kalender, auf Wunsch mit Erinnerung vor Beginn
• Personen und Unternehmen: Sprecher einmal benennen, dann Meetings, Redezeit und Aufgaben jeder Person sehen

MAC UND IPHONE
Ein Account und ein Abo für Gistsmith auf Mac und iPhone. Schalte die Synchronisierung ein, um Meetings, Notizen, Aufgaben und Personen auf beiden Geräten zu sehen. Sie ist Ende-zu-Ende-verschlüsselt, und das Audio bleibt auf dem Gerät, das es aufgenommen hat.

DEIN KI-ASSISTENT
Verbinde auf Wunsch Claude oder ChatGPT unter Einstellungen › KI-Assistentenzugriff mit deinen Meeting-Notizen, damit dein Assistent sie durchsuchen und lesen kann. Standardmäßig aus. Dafür wird eine verschlüsselte Kopie deiner Notizen in der EU gespeichert (nie Audio oder Transkripte), die beim Ausschalten sofort gelöscht wird.

SPRACHEN
Meetings in 35 Sprachen. Notizen, Übersetzungen und Antworten in 37. Die App selbst gibt es in 12 Sprachen, auch auf Deutsch.

DATENSCHUTZ
Deine Meetings werden nicht zum Training von KI-Modellen verwendet. Audio wird nur für Transkript und Notiz gesendet, und unsere Server speichern es nicht. Du bestimmst, wie lange Aufnahmen auf deinem iPhone bleiben: 7 bis 365 Tage. Sag den Anwesenden Bescheid, bevor du aufnimmst.

PREISE
Die ersten 3 Meetings oder 7 Tage sind kostenlos, je nachdem, was zuerst eintritt (Anmeldung erforderlich; Test-Meetings bis 90 Minuten). Danach ist Gistsmith Personal ein monatliches oder jährliches, sich automatisch verlängerndes Abo mit 10 Stunden Aufnahme pro Monat (Fair Use) und bis zu 4 Stunden pro Meeting. Den Preis für dein Land zeigt die App vor dem Kauf. Die Zahlung wird bei der Bestätigung über deinen Apple Account abgerechnet. Das Abo verlängert sich automatisch, wenn du es nicht spätestens 24 Stunden vor Ende des laufenden Zeitraums kündigst. Verwalten oder kündigen kannst du es in den Einstellungen deines Apple Accounts.

Nutzungsbedingungen: https://gistsmith.com/terms
Datenschutzerklärung: https://gistsmith.com/privacy
```

### PRICING — when Pro is on (replace the paragraph above at Pro launch)

```text
PREISE
Die ersten 3 Meetings oder 7 Tage sind kostenlos, je nachdem, was zuerst eintritt (Anmeldung erforderlich; Test-Meetings bis 90 Min.). Danach wählst du ein monatliches oder jährliches, sich automatisch verlängerndes Abo: Gistsmith Personal (10 Stunden Aufnahme pro Monat) oder Gistsmith Pro ({PRO_HOURS} Stunden pro Monat), beide mit Fair Use und bis zu 4 Stunden pro Meeting. Den Preis für dein Land zeigt die App vor dem Kauf. Bezahlt wird bei der Bestätigung über deinen Apple Account. Das Abo verlängert sich automatisch, wenn du es nicht spätestens 24 Stunden vor Ende des Zeitraums kündigst. Verwalten oder kündigen kannst du es in den Einstellungen deines Apple Accounts.
```

---

## French — `fr`

### Name

```text
Gistsmith: Notes de réunion IA
```

### Subtitle

```text
Transcription, résumé, tâches
```

### Promotional Text

```text
Posez votre iPhone sur la table. À la fin de la réunion, votre compte rendu est prêt : résumé, décisions et tâches. 3 premières réunions ou 7 jours offerts.
```

### Keywords

```text
compte,rendu,enregistreur,vocal,texte,cours,entretien,prise,traduction,synthèse,procès-verbal,pv
```

### Description

```text
Gistsmith transforme la conversation autour de votre iPhone en notes de réunion claires. Posez le téléphone sur la table, lancez l’enregistrement et continuez à parler. À la fin de la réunion, votre compte rendu est prêt : un résumé, les décisions prises et les tâches de chacun.

Conçu pour les réunions en présentiel : tête-à-tête, réunions d’équipe, rendez-vous clients, entretiens, cours et ateliers. Gistsmith écoute avec le micro de votre iPhone. Il n’enregistre ni les appels téléphoniques ni les réunions en ligne, et aucun bot n’est à inviter.

ENREGISTRER
• Transcription en direct pendant que vous parlez, avec les intervenants séparés
• Traduction en direct si la réunion se tient dans une autre langue
• « Qu’ai-je manqué ? » résume les dernières minutes pendant l’enregistrement
• Enregistrement en arrière-plan, suivi sur l’écran verrouillé et dans la Dynamic Island
• Démarrez depuis le centre de contrôle, le bouton Action, un widget, Siri ou Raccourcis
• Importez des enregistrements audio ou vidéo depuis Fichiers ou Photos

VOTRE COMPTE RENDU, PRÊT À LA FIN DE LA RÉUNION
• Un résumé, les décisions, les questions ouvertes et chaque tâche avec son responsable et son échéance
• Les sujets horodatés et un glossaire des noms et des termes
• Modèles : tête-à-tête, point quotidien, planification de sprint, rétrospective, réunion client, entretien d’embauche, recherche utilisateur, formation, ou votre propre modèle
• Partagez en PDF, Markdown, texte brut ou sous-titres SRT, ou envoyez un lien chiffré de bout en bout qui expire

DEMANDER
• Interrogez toutes vos réunions ; chaque réponse indique les réunions dont elle vient
• Requêtes prêtes à l’emploi : E-mail de suivi, Préparer ma journée, Risques et questions ouvertes
• Avant une réunion, un briefing sur vos réunions passées avec les mêmes personnes

GARDEZ LE CAP
• Mes tâches : les tâches de toutes vos réunions dans une seule liste ; ajoutez-en à Rappels
• Les réunions du jour depuis votre calendrier, avec un rappel avant le début
• Personnes et entreprises : nommez les intervenants une fois et retrouvez les réunions et les tâches de chacun

MAC ET IPHONE
Un seul compte et un seul abonnement pour Gistsmith sur Mac et iPhone. Activez la synchronisation pour retrouver vos réunions, notes, tâches et personnes sur les deux. Elle est chiffrée de bout en bout, et l’audio reste sur l’appareil qui l’a enregistré.

VOTRE ASSISTANT IA
Connectez, si vous le souhaitez, Claude ou ChatGPT à vos notes de réunion dans Réglages › Accès des assistants IA : votre assistant pourra les rechercher et les lire. Désactivé par défaut. Une copie chiffrée de vos notes (jamais l’audio ni les transcriptions) est alors conservée dans l’UE, et supprimée dès que vous désactivez l’accès.

LANGUES
Réunions dans 35 langues. Notes, traductions et réponses dans 37. L’app elle-même est disponible en 12 langues, dont le français.

CONFIDENTIALITÉ
Vos réunions ne servent pas à entraîner des modèles d’IA. L’audio n’est envoyé que pour produire la transcription et le compte rendu, et nos serveurs ne le conservent pas. Vous choisissez combien de temps les enregistrements restent sur votre iPhone, de 7 à 365 jours. Prévenez les personnes présentes avant d’enregistrer.

TARIFS
Vos 3 premières réunions ou 7 jours sont offerts, selon ce qui arrive en premier (connexion requise ; 90 minutes maximum par réunion d’essai). Ensuite, Gistsmith Personal est un abonnement mensuel ou annuel à renouvellement automatique, avec 10 heures d’enregistrement par mois (usage raisonnable) et jusqu’à 4 heures par réunion. Le prix local s’affiche dans l’app avant l’achat. Le paiement est débité de votre compte Apple lorsque vous confirmez. L’abonnement se renouvelle automatiquement, sauf si vous le résiliez au moins 24 heures avant la fin de la période en cours. Gérez-le ou résiliez-le dans les réglages de votre compte Apple.

Conditions d’utilisation : https://gistsmith.com/terms
Politique de confidentialité : https://gistsmith.com/privacy
```

### PRICING — when Pro is on (replace the paragraph above at Pro launch)

```text
TARIFS
Vos 3 premières réunions ou 7 jours sont offerts, selon ce qui arrive en premier (connexion requise ; 90 minutes maximum par réunion d’essai). Ensuite, choisissez un abonnement mensuel ou annuel à renouvellement automatique : Gistsmith Personal (10 h d’enregistrement par mois) ou Gistsmith Pro ({PRO_HOURS} h par mois), en usage raisonnable et jusqu’à 4 h par réunion. Le prix local s’affiche dans l’app avant l’achat. Le paiement est débité de votre compte Apple à la confirmation. L’abonnement se renouvelle automatiquement, sauf résiliation au moins 24 h avant la fin de la période. Gérez-le ou résiliez-le dans les réglages de votre compte Apple.
```

---

## Spanish (Spain) — `es-ES`

### Name

```text
Gistsmith: Notas de reunión IA
```

### Subtitle

```text
Transcripción, resumen y acta
```

### Promotional Text

```text
Deja tu iPhone sobre la mesa. Al terminar la reunión tienes tu nota lista: resumen, decisiones y tareas. Pregunta lo que quieras. 3 primeras reuniones o 7 días gratis.
```

### Keywords

```text
grabadora,voz,dictáfono,grabar,texto,clase,entrevista,tarea,traducción,apunte,asistente,grabación
```

### Description

```text
Gistsmith convierte la conversación que tiene lugar alrededor de tu iPhone en notas de reunión claras. Deja el móvil sobre la mesa, pulsa grabar y sigue hablando. Al terminar la reunión, tu nota está lista: un resumen, las decisiones tomadas y las tareas de cada uno.

Pensado para reuniones presenciales: reuniones individuales, reuniones de equipo, visitas a clientes, entrevistas, clases y talleres. Gistsmith escucha con el micrófono de tu iPhone. No graba llamadas ni reuniones online, y no hay que invitar a ningún bot.

GRABAR
• Transcripción en directo mientras habláis, con cada interlocutor por separado
• Traducción en directo si la reunión es en otro idioma
• «¿Qué me he perdido?» resume los últimos minutos sin detener la grabación
• Sigue grabando en segundo plano, con el progreso en la pantalla bloqueada y en la Dynamic Island
• Empieza desde el centro de control, el botón de acción, un widget, Siri o Atajos
• Importa grabaciones de audio o vídeo desde Archivos o Fotos

TU NOTA, LISTA AL TERMINAR LA REUNIÓN
• Un resumen, las decisiones, las cuestiones abiertas y cada tarea con su responsable y su fecha
• Los temas en orden con marcas de tiempo, y un glosario de nombres y términos
• Plantillas: reunión individual, reunión diaria (stand-up), planificación del sprint, retrospectiva, reunión con cliente, entrevista de trabajo, investigación de usuarios y clase/formación, o la tuya propia
• Edítala con una instrucción sencilla, como «acorta el resumen»
• Compártela en PDF, Markdown, texto sin formato o subtítulos SRT, o envía un enlace cifrado de extremo a extremo que caduca

PREGUNTAR
• Pregunta sobre todas tus reuniones; cada respuesta indica de qué reuniones sale
• Peticiones listas para usar: Correo de seguimiento, Preparar mi día, Riesgos y preguntas abiertas
• Antes de una reunión, un resumen de las reuniones anteriores con las mismas personas: decisiones y tareas pendientes

TODO BAJO CONTROL
• Mis tareas: las tareas de todas tus reuniones en una sola lista; añade las que quieras a Recordatorios
• Las reuniones del día de tu calendario, con un aviso antes de empezar si lo deseas
• Personas y empresas: pon nombre a cada interlocutor una vez y consulta sus reuniones, su tiempo de palabra y sus tareas

MAC Y IPHONE
Una sola cuenta y una sola suscripción para Gistsmith en Mac y iPhone. Activa la sincronización para ver tus reuniones, notas, tareas y personas en los dos. Está cifrada de extremo a extremo, y el audio se queda en el dispositivo que lo grabó.

TU ASISTENTE DE IA
Si quieres, conecta Claude o ChatGPT a tus notas de reunión en Ajustes › Acceso de asistentes de IA para que tu asistente pueda buscarlas y leerlas. Viene desactivado. Al activarlo se guarda en la UE una copia cifrada de tus notas (nunca el audio ni las transcripciones), que se borra en cuanto lo desactivas.

IDIOMAS
Reuniones en 35 idiomas. Notas, traducciones y respuestas en 37. La app está disponible en 12 idiomas, entre ellos el español.

PRIVACIDAD
Tus reuniones no se usan para entrenar modelos de IA. El audio solo se envía para crear la transcripción y la nota, y nuestros servidores no lo guardan. Tú eliges cuánto tiempo se quedan las grabaciones en tu iPhone, de 7 a 365 días. Avisa a los presentes antes de grabar.

PRECIOS
Tus 3 primeras reuniones o 7 días son gratis, lo que ocurra antes (requiere iniciar sesión; reuniones de prueba de hasta 90 minutos). Después, Gistsmith Personal es una suscripción mensual o anual con renovación automática, con 10 horas de grabación al mes (uso razonable) y hasta 4 horas por reunión. La app muestra el precio de tu país antes de la compra. El pago se carga en tu cuenta de Apple al confirmar. La suscripción se renueva automáticamente salvo que la canceles al menos 24 horas antes de que termine el periodo actual. Gestiónala o cancélala en los ajustes de tu cuenta de Apple.

Condiciones de uso: https://gistsmith.com/terms
Política de privacidad: https://gistsmith.com/privacy
```

### PRICING — when Pro is on (replace the paragraph above at Pro launch)

```text
PRECIOS
Tus 3 primeras reuniones o 7 días son gratis, lo que ocurra antes (requiere iniciar sesión; reuniones de prueba de hasta 90 minutos). Después, elige una suscripción mensual o anual con renovación automática: Gistsmith Personal (10 horas de grabación al mes) o Gistsmith Pro ({PRO_HOURS} horas al mes), ambas con uso razonable y hasta 4 horas por reunión. La app muestra el precio de tu país antes de la compra. El pago se carga en tu cuenta de Apple al confirmar. La suscripción se renueva automáticamente salvo que la canceles al menos 24 horas antes de que termine el periodo actual. Gestiónala o cancélala en los ajustes de tu cuenta de Apple.
```

---

## Spanish (Mexico) — `es-MX`

Default Spanish for Mexico and most of Latin America, and the Spanish set the U.S. storefront searches.

### Name

```text
Gistsmith: Notas de reunión IA
```

### Subtitle

```text
Graba voz, transcribe y resume
```

### Promotional Text

```text
Pon tu iPhone sobre la mesa. Al terminar la junta, tu nota está lista: resumen, acuerdos y tareas. Pregunta lo que quieras. Tus primeras 3 juntas o 7 días son gratis.
```

### Keywords

```text
junta,minuta,grabadora,transcripción,resumen,clase,entrevista,tarea,traductor,texto,asistente,acta
```

### Description

```text
Gistsmith convierte la conversación alrededor de tu iPhone en notas de reunión claras. Pon el celular sobre la mesa, toca grabar y sigue platicando. Al terminar la junta, tu nota está lista: un resumen, los acuerdos tomados y las tareas de cada quien.

Hecho para reuniones presenciales: juntas uno a uno, juntas de equipo, visitas a clientes, entrevistas, clases y talleres. Gistsmith escucha con el micrófono de tu iPhone. No graba llamadas ni reuniones en línea, y no tienes que invitar a ningún bot.

GRABAR
• Transcripción en vivo mientras hablan, con cada persona por separado
• Traducción en vivo si la junta es en otro idioma
• "¿Qué me he perdido?" resume los últimos minutos mientras sigues grabando
• Sigue grabando en segundo plano, con el avance en la pantalla bloqueada y en la Dynamic Island
• Empieza desde el centro de control, el botón de acción, un widget, Siri o Atajos
• Importa grabaciones de audio o video desde Archivos o Fotos

TU NOTA, LISTA AL TERMINAR LA JUNTA
• Un resumen, los acuerdos, los temas pendientes y cada tarea con su responsable y su fecha
• Los temas en orden con marcas de tiempo, y un glosario de nombres y términos
• Plantillas: reunión individual, reunión diaria (stand-up), planificación del sprint, retrospectiva, reunión con cliente, entrevista de trabajo, investigación de usuarios y clase/formación, o la tuya propia
• Edítala con una instrucción sencilla, como "acorta el resumen"
• Compártela en PDF, Markdown, texto simple o subtítulos SRT, o envía un enlace cifrado de extremo a extremo que vence

PREGUNTAR
• Pregunta sobre todas tus juntas; cada respuesta indica de qué juntas viene
• Peticiones listas para usar: Correo de seguimiento, Preparar mi día, Riesgos y preguntas abiertas
• Antes de una junta, un resumen de las juntas anteriores con las mismas personas: acuerdos y tareas pendientes

TODO EN ORDEN
• Mis tareas: las tareas de todas tus juntas en una sola lista; agrega las que quieras a Recordatorios
• Las juntas del día de tu calendario, con un aviso antes de empezar si quieres
• Personas y empresas: ponle nombre a cada persona una vez y ve sus juntas, su tiempo al hablar y sus tareas

MAC Y IPHONE
Una sola cuenta y una sola suscripción para Gistsmith en Mac y iPhone. Activa la sincronización para ver tus juntas, notas, tareas y personas en los dos. Está cifrada de extremo a extremo, y el audio se queda en el dispositivo que lo grabó.

TU ASISTENTE DE IA
Si quieres, conecta Claude o ChatGPT a tus notas de reunión en Ajustes › Acceso de asistentes de IA para que tu asistente pueda buscarlas y leerlas. Viene desactivado. Al activarlo se guarda en la UE una copia cifrada de tus notas (nunca el audio ni las transcripciones), que se borra en cuanto lo desactivas.

IDIOMAS
Juntas en 35 idiomas. Notas, traducciones y respuestas en 37. La app está disponible en 12 idiomas, incluido el español.

PRIVACIDAD
Tus juntas no se usan para entrenar modelos de IA. El audio solo se envía para crear la transcripción y la nota, y nuestros servidores no lo guardan. La sincronización solo guarda una copia cifrada de extremo a extremo. Tú eliges cuánto tiempo se quedan las grabaciones en tu iPhone, de 7 a 365 días. Avísales a los presentes antes de grabar.

PRECIOS
Tus primeras 3 juntas o 7 días son gratis, lo que pase primero (requiere iniciar sesión; juntas de prueba de hasta 90 minutos). Después, Gistsmith Personal es una suscripción mensual o anual con renovación automática, con 10 horas de grabación al mes (uso razonable) y hasta 4 horas por junta. La app muestra el precio de tu país antes de comprar. El pago se carga a tu cuenta de Apple cuando confirmas. La suscripción se renueva automáticamente a menos que la canceles al menos 24 horas antes de que termine el periodo actual. Adminístrala o cancélala en la configuración de tu cuenta de Apple.

Términos de uso: https://gistsmith.com/terms
Política de privacidad: https://gistsmith.com/privacy
```

### PRICING — when Pro is on (replace the paragraph above at Pro launch)

```text
PRECIOS
Tus primeras 3 juntas o 7 días son gratis, lo que pase primero (requiere iniciar sesión; juntas de prueba de hasta 90 minutos). Después, elige una suscripción mensual o anual con renovación automática: Gistsmith Personal (10 horas de grabación al mes) o Gistsmith Pro ({PRO_HOURS} horas al mes), ambas con uso razonable y hasta 4 horas por junta. La app muestra el precio de tu país antes de comprar. El pago se carga a tu cuenta de Apple cuando confirmas. La suscripción se renueva automáticamente a menos que la canceles al menos 24 horas antes de que termine el periodo actual. Adminístrala o cancélala en la configuración de tu cuenta de Apple.
```

---

## Italian — `it`

### Name

```text
Gistsmith: Note riunioni IA
```

### Subtitle

```text
Trascrizione e riassunto audio
```

### Promotional Text

```text
Appoggia l'iPhone sul tavolo. A fine riunione la nota è pronta: riassunto, decisioni e attività. Fai domande sulle riunioni passate. Prime 3 riunioni o 7 giorni gratis.
```

### Keywords

```text
registratore,vocale,verbale,lezione,intervista,attività,dittafono,sintesi,testo,traduzione,riunione
```

### Description

```text
Gistsmith trasforma la conversazione intorno al tuo iPhone in note di riunione chiare. Appoggia il telefono sul tavolo, tocca registra e continua a parlare. A fine riunione la nota è pronta: un riassunto, le decisioni prese e le attività di ciascuno.

Pensato per le riunioni in presenza: incontri faccia a faccia, riunioni di team, visite ai clienti, interviste, lezioni e workshop. Gistsmith ascolta con il microfono del tuo iPhone. Non registra telefonate né riunioni online, e non c'è nessun bot da invitare.

REGISTRA
• Trascrizione dal vivo mentre parlate, con gli interlocutori separati
• Traduzione dal vivo se la riunione si svolge in un'altra lingua
• "Cosa mi sono perso?" riassume gli ultimi minuti mentre la registrazione continua
• Continua a registrare in background, con l'avanzamento sulla schermata di blocco e nella Dynamic Island
• Avvia da Centro di Controllo, tasto Azione, un widget, Siri o Comandi Rapidi
• Importa registrazioni audio o video da File o Foto

LA TUA NOTA, PRONTA A FINE RIUNIONE
• Un riassunto, le decisioni, le questioni aperte e ogni attività con responsabile e scadenza
• Gli argomenti in ordine con i minutaggi, e un glossario di nomi e termini
• Modelli: faccia a faccia, stand-up giornaliero, pianificazione dello sprint, retrospettiva, riunione con un cliente, colloquio di lavoro, ricerca sugli utenti e lezione / formazione, oppure il tuo
• Modificala con un'istruzione semplice, come "accorcia il riassunto"
• Condividi in PDF, Markdown, testo semplice o sottotitoli SRT, oppure invia un link crittografato end-to-end che scade

CHIEDI
• Fai domande su tutte le tue riunioni; ogni risposta indica da quali riunioni proviene
• Richieste pronte come Email di follow-up, Prepara la mia giornata, Rischi e domande aperte
• Prima di una riunione, un briefing sulle riunioni precedenti con le stesse persone: decisioni e attività aperte

TUTTO SOTTO CONTROLLO
• Le mie attività: le attività di tutte le riunioni in un'unica lista; aggiungi quelle che vuoi a Promemoria
• Le riunioni di oggi dal tuo calendario, con un avviso prima dell'inizio se lo desideri
• Persone e aziende: dai un nome agli interlocutori una volta e vedi riunioni, tempo di parola e attività di ciascuno

MAC E IPHONE
Un solo account e un solo abbonamento per Gistsmith su Mac e iPhone. Attiva la sincronizzazione per vedere riunioni, note, attività e persone su entrambi. È crittografata end-to-end, e l'audio resta sul dispositivo che l'ha registrato.

IL TUO ASSISTENTE AI
Se vuoi, collega Claude o ChatGPT alle tue note di riunione in Impostazioni › Accesso degli assistenti AI, così il tuo assistente può cercarle e leggerle. È disattivato per impostazione predefinita. Una copia crittografata delle tue note (mai l'audio né le trascrizioni) viene conservata nell'UE ed eliminata appena lo disattivi.

LINGUE
Riunioni in 35 lingue. Note, traduzioni e risposte in 37. L'app stessa è disponibile in 12 lingue, tra cui l'italiano.

PRIVACY
Le tue riunioni non vengono usate per addestrare modelli di intelligenza artificiale. L'audio viene inviato solo per creare la trascrizione e la nota, e i nostri server non lo conservano. Scegli tu per quanto tempo le registrazioni restano sul tuo iPhone, da 7 a 365 giorni. Avvisa i presenti prima di registrare.

PREZZI
Le prime 3 riunioni o 7 giorni sono gratis, a seconda di cosa arriva prima (serve l'accesso; riunioni di prova fino a 90 minuti). Dopo, Gistsmith Personal è un abbonamento mensile o annuale a rinnovo automatico, con 10 ore di registrazione al mese (uso corretto) e fino a 4 ore per riunione. L'app mostra il prezzo per il tuo paese prima dell'acquisto. Il pagamento viene addebitato sul tuo Account Apple alla conferma. L'abbonamento si rinnova automaticamente se non lo disattivi almeno 24 ore prima della fine del periodo in corso. Puoi gestirlo o annullarlo nelle impostazioni del tuo Account Apple.

Condizioni d'uso: https://gistsmith.com/terms
Informativa sulla privacy: https://gistsmith.com/privacy
```

### PRICING — when Pro is on (replace the paragraph above at Pro launch)

```text
PREZZI
Le prime 3 riunioni o 7 giorni sono gratis, a seconda di cosa arriva prima (serve l'accesso; riunioni di prova fino a 90 minuti). Dopo, scegli un abbonamento mensile o annuale a rinnovo automatico: Gistsmith Personal (10 ore di registrazione al mese) o Gistsmith Pro ({PRO_HOURS} ore al mese), entrambi con uso corretto e fino a 4 ore per riunione. L'app mostra il prezzo del tuo paese prima dell'acquisto. Il pagamento è addebitato sul tuo Account Apple alla conferma. L'abbonamento si rinnova automaticamente se non lo disattivi almeno 24 ore prima della fine del periodo. Gestiscilo o annullalo nelle impostazioni del tuo Account Apple.
```

---

## Portuguese (Brazil) — `pt-BR`

### Name

```text
Gistsmith: Notas de reunião IA
```

### Subtitle

```text
Transcrição, resumo e tarefas
```

### Promotional Text

```text
Deixe o iPhone na mesa. Quando a reunião acaba, sua nota está pronta: resumo, decisões e tarefas. Pergunte sobre reuniões passadas. 3 primeiras reuniões ou 7 dias grátis.
```

### Keywords

```text
gravador,voz,ata,gravar,transcrever,texto,aula,entrevista,tradução,anotação,assistente,palestra
```

### Description

```text
O Gistsmith transforma a conversa ao redor do seu iPhone em notas de reunião claras. Deixe o celular na mesa, toque em gravar e continue a conversa. Quando a reunião termina, sua nota está pronta: um resumo, as decisões tomadas e as tarefas de cada um.

Feito para reuniões presenciais: reuniões um a um, reuniões de equipe, visitas a clientes, entrevistas, aulas e workshops. O Gistsmith ouve pelo microfone do seu iPhone. Ele não grava ligações nem reuniões online, e não há nenhum bot para convidar.

GRAVAR
• Transcrição ao vivo enquanto vocês falam, com cada pessoa separada
• Tradução ao vivo quando a reunião é em outro idioma
• "O que eu perdi?" resume os últimos minutos enquanto a gravação continua
• Continua gravando em segundo plano, com o progresso na Tela Bloqueada e na Dynamic Island
• Comece pela Central de Controle, pelo botão de Ação, por um widget, pela Siri ou por Atalhos
• Importe gravações de áudio ou vídeo do app Arquivos ou do Fotos

SUA NOTA, PRONTA QUANDO A REUNIÃO TERMINA
• Um resumo, as decisões, as questões em aberto e cada tarefa com responsável e prazo
• Os assuntos em ordem com marcação de tempo, e um glossário de nomes e termos
• Modelos: um a um, daily (reunião diária), planejamento de sprint, retrospectiva, reunião com cliente, entrevista de emprego, pesquisa com usuários e aula / treinamento, ou o seu próprio
• Edite com uma instrução simples, como "encurte o resumo"
• Compartilhe em PDF, Markdown, texto simples ou legendas SRT, ou envie um link com criptografia de ponta a ponta que expira

PERGUNTAR
• Faça perguntas sobre todas as suas reuniões; cada resposta mostra de quais reuniões veio
• Pedidos prontos como E-mail de acompanhamento, Preparar meu dia, Riscos e questões em aberto
• Antes de uma reunião, um briefing das reuniões anteriores com as mesmas pessoas: decisões e tarefas em aberto

TUDO EM DIA
• Minhas tarefas: as tarefas de todas as reuniões em uma só lista; adicione as que quiser aos Lembretes
• As reuniões do dia no seu calendário, com um aviso antes de começar, se quiser
• Pessoas e empresas: dê nome a cada pessoa uma vez e veja as reuniões, o tempo de fala e as tarefas de cada uma

MAC E IPHONE
Uma só conta e uma só assinatura para o Gistsmith no Mac e no iPhone. Ative a sincronização para ver reuniões, notas, tarefas e pessoas nos dois. Ela tem criptografia de ponta a ponta, e o áudio fica no aparelho que gravou.

SEU ASSISTENTE DE IA
Se quiser, conecte o Claude ou o ChatGPT às suas notas de reunião em Ajustes › Acesso de assistentes de IA, para que seu assistente possa buscá-las e lê-las. Vem desativado. Ao ativar, uma cópia criptografada das suas notas (nunca o áudio nem as transcrições) fica guardada na UE e é apagada assim que você desativa.

IDIOMAS
Reuniões em 35 idiomas. Notas, traduções e respostas em 37. O app está disponível em 12 idiomas, incluindo português.

PRIVACIDADE
Suas reuniões não são usadas para treinar modelos de IA. O áudio é enviado só para criar a transcrição e a nota, e nossos servidores não o guardam. A sincronização guarda apenas uma cópia com criptografia de ponta a ponta. Você escolhe por quanto tempo as gravações ficam no iPhone, de 7 a 365 dias. Avise as pessoas presentes antes de gravar.

PREÇOS
Suas 3 primeiras reuniões ou 7 dias são grátis, o que acontecer primeiro (é preciso entrar na conta; reuniões de teste de até 90 minutos). Depois, o Gistsmith Personal é uma assinatura mensal ou anual com renovação automática, com 10 horas de gravação por mês (uso justo) e até 4 horas por reunião. O app mostra o preço do seu país antes da compra. O pagamento é cobrado na sua Conta Apple quando você confirma. A assinatura é renovada automaticamente, a menos que seja cancelada pelo menos 24 horas antes do fim do período atual. Gerencie ou cancele nos ajustes da sua Conta Apple.

Termos de Uso: https://gistsmith.com/terms
Política de Privacidade: https://gistsmith.com/privacy
```

### PRICING — when Pro is on (replace the paragraph above at Pro launch)

```text
PREÇOS
Suas 3 primeiras reuniões ou 7 dias são grátis, o que acontecer primeiro (é preciso entrar na conta; reuniões de teste de até 90 minutos). Depois, escolha uma assinatura mensal ou anual com renovação automática: o Gistsmith Personal, com 10 horas de gravação por mês, ou o Gistsmith Pro, com {PRO_HOURS} horas de gravação por mês. As duas seguem o uso justo e permitem até 4 horas por reunião. O app mostra o preço do seu país antes da compra. O pagamento é cobrado na sua Conta Apple quando você confirma. A assinatura é renovada automaticamente, a menos que seja cancelada pelo menos 24 horas antes do fim do período atual. Gerencie ou cancele nos ajustes da sua Conta Apple.
```

---

## Dutch — `nl`

### Name

```text
Gistsmith: Notulen met AI
```

### Subtitle

```text
Transcriptie en samenvatting
```

### Promotional Text

```text
Leg je iPhone op tafel. Na het overleg staat je verslag klaar: samenvatting, besluiten en taken. Vraag alles over eerder overleg. 3 vergaderingen of 7 dagen gratis.
```

### Keywords

```text
vergadering,notitie,opname,spraak,tekst,voicememo,college,sollicitatie,actiepunt,verslag,notulist
```

### Description

```text
Gistsmith maakt van het gesprek rond je iPhone heldere notulen. Leg je telefoon op tafel, tik op opnemen en praat gewoon door. Als de vergadering klaar is, staat je verslag er: een samenvatting, de genomen besluiten en ieders taken.

Gemaakt voor overleg op locatie: één-op-ééngesprekken, teamoverleg, klantbezoeken, interviews, colleges en workshops. Gistsmith luistert mee via de microfoon van je iPhone. Het neemt geen telefoongesprekken of online vergaderingen op, en je hoeft geen bot uit te nodigen.

OPNEMEN
• Live transcriptie terwijl jullie praten, per spreker gescheiden
• Live vertaling als de vergadering in een andere taal is
• 'Wat heb ik gemist?' vat de laatste minuten samen terwijl de opname doorloopt
• Neemt op de achtergrond door, met de voortgang op het toegangsscherm en in het Dynamic Island
• Start vanuit het bedieningspaneel, de actieknop, een widget, Siri of Opdrachten
• Importeer audio- of video-opnamen uit Bestanden of Foto's

JE VERSLAG, KLAAR ALS DE VERGADERING EINDIGT
• Een samenvatting, de besluiten, open vragen en elke taak met eigenaar en deadline
• De onderwerpen op volgorde met tijdstempels, en een woordenlijst met namen en termen
• Sjablonen: één-op-één, dagelijkse stand-up, sprintplanning, retrospective, klantgesprek, sollicitatiegesprek, gebruikersonderzoek en college / training, of je eigen sjabloon
• Pas het aan met een gewone opdracht, zoals 'maak de samenvatting korter'
• Deel als pdf, Markdown, platte tekst of SRT-ondertiteling, of stuur een end-to-end versleutelde link die verloopt

VRAAG
• Stel vragen over al je vergaderingen; elk antwoord laat zien uit welke vergaderingen het komt
• Kant-en-klare vragen zoals Follow-up-e-mail, Bereid mijn dag voor en Risico's en open vragen
• Vóór een vergadering een briefing over eerdere vergaderingen met dezelfde mensen: besluiten en open taken

ALLES OP EEN RIJ
• Mijn taken: de taken uit al je vergaderingen in één lijst; zet wat je wilt in Herinneringen
• De vergaderingen van vandaag uit je agenda, desgewenst met een herinnering vooraf
• Personen en bedrijven: geef sprekers één keer een naam en zie per persoon de vergaderingen, spreektijd en taken

MAC EN IPHONE
Eén account en één abonnement voor Gistsmith op Mac en iPhone. Zet synchronisatie aan om je vergaderingen, notities, taken en personen op allebei te zien. Die is end-to-end versleuteld, en de audio blijft op het apparaat dat hem heeft opgenomen.

JE AI-ASSISTENT
Als je wilt, koppel je Claude of ChatGPT aan je vergadernotities via Instellingen › Toegang voor AI-assistenten, zodat je assistent ze kan doorzoeken en lezen. Dit staat standaard uit. Er wordt dan een versleutelde kopie van je notities (nooit audio of transcripties) in de EU bewaard, die meteen wordt verwijderd als je het uitzet.

TALEN
Vergaderingen in 35 talen. Notities, vertalingen en antwoorden in 37. De app zelf is er in 12 talen, waaronder het Nederlands.

PRIVACY
Je vergaderingen worden niet gebruikt om AI-modellen te trainen. Audio wordt alleen verstuurd om de transcriptie en het verslag te maken, en onze servers bewaren hem niet. Synchronisatie bewaart alleen een end-to-end versleutelde kopie. Je kiest zelf hoe lang opnamen op je iPhone blijven: 7 tot 365 dagen. Laat de aanwezigen weten dat je opneemt.

PRIJZEN
Je eerste 3 vergaderingen of 7 dagen zijn gratis, wat het eerst komt (inloggen vereist; proefvergaderingen tot 90 minuten). Daarna is Gistsmith Personal een maand- of jaarabonnement dat automatisch wordt verlengd, met 10 uur opnemen per maand (redelijk gebruik) en tot 4 uur per vergadering. De app toont de prijs voor jouw land voordat je koopt. De betaling wordt bij bevestiging via je Apple Account afgeschreven. Het abonnement wordt automatisch verlengd, tenzij je het uiterlijk 24 uur voor het einde van de lopende periode opzegt. Beheer of annuleer het in de instellingen van je Apple Account.

Gebruiksvoorwaarden: https://gistsmith.com/terms
Privacybeleid: https://gistsmith.com/privacy
```

### PRICING — when Pro is on (replace the paragraph above at Pro launch)

```text
PRIJZEN
Je eerste 3 vergaderingen of 7 dagen zijn gratis, wat het eerst komt (inloggen vereist; proefvergaderingen tot 90 minuten). Daarna kies je een maand- of jaarabonnement dat automatisch wordt verlengd: Gistsmith Personal (10 uur opnemen per maand) of Gistsmith Pro ({PRO_HOURS} uur per maand), allebei met redelijk gebruik en tot 4 uur per vergadering. De app toont de prijs voor jouw land voordat je koopt. De betaling wordt bij bevestiging via je Apple Account afgeschreven. Het abonnement wordt automatisch verlengd, tenzij je het uiterlijk 24 uur voor het einde van de lopende periode opzegt. Beheer of annuleer het in de instellingen van je Apple Account.
```

---

## Japanese — `ja`

### Name

```text
Gistsmith: AI議事録・文字起こし
```

### Subtitle

```text
会議を録音して要約とタスクを自動作成
```

### Promotional Text

```text
iPhoneをテーブルに置くだけ。会議が終わるとノートが完成：要約、決定事項、タスク。過去の会議にも質問できます。最初の3回の会議または7日間は無料。
```

### Keywords

```text
ボイスレコーダー,メモ,ノート,講義,面接,翻訳,音声,テキスト,打ち合わせ
```

### Description

```text
Gistsmithは、iPhoneのまわりで交わされた会話をわかりやすい議事録にします。iPhoneをテーブルに置いて録音をタップし、そのまま話を続けるだけ。会議が終わるとノートが完成しています。要約、決まったこと、そして一人ひとりのタスクまで。

対面の会議のために作りました。1対1、チームミーティング、顧客訪問、インタビュー、講義、ワークショップに。GistsmithはiPhoneのマイクで聞き取ります。電話やオンライン会議は録音しません。会議にボットを招待する必要もありません。

録音
• 話している間にリアルタイムで文字起こし。話者ごとに分けて表示
• 会議が別の言語でもライブ翻訳
• 「聞き逃したことは？」で、録音を続けたまま直近の数分を要約
• バックグラウンドでも録音を継続。進行状況はロック画面とDynamic Islandに表示
• コントロールセンター、アクションボタン、ウィジェット、Siri、ショートカットから開始
• 「ファイル」や「写真」から音声・動画を読み込み

会議が終わると、ノートが完成
• 要約、決定事項、未解決事項、そして担当者と期限つきのすべてのタスク
• タイムスタンプつきの話題の流れと、名前や用語の用語集
• テンプレート：1対1、デイリースタンドアップ、スプリント計画、振り返り、顧客ミーティング、採用面接、ユーザーリサーチ、講義／研修、または独自のテンプレート
• 会議中に書いたメモも最終的なノートに反映
• 「要約を短くして」のような指示で編集
• PDF、Markdown、テキスト、SRT字幕で共有。期限つきのエンドツーエンド暗号化リンクも送れます

質問
• すべての会議にまとめて質問。回答にはもとになった会議が示されます
• フォローアップメール、今日の準備、リスクと未解決の課題などのすぐ使えるプロンプト
• 会議の前に、同じ相手との過去の会議のブリーフィング：決定事項と未完了のタスク

抜け漏れなく
• 自分のタスク：すべての会議のタスクをひとつのリストに。リマインダーにも追加できます
• カレンダーから今日の会議を表示。開始前の通知も設定できます
• 人物と会社：話者に一度名前をつければ、その人の会議、発言時間、タスクがわかります
• タイトル、人物、文字起こしを検索

MacとiPhone
MacとiPhoneのGistsmithは、ひとつのアカウントとひとつのサブスクリプションで使えます。同期をオンにすると、会議、ノート、タスク、人物を両方で確認できます。同期はエンドツーエンドで暗号化され、音声は録音したデバイスに残ります。

AIアシスタント
必要に応じて、設定 › AIアシスタントのアクセス からClaudeやChatGPTを会議ノートに接続すると、アシスタントがノートを検索して読めるようになります。音声や文字起こしにはアクセスしません。

対応言語
会議は35言語、ノート・翻訳・回答は37言語に対応。アプリ自体は日本語を含む12言語で使えます。

プライバシー
会議の内容がAIモデルの学習に使われることはありません。音声は文字起こしとノートの作成のためだけに送信され、サーバーには保存されません。同期で保存されるのはエンドツーエンドで暗号化されたコピーだけです。AIアシスタントのアクセスは初期設定でオフ。オンにすると、接続したアシスタントが読めるよう、ノートの暗号化コピー（音声は含みません）がEU内に保存され、オフにするとすぐに削除されます。録音をiPhoneに残す期間は7〜365日から選べます。録音する前に、その場の人に伝えてください。

料金
最初の3回の会議または7日間のどちらか早いほうまで無料（サインインが必要。お試しの会議は1回最大90分）。その後、Gistsmith Personalは月額または年額の自動更新サブスクリプションで、録音は月10時間（フェアユース）、1回の会議につき最大4時間です。お住まいの国の価格は購入前にアプリに表示されます。お支払いは購入の確定時にApple Accountに請求されます。現在の期間が終了する24時間前までに解約しない限り、サブスクリプションは自動的に更新されます。管理や解約はApple Accountの設定から行えます。

利用規約：https://gistsmith.com/terms
プライバシーポリシー：https://gistsmith.com/privacy
```

### PRICING — when Pro is on (replace the paragraph above at Pro launch)

```text
料金
最初の3回の会議または7日間のどちらか早いほうまで無料（サインインが必要。お試しの会議は1回最大90分）。その後は、月額または年額の自動更新サブスクリプションをお選びいただけます。録音はGistsmith Personalが月10時間、Gistsmith Proが月{PRO_HOURS}時間で、どちらもフェアユース、1回の会議につき最大4時間です。お住まいの国の価格は購入前にアプリに表示されます。お支払いは購入の確定時にApple Accountに請求されます。現在の期間が終了する24時間前までに解約しない限り、サブスクリプションは自動的に更新されます。管理や解約はApple Accountの設定から行えます。
```

---

## Korean — `ko`

### Name

```text
Gistsmith: AI 회의록
```

### Subtitle

```text
녹음, 받아쓰기, 요약을 한 번에
```

### Promotional Text

```text
iPhone을 테이블에 올려 두세요. 회의가 끝나면 노트가 완성됩니다: 요약, 결정 사항, 할 일. 지난 회의에도 질문할 수 있습니다. 처음 3번의 회의 또는 7일간 무료.
```

### Keywords

```text
녹취,녹취록,음성,텍스트,변환,메모,노트,강의,인터뷰,면접,번역,할일,회의
```

### Description

```text
Gistsmith는 iPhone 주변에서 오간 대화를 깔끔한 회의록으로 만들어 줍니다. 휴대폰을 테이블에 올려 두고 녹음을 누른 뒤 그대로 대화하세요. 회의가 끝나면 노트가 완성됩니다. 요약, 결정 사항, 그리고 각자의 할 일까지.

대면 회의를 위해 만들었습니다. 일대일 면담, 팀 회의, 고객 미팅, 인터뷰, 강의, 워크숍에 쓰세요. Gistsmith는 iPhone 마이크로 듣습니다. 전화 통화나 온라인 회의는 녹음하지 않으며, 회의에 봇을 초대할 필요도 없습니다.

녹음
• 말하는 동안 실시간 받아쓰기, 화자별로 구분
• 다른 언어로 진행되는 회의도 실시간 번역
• '무엇을 놓쳤나요?'로 녹음을 계속하면서 최근 몇 분을 요약
• 백그라운드에서도 녹음 유지, 진행 상황은 잠금 화면과 Dynamic Island에 표시
• 제어 센터, 동작 버튼, 위젯, Siri, 단축어로 시작
• 파일 또는 사진 앱에서 오디오·동영상 녹음 가져오기

회의가 끝나면 노트 완성
• 요약, 결정 사항, 미결 사항, 담당자와 기한이 정리된 모든 할 일
• 타임스탬프가 붙은 주제 흐름, 이름과 용어를 정리한 용어집
• 템플릿: 일대일, 데일리 스탠드업, 스프린트 계획, 회고, 고객 회의, 채용 면접, 사용자 리서치, 강의 / 교육, 또는 나만의 템플릿
• 회의 중에 적은 메모가 최종 노트에 반영
• '요약을 짧게 해 줘'처럼 간단한 지시로 편집
• PDF, Markdown, 일반 텍스트, SRT 자막으로 공유하거나, 만료되는 종단간 암호화 링크로 전송

질문하기
• 모든 회의에 걸쳐 질문하세요. 답변마다 근거가 된 회의가 표시됩니다
• 후속 이메일, 오늘 하루 준비, 위험 요소 및 미결 질문 같은 바로 쓰는 프롬프트
• 회의 전에는 같은 사람들과 했던 이전 회의 브리핑: 결정 사항과 남은 할 일

놓치는 일 없이
• 나의 할 일: 모든 회의의 할 일을 한 목록에서. 원하는 항목은 미리 알림에 추가
• 캘린더의 오늘 회의 표시, 원하면 시작 전 알림
• 사람과 회사: 화자 이름을 한 번만 지정하면 각자의 회의, 발언 시간, 할 일을 확인
• 제목, 사람, 받아쓰기 내용 검색

Mac과 iPhone
Mac과 iPhone의 Gistsmith를 하나의 계정과 하나의 구독으로 사용합니다. 동기화를 켜면 회의, 노트, 할 일, 사람을 두 기기에서 모두 볼 수 있습니다. 동기화는 종단간 암호화되며, 오디오는 녹음한 기기에만 남습니다.

AI 어시스턴트
원하면 설정 › AI 어시스턴트 접근에서 Claude 또는 ChatGPT를 회의 노트에 연결해 어시스턴트가 노트를 검색하고 읽게 할 수 있습니다. 오디오나 받아쓰기 내용에는 접근하지 않습니다.

언어
회의는 35개 언어, 노트·번역·답변은 37개 언어를 지원합니다. 앱은 한국어를 포함한 12개 언어로 제공됩니다.

개인정보 보호
회의 내용은 AI 모델 학습에 사용되지 않습니다. 오디오는 받아쓰기와 노트를 만들 때만 전송되며, 서버에 보관되지 않습니다. 동기화는 종단간 암호화된 사본만 보관합니다. AI 어시스턴트 접근은 기본적으로 꺼져 있으며, 켜면 연결한 어시스턴트가 읽을 수 있도록 노트의 암호화된 사본(오디오 제외)이 EU에 보관되고, 끄면 즉시 삭제됩니다. 녹음을 iPhone에 보관할 기간은 7일부터 365일까지 직접 고를 수 있습니다. 녹음 전에 함께 있는 사람들에게 알려 주세요.

요금
처음 3번의 회의 또는 7일 중 먼저 끝나는 시점까지 무료입니다(로그인 필요, 체험 회의는 회당 최대 90분). 이후 Gistsmith Personal은 월간 또는 연간 자동 갱신 구독이며, 매월 10시간 녹음(공정 사용)과 회의당 최대 4시간을 제공합니다. 국가별 가격은 구매 전에 앱에 표시됩니다. 결제는 구매를 확인할 때 Apple 계정으로 청구됩니다. 현재 기간이 끝나기 최소 24시간 전에 해지하지 않으면 구독은 자동으로 갱신됩니다. Apple 계정 설정에서 관리하거나 해지할 수 있습니다.

이용약관: https://gistsmith.com/terms
개인정보 처리방침: https://gistsmith.com/privacy
```

### PRICING — when Pro is on (replace the paragraph above at Pro launch)

```text
요금
처음 3번의 회의 또는 7일 중 먼저 끝나는 시점까지 무료입니다(로그인 필요, 체험 회의는 회당 최대 90분). 이후 월간 또는 연간 자동 갱신 구독을 선택할 수 있습니다. Gistsmith Personal은 매월 10시간, Gistsmith Pro는 매월 {PRO_HOURS}시간 녹음을 제공하며, 둘 다 공정 사용 기준으로 회의당 최대 4시간입니다. 국가별 가격은 구매 전에 앱에 표시됩니다. 결제는 구매를 확인할 때 Apple 계정으로 청구됩니다. 현재 기간이 끝나기 최소 24시간 전에 해지하지 않으면 구독은 자동으로 갱신됩니다. Apple 계정 설정에서 관리하거나 해지할 수 있습니다.
```

---

## Chinese (Simplified) — `zh-Hans`

### Name

```text
Gistsmith: AI会议纪要
```

### Subtitle

```text
录音转文字，自动生成摘要和待办
```

### Promotional Text

```text
把 iPhone 放在桌上，会议一结束，笔记就已写好：摘要、决策和任务。还能就过去的会议随时提问。前 3 场会议或 7 天免费。
```

### Keywords

```text
录音笔,语音,速记,笔记,讲座,课堂,面试,采访,翻译,记录,字幕,备忘录,助手
```

### Description

```text
Gistsmith 把 iPhone 周围的对话变成清晰的会议纪要。把手机放在桌上，轻点录制，然后照常交谈。会议一结束，笔记就已写好：摘要、做出的决策，以及每个人的任务。

专为面对面会议打造：一对一沟通、团队会议、客户拜访、访谈、讲座和工作坊。Gistsmith 通过 iPhone 的麦克风收音。它不会录制电话或线上会议，也无需邀请机器人入会。

录制
• 边说边实时转写，按发言人区分
• 会议使用其他语言时提供实时翻译
• “我错过了什么？”在录制进行中总结最近几分钟的内容
• 可在后台持续录制，进度显示在锁定屏幕和灵动岛上
• 可从控制中心、操作按钮、小组件、Siri 或快捷指令开始
• 从“文件”或“照片”导入音频或视频录音

会议结束，笔记即成
• 摘要、决策、待解决问题，以及注明负责人和截止日期的每项任务
• 带时间戳的议题脉络，以及人名和术语的术语表
• 模板：一对一、每日站会、迭代计划会、回顾会、客户会议、求职面试、用户研究、讲座/培训，也可以自定义模板
• 会议中你记下的要点会体现在最终笔记里
• 用一句简单的指令编辑，例如“把摘要缩短一些”
• 可导出为 PDF、Markdown、纯文本或 SRT 字幕分享，也可以发送会过期的端到端加密链接

提问
• 跨所有会议提问，每个回答都会注明出自哪些会议
• 现成的提问模板，如跟进邮件、规划我的一天、风险和未决问题
• 会议开始前，获取与同一批人之前会议的简报：决策和未完成的任务

井井有条
• 我的任务：所有会议的任务汇总在一个列表里，可添加到“提醒事项”
• 显示日历中今天的会议，并可在开始前提醒
• 人员和公司：为发言人命名一次，即可查看每个人的会议、发言时长和任务
• 在标题、人员和转写内容中搜索

Mac 与 iPhone
Mac 和 iPhone 上的 Gistsmith 共用一个账户和一份订阅。打开同步后，会议、笔记、任务和人员在两台设备上都能看到。同步采用端到端加密，音频只保留在录制它的设备上。

你的 AI 助手
如有需要，可在“设置 › AI 助手访问”中将 Claude 或 ChatGPT 连接到你的会议笔记，让助手搜索和阅读这些笔记。助手永远无法访问你的音频或转写内容。

语言
会议支持 35 种语言，笔记、翻译和回答支持 37 种语言。App 界面提供包括简体中文在内的 12 种语言。

隐私
你的会议不会被用于训练 AI 模型。音频仅用于生成转写和笔记，我们的服务器不会保存。同步只保存端到端加密的副本。AI 助手访问默认关闭；开启后，你的笔记会以加密副本（绝不包含音频）保存在欧盟，供你连接的助手读取，关闭后立即删除。录音在 iPhone 上保留多久由你决定，可选 7 至 365 天。录制前请告知在场的人。

价格
前 3 场会议或 7 天免费，以先到者为准（需要登录；试用会议每场最长 90 分钟）。之后，Gistsmith Personal 为按月或按年自动续订的订阅，每月 10 小时录制时长（合理使用），每场会议最长 4 小时。购买前，App 会显示你所在国家或地区的价格。确认购买后，费用将从你的 Apple 账户中扣除。除非在当前订阅期结束前至少 24 小时关闭自动续订，否则订阅将自动续订。可在 Apple 账户设置中管理或取消订阅。

使用条款：https://gistsmith.com/terms
隐私政策：https://gistsmith.com/privacy
```

### PRICING — when Pro is on (replace the paragraph above at Pro launch)

```text
价格
前 3 场会议或 7 天免费，以先到者为准（需要登录；试用会议每场最长 90 分钟）。之后，你可以选择按月或按年自动续订的订阅：Gistsmith Personal 每月 10 小时录制时长，Gistsmith Pro 每月 {PRO_HOURS} 小时录制时长；两者均为合理使用，每场会议最长 4 小时。购买前，App 会显示你所在国家或地区的价格。确认购买后，费用将从你的 Apple 账户中扣除。除非在当前订阅期结束前至少 24 小时关闭自动续订，否则订阅将自动续订。可在 Apple 账户设置中管理或取消订阅。
```
