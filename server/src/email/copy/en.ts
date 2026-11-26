import type { EmailCopy, FreePlanFacts, TrialFacts } from "./types";

export const en: EmailCopy = {
  htmlLang: "en",
  footer: {
    lifecycleReason: "You're getting this because you asked for Gistsmith tips and reminders.",
    unsubscribe: "Unsubscribe",
    inApp: "or turn it off in Gistsmith › Settings › Account.",
    confirmReason:
      "Someone entered this address in Gistsmith. If it wasn't you, just ignore this email: nothing more is sent unless the link is clicked, and we delete the address within 7 days.",
    notMe: "This wasn't me",
    privacy: (address: string): string => `Privacy questions: ${address}`,
    privacyPolicy: "Privacy policy",
    country: "Finland",
    reply: "Questions? Reply to this email.",
    linkFallback: "If the button doesn't work, open this link:",
  },
  confirm: {
    subject: "Confirm your email for Gistsmith",
    preheader: "One click to get Gistsmith tips and your trial reminder.",
    heading: "Confirm your email",
    body: [
      "You asked Gistsmith to email you a few tips and a reminder before your free trial ends.",
      "Confirm this address and we'll start. We send nothing else, and you can stop at any time.",
    ],
    cta: "Confirm my email",
    note: "The link works for 7 days.",
  },
  welcome: {
    subject: "Your first meeting with Gistsmith",
    preheader: "Record one meeting and get the note when it ends.",
    heading: "Welcome to Gistsmith",
    body: [
      "The quickest way to see what Gistsmith does is one real meeting. When your next call starts, click Start recording in Gistsmith on your Mac, or open Gistsmith on your iPhone and tap Start recording.",
      "When the meeting ends, you get the transcript, a short note and the action items.",
      "On the iPhone, Gistsmith Keyboard lets you type by voice in any app. It's free: turn it on in Gistsmith › Settings › Keyboard.",
    ],
    cta: "Record a meeting",
  },
  activation: {
    subject: "Ready for your first meeting?",
    preheader: "Your free trial starts with your first meeting, not before.",
    heading: "Your trial hasn't started yet",
    body: (trial: TrialFacts): readonly string[] => [
      `You signed up for Gistsmith but haven't recorded a meeting yet. That's fine: your free trial (${trial.meetings} meetings or ${trial.days} days) only starts with your first meeting.`,
      "Next time you're on Zoom, Teams or Google Meet, or in a room, start recording in Gistsmith. The note is ready when the meeting ends.",
      "This is the only reminder we send about it.",
    ],
    cta: "Record a meeting",
  },
  trialEnding: {
    subject: "Your Gistsmith trial ends soon",
    preheader: "What happens next to your meetings and notes.",
    heading: "Your trial ends soon",
    oneMeetingLeft: "You have one free trial meeting left.",
    endsWithinDay: "Your free trial ends within a day.",
    nextFree: (free: FreePlanFacts): string =>
      `After that, your account moves to the Free plan on its own: ${free.notesPerMonth} AI notes a month for meetings up to ${free.maxMeetingMinutes} minutes, and ${free.asksPerMonth} Ask answers a month.`,
    nextSubscribe: "After that, a subscription keeps Gistsmith transcribing your meetings and writing the notes.",
    keep: "Your meetings and notes stay on your devices either way.",
    cta: "See plans",
  },
  freePlan: {
    subject: "You're on the Gistsmith Free plan",
    preheader: "What the Free plan includes every month.",
    heading: "Welcome to the Free plan",
    intro: "Your trial is over, and your account is now on the Free plan. It doesn't expire.",
    items: (free: FreePlanFacts): readonly string[] => [
      `${free.notesPerMonth} AI notes a month, for meetings up to ${free.maxMeetingMinutes} minutes`,
      `${free.asksPerMonth} Ask answers a month`,
      "Transcripts written on your device",
      "Gistsmith Keyboard on the iPhone",
    ],
    outro: "When you need longer meetings or more notes, Personal and Pro raise the limits.",
    cta: "Compare plans",
  },
};
