# Gistsmith for iPhone: custom product page concepts

Three custom product pages (CPPs). Each targets one audience with its own promotional text, screenshot order and
headlines, header, and search keywords. Each page also gets its own Apple Ads ad variation. They are written in
English (U.S.) first because that is the only live storefront language. Translate the winner(s) once the data shows
which page converts. Limits are the same as on the main page (promotional text ≤ 170, keywords ≤ 100). To check the
`text` blocks, run `node scripts/appstore-screenshots/metadata-check.ts docs/appstore/custom-product-pages.md`.

Screenshot headlines use the pipeline's limits (`scripts/appstore-screenshots/config.ts`: headline ≤ 30, subhead
≤ 60). The tables below are mirrored in `customPages` in `config.ts`; the raws come from `pageScenes`, captured with
their own seeded data (`seeder`: `lectures` and `interviews` sets). "Existing" means a raw from the main set; "new raw"
means a page-only capture. The marketing renderer writes each page to `cpp-<name>/6.9` and `cpp-<name>/6.3` (see
`after-approval-checklist.md`).

Trial wording, where it fits: "first 3 meetings or 7 days free, whichever comes first". Every claim stays inside
what the iPhone app does: it records the conversation in the room through the iPhone
microphone. It does not record phone calls or online meetings.

---

## 1. Students: lectures and seminars

**Reference name:** `cpp-students-lectures`
**Audience:** university and adult-education students who record lectures, seminars and study groups.
**Deep link use:** campus and student-community posts, the gistsmith.com blog posts about lectures.

### Promotional Text

```text
Record the lecture; when it ends, your notes are ready: key points, glossary and to-dos. Ask past lectures anything. First 3 lectures or 7 days free.
```

### Keywords

```text
lecture,class,seminar,student,study,university,college,course,exam,revision,notes app,school,teacher
```

### Screenshots (order)

| # | Raw | Headline (≤ 30) | Subhead (≤ 60) |
|---|-----|-----------------|----------------|
| 1 | live (existing) | Never miss what was said | Live transcript of the lecture, speaker by speaker. |
| 2 | note, re-seeded as a lecture (new raw) | Lecture notes, done | Key points and to-dos, ready when class ends. |
| 3 | ask (existing; new raw with an exam question is better) | Revise by asking | "What did the lecturer say about the exam?" |
| 4 | meetings (new raw) | Every class, searchable | Find any topic by word, course or date. |
| 5 | record (existing) | One tap to start | Put your iPhone on the desk and press record. |

Template to show in the note raw: **Lecture / training** (`NoteTemplateKind.lecture`). Header: the main header with the
headline "Lectures, already written up."

**Apple Ads:** a Search Results ad variation with this page, in an ad group with the keywords above plus
`lecture recorder`, `lecture notes`, `class notes`, `record lectures`. Use exact match for these terms and
search match off, so the ads don't show for meeting queries.

---

## 2. Interviews and research

**Reference name:** `cpp-interviews-research`
**Audience:** UX researchers, journalists, recruiters and students doing in-person interviews.
**Deep link use:** research-community newsletters, LinkedIn posts aimed at recruiters.

### Promotional Text

```text
Record in-person interviews: a transcript by speaker, and when it ends, a note with key points and next steps. Ask across interviews. Export text or SRT subtitles.
```

### Keywords

```text
interview,research,journalist,quotes,transcriber,qualitative,user research,podcast,hiring,recruiter
```

Note: "podcast" only fits in-person recordings and imported audio files. Remove it if Apple Ads data shows people
searching it want call or remote recording.

### Screenshots (order)

| # | Raw | Headline (≤ 30) | Subhead (≤ 60) |
|---|-----|-----------------|----------------|
| 1 | live (existing) | Every answer, word for word | A live transcript, separated by speaker. |
| 2 | ask (new raw with an interview question) | Ask across interviews | Plain-language answers that cite each interview. |
| 3 | note, re-seeded as an interview (new raw) | Key points, not just text | Summary, glossary and follow-ups for each interview. |
| 4 | people (new raw: `PhonePeople`) | Know who said what | Name speakers once; see their meetings and talk time. |
| 5 | meetings (new raw) | Bring your recordings | Import audio or video from Files or Photos. |

Templates to show: **Job interview** for recruiting, or a **custom** template for research ("list quotes about
pricing with timestamps"). Header idea: one phone with a transcript, headline "Interviews, word for word."

**Apple Ads:** an ad group with `interview transcription`, `transcribe interview`, `interview recorder`,
`research notes` (exact match). Keep `call recorder`-style terms as **negative** keywords.

---

## 3. In-person team meetings: managers and leads

**Reference name:** `cpp-team-meetings`
**Audience:** managers and team leads who run one-to-ones, stand-ups and client visits face to face.
**Deep link use:** the gistsmith.com iPhone section and Gistsmith for Mac users (one account and subscription for
Mac and iPhone; meeting sync between devices is optional and off until it launches, so the copy doesn't promise it).

### Promotional Text

```text
One-to-ones, stand-ups, client visits: when the meeting ends, your note is ready with decisions and tasks. Add tasks to Reminders. One account for Mac and iPhone.
```

### Keywords

```text
1on1,one on one,standup,team,manager,action items,tasks,follow up,client,decisions,meeting notes
```

### Screenshots (order)

| # | Raw | Headline (≤ 30) | Subhead (≤ 60) |
|---|-----|-----------------|----------------|
| 1 | tasks (existing) | Never drop a follow-up | Your tasks from every meeting, in one list. |
| 2 | note (existing) | Decisions, written down | Summary, decisions and tasks, ready when it ends. |
| 3 | upcoming meetings (new raw: `--ornek-takvim`) | Walk in prepared | A briefing on past meetings with the same people. |
| 4 | ask (existing) | Ask your meetings | Plain-language answers that cite the meeting. |
| 5 | record (existing) | One tap to start | Put your iPhone on the table and press record. |

Templates to show: **One-on-one** and **Client meeting**. Header: the main header ("Your meetings, already written
up.") works as is.

**Apple Ads:** an ad group with `1on1 notes`, `one on one meeting`, `meeting tasks`, `action items`, `meeting minutes`
(exact match). Send brand searches (`gistsmith`) to the default page, not to a CPP.

---

## Measuring

- Analytics › Acquisition › Custom Product Pages: compare each page's **conversion rate** with the default page's
  over at least 2 weeks, or until each page has a few hundred impressions.
- Keep the page that converts best for each audience. Fold its winning first screenshot into a Product Page
  Optimization test on the default page (see `after-approval-checklist.md`).
