/**
 * Toplantı oturumunun (`meeting_sessions`) yaşam döngüsü: tek kaynak. Evre saklanmaz, satırdan ve andan türetilir;
 * TS kararları (`meetingPhase`, `meetingTransition`) ve SQL koşulları (`…Sql`) aynı tablolardan üretilir. Durum
 * değiştiren her UPDATE kaynak evrenin koşulunu (`meetingTransitionSql`) taşır ve değişen satır sayısına bakar; göç 0057
 * tetikleyicileri geri dönüşsüz geçişleri veritabanında da zorlar.
 *
 * Evreler (`meetingPhase`):
 * - `recording`: bitmemiş, en çok bitişi (`max_ends_at`) gelmemiş, duraklatılmamış.
 * - `paused`: bitmemiş, en çok bitişi gelmemiş, süren duraklatması var (`paused_at`; bkz. `meetingPause.ts`).
 * - `expired`: bitmemiş ama en çok bitişi geçmiş. Veritabanına yazılmaz: bitiş en çok `max_ends_at` sayılır, satır
 *   `endMeeting` ya da yeni toplantıyla kapanır.
 * - `ended`: `ended_at` dolu (kullanıcı bitirdi: `end_reason='ended'`, yeni toplantıyla kapandı: `superseded`;
 *   sonradan işlenen kayıt `deferred=1` bitmiş olarak eklenir). Son evredir: bitiş anı bir daha değişmez.
 *
 * `recording` ve `paused` canlıdır (`isMeetingLive`); `expired` ve `ended` kaydı bitmiş toplantılardır. Bitişten sonraki
 * kullanım pencereleri (canlı çağrılar için ek süre, kaydın işlenmesi, yeniden işleme açıklığı) evreden bağımsız
 * zaman sınırlarıdır (`meetingOpenUntil`).
 *
 * Geçişler (`meetingTransitions`): olay → uygulandığı kaynak evreler; zaten hedef evrede olan toplantıda olay bir şey
 * değiştirmez (`noop`), diğer evrelerde reddedilir (`refuse`).
 */

import type { Config } from "./config";

/** Yaşam döngüsünün okuduğu sütunlar (`MeetingRow`'un parçası). */
export interface MeetingLifecycleColumns {
  readonly started_at: number;
  readonly max_ends_at: number;
  readonly ended_at: number | null;
  readonly end_reason: "ended" | "superseded" | null;
  readonly deferred: number;
  readonly paused_at: number | null;
  readonly reprocess_until: number | null;
  readonly transcription_closed: number;
}

/** Evreyi belirleyen sütunlar. */
export type MeetingPhaseColumns = Pick<MeetingLifecycleColumns, "max_ends_at" | "ended_at" | "deferred" | "paused_at">;

/** Toplantının evresi (bkz. modül belgesi). */
export type MeetingPhase = "recording" | "paused" | "expired" | "ended";

/** Toplantıyı değiştiren olaylar. */
export type MeetingEvent = "pause" | "resume" | "closePauseForAudio" | "end" | "supersede" | "reprocess" | "liveGrant";

/** Olayın bir evredeki sonucu. */
export type MeetingTransition = "apply" | "noop" | "refuse";

/** Olayın kaynak (uygulandığı) ve zaten-sonuçlanmış (bir şey değiştirmediği) evreleri. */
interface TransitionRule {
  readonly from: readonly MeetingPhase[];
  readonly noop: readonly MeetingPhase[];
}

/**
 * Geçiş tablosu.
 * - `pause`: yalnızca kaydı süren toplantı; duraklatılmış toplantıda değişmez.
 * - `resume` ve `closePauseForAudio` (duraklatmada ses yazıya dökülüyor): yalnızca duraklatılmış toplantı; süresi geçmiş
 *   ya da bitmiş toplantının açık duraklatması bitişte kapanır (`endMeetingSetSql`).
 * - `end`, `supersede`: bitmemiş her toplantı (süresi geçmiş olan da: bitiş en çok `max_ends_at` yazılır).
 * - `reprocess`: yalnızca kaydı bitmiş toplantı (canlı toplantının bütçesi ve ses hakkı yeniden yazılmaz).
 * - `liveGrant` (Deepgram jetonu): yalnızca canlı toplantı.
 */
export const meetingTransitions: Readonly<Record<MeetingEvent, TransitionRule>> = {
  pause: { from: ["recording"], noop: ["paused"] },
  resume: { from: ["paused"], noop: ["recording", "expired", "ended"] },
  closePauseForAudio: { from: ["paused"], noop: ["recording", "expired", "ended"] },
  end: { from: ["recording", "paused", "expired"], noop: ["ended"] },
  supersede: { from: ["recording", "paused", "expired"], noop: ["ended"] },
  reprocess: { from: ["expired", "ended"], noop: [] },
  liveGrant: { from: ["recording", "paused"], noop: [] },
};

