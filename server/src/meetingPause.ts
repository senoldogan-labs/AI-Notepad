/**
 * Toplantı duraklatmaları (göç 0055). Duraklatılan süre ne toplantının süre sınırına ne aylık süreye sayılır; zaman
 * yalnızca sunucu saatiyle ölçülür (istemci aralık bildirmez, duraklattığı ve sürdürdüğü anda çağırır).
 *
 * Sütunlar: `paused_ms` kapanmış duraklatmaların sayılan toplamı; `paused_at` süren duraklatmanın başlangıcı (sürmüyorsa
 * NULL); `pause_extension_ms` `max_ends_at`'in toplantının taban bitişinin ne kadar ötesinde olduğu (duraklatma
 * sürmüyorken `paused_ms`'e eşittir); `pause_count` duraklatma sayısı.
 *
 * Taban süre B = `max_ends_at − pause_extension_ms − started_at` (başlatmada verilen en çok süre). Sayılan duraklatma
 * toplamı en çok B'dir: toplantının duvar saati süresi en çok 2B olur. Duraklatılınca `max_ends_at` kalan hak kadar
 * (B − `paused_ms`) ileri alınır: süren duraklatmada toplantının süresi dolmaz. Sürdürülünce (ya da toplantı bitince)
 * süren duraklatmanın sayılan kısmı `paused_ms`'e eklenir ve kullanılmayan uzatma geri alınır.
 *
 * Kötüye kullanıma karşı: yazıya dökülen ses her zaman sayılır (aylık süre toplantı başına kaydedilen süre ile
 * örtüşmesiz sesin büyüğüdür; toplantının ses hakkı taban süreye göredir, `meetingAudioLimit`), duraklatmada Deepgram
 * jetonu ya da ses yüklemesi duraklatmayı o anda kapatır (`closePauseStatement`) ve toplantı başına en çok
 * `maxPausesPerMeeting` duraklatma vardır. Sunucu açık Deepgram bağlantısını göremez: duraklatmadan önce açılmış
 * bağlantıdan ses akıtan değiştirilmiş istemci, son geçiş sesini yüklemezse en çok taban süre kadar canlı metni aylık
 * süreye saydırmadan alabilir (duvar saati en çok 2B; harcama Deepgram bütçesi ve günlük tavanla sınırlı).
 */

import { log } from "./log";

/** Toplantı başına en çok duraklatma. */
export const maxPausesPerMeeting: number = 100;

/** Duraklatma sütunları (`MeetingRow`'un parçası). */
export interface MeetingPauseColumns {
  readonly started_at: number;
  readonly max_ends_at: number;
  readonly ended_at: number | null;
  readonly paused_ms: number;
  readonly paused_at: number | null;
  readonly pause_extension_ms: number;
}

/**
 * Süren duraklatmanın `at` anına dek sayılan kısmı (SQL ifadesi; `p` tablo öneki, ör. `"s."` ya da `""`): duraklatma
 * başından `at`'e dek geçen, en çok kalan hak (`pause_extension_ms − paused_ms`). Duraklatma sürmüyorsa 0.
 */
export function openPauseCreditSql(p: string, at: string): string {
  return `(CASE WHEN ${p}paused_at IS NULL THEN 0 ELSE MIN(MAX(0, ${at} - ${p}paused_at), ${p}pause_extension_ms - ${p}paused_ms) END)`;
}

/** Toplantının `now` anına göre bitişi (SQL): bitmişse bitişi, değilse şimdi; en çok `max_ends_at`. */
function meetingEndAtSql(p: string, now: string): string {
  return `MIN(COALESCE(${p}ended_at, ${now}), ${p}max_ends_at, ${now})`;
}

/**
 * Toplantının `now` anına dek kaydedilen (duraklatılmamış) süresi, milisaniye (SQL ifadesi): bitişe dek geçen süreden
 * sayılan duraklatmalar (süren dahil) düşülür; negatif olmaz. Aylık süre ve yönetim istatistikleri bunu sayar.
 */
export function meetingRecordedMsSql(p: string, now: string): string {
  const end: string = meetingEndAtSql(p, now);
  return `MAX(0, ${end} - ${p}started_at - (${p}paused_ms + ${openPauseCreditSql(p, end)}))`;
}

/** Toplantının taban süresi, milisaniye (SQL ifadesi): duraklatma uzatması düşülmüş en çok süre. */
export function meetingBaseMsSql(p: string): string {
  return `(${p}max_ends_at - ${p}pause_extension_ms - ${p}started_at)`;
}

/**
 * Süren duraklatmayı `?1` anında (bitiş en çok `max_ends_at`) kapatan `SET` parçası: sayılan kısım `paused_ms`'e
 * eklenir, kullanılmayan uzatma `max_ends_at`'ten geri alınır. SQLite `SET` ifadeleri satırın eski değerlerini okur.
 * Duraklatma sürmüyorsa değerler değişmez. Bağ: `?1` = şimdi (ms).
 */
