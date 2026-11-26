// Text of the live translation landing pages: the hub (`/live-translation`) and one page each for Zoom, Microsoft Teams
// and Google Meet. They answer one question: how do I get a live translated transcript of a call on my Mac?
//
// Every product claim is checked against the app or the site's existing copy:
// - The Mac app records the microphone (you) and the system audio (the other side) separately, with no bot: the home
//   FAQ "Does a bot join my meetings?", the blog post "Recording Teams, Zoom and Google Meet on a Mac" and
//   App/SetupPage.swift (permissions: microphone and system audio).
// - The "Live translation" chip on the record bar and in Settings (App/MainWindow.swift, App/SettingsPage.swift
//   `TranslationSettings`) turns translation on; the display is "both languages" or "only the translation"
//   (`DisplayMode`). On the Mac it is off until you turn it on (App/AppSettings.swift `registerDefaultSettings`), on the
//   iPhone it is on from the start (iOS/PhoneSettings.swift).
// - Translation goes into the note language, one of `noteLanguages`, set in Settings › Recording and languages. What the
//   other participants say is translated; the user's own lines and lines already in the note language are not
//   (copy.ts `languages.mixed`). Sentences appear within seconds (copy.ts `home.showcase.live`).
// - The recording finishes when the call ends after a 30-second countdown (copy.ts `home.featureList`).
// - The iPhone app records through its microphone and is for meetings in the room; iOS lets no app listen to a call in
//   progress (blog post above, copy.ts `home.faq`).
// - Notes can be sent to Microsoft Teams and Zoom Team Chat channels (copy.ts `integrations`).
// - What Zoom, Teams and Meet offer natively is as of November 2026 and comes from the blog post
//   "Live translation in Zoom, Teams and Google Meet".
// No speech or AI provider is named: the site's marketing copy never names them (the privacy policy does).
import { productName } from "./config";
import type { Faq, PageMeta, TitledText } from "./copy";
import type { IconName } from "./lib/icons";
import { noteLanguages, spokenLanguages } from "./lib/languages";
import { formatUsdCents } from "./lib/plans";
import { tierPrices } from "./lib/tier-prices";

/** The call apps with their own page. */
export type CallApp = "zoom" | "teams" | "meet";

/** A step of the how-to list. */
export interface LiveTranslationStep {
  readonly title: string;
  readonly text: string;
}

/** A call app card on the hub. */
export interface CallAppCard {
  readonly app: CallApp;
  readonly name: string;
  readonly text: string;
  readonly link: string;
}

/** A section with an icon per item. */
export interface LiveTranslationIconItem extends TitledText {
  readonly icon: IconName;
}

/** The page of one call app. */
export interface CallAppPageCopy {
  readonly meta: PageMeta;
  /** The breadcrumb name. */
  readonly crumb: string;
  readonly title: string;
  readonly lead: string;
  readonly stepsTitle: string;
  readonly steps: readonly LiveTranslationStep[];
  readonly detailsTitle: string;
  readonly details: readonly LiveTranslationIconItem[];
  readonly faq: readonly Faq[];
}

/** The hub page. */
export interface LiveTranslationHubCopy {
  readonly meta: PageMeta;
  readonly crumb: string;
  readonly title: string;
  readonly lead: string;
  readonly appsTitle: string;
  readonly apps: readonly CallAppCard[];
  readonly stepsTitle: string;
  readonly steps: readonly LiveTranslationStep[];
  readonly faq: readonly Faq[];
}

/** Sections every live translation page shares. */
export interface LiveTranslationSharedCopy {
  readonly assurances: readonly string[];
  readonly shotAlt: string;
  readonly benefitsTitle: string;
  readonly benefits: readonly LiveTranslationIconItem[];
  readonly languagesTitle: string;
  readonly languagesText: string;
  readonly languagesLink: string;
  readonly phoneTitle: string;
  readonly phoneText: string;
  readonly phoneLinkText: string;
  readonly limitsTitle: string;
  readonly limits: readonly TitledText[];
  readonly compareTitle: string;
  readonly compareText: string;
  readonly compareLink: string;
  readonly otherAppsTitle: string;
  readonly backLabel: string;
  readonly faqTitle: string;
  readonly ctaTitle: string;
  readonly ctaText: string;
  readonly priceFaq: Faq;
}

