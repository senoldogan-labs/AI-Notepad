import { grantComplimentaryAccess, revokeComplimentaryAccess } from "../complimentary";
import { log } from "../log";
import type { AssistantKeyring } from "./crypto";
import type { ProjectionUpload } from "./projection";
import { type AssistantSettingsRow, deleteAssistantMeeting, disableAssistant, enableAssistant, putAssistantMeeting } from "./store";

/**
 * The connector directories' reviewer account (`REVIEWER_LOGINS` in the MCP Worker, docs/superpowers/specs/
 * 2026-11-05-remote-mcp.md): a Gistsmith user with no Apple or Google identity, so nobody can sign in to the apps with
 * it; reviewers reach it only through the MCP Worker's password sign-in. The admin seeds it
 * (`POST /v1/admin/assistant/reviewer`): the account gets free access like any complimentary account, AI assistant
 * access turned on, and fictional demo meetings written through the same store path as an app upload, so they are
 * sealed with the normal keyring. `DELETE` on the same path turns assistant access off (every connection is revoked and
 * the copy deleted) and ends the free access.
 */

/** The reviewer account's user id: fixed, so seeding again reuses the account. Not a secret (passwords are). */
export const reviewerUserId: string = "5e1f0c3a-7b2d-4c8e-9a61-0d4b2f7e9c15";
/** The "device" the demo meetings are uploaded from. */
const reviewerDeviceId: string = "9b3e6d21-4f0a-4c57-8e2b-61d0a7c4f3e8";
const dayMs: number = 86_400_000;
const minuteMs: number = 60_000;

/** One demo meeting: its app-format id and its upload body. */
export interface DemoMeeting {
  readonly meetingId: string;
  readonly upload: ProjectionUpload;
}

/** `POST /v1/admin/assistant/reviewer` response. */
export interface ReviewerSeedResult {
  readonly userId: string;
  readonly epoch: number;
  readonly meetingIds: readonly string[];
}

/** `DELETE /v1/admin/assistant/reviewer` response. */
export interface ReviewerRemoval {
  readonly userId: string;
  readonly assistantEnabled: boolean;
  readonly complimentaryRevoked: boolean;
}

/** A meeting id in the apps' session folder format `yyyyMMdd-HHmmss` (UTC here). Pure function. */
export function appMeetingId(startMs: number): string {
  const iso: string = new Date(startMs).toISOString();
  return `${iso.slice(0, 4)}${iso.slice(5, 7)}${iso.slice(8, 10)}-${iso.slice(11, 13)}${iso.slice(14, 16)}${iso.slice(17, 19)}`;
}

/** `YYYY-MM-DD` of a time. Pure function. */
function isoDay(ms: number): string {
  return new Date(ms).toISOString().slice(0, 10);
}

/** Where a demo meeting sits: days before today (UTC), start hour and minute (UTC). */
interface DemoSlot {
  readonly daysAgo: number;
  readonly hour: number;
  readonly minute: number;
}

/** Start time of a slot relative to the start of `now`'s UTC day. Pure function. */
function slotStartMs(slot: DemoSlot, now: Date): number {
  const dayStart: number = Math.floor(now.getTime() / dayMs) * dayMs;
  return dayStart - slot.daysAgo * dayMs + slot.hour * 60 * minuteMs + slot.minute * minuteMs;
}

/**
 * Six fictional meetings of Larkfield Robotics (a made-up warehouse robotics company) over the last two weeks, seen by
 * its Head of Product, Alex Rivera (the reviewer's own tasks are `isMine`). Ids and dates move with `now`, so a seed
 * always looks recent. Pure function.
 */
