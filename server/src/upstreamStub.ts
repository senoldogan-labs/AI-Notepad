import type { Env } from "./env";

/**
 * Yerel uçtan uca denemelerin sahte üst servisleri: `wrangler dev --var UPSTREAM_STUB_URL:http://127.0.0.1:<port>` ile
 * Anthropic ve ElevenLabs istekleri o yerel adrese gider (`server/scripts/fake-upstreams.mjs`); böylece deneme gerçek
 * servise ve ücretli çağrıya dokunmadan notun ve son geçişin tamamlandığını doğrular. Yalnızca geliştirme ortamında ve
 * yalnızca geri döngü (loopback) adresiyle geçerlidir; üretimde ayar varsa yapılandırma reddedilir
 * (`parseConfig` → `UPSTREAM_STUB_URL`).
 */
export const stubbedUpstreamOrigins: readonly string[] = ["https://api.anthropic.com", "https://api.elevenlabs.io"];

/** Geri döngü adresi mi (yerel sahte servis; yolsuz `http://127.0.0.1:<port>` ya da `localhost`). Saf fonksiyondur. */
export function isLoopbackStubUrl(value: string): boolean {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    return false;
  }
  return url.protocol === "http:" && (url.hostname === "127.0.0.1" || url.hostname === "localhost") && url.pathname === "/";
}

/**
 * Ortamın sahte üst servis adresi: yalnızca geliştirmede ve geri döngü adresiyse; değilse null (gerçek servisler).
 * Saf fonksiyondur.
 */
export function upstreamStubBase(env: Env): string | null {
  const value: string | undefined = env.UPSTREAM_STUB_URL;
  if (env.ENVIRONMENT !== "development" || value === undefined || value === "" || !isLoopbackStubUrl(value)) {
    return null;
  }
  return value.replace(/\/$/, "");
}

/** Üst servis adresinin sahte servisteki karşılığı (yol ve sorgu korunur); başka adres değişmez. Saf fonksiyondur. */
export function stubbedUpstreamUrl(url: string, stubBase: string): string {
  const origin: string | undefined = stubbedUpstreamOrigins.find((candidate: string): boolean => url === candidate || url.startsWith(`${candidate}/`));
  return origin === undefined ? url : `${stubBase}${url.slice(origin.length)}`;
}

/** Üst servis isteklerini sahte servise yönlendiren fetch. */
export function stubbedFetch(inner: typeof fetch, stubBase: string): typeof fetch {
  return (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const request: Request = new Request(input, init);
    const target: string = stubbedUpstreamUrl(request.url, stubBase);
    return inner(target === request.url ? request : new Request(target, request));
  };
}
