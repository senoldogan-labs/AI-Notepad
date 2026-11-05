import { z } from "zod";
import type { Config } from "../config";
import { ApiError } from "../errors";
import { jsonResponse, readJsonBody } from "../http";
import { log } from "../log";
import { hasSyncAccess } from "../sync";
import { type AssistantKeyring, AssistantKeyringError, parseAssistantKeyring } from "./crypto";
import { type ProjectionUpload, normalizedUuid, projectionMaxBytes, projectionUploadSchema } from "./projection";
import {
  type AssistantSettingsRow,
  assistantGrantBody,
  assistantMeetingCount,
  assistantSettings,
  assistantSettingsBody,
  deleteAssistantDevice,
  deleteAssistantGrant,
  deleteAssistantMeeting,
  disableAssistant,
  enableAssistant,
  listAssistantGrants,
  putAssistantMeeting,
} from "./store";

/**
 * App-facing API of AI assistant access on `api.gistsmith.com` (app bearer tokens; the MCP Worker's OAuth tokens are
 * never accepted here, they are not app JWTs). Design: docs/superpowers/specs/2026-11-05-remote-mcp.md, "Data flow".
 *
 * Adding data (turning the feature on, uploading a meeting) needs a subscription or a running trial
 * (`hasSyncAccess`). Reading the settings, deleting meetings, disconnecting assistants and turning the feature off
 * always work, so a lapsed subscriber can still remove the copy.
 */

/** The bindings the routes use. */
export interface AssistantBindings {
  readonly adb: D1Database;
  readonly bucket: R2Bucket;
  readonly dataKey: string | undefined;
}

const settingsSchema = z.strictObject({ enabled: z.boolean() });
const meetingPath: RegExp = /^\/v1\/assistant\/meetings\/([^/]+)$/;
const grantPath: RegExp = /^\/v1\/assistant\/grants\/([^/]+)$/;
const devicePath: RegExp = /^\/v1\/assistant\/devices\/([^/]+)$/;

/** The path's id as a lower-case UUID; `bad_request` otherwise. Pure function. */
function pathUuid(match: RegExpExecArray, name: string): string {
  const id: string | null = normalizedUuid(match[1] ?? "");
  if (id === null) {
    throw new ApiError("bad_request", `The ${name} must be a UUID.`);
  }
  return id;
}

/** Grant ids come from the OAuth library (`<user>:<random>`-free opaque strings); only a safe charset is accepted. */
function pathGrantId(match: RegExpExecArray): string {
  const value: string = match[1] ?? "";
  if (!/^[A-Za-z0-9_-]{8,128}$/.test(value)) {
    throw new ApiError("bad_request", "The grant id is not valid.");
  }
  return value;
}

function keyringOf(dataKey: string | undefined): AssistantKeyring {
  try {
    return parseAssistantKeyring(dataKey);
  } catch (error: unknown) {
    if (error instanceof AssistantKeyringError) {
      log("alert", "assistant_data_key_invalid", { reason: error.message });
      throw new ApiError("assistant_unavailable", "AI assistant access is not available right now; try again later.");
    }
    throw error;
  }
}

async function requireAccess(db: D1Database, config: Config, userId: string, now: Date): Promise<void> {
  if (!(await hasSyncAccess(db, config, userId, now))) {
    throw new ApiError("subscription_required", "AI assistant access needs a subscription or a running trial.");
  }
}

async function settingsResponse(adb: D1Database, userId: string, row: AssistantSettingsRow | null): Promise<Response> {
  return jsonResponse(200, assistantSettingsBody(row, await assistantMeetingCount(adb, userId)));
}

/**
 * Routes `/v1/assistant/…` for an authenticated, rate-limited user. The caller passes bindings only while
 * `ASSISTANT_POLICY` is on (`assistantStorageOf`); with the policy off it answers `assistant_unavailable` itself.
 */
export async function routeAssistant(
  request: Request,
  db: D1Database,
  bindings: AssistantBindings,
  config: Config,
  path: string,
  userId: string,
  now: Date,
): Promise<Response> {
  const { adb, bucket } = bindings;
  const method: string = request.method;
  if (path === "/v1/assistant/settings") {
    if (method === "GET") {
      return settingsResponse(adb, userId, await assistantSettings(adb, userId));
    }
    if (method === "PUT") {
      const body = await readJsonBody(request, settingsSchema, 1024);
      if (body.enabled) {
        await requireAccess(db, config, userId, now);
        const row: AssistantSettingsRow = await enableAssistant(adb, userId, now);
        log("info", "assistant_enabled", { userId, epoch: row.epoch });
        return settingsResponse(adb, userId, row);
      }
      return settingsResponse(adb, userId, await disableAssistant(adb, bucket, userId, now));
    }
  }
  const meetingMatch: RegExpExecArray | null = meetingPath.exec(path);
  if (meetingMatch !== null) {
    const meetingId: string = pathUuid(meetingMatch, "meeting id");
    if (method === "PUT") {
      await requireAccess(db, config, userId, now);
      const keyring: AssistantKeyring = keyringOf(bindings.dataKey);
      const upload: ProjectionUpload = await readJsonBody(request, projectionUploadSchema, projectionMaxBytes);
      return jsonResponse(200, await putAssistantMeeting(adb, bucket, keyring, userId, meetingId, upload, now));
    }
    if (method === "DELETE") {
      return jsonResponse(200, { meetingId, deleted: await deleteAssistantMeeting(adb, bucket, userId, meetingId) });
    }
  }
  if (path === "/v1/assistant/grants" && method === "GET") {
    return jsonResponse(200, { grants: (await listAssistantGrants(adb, userId)).map(assistantGrantBody) });
  }
  const grantMatch: RegExpExecArray | null = grantPath.exec(path);
  if (grantMatch !== null && method === "DELETE") {
    const grantId: string = pathGrantId(grantMatch);
    const deleted: boolean = await deleteAssistantGrant(adb, userId, grantId, now);
    log("info", "assistant_grant_deleted", { userId, grantId, deleted });
    return jsonResponse(200, { grantId, deleted });
  }
  const deviceMatch: RegExpExecArray | null = devicePath.exec(path);
  if (deviceMatch !== null && method === "DELETE") {
    const deviceId: string = pathUuid(deviceMatch, "device id");
    const meetings: number = await deleteAssistantDevice(adb, bucket, userId, deviceId);
    log("info", "assistant_device_deleted", { userId, meetings });
    return jsonResponse(200, { deviceId, deletedMeetings: meetings });
  }
  throw new ApiError("not_found", "No such endpoint.");
}
