import { z } from "zod";
import { ApiError } from "../errors";
import type { LLMPurpose } from "./purpose";

// Shared-screen snapshots in the AI meeting note and in Ask ("Use screen snapshots in notes", off by default in the
// app). The client picks and downscales a few key snapshots (`ScreenNotes.swift`, `AskScreens.swift`: Ask sends at most
// 3 and 1,350 visual tokens); the server never trusts that and enforces the same caps itself before anything reaches
// Anthropic. Images are passed through to Claude only: they are never stored
// and never logged (only their count and estimated tokens are).
//
// The caps below are mirrored by the client (`screenNoteBudget` in `ScreenNotes.swift`; `askScreenBudget` stays within
// them); `ServerParityTests` reads this file and fails when the two drift apart.

/** At most this many images per request. */
export const screenImageMaxCount: number = 6;
/** At most this many decoded JPEG bytes per image. */
export const screenImageMaxBytes: number = 250_000;
/** At most this many visual tokens (Claude vision: one token per 28×28 px patch) across all images of a request. */
export const screenImageMaxTotalTokens: number = 2_700;

/** Purposes that may carry images: the single-call note, the overview of a long (chunked) note and Ask's answer. */
export const screenImagePurposes: readonly LLMPurpose[] = ["note", "note_overview", "ask_answer"];

/** Base64 length of `screenImageMaxBytes` (4 characters per 3 bytes, padded). */
const maxBase64Length: number = Math.ceil(screenImageMaxBytes / 3) * 4;

/**
 * Extra request-body bytes allowed for a request whose purpose may carry images: the base64 of every image at the cap
 * plus JSON framing. Only those purposes read the body with this allowance (`llmBodyLimitBytes`); the text of the
 * request is still held to `LLM_MAX_REQUEST_BYTES`.
 */
export const screenImageBodyAllowanceBytes: number = screenImageMaxCount * (maxBase64Length + 256);

/** A base64 JPEG image block (the only image form the proxy accepts). */
export const imageBlockSchema = z.strictObject({
  type: z.literal("image"),
  source: z.strictObject({
    type: z.literal("base64"),
    media_type: z.literal("image/jpeg"),
    data: z
      .string()
      .min(4)
      .max(maxBase64Length)
      .regex(/^[A-Za-z0-9+/]+={0,2}$/),
  }),
});

export type ImageBlock = z.output<typeof imageBlockSchema>;

/** Pixel size of a JPEG. */
export interface JpegSize {
  readonly width: number;
  readonly height: number;
}

/** Start-of-frame markers (baseline, progressive, lossless, arithmetic); they carry the image size. */
const startOfFrameMarkers: ReadonlySet<number> = new Set([0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf]);

/**
 * Size of a JPEG read from its start-of-frame segment; null when the bytes are not a JPEG or carry no frame (the
 * image is then rejected, never guessed). Pure function.
 */
export function jpegSize(bytes: Uint8Array): JpegSize | null {
  if (bytes.length < 4 || bytes[0] !== 0xff || bytes[1] !== 0xd8) {
    return null;
  }
  let offset: number = 2;
  while (offset + 3 < bytes.length) {
    if (bytes[offset] !== 0xff) {
      return null;
    }
    const marker: number = bytes[offset + 1] ?? 0;
    if (marker === 0xff) {
      // Fill byte before a marker.
      offset += 1;
      continue;
    }
    if (marker === 0xd8 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) {
      // Markers without a length field.
      offset += 2;
      continue;
    }
    if (marker === 0xd9 || marker === 0xda) {
      // End of image or start of scan before any frame header.
      return null;
    }
    const length: number = ((bytes[offset + 2] ?? 0) << 8) | (bytes[offset + 3] ?? 0);
    if (length < 2) {
      return null;
    }
    if (startOfFrameMarkers.has(marker)) {
      if (offset + 8 >= bytes.length) {
        return null;
      }
      const height: number = ((bytes[offset + 5] ?? 0) << 8) | (bytes[offset + 6] ?? 0);
      const width: number = ((bytes[offset + 7] ?? 0) << 8) | (bytes[offset + 8] ?? 0);
      return width > 0 && height > 0 ? { width, height } : null;
    }
    offset += 2 + length;
  }
  return null;
}

/**
 * Visual tokens of an image of this size: Claude splits images into 28×28 px patches, `⌈w/28⌉ × ⌈h/28⌉`
 * (platform.claude.com/docs/en/build-with-claude/vision, "Resolution and token cost"). Images larger than the model's
 * limit are downscaled by the API, so this is an upper bound. Pure function.
 */
export function visualTokens(size: JpegSize): number {
  return Math.ceil(size.width / 28) * Math.ceil(size.height / 28);
}

/** Decodes base64 (already shape-checked by the schema). Pure function. */
function decodeBase64(data: string): Uint8Array {
  const binary: string = atob(data);
  const bytes: Uint8Array = new Uint8Array(binary.length);
  for (let index: number = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index);
  }
  return bytes;
}

/** Images of a request and their checked cost. */
export interface ScreenImageUsage {
  readonly count: number;
  readonly bytes: number;
  readonly tokens: number;
}

/** No images. */
export const noScreenImages: ScreenImageUsage = { count: 0, bytes: 0, tokens: 0 };

/**
 * Checks the images of a request and returns their cost; over a cap, undecodable, or on a purpose that may not carry
 * images, throws `screen_images_over_limit` (the message names the cap, never the content). Pure function.
 */
export function screenImageUsage(images: readonly ImageBlock[], purpose: LLMPurpose): ScreenImageUsage {
  if (images.length === 0) {
    return noScreenImages;
  }
  if (!screenImagePurposes.includes(purpose)) {
    throw new ApiError("screen_images_over_limit", `Images are accepted only for these purposes: ${screenImagePurposes.join(", ")}.`);
  }
  if (images.length > screenImageMaxCount) {
    throw new ApiError("screen_images_over_limit", `At most ${screenImageMaxCount} images per request (received ${images.length}).`);
  }
  return images.reduce((usage: ScreenImageUsage, image: ImageBlock, index: number): ScreenImageUsage => {
    const bytes: Uint8Array = decodeBase64(image.source.data);
    if (bytes.length > screenImageMaxBytes) {
      throw new ApiError("screen_images_over_limit", `Image ${index + 1} is ${bytes.length} bytes; the limit is ${screenImageMaxBytes}.`);
    }
    const size: JpegSize | null = jpegSize(bytes);
    if (size === null) {
      throw new ApiError("screen_images_over_limit", `Image ${index + 1} is not a readable JPEG.`);
    }
    const tokens: number = usage.tokens + visualTokens(size);
    if (tokens > screenImageMaxTotalTokens) {
      throw new ApiError("screen_images_over_limit", `The images need about ${tokens} tokens; the limit is ${screenImageMaxTotalTokens}.`);
    }
    return { count: usage.count + 1, bytes: usage.bytes + bytes.length, tokens };
  }, noScreenImages);
}

/**
 * Body-size limit of `/v1/llm/messages`: text-only purposes keep `LLM_MAX_REQUEST_BYTES`; purposes that may carry
 * images get `screenImageBodyAllowanceBytes` on top. Pure function.
 */
export function llmBodyLimitBytes(maxRequestBytes: number, purpose: LLMPurpose): number {
  return screenImagePurposes.includes(purpose) ? maxRequestBytes + screenImageBodyAllowanceBytes : maxRequestBytes;
}
