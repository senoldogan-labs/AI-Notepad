// "Data handling at a glance": her veri türü nerede işlenir, saklanır mı, ne kadar. Gizlilik politikasının başındaki
// tablo (privacy.astro), /llms.txt ve /llms-full.txt bu tek kaynaktan üretilir. Her satır gizlilik politikasının ilgili
// bölümüyle (3 meeting content, 6 statistics, 8 providers, 9 retention, 10 deletion) ve sunucunun davranışıyla
// (server/src/transcriptionCache.ts nihai metni 2 saat şifreli tutar, satırı cleanup.ts'in günlük cron'u siler;
// Linear/Jira ajanı ve paylaşım çevirisi sunucu üzerinden Anthropic'e gider) birebir aynı olmalı; politika
// değişince bu dosya da değişir. iPhone uygulaması henüz App Store'da değildir: satırlar onu privacy.astro ve terms.astro
// gibi "App Store'a çıktığında" diye anar.

/** Bir veri türünün işlenişi. `id` gizlilik sayfasında satırın kalıcı çapasıdır (`#data-<id>`); değiştirme. */
export interface DataHandlingRow {
  readonly id: string;
  readonly data: string;
  /** Nerede ve kim işler. */
  readonly where: string;
  /** Bizim sunucumuzda ya da sağlayıcıda saklanır mı. */
  readonly stored: string;
  readonly retention: string;
  /** Gizlilik politikasında ayrıntının olduğu bölümün çapası. */
  readonly policySection: string;
}

/** Tablonun sütun başlıkları ve çevresindeki metin. */
export interface DataHandlingCopy {
  readonly title: string;
  readonly lead: string;
  readonly columns: { readonly data: string; readonly where: string; readonly stored: string; readonly retention: string };
  readonly details: string;
  readonly rows: readonly DataHandlingRow[];
}

