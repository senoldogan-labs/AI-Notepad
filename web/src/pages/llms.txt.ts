// /llms.txt: yapay zekâ asistanları için kısa ürün özeti ve sayfa bağlantıları (src/lib/llms.ts).
import type { APIRoute } from "astro";
import { llmsTxt } from "../lib/llms";
import { llmsInput } from "../lib/llms-input";

export const GET: APIRoute = async (): Promise<Response> =>
  new Response(llmsTxt(await llmsInput()), { headers: { "content-type": "text/plain; charset=utf-8" } });