/** Satır yaşam döngüsünün izin vermediği bir bileşim taşıyor (kod ya da göç hatası; tetikleyiciler bunu engeller). */
export class MeetingStateError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "MeetingStateError";
  }
}

/**
 * Toplantının `nowMs` anındaki evresi. Çelişkili satırda (bitmiş ama duraklatması açık; sonradan işlenen ama bitmemiş)
 * `MeetingStateError` fırlatır. Saf fonksiyondur (`meetingPhaseSql`'in eşi).
 */
export function meetingPhase(row: MeetingPhaseColumns, nowMs: number): MeetingPhase {
  if (row.ended_at !== null) {
    if (row.paused_at !== null) {
      throw new MeetingStateError("An ended meeting still has an open pause.");
    }
    return "ended";
  }
  if (row.deferred === 1) {
    throw new MeetingStateError("A deferred meeting has no end.");
  }
  if (nowMs >= row.max_ends_at) {
    return "expired";
  }
  return row.paused_at === null ? "recording" : "paused";
}

/** `meetingPhase`'in SQL eşi (çelişki denetimi yok: tetikleyiciler zorlar); `p` tablo öneki, `now` şimdinin bağı (ms). */
export function meetingPhaseSql(p: string, now: string): string {
  return `(CASE WHEN ${p}ended_at IS NOT NULL THEN 'ended' WHEN ${p}max_ends_at <= ${now} THEN 'expired'
    WHEN ${p}paused_at IS NOT NULL THEN 'paused' ELSE 'recording' END)`;
}

/** Olayın evredeki sonucu. Saf fonksiyondur. */
export function meetingTransition(phase: MeetingPhase, event: MeetingEvent): MeetingTransition {
  const rule: TransitionRule = meetingTransitions[event];
  if (rule.from.includes(phase)) {
    return "apply";
  }
  return rule.noop.includes(phase) ? "noop" : "refuse";
}

/** Evre listesini SQL `IN (…)` listesine çevirir (sabit metinler). */
function phaseList(phases: readonly MeetingPhase[]): string {
  return phases.map((phase: MeetingPhase): string => `'${phase}'`).join(", ");
}

/**
 * Olayın uygulanabildiği kaynak evrelerin SQL koşulu (koşullu UPDATE'in `WHERE`'i için); `p` tablo öneki, `now` şimdinin
 * bağı (ms).
 */
export function meetingTransitionSql(event: MeetingEvent, p: string, now: string): string {
  return `(${meetingPhaseSql(p, now)} IN (${phaseList(meetingTransitions[event].from)}))`;
}

/** Toplantı canlı mı (`recording` ya da `paused`). Saf fonksiyondur. */
export function isMeetingLive(row: MeetingPhaseColumns, nowMs: number): boolean {
  const phase: MeetingPhase = meetingPhase(row, nowMs);
  return phase === "recording" || phase === "paused";
}

/** `isMeetingLive`'ın SQL eşi (dizinli sütunlarla; `meetingPhaseSql` ile aynı sınır). */
export function meetingLiveSql(p: string, now: string): string {
  return `(${p}ended_at IS NULL AND ${p}max_ends_at > ${now})`;
}

/** Bitmemiş ama süresi geçmiş toplantı (`expired`) için SQL koşulu. */
export function meetingExpiredSql(p: string, now: string): string {
  return `(${p}ended_at IS NULL AND ${p}max_ends_at <= ${now})`;
}

/** Kaydın bittiği an (ms): bitmişse bitişi, değilse en çok bitişi (ikisinden küçüğü). Saf fonksiyondur. */
export function meetingEndMs(row: Pick<MeetingLifecycleColumns, "ended_at" | "max_ends_at">): number {
  return Math.min(row.ended_at ?? row.max_ends_at, row.max_ends_at);
}

/** `meetingEndMs`'in SQL eşi. */
export function meetingEndSql(p: string): string {
  return `MIN(COALESCE(${p}ended_at, ${p}max_ends_at), ${p}max_ends_at)`;
}

/** Kaydın `nowMs` anına dek sürdüğü son an: bitiş, şimdi ve en çok bitişin küçüğü. Saf fonksiyondur. */
export function meetingElapsedEndMs(row: Pick<MeetingLifecycleColumns, "ended_at" | "max_ends_at">, nowMs: number): number {
  return Math.min(row.ended_at ?? nowMs, row.max_ends_at, nowMs);
}

/** `meetingElapsedEndMs`'in SQL eşi. */
export function meetingElapsedEndSql(p: string, now: string): string {
  return `MIN(COALESCE(${p}ended_at, ${now}), ${p}max_ends_at, ${now})`;
}