/** Veri işleme özeti. */
export const dataHandling: DataHandlingCopy = {
  title: "Data handling at a glance",
  lead: "Where each kind of data goes, whether it is stored and for how long. This table summarises the policy below; the numbered sections are the binding text.",
  columns: { data: "Data", where: "Where it is processed", stored: "Stored?", retention: "How long" },
  details: "Details",
  rows: [
    {
      id: "live-audio",
      data: "Meeting audio while you record (live transcript)",
      where:
        "Streamed directly from your Mac, or from your iPhone once the iPhone app is available on the App Store, to Deepgram. When Deepgram can't be used (our reserved capacity is used up, it can't be reached or you're offline), the live transcript is made on your device instead.",
      stored: "Not by us: our server never receives this audio. Deepgram keeps it only while processing; every connection opts out of its model training.",
      retention: "Only while the request is processed",
      policySection: "meetings",
    },
    {
      id: "recording",
      data: "The recording after the meeting, and audio or video files you import",
      where: "Streamed through our server, without being written to storage, to ElevenLabs for the final transcript and speaker separation.",
      stored: "Not on our server. ElevenLabs may keep it under its own retention rules; we have opted out of its use for model training.",
      retention: "ElevenLabs' own retention rules; data it deletes leaves its backups within 30 days",
      policySection: "providers",
    },
    {
      id: "final-transcript",
      data: "The final transcript returned by ElevenLabs",
      where: "Our server, on its way back to your device.",
      stored: "Yes, encrypted, only so it can be re-sent if the connection drops.",
      retention: "Can be re-sent for 2 hours, then deleted at the next daily cleanup, within about a day (immediately if you delete your account)",
      policySection: "meetings",
    },
    {
      id: "ai-text",
      data: "Transcript text for notes, live translation, “What did I miss?” and Ask, with the participant names and terms you add; tasks, the meeting title and Linear's or Jira's replies when you create issues there; a note you translate to send in another language; a note you turn into a follow-up email, with the meeting title, date and attendee names",
      where: "Sent through our server to Anthropic's Claude model; the answer returns to your device.",
      stored: "Not by us: our server doesn't store or log the text and records only token counts. Anthropic doesn't train its models on it.",
      retention: "Anthropic deletes it within 30 days (up to 2 years if a request is flagged under its usage policy)",
      policySection: "providers",
    },
    {
      id: "on-device",
      data: "Notes, transcripts, recordings, screen snapshots, and the people and terms you add",
      where: "In the app's folder on your Mac, or on your iPhone once the iPhone app is available on the App Store.",
      stored: "On your device only. No cloud sync; meetings recorded on one device don't appear on the other.",
      retention: "Until you delete them in the app",
      policySection: "meetings",
    },
    {
      id: "screen-snapshots",
      data: "Shared-screen snapshots (Mac app, off by default)",
      where:
        "Taken and kept on your Mac. Only if you also turn on “Use screen snapshots in notes”: up to 6 downscaled snapshots per note and up to 3 per Ask answer go through our server to Anthropic.",
      stored: "On your Mac. Our server checks and passes them on without storing or logging them.",
      retention: "On your Mac until you delete them; at Anthropic as for transcript text",
      policySection: "meetings",
    },
    {
      id: "voice-typing",
      data: "Voice typing audio and text (Mac app)",
      where: "Transcribed on your Mac.",
      stored: "No. Neither the audio nor the text is sent to us or any provider, and neither is saved.",
      retention: "Not kept",
      policySection: "meetings",
    },
    {
      id: "calendar",
      data: "Calendar events",
      where:
        "Read on your device and not sent to us. A linked event's title and attendee names travel with that meeting to the providers above, as spelling and speaker-naming hints.",
      stored: "Not by us.",
      retention: "As for the meeting content they travel with",
      policySection: "meetings",
    },
    {
      id: "integrations",
      data: "Notes and tasks you send to Notion, Slack, Linear, a webhook and other destinations",
      where:
        "Sent from your Mac directly to the destination you chose; not through our server. Creating Linear or Jira issues and translating a note you send in another language also use Anthropic's Claude model through our server (see the row on AI text).",
      stored: "By the destination, under its own terms.",
      retention: "The destination's own rules",
      policySection: "meetings",
    },
    {
      id: "account",
      data: "Account (the Apple or Google account identifier), sessions and subscription status",
      where: "Our server on Cloudflare; the database is stored in the EU.",
      stored: "Yes. Sign-in tokens only as one-way hashes.",
      retention: "While your account exists; deleted immediately when you delete it (sign-in tokens at most 60 days)",
      policySection: "retention",
    },
    {
      id: "usage",
      data: "Usage numbers: meeting length, audio duration and AI tokens used (no content)",
      where: "Our server, to apply the trial and plan limits.",
      stored: "Yes.",
      retention: "Up to 13 months; deleted immediately when you delete your account",
      policySection: "retention",
    },
    {
      id: "trial-record",
      data: "Pseudonymous free-trial record: a keyed hash of your sign-in identity with the trial meetings used",
      where: "Our server, to stop the same person getting the free trial again.",
      stored: "Yes, also after you delete your account.",
      retention: "Up to 24 months after you delete your account",
      policySection: "deletion",
    },
    {
      id: "statistics",
      data: "Anonymous usage statistics (on by default; you can turn them off)",
      where: "Our server, as daily totals not linked to your account. Never meeting content.",
      stored: "Yes, as daily totals.",
      retention: "400 days",
      policySection: "statistics",
    },
    {
      id: "payments",
      data: "Card and payment details",
      where: "Stripe and Link for web subscriptions; Apple and RevenueCat for App Store subscriptions.",
      stored: "Never reach us. We receive the subscription status and invoice amounts.",
      retention: "Their own policies; our accounting records of invoice amounts as long as Finnish law requires (up to 10 years)",
      policySection: "providers",
    },
    {
      id: "messages",
      data: "Contact messages, feedback and crash reports (sent only when you choose)",
      where: "Our server.",
      stored: "Yes.",
      retention: "180 days",
      policySection: "messages",
    },
  ],
};