/** The whole text of the live translation pages. */
export interface LiveTranslationCopy {
  /** The footer link. */
  readonly navLabel: string;
  /** The sentence and link on the languages page that lead here. */
  readonly languagesPageLead: string;
  readonly languagesPageLink: string;
  readonly shared: LiveTranslationSharedCopy;
  readonly hub: LiveTranslationHubCopy;
  readonly pages: Readonly<Record<CallApp, CallAppPageCopy>>;
}

const spoken: number = spokenLanguages.length;
const notes: number = noteLanguages.length;
const personalMonthly: string = formatUsdCents(tierPrices.personal.monthlyCents);
const personalYearly: string = formatUsdCents(tierPrices.personal.yearlyCents);

/** The answer about price, shared by every page (the trial and plan figures come from the same sources as /pricing). */
const priceFaq: Faq = {
  question: "What does it cost?",
  answer: `Live translation is part of ${productName}, and so is every language. You can try it free for 3 meetings or 7 days with no card; after that ${productName} Personal is ${personalMonthly} a month or ${personalYearly} a year, taxes included, for up to 10 meeting hours a month.`,
};

/** The steps every call app shares; `call` is how the call app is named in the first step. */
function steps(call: string): readonly LiveTranslationStep[] {
  return [
    { title: "Join the call as usual", text: `Open ${call} the way you always do. Nothing changes for the other people: no bot joins and no one is asked to install anything.` },
    {
      title: "Press record in Gistsmith",
      text: `Pick the language people speak, or leave it on Automatic, and turn on Live translation on the record bar. The first time, macOS asks for permission to use the microphone (you) and system audio (everyone else). Translation goes into your note language, set in Settings › Recording and languages.`,
    },
    { title: "Read along in your language", text: "Each sentence appears within seconds, with its translation underneath. If your attention drifts, “What did I miss?” summarizes the last few minutes." },
    { title: "Hang up and get the note", text: "The recording finishes when the call ends, after a 30-second countdown you can cancel with Keep recording. The note is written in your language: a summary, your own tasks, the decisions." },
  ];
}

/** The questions every call app page shares, worded for `app` (its name) and the way it is joined. */
function sharedFaq(app: string): readonly Faq[] {
  return [
    {
      question: `Do the other people in the ${app} call see anything?`,
      answer: `No. ${productName} listens to your Mac's audio and microphone; participants never see a bot and nobody else installs anything. The translation is for you only, on your screen. It reminds you to tell participants before you start recording, and the law where you are may require everyone's consent.`,
    },
    {
      question: `Which languages can it translate ${app} calls between?`,
      answer: `People can speak any of ${spoken} languages, and you read the translation in any of ${notes}, whatever language the call is in. Both lists are on the languages page. The call follows one main spoken language at a time; you can change it from the panel during the call.`,
    },
    {
      question: "Does it speak the translation aloud?",
      answer: `No. It shows the translation as text next to each sentence, so you hear the real voices and read the translation. It doesn't read it out in a synthetic voice.`,
    },
    {
      question: "Can the translation be wrong?",
      answer: "Yes. It is machine translation: it carries what the speaker means rather than word for word, but it can still be wrong, especially with names, acronyms and people talking over each other. You can keep the original sentence beside the translation, and for anything important, confirm decisions in writing afterwards.",
    },
    {
      question: "Where does the audio go?",
      answer: `Nothing goes to our speech-recognition and AI providers until you agree on the app's AI services screen, and you can withdraw in Settings at any time. After that, the audio streams from your Mac for the live transcript, and the text goes to our AI model provider for the translation. The privacy policy names each provider and explains what is kept and for how long.`,
    },
    priceFaq,
  ];
}

