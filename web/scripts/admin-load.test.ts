// Yönetim paneli görünümlerinin yükleme durumu (src/lib/admin-load.ts): ilk yükleme sürerken görünüme dönmek isteği
// yeniden göndermez, eski yanıt yenisini ezmez, başarısız yükleme sonraki açılışta yeniden denenir. Derleme gerektirmez.
import { strict as assert } from "node:assert";
import { test } from "node:test";
import { type LoadState, createViewLoader, ensureStep, finishingLoad, initialLoadState, isCurrentLoad, startingLoad } from "../src/lib/admin-load.ts";

/** Elle çözülen getirme: her çağrı sıraya bir istek ekler, test istediği sırayla yanıtlar. */
interface PendingFetch {
  readonly resolve: (value: string) => void;
  readonly reject: (error: Error) => void;
}

function manualFetch(): { readonly fetch: () => Promise<string>; readonly calls: PendingFetch[] } {
  const calls: PendingFetch[] = [];
  const fetch = (): Promise<string> =>
    new Promise<string>((resolve: (value: string) => void, reject: (error: Error) => void): void => {
      calls.push({ resolve, reject });
    });
  return { fetch, calls };
}

function call(calls: readonly PendingFetch[], index: number): PendingFetch {
  const pending: PendingFetch | undefined = calls[index];
  assert.ok(pending !== undefined, `fetch call ${index} was not made`);
  return pending;
}

test("a newer load supersedes an older one and only its outcome changes the state", () => {
  const first: LoadState = startingLoad(initialLoadState);
  const second: LoadState = startingLoad(first);
  assert.equal(isCurrentLoad(second, first.seq), false);
  assert.deepEqual(finishingLoad(second, first.seq, "loaded"), second);
  assert.deepEqual(finishingLoad(second, second.seq, "failed"), { kind: "failed", seq: second.seq });
  assert.deepEqual(finishingLoad(finishingLoad(second, second.seq, "loaded"), second.seq, "failed"), { kind: "loaded", seq: second.seq });
});

test("opening a view starts, joins or skips the load by state", () => {
  assert.equal(ensureStep(initialLoadState), "start");
  const loading: LoadState = startingLoad(initialLoadState);
  assert.equal(ensureStep(loading), "join");
  assert.equal(ensureStep(finishingLoad(loading, loading.seq, "loaded")), "none");
  assert.equal(ensureStep(finishingLoad(loading, loading.seq, "failed")), "start");
});

test("switching back to a view while its first load runs sends no second request", async () => {
  const { fetch, calls } = manualFetch();
  const rendered: string[] = [];
  const loader = createViewLoader(fetch, (data: string): void => {
    rendered.push(data);
  });
  const opened: Promise<void> = loader.ensureLoaded();
  const reopened: Promise<void> = loader.ensureLoaded();
  assert.equal(calls.length, 1);
  call(calls, 0).resolve("a");
  await Promise.all([opened, reopened]);
  await loader.ensureLoaded();
  assert.equal(calls.length, 1);
  assert.deepEqual(rendered, ["a"]);
});

test("a late answer from an older load does not overwrite a newer refresh", async () => {
  const { fetch, calls } = manualFetch();
  const rendered: string[] = [];
  const loader = createViewLoader(fetch, (data: string): void => {
    rendered.push(data);
  });
  const opened: Promise<void> = loader.ensureLoaded();
  const refreshed: Promise<void> = loader.refresh();
  call(calls, 1).resolve("new");
  await refreshed;
  call(calls, 0).resolve("old");
  await opened;
  assert.deepEqual(rendered, ["new"]);
});

test("a caller of a superseded load waits for the newer load", async () => {
  const { fetch, calls } = manualFetch();
  const rendered: string[] = [];
  const loader = createViewLoader(fetch, (data: string): void => {
    rendered.push(data);
  });
  const opened: Promise<void> = loader.ensureLoaded();
  const refreshed: Promise<void> = loader.refresh();
  call(calls, 0).resolve("old");
  const order: string[] = [];
  const settledOpen: Promise<void> = opened.then((): void => {
    order.push(`opened after ${rendered.join(",")}`);
  });
  call(calls, 1).resolve("new");
  await Promise.all([settledOpen, refreshed]);
  assert.deepEqual(order, ["opened after new"]);
});

test("a failed load reports its error and is retried on the next open", async () => {
  const { fetch, calls } = manualFetch();
  const rendered: string[] = [];
  const loader = createViewLoader(fetch, (data: string): void => {
    rendered.push(data);
  });
  const opened: Promise<void> = loader.ensureLoaded();
  call(calls, 0).reject(new Error("offline"));
  await assert.rejects(opened, /offline/);
  const retried: Promise<void> = loader.ensureLoaded();
  assert.equal(calls.length, 2);
  call(calls, 1).resolve("b");
  await retried;
  assert.deepEqual(rendered, ["b"]);
});

test("a stale failure does not mark a newer successful load as failed", async () => {
  const { fetch, calls } = manualFetch();
  const loader = createViewLoader(fetch, (): void => {});
  const opened: Promise<void> = loader.ensureLoaded();
  const refreshed: Promise<void> = loader.refresh();
  call(calls, 1).resolve("new");
  await refreshed;
  call(calls, 0).reject(new Error("old request failed"));
  await opened;
  await loader.ensureLoaded();
  assert.equal(calls.length, 2);
});