/** Toplantının açıklık pencereleri (ms): canlı kullanım ek süresi ve kayıt sonrası işleme süresi. */
export interface MeetingWindows {
  readonly graceMs: number;
  readonly processingGraceMs: number;
}

/**
 * Vekil çağrısının kullanımı: `live` kayıt sırasındaki ya da kaydın hemen ardındaki çağrılar (canlı çeviri, "Ne
 * kaçırdım?", toplantı sorusu, amacı bildirilmemiş eski istemci çağrısı), `processing` kaydın işlenmesi (son geçiş sesi,
 * not, not parçası ve birleştirmesi, konuşmacı incelemesi).
 */
export type MeetingUse = "live" | "processing";

/**
 * Toplantının vekil çağrılarına açık olduğu son an: bitiş (ya da en çok süre) + not üretimi için ek süre. Yeni toplantı
 * başlayınca kapanan (`superseded`) toplantı ek süre almaz. Saf fonksiyondur.
 */
export function meetingUsableUntil(row: MeetingLifecycleColumns, graceMs: number): number {
  const end: number = meetingEndMs(row);
  const usual: number = row.end_reason === "superseded" ? end : end + graceMs;
  // Yeniden işleme açıklığı (bkz. `reprocessMeeting`) ek süreden bağımsızdır.
  return Math.max(usual, row.reprocess_until ?? 0);
}

/**
 * Kayıt sonrası işlemenin (son geçiş ve not) toplantıda açık olduğu son an. Düzgün biten (kullanıcı bitirdi ya da en
 * çok süreye ulaştı) toplantı, bitişinden sonra `processingGraceMs` boyunca işlenebilir: iPhone arka planda askıya
 * alındığında ya da bağlantı koptuğunda işleme saatler sonra sürebilir ve kayıtlı toplantının notu kaybolmamalı. Süre
 * harcamayı artırmaz: toplantının token bütçesi, ses hakkı (`meetingAudioLimit`) ve kullanıcının günlük/aylık sınırları
 * aynıdır; yalnızca aynı bütçenin ne zamana dek kullanılabileceği uzar. Yeni toplantı başlayınca kapanan (`superseded`)
 * toplantı uzatma almaz (aynı anda tek açık bütçe kuralı; istemci yeniden işlemeyle açar). Yeniden işleme açıklığı da
 * işlemede aynı süreyle uzar (`reprocess_until` − `graceMs` yeniden işlemenin anıdır). Saf fonksiyondur.
 */
export function meetingProcessingUntil(row: MeetingLifecycleColumns, windows: MeetingWindows): number {
  const live: number = meetingUsableUntil(row, windows.graceMs);
  const ended: number = row.end_reason === "superseded" ? live : meetingEndMs(row) + windows.processingGraceMs;
  const reopened: number = row.reprocess_until === null ? 0 : row.reprocess_until - windows.graceMs + windows.processingGraceMs;
  return Math.max(live, ended, reopened);
}

/** Yapılandırmanın toplantı pencereleri. Saf fonksiyondur. */
export function meetingWindows(config: Pick<Config, "meetingGraceMs" | "meetingProcessingGraceMs">): MeetingWindows {
  return { graceMs: config.meetingGraceMs, processingGraceMs: config.meetingProcessingGraceMs };
}

/** Kullanıma göre toplantının açık olduğu son an. Saf fonksiyondur. */
export function meetingOpenUntil(row: MeetingLifecycleColumns, windows: MeetingWindows, use: MeetingUse): number {
  return use === "live" ? meetingUsableUntil(row, windows.graceMs) : meetingProcessingUntil(row, windows);
}

/** Yeniden işlemenin neden reddedildiği (hak harcanmadan); izin varsa null. */
export type ReprocessRefusal = "meeting_in_progress" | "transcription_closed";

/**
 * Yeniden işleme bu toplantıda yapılabilir mi: kaydı süren (canlı) toplantı yeniden işlenmez (bütçesi ve ses hakkı
 * yeniden yazılmaz); ses hakkı kapanmış (`transcription_closed`) toplantıda yeniden işleme sesi yine reddedileceği için
 * hak harcanmaz. Saf fonksiyondur (`reprocessAllowedSql`'in eşi).
 */
export function reprocessRefusal(row: MeetingLifecycleColumns, nowMs: number): ReprocessRefusal | null {
  if (meetingTransition(meetingPhase(row, nowMs), "reprocess") !== "apply") {
    return "meeting_in_progress";
  }
  return row.transcription_closed === 0 ? null : "transcription_closed";
}

/** `reprocessRefusal(...) === null`'ın SQL eşi. */
export function reprocessAllowedSql(p: string, now: string): string {
  return `(${meetingTransitionSql("reprocess", p, now)} AND ${p}transcription_closed = 0)`;
}
