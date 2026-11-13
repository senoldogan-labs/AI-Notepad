---
title: How to stop AI note-taker bots from joining your meetings
description: Otter, Fireflies or Read.ai keep turning up in your calls? How to remove them in Zoom, Teams and Google Meet, stop them for good, and still get notes.
author: Senol Dogan
published: 2026-11-04
draft: false
---

You open your Monday call and there are seven participants for five people. Two of them are called something like "Otter.ai" and "Fireflies Notetaker". Nobody remembers inviting them, and one of them belongs to someone who isn't even in the meeting.

AI note-takers are useful, but the bots that join calls on someone's behalf have become a real nuisance. Universities, public agencies and law firms have started asking staff to keep them out of meetings, mostly over consent and confidential information. Microsoft added bot detection to Teams in 2026 for the same reason.

This guide covers three things: how to remove a bot from a call that's already running, how to keep bots out of future meetings in Zoom, Teams and Google Meet, and how to stop your *own* account from sending one. At the end there's a way to keep notes without any bot at all.

## Why the bots keep showing up

Most bot-based note-takers connect to a person's calendar. When a meeting appears on that calendar, the bot joins it automatically, whether or not its owner attends. So the bot in your meeting usually isn't there because someone decided to bring it today. It's there because one invitee connected their calendar months ago and left auto-join switched on.

That explains the two common surprises:

- **The bot joins even when its owner doesn't.** It follows the calendar, not the person.
- **Removing it once doesn't help.** Next week, the same calendar sends it again.

The fix has two halves: remove the bot now, then deal with the source.

## Remove a bot from a meeting in progress

If you're the host (or a co-host), you can remove a bot like any other participant.

**Zoom.** Open **Participants**, hover over the bot's name, click **More** (the three dots) and choose **Remove**. In your Zoom settings, check that **Allow removed participants to rejoin** is off, so it can't come straight back.

**Microsoft Teams.** Open **People**, right-click the bot (or use the three dots next to its name) and choose **Remove from meeting**.

**Google Meet.** Click **People**, find the bot, open the three-dot menu next to its name and choose **Remove from the call**.

Before you remove it, say why in one sentence: "I've removed the note-taker bot, since we didn't agree to recording. Happy to share notes afterwards." It keeps things friendly, and its owner will probably switch it off once they know.

## Keep bots out of future meetings

### Use a waiting room or lobby

The simplest control works on every platform: make people wait to be admitted. Bots arrive with names that give them away ("Notetaker", "AI", "Assistant"), so you can decline them from the waiting room before they hear anything.

- In **Zoom**, turn on the **Waiting Room** for the meeting or in your settings.
- In **Teams**, set **Who can bypass the lobby** in the meeting options to people in your organization, or to only you and co-organizers.
- In **Google Meet**, guests from outside your organization usually have to ask to join. Hosts can also open **Host controls** and set meeting access to **Restricted**, so only invited people get in without asking.

It costs you a click per guest, which is fine for client calls and board meetings and annoying for a large all-hands.

### Ask your admin about organization-wide controls

Admins have stronger tools than meeting hosts:

- **Microsoft Teams** now identifies many external bots when they try to join. Detected bots are labelled in the lobby so the organizer can decide, and admins can set meeting policies that block identified bots automatically. Microsoft announced the automatic block on its 2026 roadmap, so check your Teams admin center for what your tenant has.
- **Zoom** admins can enable **Block users in specific domains from joining meetings and webinars** and add the note-taker services' domains. It catches bots that sign in with their vendor's domain, but not those that join under a person's own account, so treat it as a filter, not a wall.
- **Google Workspace** admins can control who joins meetings from outside the organization. Several note-taker vendors report that Meet started treating third-party bots more strictly in 2026, but the details depend on your edition and settings.

If your company has a policy on AI note-takers, this is where it should be enforced. Asking each host to remember is not a plan.

### Tell people before the meeting

A line in the invite does more than any setting: "Please don't bring AI note-takers to this meeting. I'll share notes afterwards." Most bot owners have no idea their bot is wandering into other people's meetings, and they're glad to be told.

## Stop your own account from sending a bot

If the bot in other people's meetings is yours, turn off auto-join in the app that sends it. The setting's name differs by app, but it's usually in the meeting or calendar settings: look for something like "Auto-join meetings" or "Join all calendar events". In Otter, the assistant that joins calls is called OtterPilot, and auto-join is in its meeting settings.

Three more checks:

1. **Disconnect calendars you don't need.** If the app only needs your work calendar, remove the personal one, and vice versa.
2. **Check the Zoom and Teams app connections.** Some note-takers install an app in Zoom's or Teams' marketplace. Removing the note-taker from your calendar doesn't always remove that app.
3. **Delete old accounts properly.** If you tried a note-taker once and forgot about it, its bot may still be joining your meetings. Sign in, turn off auto-join, then delete the account.

## Why people are tired of meeting bots

It's worth understanding the objection, because it shapes how you replace the bot.

- **Consent.** A bot that joins because of someone's calendar settings records everyone in the call, including people who never agreed to it. A class action filed in California in 2025 accuses one of the best-known bot vendors of recording participants without their consent; the case is still going through the courts.
- **Confidentiality.** Legal calls, board meetings, HR conversations and client negotiations are exactly where an uninvited recorder does the most damage.
- **Atmosphere.** People talk differently when an unknown "participant" is listening, especially clients meeting you for the first time.

None of this means notes are bad. It means the recording should be a decision made by someone in the meeting, announced to everyone, and not a side effect of a calendar sync.

## Notes without a bot

You don't need a bot in the call to get a transcript and notes. Your Mac already hears the whole meeting: the other people through its speakers or headphones, and you through the microphone. A note app on the Mac can capture both, so nothing joins the call. We explain how that works, and how to tell people you're recording, in [How to take meeting notes on a Mac without a bot joining the call](/blog/meeting-notes-on-mac-without-a-bot).

This changes the consent question in a useful way. With a bot, the recording happens because of a setting. Without one, it happens because you pressed record, in a meeting you're attending, and the one-sentence announcement is yours to make.

Gistsmith, the Mac app we make, works this way. It listens to your Mac's audio and microphone, so it works with Zoom, Teams, Google Meet and calls in the browser, and it reminds you to tell participants when you start. When the meeting ends, the note is ready, with your tasks at the top, then decisions and a summary.

It runs on Macs with Apple silicon and macOS 15 or later, and on iPhone (iOS 18 or later) for meetings in the room. The first 3 meetings or 7 days are free with no card; after that it's $5.99 a month or $49 a year. See the [pricing page](/pricing) for the details, or [download it](/download) and try it on your next call.

## The short version

- Remove a bot in progress from the participant list; turn off rejoining in Zoom.
- Use a waiting room or lobby to decline bots before they join.
- Ask your admin about Teams bot blocking, Zoom domain blocking or Meet's access settings.
- Ask people in the invite not to bring note-taker bots.
- If the bot is yours, turn off auto-join and disconnect calendars you don't need.
- If you want notes, take them from your own device and tell people you're recording.
