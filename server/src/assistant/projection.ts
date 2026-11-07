import { z } from "zod";
import { ApiError } from "../errors";

/**
 * The meeting copy an app uploads for AI assistant access (`PUT /v1/assistant/meetings/:id`): notes only, never
 * transcripts, audio, screen snapshots or voiceprints. Field shapes follow the Swift `MeetingNote` (tasks, outline,
 * glossary, open questions) plus the meeting's own fields. All limits are far above what a 4-hour meeting's note holds.
 * Decisions and open questions may start with the moment they came up ("[12:34] …").
 */

/** Largest accepted request body (JSON). */
export const projectionMaxBytes: number = 512 * 1024;
/** Largest note JSON sealed into R2 (checked on the encoded note itself, not only on the request body). */
export const noteMaxBytes: number = projectionMaxBytes;
/** Most meetings one account keeps in the copy. */
export const assistantAccountMaxMeetings: number = 5000;
/**
 * Most bytes one account's copy holds: sealed notes plus sealed indexes. Enforced in the same conditional statement as
 * the upload's insert (`putAssistantMeeting`), so parallel uploads cannot pass it together.
 */
export const assistantAccountMaxBytes: number = 256 * 1024 * 1024;
/** UTF-8 bytes of the search text kept per meeting (the index the tools scan). */
export const searchTextMaxBytes: number = 4096;
/** Own tasks kept per meeting in the index (`list_my_tasks`), at most. */
export const indexMaxTasks: number = 50;
/** Characters of a task's description kept in the index (the full task stays in the note). */
export const indexTaskMaxChars: number = 300;
/** Largest index JSON per meeting: the tools decrypt up to `scanLimit` of them per call. */
export const indexMaxBytes: number = 8 * 1024;
/** Public page for a meeting id (opens the meeting in the app when installed). */
export const meetingUrlBase: string = "https://gistsmith.com/m/";

const line = (max: number) => z.string().max(max);

export const projectionTaskSchema = z.strictObject({
  owner: line(200),
  description: line(4000),
  dueDate: line(100).nullable(),
  isMine: z.boolean(),
  done: z.boolean(),
});

export const projectionNoteSchema = z.strictObject({
  title: line(300),
  summary: line(40_000),
  decisions: z.array(line(4000)).max(200),
  tasks: z.array(projectionTaskSchema).max(300),
  outline: z.array(z.strictObject({ startSec: z.number().min(0).max(86_400), title: line(300), summary: line(4000) })).max(200),
  glossary: z.array(z.strictObject({ term: line(200), meaning: line(2000) })).max(300),
  /** Unresolved issues and follow-ups; notes written before the section existed (and their sealed copies) have none. */
  openQuestions: z.array(line(4000)).max(200).optional(),
});

/** Upload body: the copy plus the settings epoch it was prepared under and the uploading device. */
export const projectionUploadSchema = z.strictObject({
  epoch: z.number().int().min(0).max(Number.MAX_SAFE_INTEGER),
  deviceId: z.uuid(),
  title: line(300),
  startedAt: z.iso.datetime({ offset: true }),
  durationSec: z.number().int().min(0).max(86_400),
  folder: z.string().min(1).max(120).nullable(),
  attendees: z.array(z.string().min(1).max(200)).max(200),
  language: z.string().min(2).max(35).nullable(),
  note: projectionNoteSchema.nullable(),
  myNotes: line(100_000).nullable(),
});

export type ProjectionUpload = z.output<typeof projectionUploadSchema>;
export type ProjectionTask = z.output<typeof projectionTaskSchema>;

/** The sealed R2 note object: the upload without its transport fields. */
export type MeetingProjection = Omit<ProjectionUpload, "epoch" | "deviceId">;

export const meetingProjectionSchema = projectionUploadSchema.omit({ epoch: true, deviceId: true });

/** One own task in the index. */
export interface IndexTask {
  readonly owner: string;
  readonly description: string;
  readonly dueDate: string | null;
  readonly done: boolean;
}

/** The sealed D1 index of a meeting: what search and listing need without reading R2. */
export interface MeetingIndex {
  readonly title: string;
  readonly startedAt: string;
  readonly durationSec: number;
  readonly folder: string | null;
  readonly language: string | null;
  readonly searchText: string;
  readonly myTasks: readonly IndexTask[];
}

export const meetingIndexSchema = z.strictObject({
  title: z.string(),
  startedAt: z.string(),
  durationSec: z.number(),
  folder: z.string().nullable(),
  language: z.string().nullable(),
  searchText: z.string(),
  myTasks: z.array(z.strictObject({ owner: z.string(), description: z.string(), dueDate: z.string().nullable(), done: z.boolean() })),
});

