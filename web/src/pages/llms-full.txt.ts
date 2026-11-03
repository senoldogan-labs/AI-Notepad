// /llms-full.txt: yapay zekâ asistanları için ayrıntılı ürün belgesi (src/lib/llms.ts).
import type { APIRoute } from "astro";
import { llmsFullTxt } from "../lib/llms";
import { llmsInput } from "../lib/llms-input";

export const GET: APIRoute = async (): Promise<Response> =>
  new Response(llmsFullTxt(await llmsInput()), { headers: { "content-type": "text/plain; charset=utf-8" } });