export function reviewerDemoMeetings(epoch: number, now: Date): DemoMeeting[] {
  const meeting = (slot: DemoSlot, body: Omit<ProjectionUpload, "epoch" | "deviceId" | "startedAt">): DemoMeeting => {
    const startMs: number = slotStartMs(slot, now);
    return { meetingId: appMeetingId(startMs), upload: { epoch, deviceId: reviewerDeviceId, startedAt: new Date(startMs).toISOString(), ...body } };
  };
  const due = (daysFromNow: number): string => isoDay(now.getTime() + daysFromNow * dayMs);
  return [
    meeting(
      { daysAgo: 13, hour: 9, minute: 30 },
      {
        title: "Q1 product planning",
        durationSec: 3300,
        folder: "Product",
        attendees: ["Alex Rivera", "Priya Nair", "Tom Becker", "Sofia Alvarez"],
        language: "en",
        note: {
          title: "Q1 product planning",
          summary:
            "The team set the Q1 roadmap for the Larkfield picking robot. Fleet dashboard v2 and the battery health alerts are the two commitments; the self-service setup wizard moves to Q2 because firmware 4.2 has to ship first. Support tickets show that operators lose the most time on manual battery swaps, which drove the priority on alerts.",
          decisions: [
            "[06:40] Fleet dashboard v2 and battery health alerts are the Q1 commitments.",
            "[21:15] The self-service setup wizard moves to Q2, after firmware 4.2.",
            "[38:50] Beta customers get dashboard v2 two weeks before general release.",
          ],
          tasks: [
            { owner: "Alex Rivera", description: "Write the one-page brief for battery health alerts", dueDate: due(-6), isMine: true, done: true },
            { owner: "Alex Rivera", description: "Share the Q1 roadmap with the customer success team", dueDate: due(3), isMine: true, done: false },
            { owner: "Tom Becker", description: "Estimate the firmware 4.2 work for the wizard", dueDate: due(1), isMine: false, done: false },
            { owner: "Sofia Alvarez", description: "Pick five beta customers for dashboard v2", dueDate: due(-2), isMine: false, done: true },
          ],
          outline: [
            { startSec: 0, title: "Support ticket review", summary: "Battery swaps and map edits are the top two complaints." },
            { startSec: 900, title: "Roadmap options", summary: "Dashboard v2, battery alerts and the setup wizard were sized." },
            { startSec: 2100, title: "Sequencing", summary: "The wizard depends on firmware 4.2, so it moves to Q2." },
            { startSec: 2900, title: "Beta plan", summary: "Five customers get early access to dashboard v2." },
          ],
          glossary: [{ term: "Fleet dashboard", meaning: "The web view where customers watch their robots and battery levels." }],
          openQuestions: ["Do battery alerts need SMS, or is email enough for the first release?"],
        },
        myNotes: "Ask Sofia which beta customers run night shifts; alerts matter most there.",
      },
    ),
    meeting(
      { daysAgo: 10, hour: 15, minute: 0 },
      {
        title: "Brightwater Logistics pilot review",
        durationSec: 2400,
        folder: "Customers",
        attendees: ["Alex Rivera", "Sofia Alvarez", "Dana Okafor (Brightwater Logistics)", "Luis Romero (Brightwater Logistics)"],
        language: "en",
        note: {
          title: "Brightwater Logistics pilot review",
          summary:
            "Brightwater Logistics reviewed the 60-day pilot at their Dayton warehouse. Pick rates rose 18% on the two pilot aisles, but night-shift operators reported robots waiting at charging docks. Brightwater wants to expand to eight aisles if charging is scheduled around shift changes, and asked for a proposal by the end of the month.",
          decisions: [
            "[12:05] Larkfield will send an expansion proposal for eight aisles.",
            "[27:30] Charging windows will follow Brightwater's shift schedule during the expansion.",
          ],
          tasks: [
            { owner: "Alex Rivera", description: "Send the eight-aisle expansion proposal to Dana", dueDate: due(4), isMine: true, done: false },
            { owner: "Sofia Alvarez", description: "Get the night-shift charging logs from the Dayton site", dueDate: due(-5), isMine: false, done: true },
            { owner: "Dana Okafor", description: "Share the shift schedule for November and December", dueDate: due(-3), isMine: false, done: true },
          ],
          outline: [
            { startSec: 0, title: "Pilot results", summary: "Pick rate up 18% on the pilot aisles; no safety incidents." },
            { startSec: 780, title: "Night-shift issues", summary: "Robots queue at charging docks around the 10 pm shift change." },
            { startSec: 1500, title: "Expansion", summary: "Eight aisles, with charging planned around shift changes." },
          ],
          glossary: [],
          openQuestions: ["Will Brightwater pay for the extra charging docks, or is that part of the subscription?"],
        },
        myNotes: null,
      },
    ),
    meeting(
      { daysAgo: 8, hour: 16, minute: 0 },
      {
        title: "Hiring debrief: Senior Robotics Engineer",
        durationSec: 2100,
        folder: "Hiring",
        attendees: ["Alex Rivera", "Tom Becker", "Mei Lin", "Jordan Brooks"],
        language: "en",
        note: {
          title: "Hiring debrief: Senior Robotics Engineer",
          summary:
            "The panel debriefed the final round for the Senior Robotics Engineer role. Candidate A was strong on motion planning and system design; the panel was split on Candidate B, who did well in the coding round but had little field deployment experience. The team agreed to make an offer to Candidate A and keep Candidate B in mind for the simulation team.",
          decisions: [
            "[08:20] Make an offer to Candidate A.",
            "[24:45] Refer Candidate B to the simulation team's open role.",
          ],
          tasks: [
            { owner: "Jordan Brooks", description: "Prepare the offer for Candidate A", dueDate: due(-6), isMine: false, done: true },
            { owner: "Alex Rivera", description: "Call Candidate A to talk about the first 90 days", dueDate: due(-5), isMine: true, done: true },
            { owner: "Mei Lin", description: "Forward Candidate B's take-home to the simulation team", dueDate: due(-4), isMine: false, done: false },
          ],
          outline: [
            { startSec: 0, title: "Candidate A", summary: "Strong system design; clear examples of field deployments." },
            { startSec: 840, title: "Candidate B", summary: "Excellent coding round; limited time on real warehouse floors." },
            { startSec: 1500, title: "Decision", summary: "Offer to A; B referred to simulation." },
          ],
          glossary: [],
        },
        myNotes: null,
      },
    ),
    meeting(
      { daysAgo: 5, hour: 14, minute: 0 },
      {
        title: "1:1 with Priya",
        durationSec: 1800,
        folder: "1:1s",
        attendees: ["Alex Rivera", "Priya Nair"],
        language: "en",
        note: {
          title: "1:1 with Priya",
          summary:
            "Priya is ready to own the battery health alerts project end to end. She wants more time with customers and asked to join the Brightwater expansion calls. They also talked about her goal of presenting at the internal tech talk in December.",
          decisions: ["[09:10] Priya leads battery health alerts from design to launch.", "[18:30] Priya joins the Brightwater expansion calls."],
          tasks: [
            { owner: "Alex Rivera", description: "Add Priya to the Brightwater expansion calls", dueDate: due(-4), isMine: true, done: true },
            { owner: "Alex Rivera", description: "Introduce Priya to the tech talk organisers", dueDate: due(2), isMine: true, done: false },
            { owner: "Priya Nair", description: "Draft the battery alerts launch plan", dueDate: due(5), isMine: false, done: false },
          ],
          outline: [
            { startSec: 0, title: "Project ownership", summary: "Priya takes battery health alerts end to end." },
            { startSec: 900, title: "Customer exposure", summary: "Join Brightwater calls; shadow two support sessions." },
            { startSec: 1440, title: "Growth", summary: "Tech talk in December on fleet telemetry." },
          ],
          glossary: [],
        },
        myNotes: "Priya prefers written feedback before our 1:1s.",
      },
    ),
    meeting(
      { daysAgo: 3, hour: 11, minute: 0 },
      {
        title: "Q1 budget review",
        durationSec: 3000,
        folder: "Finance",
        attendees: ["Alex Rivera", "Hannah Weiss", "Tom Becker", "Sofia Alvarez"],
        language: "en",
        note: {
          title: "Q1 budget review",
          summary:
            "Finance walked through the Q1 budget. Cloud costs for fleet telemetry are 12% over plan because dashboard v2 keeps a longer history; the team will cut retention for raw sensor data from 90 to 30 days. Hardware spend for the Brightwater expansion is approved if the proposal is signed by the end of the quarter.",
          decisions: [
            "[14:20] Raw sensor data retention goes from 90 to 30 days.",
            "[31:45] Brightwater expansion hardware is approved once the contract is signed.",
            "[42:10] Travel budget stays flat; customer visits take priority over conferences.",
          ],
          tasks: [
            { owner: "Tom Becker", description: "Change raw sensor data retention to 30 days", dueDate: due(6), isMine: false, done: false },
            { owner: "Alex Rivera", description: "Send Hannah the dashboard v2 storage estimate", dueDate: due(1), isMine: true, done: false },
            { owner: "Hannah Weiss", description: "Update the Q1 forecast with the retention change", dueDate: due(7), isMine: false, done: false },
          ],
          outline: [
            { startSec: 0, title: "Overview", summary: "Total spend is 4% over plan, driven by cloud costs." },
            { startSec: 780, title: "Cloud costs", summary: "Telemetry history for dashboard v2 is the main driver." },
            { startSec: 1800, title: "Hardware", summary: "Brightwater expansion hardware tied to the signed contract." },
            { startSec: 2460, title: "Travel", summary: "Flat budget; customer visits first." },
          ],
          glossary: [{ term: "Raw sensor data", meaning: "Unaggregated lidar and motor readings uploaded by each robot." }],
          openQuestions: ["Can aggregated telemetry keep 90 days of history without raising costs?"],
        },
        myNotes: null,
      },
    ),
    meeting(
      { daysAgo: 1, hour: 9, minute: 0 },
      {
        title: "Weekly product stand-up",
        durationSec: 900,
        folder: "Team",
        attendees: ["Alex Rivera", "Priya Nair", "Tom Becker", "Mei Lin", "Sofia Alvarez"],
        language: "en",
        note: {
          title: "Weekly product stand-up",
          summary:
            "Dashboard v2 is feature complete and in internal testing. Firmware 4.2 slipped by three days because of a motor driver bug. Priya's battery alerts design review is on Thursday. The Brightwater proposal draft is waiting on the storage estimate.",
          decisions: ["[07:30] Dashboard v2 internal testing runs until Friday before the beta opens."],
          tasks: [
            { owner: "Alex Rivera", description: "Review Priya's battery alerts design before Thursday", dueDate: due(2), isMine: true, done: false },
            { owner: "Mei Lin", description: "Post the motor driver bug fix status in the team channel", dueDate: due(0), isMine: false, done: false },
            { owner: "Tom Becker", description: "Confirm the new firmware 4.2 date", dueDate: due(1), isMine: false, done: false },
          ],
          outline: [
            { startSec: 0, title: "Dashboard v2", summary: "Feature complete; internal testing this week." },
            { startSec: 240, title: "Firmware 4.2", summary: "Three-day slip for a motor driver bug." },
            { startSec: 540, title: "Battery alerts and Brightwater", summary: "Design review Thursday; proposal waits on the storage estimate." },
          ],
          glossary: [],
        },
        myNotes: null,
      },
    ),
  ];
}