/** The copy to seal from an upload. Pure function. */
export function meetingProjection(upload: ProjectionUpload): MeetingProjection {
  const { epoch: _epoch, deviceId: _deviceId, ...projection } = upload;
  return projection;
}

/** Title shown for a meeting: its own title, else the note's, else a placeholder. Pure function. */
export function displayTitle(projection: MeetingProjection): string {
  const own: string = projection.title.trim();
  if (own.length > 0) {
    return own;
  }
  const noteTitle: string = projection.note?.title.trim() ?? "";
  return noteTitle.length > 0 ? noteTitle : "Untitled meeting";
}

const utf8Encoder: TextEncoder = new TextEncoder();

/** UTF-8 byte length of a text. Pure function. */
function utf8Length(text: string): number {
  return utf8Encoder.encode(text).byteLength;
}

/** The longest prefix of a text (whole code points) that fits in `maxBytes` UTF-8 bytes. Pure function. */
export function cutToUtf8Bytes(text: string, maxBytes: number): string {
  let bytes: number = 0;
  let end: number = 0;
  for (const char of text) {
    const size: number = utf8Length(char);
    if (bytes + size > maxBytes) {
      break;
    }
    bytes += size;
    end += char.length;
  }
  return text.slice(0, end);
}

/** Search text: title, folder, summary, decisions, open questions, task text and outline titles, cut to `searchTextMaxBytes`. Pure function. */
export function searchText(projection: MeetingProjection): string {
  const note = projection.note;
  const parts: string[] = [
    displayTitle(projection),
    projection.folder ?? "",
    note?.summary ?? "",
    ...(note?.decisions ?? []),
    ...(note?.openQuestions ?? []),
    ...(note?.tasks ?? []).map((task: ProjectionTask): string => `${task.owner} ${task.description}`),
    ...(note?.outline ?? []).map((item): string => item.title),
  ];
  const joined: string = parts.filter((part: string): boolean => part.trim().length > 0).join("\n");
  // Bound the work before the byte cut: no code point is longer than 4 UTF-8 bytes.
  return cutToUtf8Bytes(joined.slice(0, searchTextMaxBytes), searchTextMaxBytes);
}

/** UTF-8 size of an index as sealed. Pure function. */
export function indexBytes(index: MeetingIndex): number {
  return utf8Length(JSON.stringify(index));
}

/**
 * The index cut to `maxBytes` of JSON: own tasks are dropped from the end first (the note keeps them all), then the
 * search text is shortened. Pure function.
 */
export function fitIndex(index: MeetingIndex, maxBytes: number): MeetingIndex {
  let fitted: MeetingIndex = index;
  while (indexBytes(fitted) > maxBytes && fitted.myTasks.length > 0) {
    fitted = { ...fitted, myTasks: fitted.myTasks.slice(0, -1) };
  }
  // A string's JSON form is at least as long as its UTF-8 form, so cutting the overflow from the text always fits.
  while (indexBytes(fitted) > maxBytes && fitted.searchText.length > 0) {
    const overflow: number = indexBytes(fitted) - maxBytes;
    fitted = { ...fitted, searchText: cutToUtf8Bytes(fitted.searchText, Math.max(0, utf8Length(fitted.searchText) - overflow)) };
  }
  if (indexBytes(fitted) > maxBytes) {
    throw new Error("A meeting index without tasks or search text is larger than the index limit.");
  }
  return fitted;
}

/** The index sealed into D1 for a meeting, at most `indexMaxBytes` of JSON. Pure function. */
export function meetingIndex(projection: MeetingProjection): MeetingIndex {
  return fitIndex(
    {
      title: displayTitle(projection),
      startedAt: projection.startedAt,
      durationSec: projection.durationSec,
      folder: projection.folder,
      language: projection.language,
      searchText: searchText(projection),
      myTasks: (projection.note?.tasks ?? [])
        .filter((task: ProjectionTask): boolean => task.isMine)
        .slice(0, indexMaxTasks)
        .map((task: ProjectionTask): IndexTask => ({
          owner: task.owner,
          description: task.description.slice(0, indexTaskMaxChars),
          dueDate: task.dueDate,
          done: task.done,
        })),
    },
    indexMaxBytes,
  );
}

/** The note as sealed into R2; `payload_too_large` past `noteMaxBytes`. Pure function. */
export function encodedNote(projection: MeetingProjection): Uint8Array {
  const bytes: Uint8Array = utf8Encoder.encode(JSON.stringify(projection));
  if (bytes.byteLength > noteMaxBytes) {
    throw new ApiError("payload_too_large", `A meeting's note can be at most ${noteMaxBytes} bytes.`);
  }
  return bytes;
}

