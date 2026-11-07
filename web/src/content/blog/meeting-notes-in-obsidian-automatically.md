---
title: Meeting notes in Obsidian, written for you after every call
description: A simple Obsidian setup for meeting notes on a Mac, from file names to searchable task checkboxes, and how to have each note written into your vault for you.
author: Senol Dogan
published: 2026-11-01
draft: false
---

Obsidian is a good home for meeting notes. They're plain Markdown files in a folder you own, they link to your projects and people, and they'll still open in twenty years. The weak spot is getting the notes in there. After a call, writing up the meeting is the first thing that gets skipped.

This guide sets up a meetings folder in Obsidian that works well whether you type the notes yourself or have an app write them. The second half shows how to have every note land in your vault on its own.

## One folder, one file per meeting

Make a folder called `Meetings` in your vault. Every meeting gets its own file, named with the date and time first:

```
Meetings/
  2026-10-27 0930 Product weekly.md
  2026-10-27 1400 Client call Nordia.md
  2026-10-28 1000 One-on-one with Elif.md
```

The date at the front keeps the folder in order without any plugins. The time stops two meetings with the same name on the same day, like two "Daily" stand-ups, from overwriting each other. The title after it is what you'll search for later.

Resist the urge to build a deep tree of subfolders per client or project. Links and search do that job better, and a flat folder never leaves you wondering where a meeting went.

## Put the outcome at the top

Inside each file, the order matters more than the formatting. Put what you need afterwards first:

```markdown
# Product weekly

## Your tasks

- [ ] **Me** — Write the beta release notes (Friday)

## Summary

The beta opens on 14 November. Pricing stays as it is until January.

## Decisions

- The beta opens on 14 November.

## Other tasks

- [ ] **Ayşe** — Send the two pricing options to the team (Thursday)

## Transcript

...
```

Your own tasks at the very top, because that's what you open the note for. Then the summary and decisions. Everyone else's tasks below that, and the full transcript at the bottom for when you need the exact words.

## Tasks as checkboxes

Write tasks as Markdown checkboxes: `- [ ] **Owner** — what (when)`. Obsidian renders them as real checkboxes you can tick, and the format makes them searchable across every meeting.

In Obsidian's search, try:

- `task-todo:` lists every unticked checkbox in the vault.
- `path:Meetings task-todo:Ayşe` lists Ayşe's open tasks from your meetings.
- `path:Meetings Nordia` finds every meeting that mentions a client.

If you use the Tasks or Dataview community plugins, the same checkboxes work there too, so you can build a dashboard of open tasks by due date. You don't need either to start.

## Link the people and projects

The real strength of Obsidian is links. After a meeting, turn the names that matter into links: `[[Elif]]`, `[[Nordia]]`, `[[Beta launch]]`. The backlinks panel on each of those pages then shows every meeting they came up in.

Don't link everything. Two or three links per meeting, to the people and projects you'll want to look up later, is plenty.

## Keep the vault in sync

If your vault is in iCloud Drive, your meeting notes appear on your iPhone and iPad as well, in the Obsidian app. Obsidian Sync works too. Whichever you use, put the `Meetings` folder inside the vault, not next to it.

## Having the notes written for you

The setup above works by hand. It works better when the notes appear on their own, because then they're always there, including after the meetings you'd never have written up.

Gistsmith, the Mac app we make, has a folder option for exactly this. It listens to the meeting on your Mac, with no bot in the call, and when the meeting ends it writes the note as a Markdown file:

1. In Gistsmith, open **Settings › Connections**.
2. On the **Folder (Obsidian, iCloud)** card, click **Choose…** and select the `Meetings` folder in your vault.
3. Turn on **Write to folder**.

From then on, every finished note is written to that folder in the format described above:

- The file is named with the date and time, then the title, for example `2026-10-27 0930 Product weekly.md`.
- It starts with **Your tasks** as checkboxes, with owners and due dates when they were mentioned. Then **Summary**, a **Topic flow** with timestamps, **Decisions**, **Other tasks**, a **Glossary**, and the **Transcript** by speaker with timestamps.
- If the meeting was translated, each paragraph of the transcript has its translation underneath.
- If the note changes later, for example when you rename the meeting, the file is updated. A renamed meeting replaces its old file instead of leaving a copy behind.
- Gistsmith only replaces files it wrote itself. It marks each one with an invisible comment at the end, so your own notes in the same folder are never touched.

The note is a normal Markdown file. Add your links, tick your tasks and write your own thoughts under it.

One thing to keep in mind: if you edit a note in Obsidian and the meeting's note later changes in Gistsmith, the file is written again and your edits in that file are replaced. If you plan to write a lot, keep your own thoughts in a separate note that links to the meeting.

Gistsmith runs on Macs with Apple silicon and macOS 15 or later, and on iPhone (iOS 26.1 or later) for meetings in the room. You can try it on 3 meetings or for 7 days without a card; after that it's $5.99 a month or $49 a year. If you'd rather your AI apps read the meetings directly, it also includes a [read-only MCP server](/mcp) for Claude, Cursor and VS Code.

## The short version

- One flat `Meetings` folder, one file per meeting, named `YYYY-MM-DD HHmm Title.md`.
- Your tasks first, as checkboxes. Search them with `task-todo:`.
- Link the two or three people and projects that matter.
- Keep the folder inside a synced vault.
- Let an app write the first draft, so the note exists even when you're too busy to write it.
