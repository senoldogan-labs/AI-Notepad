// Bildirim kutusundaki çökme raporunun okunur hâli: JSON'u girintili yazar ve MetricKit yükü
// (`MXDiagnosticPayload.jsonRepresentation()` ya da tek teşhis) ise tek satırlık özet çıkarır (tür, donma süresi ya da
// istisna/sinyal, uygulama sürümü, sistem, cihaz). Biçim tanınmazsa özet yoktur, yalnızca JSON gösterilir.
// İstisna ve sinyal adları sunucudaki imzayla aynıdır (server/src/reports.ts).
import type { JsonObject, JsonValue } from "./api";
import { fill } from "./copy";

/** Çökme raporunun ayrıştırılmış hâli: gösterilecek metin ve (JSON ise) değeri. */
export interface ParsedPayload {
  /** JSON ise iki boşluk girintili, değilse olduğu gibi. */
  readonly pretty: string;
  readonly json: JsonValue | null;
}

/** Teşhisin türü. */
export type DiagnosticKind = "crash" | "hang";

/** MetricKit teşhisinin özet alanları; olmayan alan null. */
export interface DiagnosticSummary {
  readonly kind: DiagnosticKind;
  readonly appVersion: string | null;
  readonly appBuild: string | null;
  readonly os: string | null;
  readonly device: string | null;
  readonly hangDuration: string | null;
  readonly exceptionType: number | null;
  readonly signal: number | null;
  readonly exceptionName: string | null;
}

/** Özet satırının metinleri: türler ve `{count}` ek teşhis sayısı. */
export interface DiagnosticSummaryLabels {
  readonly kinds: { readonly crash: string; readonly hang: string };
  readonly more: string;
}

/** Mach istisna türleri (`mach/exception_types.h`). */
const machExceptionNames: Readonly<Record<number, string>> = {
  1: "EXC_BAD_ACCESS",
  2: "EXC_BAD_INSTRUCTION",
  3: "EXC_ARITHMETIC",
  4: "EXC_EMULATION",
  5: "EXC_SOFTWARE",
  6: "EXC_BREAKPOINT",
  10: "EXC_CRASH",
  11: "EXC_RESOURCE",
  12: "EXC_GUARD",
};

/** POSIX sinyalleri (Darwin numaraları). */
const signalNames: Readonly<Record<number, string>> = {
  4: "SIGILL",
  5: "SIGTRAP",
  6: "SIGABRT",
  8: "SIGFPE",
  9: "SIGKILL",
  10: "SIGBUS",
  11: "SIGSEGV",
  13: "SIGPIPE",
  15: "SIGTERM",
};

/** Çökme raporunu ayrıştırır; JSON değilse metin olduğu gibi kalır ve uyarı konsola yazılır. */
export function parsePayload(payload: string): ParsedPayload {
  try {
    // `JSON.parse` yalnızca JSON değerleri üretir; tür bu yüzden daraltılmadan verilir.
    const json: JsonValue = JSON.parse(payload) as JsonValue;
    return { pretty: JSON.stringify(json, null, 2), json };
  } catch (error: unknown) {
    console.warn("crash_payload_not_json", { error: error instanceof Error ? error.message : String(error) });
    return { pretty: payload, json: null };
  }
}

/** Değer JSON nesnesiyse onu, değilse null. Saf fonksiyondur. */
function asObject(value: JsonValue | undefined): JsonObject | null {
  return typeof value === "object" && value !== null && !Array.isArray(value) ? value : null;
}

/** Boş olmayan metin alanı; yoksa ya da metin değilse null. Saf fonksiyondur. */
function textField(object: JsonObject, key: string): string | null {
  const value: JsonValue | undefined = object[key];
  return typeof value === "string" && value.trim() !== "" ? value.trim() : null;
}

/** Tam sayı alanı; yoksa ya da tam sayı değilse null. Saf fonksiyondur. */
function integerField(object: JsonObject, key: string): number | null {
  const value: JsonValue | undefined = object[key];
  return typeof value === "number" && Number.isInteger(value) ? value : null;
}