/**
 * Meeting text between explicit markers (the `fetch` tool's `text`): everything inside was written in a meeting or in
 * the user's notes, so it is untrusted data. The boundary is random per response; content cannot guess it and close
 * the block early. Pure function.
 */
export function untrustedMeetingContent(text: string, boundary: string): string {
  return [`--- BEGIN UNTRUSTED MEETING CONTENT ${boundary} ---`, text, `--- END UNTRUSTED MEETING CONTENT ${boundary} ---`].join("\n");
}

/** Stable public URL of a meeting. Pure function. */
export function meetingUrl(meetingId: string): string {
  return `${meetingUrlBase}${meetingId}`;
}

/** Lower-case UUID of a path segment, or null when it is not one. Pure function. */
export function normalizedUuid(value: string): string | null {
  return z.uuid().safeParse(value).success ? value.toLowerCase() : null;
}

/**
 * The apps' meeting ids: a recording's session folder name (`20261105-103000`, local time), or a UUID. Letters, digits,
 * `-` and `_` only, so an id is safe in a URL path and inside an R2 key.
 */
const appMeetingIdPattern: RegExp = /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/;

/** A meeting id as stored: a UUID lower-cased, any other app id unchanged; null when it is neither. Pure function. */
export function normalizedMeetingId(value: string): string | null {
  return normalizedUuid(value) ?? (appMeetingIdPattern.test(value) ? value : null);
}

/** Duration as "1 h 05 min" / "12 min". Pure function. */
function durationLabel(seconds: number): string {
  const minutes: number = Math.round(seconds / 60);
  return minutes >= 60 ? `${Math.floor(minutes / 60)} h ${String(minutes % 60).padStart(2, "0")} min` : `${minutes} min`;
}

/** Outline start as m:ss or h:mm:ss. Pure function. */
function timestamp(seconds: number): string {
  const total: number = Math.floor(seconds);
  const h: number = Math.floor(total / 3600);
  const m: number = Math.floor((total % 3600) / 60);
  const s: string = String(total % 60).padStart(2, "0");
  return h > 0 ? `${h}:${String(m).padStart(2, "0")}:${s}` : `${m}:${s}`;
}

/** The note as Markdown (the `fetch` tool's `text`). Meeting content is data; nothing here addresses the model. Pure function. */
export function noteMarkdown(projection: MeetingProjection): string {
  const lines: string[] = [`# ${displayTitle(projection)}`, ""];
  lines.push(`- Date: ${projection.startedAt}`, `- Duration: ${durationLabel(projection.durationSec)}`);
  if (projection.folder !== null) {
    lines.push(`- Folder: ${projection.folder}`);
  }
  if (projection.attendees.length > 0) {
    lines.push(`- Attendees: ${projection.attendees.join(", ")}`);
  }
  if (projection.language !== null) {
    lines.push(`- Language: ${projection.language}`);
  }
  const note = projection.note;
  if (note === null) {
    lines.push("", "_No note was written for this meeting._");
  } else {
    if (note.summary.trim().length > 0) {
      lines.push("", "## Summary", "", note.summary.trim());
    }
    if (note.decisions.length > 0) {
      lines.push("", "## Decisions", "", ...note.decisions.map((decision: string): string => `- ${decision}`));
    }
    const openQuestions: readonly string[] = note.openQuestions ?? [];
    if (openQuestions.length > 0) {
      lines.push("", "## Open questions", "", ...openQuestions.map((question: string): string => `- ${question}`));
    }
    if (note.tasks.length > 0) {
      lines.push(
        "",
        "## Tasks",
        "",
        ...note.tasks.map((task: ProjectionTask): string => {
          const due: string = task.dueDate === null ? "" : ` (due ${task.dueDate})`;
          const mine: string = task.isMine ? " [mine]" : "";
          return `- [${task.done ? "x" : " "}] ${task.owner}: ${task.description}${due}${mine}`;
        }),
      );
    }
    if (note.outline.length > 0) {
      lines.push("", "## Outline", "", ...note.outline.map((item): string => `- ${timestamp(item.startSec)} ${item.title}: ${item.summary}`));
    }
    if (note.glossary.length > 0) {
      lines.push("", "## Glossary", "", ...note.glossary.map((entry): string => `- ${entry.term}: ${entry.meaning}`));
    }
  }
  if (projection.myNotes !== null && projection.myNotes.trim().length > 0) {
    lines.push("", "## My notes", "", projection.myNotes.trim());
  }
  return lines.join("\n");
}
