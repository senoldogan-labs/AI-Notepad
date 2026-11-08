---
title: "AI note-takers and GDPR: a checklist before you record a meeting in Europe"
description: What GDPR asks of you when an AI app transcribes a meeting, what the EU AI Act changed in 2026, and the questions to ask any note-taker vendor.
author: Senol Dogan
published: 2026-11-06
cover: mint
draft: false
---

If you work in Europe, or with people who do, recording and transcribing a meeting is processing personal data. Voices, names, opinions, sometimes health or HR details: all of it lands in a transcript, and often with an AI provider somewhere along the way.

That doesn't make AI note-takers off-limits. It means you need a few things in place before you press record. This checklist covers what the GDPR expects, what the EU AI Act changed in August 2026, and what to ask a vendor before you trust it with your meetings.

One honest caveat first: this is a practical overview, not legal advice. Rules differ between countries, and your organization's data protection officer has the final word.

## Who is responsible: you, not the app

Under the GDPR, the organization that decides to record a meeting is usually the **controller**. The note-taker vendor processes data on your behalf, which makes it a **processor**. You can hand the transcription to a vendor, but not the responsibility for it.

In practice that means three questions are yours to answer:

1. Why are you recording, and on what legal basis?
2. Have the people in the meeting been told?
3. Does the vendor's setup meet your obligations?

If you record a meeting for your own job at a company, your employer is the controller and its policies apply. If you're self-employed, it's you.

## Step 1: Pick a lawful basis

The GDPR lists six legal bases for processing personal data. For meeting notes, two come up most:

- **Legitimate interests.** You have a genuine reason, such as accurate minutes or follow-up tasks, and it isn't outweighed by the participants' interests. Many organizations use this for internal meetings, backed by a short written assessment.
- **Consent.** Everyone agrees, freely and in a way you can show. It sounds simplest, but it has a catch: consent must be as easy to withdraw as to give, and in a workplace, "freely given" is hard to prove when your manager is asking.

Whichever you choose, write it down. A two-paragraph note explaining why you record, what you keep and for how long is far better than nothing when someone asks.

If your meetings regularly touch on health, trade union membership or other special categories of data, you need an additional condition under Article 9. In that case, involve your data protection officer before you start.

## Step 2: Tell people, every time

Whatever the legal basis, people have a right to know their words are being recorded and transcribed. Several European regulators stress telling participants in advance, not halfway through.

A simple routine covers most of it:

- **In the invite:** "This meeting will be transcribed by an AI app to produce notes. Reply if you'd rather it wasn't."
- **At the start:** one spoken sentence, before the agenda.
- **In the chat:** for people who join late.
- **A link to details:** your privacy notice, or the vendor's, so anyone can see where the data goes.

When a bot joins the call, its name in the participant list does part of this job, although a name like "Notetaker" doesn't tell anyone where the data goes. When you record on your own device, no indicator appears, so the announcement is entirely yours. We wrote about [how to say it without making it awkward](/blog/meeting-notes-on-mac-without-a-bot).

Recording laws outside the GDPR can apply too. Some countries, and some US states such as California, require every party's consent to record a conversation. If your meetings cross borders, the strictest rule in the room is the safe one to follow.

## Step 3: Keep only what you need

Data minimisation is the GDPR principle that matters most for meetings, because transcripts are long and full of things nobody needs a year later.

- **Decide what you keep.** Often the note (decisions, tasks, summary) is enough, and the audio can go.
- **Set a retention period.** "We delete recordings after 30 days and keep notes for the project's lifetime" is a policy. "We keep everything" isn't.
- **Pause for sensitive moments.** If the conversation turns personal, stop recording and start again afterwards.
- **Limit sharing.** Send the note to the people who were there, not to a company-wide channel by default.

## Step 4: Check the vendor

This is where most of the risk sits. Before you use a note-taker for work, get clear answers to these questions. A good vendor has them in its privacy policy or security documentation.

- **Is there a data processing agreement (Article 28)?** Without one, using a processor isn't compliant.
- **Which subprocessors handle audio and text?** Transcription and AI summaries often run on other companies' services.
- **Where is the data processed and stored?** Transfers outside the EU need safeguards such as the EU–US Data Privacy Framework or standard contractual clauses.
- **How long does each party keep it?** The vendor and every subprocessor should have a stated retention period.
- **Is your data used to train models?** You want a clear "no", or at least an opt-out.
- **Can you delete everything?** Deleting your account should delete your data, on a timeline you can check.
- **Does a bot join, or does it record locally?** It changes who sees that a recording is happening, and who has to announce it.

For larger roll-outs, a data protection impact assessment (DPIA) is often expected, especially if meetings are recorded systematically or include sensitive topics.

## What the EU AI Act changed in 2026

The EU AI Act's transparency rules in **Article 50** started to apply on **2 August 2026**. The Digital Omnibus package postponed several other parts of the Act, notably obligations for high-risk systems, but most of Article 50 stayed on schedule.

Article 50 is mainly about telling people when they're dealing with AI: chatbots must say they're chatbots, emotion recognition and biometric categorisation must be disclosed, deepfakes must be labelled, and AI-generated text published to inform the public needs a disclosure.

A note-taker that transcribes your meeting and writes a summary for you is usually not the main target of these rules. But two things follow from the new climate:

- **Expect vendors to be more explicit** about what is AI-generated, including summaries and translations.
- **Label AI-written notes when you share them.** A line like "Summary written by an AI app from the transcript; check before relying on it" is honest and costs nothing.

The duty to inform participants about the recording itself still comes from the GDPR, as described above. The AI Act adds to it; it doesn't replace it.

## A one-page policy you can adapt

If your team has nothing written down, start with this:

```
AI meeting notes: how we do it

- We transcribe meetings only when it's useful for notes or tasks.
- We say so in the invite and at the start of the meeting.
- Anyone can ask us not to record; we then take notes by hand.
- We don't record HR, health or legal conversations.
- Notes go to the people who attended.
- Audio is deleted after [30] days; notes are kept for [the project].
- Approved tools: [list]. No other note-taker bots in our meetings.
```

It fits on one screen, and it answers most of the questions a participant, a client or a regulator would ask.

## How Gistsmith handles it

Gistsmith, the app we make, records on your Mac, with no bot in the call, and reminds you to tell participants when a recording starts.

Notes, transcripts and recordings are stored on your Mac. While you record, audio is sent to a transcription provider for the live transcript. When the meeting ends, the recording goes through our server to a second transcription provider for the final transcript, and the text goes to an AI model for the note. Our servers don't store your audio, or notes they can read unless you turn on the optional AI assistant access (sync and share links keep only end-to-end encrypted copies), and your meetings aren't used to train our providers' models. The [privacy policy](/privacy) names each provider, what it receives and how long it may keep it, which is exactly the list your data protection officer will ask for.

It runs on Macs with Apple silicon and macOS 15 or later, and on iPhone (iOS 26.1 or later) for meetings in the room. You can try it on 3 meetings or for 7 days without a card; after that it's $5.99 a month or $49 a year ([pricing](/pricing)).

## The short version

- Your organization is the controller; the note-taker is a processor.
- Choose and document a lawful basis, usually legitimate interests or consent.
- Tell people in the invite, at the start and in the chat.
- Keep the note, delete the audio, set a retention period.
- Ask vendors about subprocessors, data location, retention, training and deletion.
- The AI Act's transparency rules apply from 2 August 2026; label AI-written notes when you share them.