export function closePauseSetSql(): string {
  const credit: string = openPauseCreditSql("", "MIN(?1, max_ends_at)");
  return `paused_ms = paused_ms + ${credit},
    max_ends_at = max_ends_at - (pause_extension_ms - paused_ms - ${credit}),
    pause_extension_ms = paused_ms + ${credit},
    paused_at = NULL`;
}

/**
 * Toplantıyı `?1` anında bitiren `SET` parçası (kullanıcı bitirdi ya da yeni toplantı başlayınca kapandı): bitiş en
 * çok `max_ends_at`; dakika kaydedilen süredir (duraklatmalar düşülür, yukarı yuvarlanır); süren duraklatma kapanır.
 * `end_reason` çağıranındır. Bağ: `?1` = şimdi (ms).
 */
export function endMeetingSetSql(): string {
  const end: string = "MIN(?1, max_ends_at)";
  return `ended_at = ${end},
    minutes = CAST((MAX(0, ${end} - started_at - (paused_ms + ${openPauseCreditSql("", end)})) + 59999) / 60000 AS INTEGER),
    ${closePauseSetSql()}`;
}

/** Süren duraklatmanın `at` anına dek sayılan kısmı. Saf fonksiyondur (`openPauseCreditSql`'in eşi). */
export function openPauseCreditMs(row: MeetingPauseColumns, at: number): number {
  if (row.paused_at === null) {
    return 0;
  }
  return Math.min(Math.max(0, at - row.paused_at), row.pause_extension_ms - row.paused_ms);
}

/** `now` anına dek sayılan toplam duraklatma (süren dahil). Saf fonksiyondur. */
export function creditedPauseMs(row: MeetingPauseColumns, now: number): number {
  const end: number = Math.min(row.ended_at ?? now, row.max_ends_at, now);
  return row.paused_ms + openPauseCreditMs(row, end);
}

/** `now` anına dek kaydedilen süre (`meetingRecordedMsSql`'in eşi). Saf fonksiyondur. */
export function meetingRecordedMs(row: MeetingPauseColumns, now: number): number {
  const end: number = Math.min(row.ended_at ?? now, row.max_ends_at, now);
  return Math.max(0, end - row.started_at - creditedPauseMs(row, now));
}

/** Taban süre (`meetingBaseMsSql`'in eşi). Saf fonksiyondur. */
export function meetingBaseMs(row: MeetingPauseColumns): number {
  return row.max_ends_at - row.pause_extension_ms - row.started_at;
}

/** Duraklatma ve sürdürme yanıtı. */
export interface MeetingPauseState {
  readonly meetingId: string;
  readonly paused: boolean;
  /** Toplantının şimdiki en çok bitişi (ISO 8601): duraklatmada kalan hak kadar ileride. */
  readonly expiresAt: string;
  /** Sayılan duraklatma (süren dahil, şimdiye dek), tam saniye. */
  readonly pausedSeconds: number;
}

/** Satırın duraklatma durumu. Saf fonksiyondur. */
export function meetingPauseState(row: MeetingPauseColumns & { readonly id: string }, now: number): MeetingPauseState {
  return {
    meetingId: row.id,
    paused: row.paused_at !== null && row.ended_at === null,
    expiresAt: new Date(row.max_ends_at).toISOString(),
    pausedSeconds: Math.floor(creditedPauseMs(row, now) / 1000),
  };
}

/**
 * Duraklatılmış toplantı ses yazıya döküyor (Deepgram jetonu, ses yüklemesi): duraklatma şimdi kapanır, bundan sonrası
 * kaydedilen süre sayılır. Dürüst uygulama duraklatmada ses göndermez; bu, sunucunun denetimidir. Duraklatma yoksa
 * bir şey yapmaz. Güncel satırı (değişmediyse verilen satırı) döndürür.
 */
export async function endPauseForAudio<Row extends MeetingPauseColumns & { readonly id: string; readonly user_id: string }>(
  db: D1Database,
  meeting: Row,
  now: Date,
): Promise<Row> {
  if (meeting.paused_at === null || meeting.ended_at !== null) {
    return meeting;
  }
  const updated: Row | null = await db
    .prepare(`UPDATE meeting_sessions SET ${closePauseSetSql()} WHERE id = ?2 AND ended_at IS NULL AND paused_at IS NOT NULL RETURNING *`)
    .bind(now.getTime(), meeting.id)
    .first<Row>();
  log("warn", "meeting_pause_ended_by_audio", { userId: meeting.user_id, meetingId: meeting.id });
  return updated ?? meeting;
}
