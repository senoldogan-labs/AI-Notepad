// Yönetim paneli görünümlerinin (src/client/admin-*.ts) veri yüklemesi: durum ve saf geçişler, ve onları bir getirme ve
// bir çizim işlevine bağlayan `createViewLoader`. Her yükleme bir sıra numarası alır; yalnızca en son başlayan
// yüklemenin sonucu durumu değiştirir ve çizilir. DOM'a dokunmaz (scripts/admin-load.test.ts sınar).

/**
 * Görünümün yükleme durumu: hiç yüklenmedi, yükleniyor, yüklendi ya da son yükleme başarısız oldu. `seq` en son
 * başlayan yüklemenin numarasıdır (hiç başlamadıysa 0).
 */
export type LoadState =
  | { readonly kind: "idle"; readonly seq: number }
  | { readonly kind: "loading"; readonly seq: number }
  | { readonly kind: "loaded"; readonly seq: number }
  | { readonly kind: "failed"; readonly seq: number };

/** Görünüm ilk açıldığında ne yapılır: yüklemeyi başlat, süren yüklemeyi bekle ya da hiçbir şey. */
export type EnsureStep = "start" | "join" | "none";

/** Yüklemenin sonucu. */
export type LoadOutcome = "loaded" | "failed";

/** Henüz yüklenmemiş görünüm. */
export const initialLoadState: LoadState = { kind: "idle", seq: 0 };

/** Yeni bir yükleme başlar (yenileme de, ilk yükleme de): öncekinin sonucu artık durumu değiştirmez. Saf fonksiyondur. */
export function startingLoad(state: LoadState): LoadState {
  return { kind: "loading", seq: state.seq + 1 };
}

/** `seq` numaralı yükleme hâlâ en son başlayan ve süren yükleme mi. Saf fonksiyondur. */
export function isCurrentLoad(state: LoadState, seq: number): boolean {
  return state.kind === "loading" && state.seq === seq;
}

/**
 * `seq` numaralı yükleme bitti: en son başlayan yüklemeyse durum sonuca geçer, değilse (yerine yenisi başladıysa)
 * durum değişmez; eski yanıt yenisini ezmez. Saf fonksiyondur.
 */
export function finishingLoad(state: LoadState, seq: number, outcome: LoadOutcome): LoadState {
  return isCurrentLoad(state, seq) ? { kind: outcome, seq } : state;
}

/**
 * Görünüm açılınca: hiç yüklenmediyse ya da son yükleme başarısızsa yükle; yükleme sürüyorsa aynı isteği yeniden
 * gönderme, onu bekle; yüklendiyse bir şey yapma. Saf fonksiyondur.
 */
export function ensureStep(state: LoadState): EnsureStep {
  switch (state.kind) {
    case "idle":
    case "failed":
      return "start";
    case "loading":
      return "join";
    case "loaded":
      return "none";
  }
}

/** Görünümün yükleme uçları (admin.ts `Loadable`). */
export interface ViewLoader {
  /** Görünüm açılınca: yüklenmediyse yükler, yükleme sürüyorsa onu bekler, yüklendiyse hemen döner. */
  readonly ensureLoaded: () => Promise<void>;
  /** Yeniden yükler; sürmekte olan eski yüklemenin yanıtı artık çizilmez. */
  readonly refresh: () => Promise<void>;
}

/** Getirmenin sonucu: veri ya da hata (hata, yüklemenin hâlâ güncel olduğu anlaşılınca yeniden fırlatılır). */
type Fetched<T> = { readonly kind: "data"; readonly data: T } | { readonly kind: "error"; readonly error: unknown };

/**
 * `fetchData` ile getirip `render` ile çizen yükleyici. Yalnızca en son başlayan yüklemenin yanıtı çizilir; yerine
 * yenisi başlamış bir yüklemeyi bekleyen, yenisinin bitmesini bekler. Hata çağırana fırlatılır ve durum `failed` olur:
 * görünüm bir sonraki açılışta yeniden yüklenir.
 */
export function createViewLoader<T>(fetchData: () => Promise<T>, render: (data: T) => void): ViewLoader {
  const current: { state: LoadState; latest: Promise<void> } = { state: initialLoadState, latest: Promise.resolve() };

  const run = async (seq: number): Promise<void> => {
    const fetched: Fetched<T> = await fetchData().then(
      (data: T): Fetched<T> => ({ kind: "data", data }),
      (error: unknown): Fetched<T> => ({ kind: "error", error }),
    );
    if (!isCurrentLoad(current.state, seq)) {
      // Yerine yeni bir yükleme başladı: bu yanıt eskidir, çizilmez; çağıran yenisinin sonucunu alır.
      await current.latest;
      return;
    }
    if (fetched.kind === "error") {
      current.state = finishingLoad(current.state, seq, "failed");
      throw fetched.error;
    }
    try {
      render(fetched.data);
    } catch (error: unknown) {
      current.state = finishingLoad(current.state, seq, "failed");
      throw error;
    }
    current.state = finishingLoad(current.state, seq, "loaded");
  };

  const refresh = (): Promise<void> => {
    current.state = startingLoad(current.state);
    current.latest = run(current.state.seq);
    return current.latest;
  };

  return {
    refresh,
    ensureLoaded: (): Promise<void> => {
      switch (ensureStep(current.state)) {
        case "start":
          return refresh();
        case "join":
          return current.latest;
        case "none":
          return Promise.resolve();
      }
    },
  };
}
