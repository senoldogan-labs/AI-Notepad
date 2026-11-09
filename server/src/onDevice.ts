/**
 * On-device live preview rollout. The app writes the live transcript of the tracks the final pass re-transcribes with
 * the device's own speech recognition instead of Deepgram, when `/v1/me` says `liveOnDevice: true` and the device
 * supports the meeting language (the app decides that; see `hostedLiveRoute` in the Swift core). The saved transcript
 * still comes from the server's final pass. A user's answer is stable: the bucket is a hash of the user id, so raising
 * `ON_DEVICE_LIVE_PERCENT` only adds users and never flips someone back and forth.
 */

/** FNV-1a 32-bit offset basis and prime. */
const fnvOffsetBasis: number = 0x811c9dc5;
const fnvPrime: number = 0x01000193;

/** The user's rollout bucket, 0–99: FNV-1a of the user id's UTF-16 code units, modulo 100. Pure function. */
export function onDeviceLiveBucket(userId: string): number {
  let hash: number = fnvOffsetBasis;
  for (let index: number = 0; index < userId.length; index += 1) {
    hash ^= userId.charCodeAt(index);
    hash = Math.imul(hash, fnvPrime) >>> 0;
  }
  return hash % 100;
}

/** Whether the user is in the on-device live preview rollout: bucket below the percent (0 = nobody, 100 = everyone). Pure function. */
export function liveOnDevice(userId: string, percent: number): boolean {
  return onDeviceLiveBucket(userId) < percent;
}