export const liveTranslationCopy: LiveTranslationCopy = {
  navLabel: "Live translation",
  languagesPageLead: "Using it in a call?",
  languagesPageLink: "Live translation for Zoom, Teams and Google Meet",
  shared: {
    assurances: ["3 meetings or 7 days free", "No credit card", "No bot joins"],
    shotAlt: `The ${productName} live panel while recording a Finnish meeting: each speaker's Finnish sentences with the English translation underneath, your own lines in English, and a “What did I miss?” button at the bottom.`,
    benefitsTitle: "What you get",
    benefits: [
      { icon: "translate", title: "Translation as people talk", text: "Each sentence is on screen within seconds, with the translation underneath. Show both languages, or only yours." },
      { icon: "laptop", title: "It listens to your Mac, not the call", text: "It records your microphone and your Mac's system audio, so it works the same in any call app. No bot joins and nobody else installs anything." },
      { icon: "globe", title: `${spoken} spoken languages, ${notes} to read in`, text: `Whatever language the call is in, you read it in the language you choose from ${notes}. Every language is included.` },
      { icon: "note", title: "A note when you hang up", text: "The note is written in your language: a short summary, your own tasks with due dates, the decisions and a glossary." },
    ],
    languagesTitle: "Languages",
    languagesText: `Speak or hear any of ${spoken} languages, including English, Finnish, Turkish, German, Spanish, French and Japanese, and read the live translation in any of ${notes}.`,
    languagesLink: "See all languages",
    phoneTitle: "On iPhone: for the room, not the call",
    phoneText: `The ${productName} iPhone app listens through its microphone, with live translation on from the start. It is made for meetings in the room: put the phone on the table and tap record. iOS doesn't let any app listen to the audio of a call in progress, so for an online call, use the Mac app.`,
    phoneLinkText: "How it works on iPhone",
    limitsTitle: "Good to know",
    limits: [
      { title: "It translates for you, not for everyone", text: "The translation appears in your own app. The other participants don't see it, and nothing changes in the meeting." },
      { title: "It translates what others say", text: "Your own lines, and lines already in your language, are not translated." },
      { title: "One spoken language at a time", text: "If people switch languages sentence by sentence, expect weaker results for the other language. You can switch the language from the panel during the call." },
      { title: "Tell people you're transcribing", text: "Because no bot joins, telling participants is up to you. The app reminds you before you start." },
    ],
    compareTitle: "Why not use the call app's own translation?",
    compareText:
      "Zoom, Microsoft Teams and Google Meet each have their own live translation, but what you get depends on the host's or organizer's plan and settings, so it is often switched off in meetings you don't run. Translating on your own Mac works the same in every call. Our blog compares what each one offers, as of November 2026.",
    compareLink: "What Zoom, Teams and Meet offer",
    otherAppsTitle: "Other call apps",
    backLabel: "Live translation",
    faqTitle: "Questions",
    ctaTitle: "Read your next call in your own language.",
    ctaText: `Try ${productName} free for 3 meetings or 7 days, no card needed.`,
    priceFaq,
  },
  hub: {
    meta: {
      title: "Live translation for Zoom, Teams and Google Meet on Mac",
      description: `Live translation for Zoom, Teams and Google Meet on Mac, in ${notes} languages. ${productName} listens to your Mac's audio: no bot joins, nobody else installs anything.`,
    },
    crumb: "Live translation",
    title: "Live translation for Zoom, Teams and Google Meet.",
    lead: `${productName} listens to your Mac's own audio and shows a live transcript with a translation into your language, in any call app. No bot joins, nobody else installs anything, and the other people see nothing change.`,
    appsTitle: "Pick your call app",
    apps: [
      { app: "zoom", name: "Zoom", text: "Translate a Zoom meeting live, whether you host it or only join, without waiting for the host to turn translated captions on.", link: "Translate Zoom live" },
      { app: "teams", name: "Microsoft Teams", text: "Read a Teams meeting in your language as people talk, with no Copilot license and nothing for your IT team to switch on in Teams.", link: "Teams live translation" },
      { app: "meet", name: "Google Meet", text: "Follow a Google Meet call in your language from the Mac, in Chrome, Safari or any browser, whatever the organizer's plan.", link: "Google Meet live translation" },
    ],
    stepsTitle: "How to get a live translated transcript of a call",
    steps: steps("your call app"),
    faq: [
      {
        question: "How do I translate a video call live on my Mac?",
        answer: `Install ${productName}, join the call as usual, press record and turn on Live translation. It captures your Mac's audio, so the same steps work in Zoom, Microsoft Teams, Google Meet and any other call app. Each sentence appears within seconds with its translation into your language underneath.`,
      },
      {
        question: "Does it work in Zoom, Teams and Google Meet?",
        answer: `Yes, and in any other call app. It records the sound your Mac plays and your microphone, so the call app doesn't matter, and the Zoom or Teams app and Google Meet in a browser all work the same way. Each has its own page: translate Zoom live, Teams live translation and Google Meet live translation.`,
      },
      {
        question: "Do I need the host's permission or a special plan?",
        answer: `No. The translation happens on your side, in ${productName}, so it doesn't depend on the host's account or on any setting in the call app. Check your own rules on transcribing meetings, though: you should tell the other participants.`,
      },
      ...sharedFaq("video"),
    ],
  },
  pages: {
    zoom: {
      meta: {
        title: "Translate a Zoom meeting live on Mac: live transcript and translation",
        description: `Translate a Zoom meeting live on your Mac, in ${notes} languages. ${productName} shows what people say in your language. No bot joins, nobody else installs anything.`,
      },
      crumb: "Zoom",
      title: "Translate a Zoom meeting live.",
      lead: `${productName} listens to your Mac's own audio, so you can read a live translated transcript of any Zoom meeting in your language, whether you host it or only join. No bot joins, and nobody else installs anything.`,
      stepsTitle: "How to translate a Zoom meeting live on a Mac",
      steps: steps("Zoom"),
      detailsTitle: "Zoom specifics",
      details: [
        {
          icon: "users",
          title: "Host or guest, it works",
          text: "Zoom's translated captions depend on the host's account and need the host or an admin to turn them on (as of November 2026). Gistsmith translates on your Mac, so it works in meetings you only join.",
        },
        { icon: "laptop", title: "The Zoom app or the browser", text: "It hears whatever Zoom plays through your Mac, in the Zoom app or the web client, and your microphone for your own voice." },
        { icon: "message", title: "Note to Zoom Team Chat", text: "When the call ends, post the note to a Zoom Team Chat channel through an incoming webhook, or to Slack, Teams or Notion." },
      ],
      faq: [
        {
          question: "How do I translate a Zoom meeting live?",
          answer: `Open ${productName} on your Mac, join the Zoom meeting as usual, press record and turn on Live translation. Each sentence appears within seconds with a translation into your language underneath. It listens to your Mac's audio, so you don't need to change anything in Zoom.`,
        },
        {
          question: `Is ${productName} a Zoom voice translator?`,
          answer: `It translates what people say in Zoom into text in your language, shown on your screen next to each sentence. It doesn't speak the translation: you keep hearing the real voices and read the translation.`,
        },
        {
          question: "Does Zoom have its own live translation?",
          answer: "Zoom offers translated captions, which depend on the host's account and plan and must be turned on by the host or an admin. Translating on your own Mac doesn't depend on any of that, so it also works in meetings you don't host. Our blog post compares Zoom, Teams and Meet as of November 2026.",
        },
        ...sharedFaq("Zoom"),
      ],
    },
    teams: {
      meta: {
        title: "Live translation for Microsoft Teams on Mac: no Copilot license",
        description: `Teams live translation on Mac: read any Microsoft Teams meeting in your language, in ${notes} languages. No bot, no Copilot license, nothing for others to install.`,
      },
      crumb: "Microsoft Teams",
      title: "Live translation for Microsoft Teams meetings.",
      lead: `${productName} listens to your Mac's own audio, so you can read a live translated transcript of any Microsoft Teams meeting in your language. No bot joins, nothing is needed from your organization's Teams settings, and nobody else installs anything.`,
      stepsTitle: "How to get live translation in a Teams meeting on a Mac",
      steps: steps("Microsoft Teams"),
      detailsTitle: "Teams specifics",
      details: [
        {
          icon: "lock",
          title: "No Copilot license, no Teams Premium",
          text: "Teams' own live translation needs licenses (as of November 2026, the Interpreter agent needs Microsoft 365 Copilot and translated captions come with Teams Premium). Gistsmith doesn't use any of it: it translates what your Mac plays.",
        },
        { icon: "users", title: "Guest in another organization's meeting", text: "It works the same when you join a client's or partner's meeting, because it runs on your Mac and not in their Teams." },
        { icon: "laptop", title: "The Teams app or the browser", text: "It hears whatever Teams plays through your Mac, in the Teams app or in a browser, and your microphone for your own voice." },
        { icon: "message", title: "Note to a Teams channel", text: "Post the note to a Microsoft Teams channel as a message after you sign in with Microsoft, or as a card through a Power Automate or Office webhook." },
      ],
      faq: [
        {
          question: "How do I get live translation in a Teams meeting?",
          answer: `Open ${productName} on your Mac, join the Teams meeting as usual, press record and turn on Live translation. Each sentence appears within seconds with a translation into your language underneath. Nothing is needed from the organizer or from Teams settings.`,
        },
        {
          question: "Do I need Microsoft 365 Copilot or Teams Premium?",
          answer: `No. Microsoft's own live translation depends on licenses (as of November 2026, the Interpreter agent needs Microsoft 365 Copilot and live translated captions are part of Teams Premium). ${productName} works on your Mac and uses neither, so you only need its own subscription after the free trial.`,
        },
        {
          question: "Do I need my IT department's approval?",
          answer: `${productName} is an ordinary Mac app that listens to your Mac's audio. It doesn't use Teams' recording feature or an admin setting in Teams. If your work Mac restricts installing apps, ask IT, and check your organization's rules on transcribing meetings.`,
        },
        ...sharedFaq("Teams"),
      ],
    },
    meet: {
      meta: {
        title: "Google Meet live translation on Mac: translate Meet calls live",
        description: `Google Meet live translation on Mac: read any Meet call in your language as people talk, in ${notes} languages. No bot joins, nobody else installs anything.`,
      },
      crumb: "Google Meet",
      title: "Google Meet live translation.",
      lead: `${productName} listens to your Mac's own audio, so you can read a live translated transcript of any Google Meet call in your language, in Chrome, Safari or any browser. No bot joins, and nobody else installs anything.`,
      stepsTitle: "How to translate a Google Meet call live on a Mac",
      steps: steps("Google Meet in your browser"),
      detailsTitle: "Google Meet specifics",
      details: [
        {
          icon: "users",
          title: "Whatever the organizer's plan",
          text: "Meet's own speech translation depends on the organizer's plan and has time limits on some plans (as of November 2026). Gistsmith translates on your Mac, so it doesn't matter whose meeting it is.",
        },
        { icon: "globe", title: "Any browser", text: "Meet runs in a browser tab, and a Mac app hears a browser like any other app: whatever the tab plays comes through your Mac's system audio. Your microphone covers your own voice." },
        { icon: "timer", title: "Long calls", text: "A meeting can run up to 4 hours with Gistsmith, and a subscription covers up to 10 meeting hours a month." },
      ],
      faq: [
        {
          question: "How do I translate a Google Meet call live?",
          answer: `Open ${productName} on your Mac, join the Meet call in your browser as usual, press record and turn on Live translation. Each sentence appears within seconds with a translation into your language underneath. It listens to your Mac's audio, so nothing changes in Meet.`,
        },
        {
          question: "Does Google Meet have live translation of its own?",
          answer: "Yes. Meet offers speech translation that depends on the organizer's plan and has time limits on some plans, and it isn't available in every meeting. Translating on your own Mac doesn't depend on the organizer's plan, so it also works in meetings you don't run. Our blog post compares Zoom, Teams and Meet as of November 2026.",
        },
        {
          question: "Does it work if Meet is open in Chrome or Safari?",
          answer: `Yes. A browser tab is sound coming out of your Mac like any other app, so ${productName} hears it with the system audio permission.`,
        },
        ...sharedFaq("Meet"),
      ],
    },
  },
};