/** Metin ya da sayı olarak gelebilen alan (MetricKit sürümleri `hangDuration`'ı farklı yazar). Saf fonksiyondur. */
function looseTextField(object: JsonObject, key: string): string | null {
  const value: JsonValue | undefined = object[key];
  return typeof value === "number" && Number.isFinite(value) ? String(value) : textField(object, key);
}

/** Tek teşhisin özeti; `diagnosticMetaData` yoksa null. Saf fonksiyondur. */
function diagnosticSummary(value: JsonValue | undefined, kind: DiagnosticKind): DiagnosticSummary | null {
  const meta: JsonObject | null = asObject(asObject(value)?.["diagnosticMetaData"]);
  if (meta === null) {
    return null;
  }
  const reason: JsonObject | null = asObject(meta["exceptionReason"]);
  return {
    kind,
    appVersion: textField(meta, "appVersion"),
    appBuild: textField(meta, "appBuildVersion"),
    os: textField(meta, "osVersion"),
    device: textField(meta, "deviceType"),
    hangDuration: looseTextField(meta, "hangDuration"),
    exceptionType: integerField(meta, "exceptionType"),
    signal: integerField(meta, "signal"),
    exceptionName: reason === null ? null : (textField(reason, "exceptionName") ?? textField(reason, "className")),
  };
}

/** Dizi alanındaki teşhislerin özetleri; alan dizi değilse boş. Saf fonksiyondur. */
function diagnosticList(object: JsonObject, key: string, kind: DiagnosticKind): readonly DiagnosticSummary[] {
  const value: JsonValue | undefined = object[key];
  if (!Array.isArray(value)) {
    return [];
  }
  return value
    .map((item: JsonValue): DiagnosticSummary | null => diagnosticSummary(item, kind))
    .filter((item: DiagnosticSummary | null): item is DiagnosticSummary => item !== null);
}

/**
 * MetricKit yükünün teşhisleri: önce çökmeler, sonra donmalar. Yük tek bir teşhisse (`diagnosticMetaData`) donma
 * süresi varsa donma, yoksa çökme sayılır. Biçim tanınmazsa boş. Saf fonksiyondur.
 */
export function metricKitDiagnostics(json: JsonValue | null): readonly DiagnosticSummary[] {
  const object: JsonObject | null = asObject(json ?? undefined);
  if (object === null) {
    return [];
  }
  const listed: readonly DiagnosticSummary[] = [...diagnosticList(object, "crashDiagnostics", "crash"), ...diagnosticList(object, "hangDiagnostics", "hang")];
  if (listed.length > 0) {
    return listed;
  }
  const single: DiagnosticSummary | null = diagnosticSummary(object, "crash");
  if (single === null) {
    return [];
  }
  return [single.hangDuration === null ? single : { ...single, kind: "hang" }];
}

/**
 * İlk teşhisin tek satırlık özeti (`Hang · 6 sec · 0.1.12 (24) · macOS 26.1 (25B78) · MacBookPro18,3 · +1 more`);
 * teşhis yoksa null. Saf fonksiyondur.
 */
export function diagnosticSummaryLine(diagnostics: readonly DiagnosticSummary[], labels: DiagnosticSummaryLabels): string | null {
  const first: DiagnosticSummary | undefined = diagnostics[0];
  if (first === undefined) {
    return null;
  }
  const version: string | null = first.appVersion === null ? null : first.appBuild === null ? first.appVersion : `${first.appVersion} (${first.appBuild})`;
  const cause: readonly (string | null)[] =
    first.kind === "hang"
      ? [first.hangDuration]
      : [
          first.exceptionType === null ? null : (machExceptionNames[first.exceptionType] ?? `exceptionType ${first.exceptionType}`),
          first.signal === null ? null : (signalNames[first.signal] ?? `signal ${first.signal}`),
          first.exceptionName,
        ];
  const more: string | null = diagnostics.length > 1 ? fill(labels.more, { count: String(diagnostics.length - 1) }) : null;
  return [labels.kinds[first.kind], ...cause, version, first.os, first.device, more]
    .filter((part: string | null): part is string => part !== null)
    .join(" · ");
}
