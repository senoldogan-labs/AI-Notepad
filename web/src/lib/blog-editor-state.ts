// Which blog editor session and image attempt a request belongs to (src/client/admin-blog.ts). Opening a post (or a new
// one) and going back to the list start a new editor session; choosing a file and resetting the image section start a
// new image attempt. A late answer acts on the editor only if it still belongs to the session (and, for a prepared
// preview, the image attempt) shown now: an image uploaded for post A is never inserted into post B, a save or delete
// of A never takes over B's editor, and an earlier file's preview never replaces a newer one. Pure; no DOM
// (scripts/blog-editor-state.test.ts).

/** The editor session and the image attempt at the time a request started (or now). */
export interface BlogWorkOwner {
  readonly session: number;
  readonly imageAttempt: number;
}

/** What a request's answer may act on. */
export type BlogWorkScope = "session" | "image";

/** Whether an answer for work started under `started` may act on the editor shown under `current`. Pure function. */
export function ownsBlogWork(current: BlogWorkOwner, started: BlogWorkOwner, scope: BlogWorkScope): boolean {
  return current.session === started.session && (scope === "session" || current.imageAttempt === started.imageAttempt);
}
