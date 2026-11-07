---
title: "Ask Claude about your meetings: MCP for meeting notes, explained"
description: What MCP is, how it lets Claude, ChatGPT, Cursor or VS Code read your meeting notes, prompts to try, and the privacy questions to ask before you connect.
author: Senol Dogan
published: 2026-11-26
draft: false
---

You've had dozens of meetings this quarter. Somewhere in them is the answer to "what did we promise the client about the March release?" You could scroll through notes for twenty minutes, or you could ask.

AI assistants like Claude are good at exactly this kind of question, as long as they can see your meetings. Until recently that meant copying transcripts into a chat window, one at a time. MCP changes that: it lets an AI app look things up in your meeting notes by itself, when it needs to.

This post explains what MCP is in plain terms, what you can do with it once your meeting notes are connected, and what to check before you connect anything.

## What MCP is, in one paragraph

The **Model Context Protocol** (MCP) is an open standard for connecting AI apps to other software. A program that speaks MCP, called an **MCP server**, offers a few **tools**, like "search meetings" or "get a meeting's notes". An AI app that supports MCP, such as Claude, Cursor or Visual Studio Code, can call those tools while it's answering you. You ask a question in plain language; the AI decides which tools to use, reads what comes back, and answers.

Think of it as giving your AI assistant a library card for one specific library, rather than handing it the whole building.

## Why meeting notes are a good fit

Meeting notes are almost perfect material for an AI assistant:

- **They're full of commitments.** Who promised what, by when.
- **They're spread over time.** The answer is rarely in a single meeting.
- **Nobody rereads them.** So the knowledge in them is mostly lost unless something can search it for you.

Without MCP you'd copy and paste. With it, the assistant searches, opens the two or three meetings that matter, and answers with the details.

## What you can ask

Here are prompts that work well once your meeting notes are connected. They're written for Claude, but any MCP-capable assistant handles them similarly.

**Catching up**
- "What happened in last week's product meetings? Three bullet points."
- "I was on holiday for two weeks. What did I miss in the client calls with Nordia?"

**Commitments and tasks**
- "List everything I promised to do in meetings this month that isn't done yet."
- "What did I tell the Nordia team I'd send them, and when?"

**Decisions**
- "What did we decide about the pricing tiers, and in which meeting?"
- "Has the launch date changed in any meeting since October? Show me each change."

**Preparation**
- "I'm meeting Elif tomorrow. Summarize our last three one-on-ones and list open topics."
- "Draft an agenda for Thursday's steering group based on the open questions from the last two meetings."

**Writing**
- "Write a status update for the leadership channel from this week's project meetings."
- "Turn the decisions from yesterday's workshop into a short changelog."

**In a code editor** (Cursor or VS Code)
- "Find the meeting where we discussed the API rate limits and summarize the requirements."
- "Did anyone mention edge cases for the import feature in meetings? List them."

Two tips make the answers better. Name the meeting, person or time range when you can; "last week's client calls" is easier to search than "recently". And ask for sources: "Tell me which meeting each point came from" lets you check the answer instead of trusting it.

## What to check before you connect

Connecting your meetings to an AI app is a real decision. Your meetings contain things you wouldn't paste into a public chat. Ask these questions about any MCP server you install:

**Can it only read, or can it also change things?** A read-only server can list and search; it can't edit, delete or send. For meeting notes, read-only is usually all you need.

**Where does it run?** A local server runs on your computer and reads data that's already there. A remote server runs somewhere else and needs an account and network access.

**What does the AI app do with what it reads?** When the assistant opens a meeting, that text goes to the AI app's model as part of your conversation, under that app's own privacy terms. Check them, especially for work data, and check your company's policy on AI tools.

**Can you see what it's doing?** Good AI apps show each tool call ("Searched your meetings", "Opened Product weekly") and let you approve tools before they run. Keep that turned on until you trust the setup.

**Does it do what it says?** Only install MCP servers from sources you trust. A server is a program running on your computer.

## Where AI assistants are going with this

The broader trend in 2026 is clear: AI assistants are moving from chatting to doing work across your tools, and MCP is one of the main ways they connect to those tools. Meeting knowledge is one of the most useful things to connect, because so much work starts with "as discussed in the meeting…".

It's also why the format of your notes matters. Notes with clear decisions and tasks, each with an owner and a date, give an AI assistant something precise to work with. A wall of transcript works too, but answers are better when the structure is already there. Our [task list method](/blog/turn-a-meeting-into-a-task-list) helps with that whether or not you use AI.

## Gistsmith's MCP connections

Claude, ChatGPT, Cursor and VS Code can search and read your Gistsmith meetings (on your Mac, or online with AI assistant access); they can never change them. There are two ways in, and you can use either or both.

**On your Mac: the local MCP server.** The Mac app includes a small MCP server that runs on your Mac and only reads. It gives your AI app six tools: list your meetings, search notes and transcripts, open a meeting's note (with the transcript if needed), list your open tasks from all your meetings, and, if you turn on shared-screen snapshots, list a meeting's screens and open each one with what was said while it was up. You connect it in one click from **Settings › Connections** for Claude, Cursor and Visual Studio Code, or copy a configuration for any other MCP app.

**In the browser or on your phone: AI assistant access.** Claude and ChatGPT on the web or on a phone can't start an app on your Mac, so for them there is an online connector. It's off by default: you turn on "Let AI assistants read my meeting notes" in the Gistsmith app on Mac or iPhone, under **Settings › Connections**, then add Gistsmith in Claude (it's in Claude's connector directory) or as a custom connector in ChatGPT. It reads your meeting notes only, never transcripts or audio, through four read-only tools: search, open a note, list your meetings and list your tasks. To make that work, an encrypted copy of your notes is kept in the EU; it's encrypted at rest but not end to end, so our servers can read it to answer your assistant. Turn the setting off and the copy is deleted at once.

The [MCP page](/mcp) has the steps for both, including the connector address and exactly which configuration file each Mac app uses.

If you prefer plain files to AI apps, Gistsmith can also save every note as Markdown in a folder, such as your Obsidian vault; we described that setup in [Meeting notes in Obsidian](/blog/meeting-notes-in-obsidian-automatically).

Gistsmith runs on Macs with Apple silicon and macOS 15 or later, and on iPhone for meetings in the room. It records meetings with no bot in the call and writes a note with a summary, your own tasks picked out with due dates, decisions and a glossary. The first 3 meetings or 7 days are free with no card; then it's $5.99 a month or $49 a year ([pricing](/pricing)).

## The short version

- MCP lets an AI app call tools, such as "search meetings", while it answers you.
- Meeting notes are a great fit: full of commitments, spread over time, rarely reread.
- Ask specific questions and ask for sources.
- Before connecting, check: read-only, local or remote, where any copy of your notes is kept, the AI app's privacy terms, and visible tool calls.
- Structured notes (decisions, tasks with owners and dates) make AI answers better.
