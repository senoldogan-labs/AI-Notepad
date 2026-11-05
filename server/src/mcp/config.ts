import { z } from "zod";
import { type AssistantKeyring, AssistantKeyringError, parseAssistantKeyring } from "../assistant/crypto";
import type { AccessConfig } from "../entitlements";
import type { McpEnv } from "./env";

/** Origin of the MCP Worker; the protected resource is exactly `${mcpOrigin}/mcp`. */
export const mcpOrigin: string = "https://mcp.gistsmith.com";
export const mcpResource: string = `${mcpOrigin}/mcp`;
export const mcpHostname: string = "mcp.gistsmith.com";
/** The one scope: read the user's meeting notes. */
export const notesReadScope: string = "notes:read";

/** One directory reviewer account. */
export interface ReviewerLogin {
  readonly email: string;
  readonly password: string;
  readonly userId: string;
}

/** Validated configuration of the MCP Worker. */
export interface McpConfig {
  readonly environment: "development" | "production";
  readonly access: AccessConfig;
  readonly appleClientId: string;
  readonly googleClientId: string;
  readonly keyring: AssistantKeyring;
  readonly reviewers: readonly ReviewerLogin[];
}

/** Configuration is missing or invalid; carries field names only, never values. */
export class McpConfigError extends Error {
  override readonly name: string = "McpConfigError";
  readonly fields: readonly string[];

  constructor(fields: readonly string[]) {
    super(`Invalid MCP Worker configuration: ${fields.join(", ")}`);
    this.fields = fields;
  }
}

const dayMs: number = 86_400_000;
const positiveInt = z.string().regex(/^\d+$/).transform(Number).pipe(z.number().int().min(1));
const varsSchema = z.object({
  ENVIRONMENT: z.enum(["development", "production"]),
  APPLE_SIGNIN_CLIENT_ID: z.string().min(1),
  GOOGLE_SIGNIN_CLIENT_ID: z.string().min(1),
  TRIAL_MEETINGS: positiveInt,
  TRIAL_DAYS: positiveInt,
  PAST_DUE_GRACE_DAYS: positiveInt,
  REVENUECAT_ACCEPT_SANDBOX: z.enum(["true", "false"]),
  DEVICECHECK_POLICY: z.enum(["required", "off"]),
});
const reviewersSchema = z.array(z.strictObject({ email: z.email().max(200), password: z.string().min(16).max(200), userId: z.uuid() })).max(10);

/** Parses the Worker's bindings; `McpConfigError` names every invalid field. Pure function. */
export function parseMcpConfig(env: McpEnv): McpConfig {
  const fields: string[] = [];
  const vars = varsSchema.safeParse(env);
  if (!vars.success) {
    fields.push(...vars.error.issues.map((issue): string => issue.path.join(".")));
  }
  let keyring: AssistantKeyring | null = null;
  try {
    keyring = parseAssistantKeyring(env.ASSISTANT_DATA_KEY);
  } catch (error: unknown) {
    if (!(error instanceof AssistantKeyringError)) {
      throw error;
    }
    fields.push("ASSISTANT_DATA_KEY");
  }
  let reviewers: readonly ReviewerLogin[] = [];
  if (env.REVIEWER_LOGINS !== undefined) {
    let raw: unknown = null;
    try {
      raw = JSON.parse(env.REVIEWER_LOGINS);
    } catch (error: unknown) {
      if (!(error instanceof SyntaxError)) {
        throw error;
      }
    }
    const parsed = reviewersSchema.safeParse(raw);
    if (parsed.success) {
      reviewers = parsed.data.map((reviewer): ReviewerLogin => ({ ...reviewer, email: reviewer.email.toLowerCase() }));
    } else {
      fields.push("REVIEWER_LOGINS");
    }
  }
  if (!vars.success || keyring === null || fields.length > 0) {
    throw new McpConfigError(fields);
  }
  const value = vars.data;
  return {
    environment: value.ENVIRONMENT,
    access: {
      pastDueGraceMs: value.PAST_DUE_GRACE_DAYS * dayMs,
      trialDurationMs: value.TRIAL_DAYS * dayMs,
      trialMeetings: value.TRIAL_MEETINGS,
      deviceCheck: { policy: value.DEVICECHECK_POLICY },
      appStore: { acceptSandbox: value.REVENUECAT_ACCEPT_SANDBOX === "true" },
    },
    appleClientId: value.APPLE_SIGNIN_CLIENT_ID,
    googleClientId: value.GOOGLE_SIGNIN_CLIENT_ID,
    keyring,
    reviewers,
  };
}