/**
 * Creates the reviewer account or reuses it, gives it free access (no end date) and assistant access, and writes the
 * demo meetings; demo meetings from an earlier seed whose ids moved with the date are deleted, so the copy holds
 * exactly the current set.
 */
export async function seedReviewerAccount(
  db: D1Database,
  adb: D1Database,
  bucket: R2Bucket,
  keyring: AssistantKeyring,
  adminUserId: string,
  now: Date,
): Promise<ReviewerSeedResult> {
  await db.prepare("INSERT INTO users (id, created_at) VALUES (?, ?) ON CONFLICT(id) DO NOTHING").bind(reviewerUserId, now.getTime()).run();
  await grantComplimentaryAccess(db, reviewerUserId, null, adminUserId, now);
  const settings: AssistantSettingsRow = await enableAssistant(adb, reviewerUserId, now);
  const meetings: DemoMeeting[] = reviewerDemoMeetings(settings.epoch, now);
  const current: ReadonlySet<string> = new Set(meetings.map((meeting: DemoMeeting): string => meeting.meetingId));
  const stored = await adb.prepare("SELECT meeting_id FROM assistant_meetings WHERE user_id = ?").bind(reviewerUserId).all<{ meeting_id: string }>();
  for (const row of stored.results) {
    if (!current.has(row.meeting_id)) {
      await deleteAssistantMeeting(adb, bucket, reviewerUserId, row.meeting_id);
    }
  }
  for (const meeting of meetings) {
    await putAssistantMeeting(adb, bucket, keyring, reviewerUserId, meeting.meetingId, meeting.upload, now);
  }
  log("info", "assistant_reviewer_seeded", { userId: reviewerUserId, adminUserId, meetings: meetings.length });
  return { userId: reviewerUserId, epoch: settings.epoch, meetingIds: [...current] };
}

/**
 * Turns the reviewer account's assistant access off (queues the KV revocation of every connection, deletes the copy)
 * and ends its free access if it is running. Repeating is harmless.
 */
export async function removeReviewerAccount(db: D1Database, adb: D1Database, bucket: R2Bucket, adminUserId: string, now: Date): Promise<ReviewerRemoval> {
  const settings: AssistantSettingsRow | null = await disableAssistant(adb, bucket, reviewerUserId, now);
  const running: { found: number } | null = await db
    .prepare("SELECT EXISTS (SELECT 1 FROM subscriptions WHERE user_id = ? AND complimentary = 1 AND current_period_end > ?) AS found")
    .bind(reviewerUserId, now.getTime())
    .first<{ found: number }>();
  const complimentaryRevoked: boolean = running !== null && running.found === 1;
  if (complimentaryRevoked) {
    await revokeComplimentaryAccess(db, reviewerUserId, adminUserId, now);
  }
  log("info", "assistant_reviewer_removed", { userId: reviewerUserId, adminUserId, complimentaryRevoked });
  return { userId: reviewerUserId, assistantEnabled: settings !== null && settings.enabled === 1, complimentaryRevoked };
}
