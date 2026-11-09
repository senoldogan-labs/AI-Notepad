import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { randomId } from "../src/crypto";
import {
  type ReferralEvent,
  type ReferralState,
  allowedReferralStatusChanges,
  referralClaimLeaseMs,
  referralTransition,
} from "../src/referralState";
import type { ReferralStatus } from "../src/referrals";

const statuses: readonly ReferralStatus[] = ["checkout", "joined", "qualified", "granted", "capped", "void"];
const claimMs: number = 1_000_000_000;

/** Her olay türünden bir örnek (sahiplenme ve sonuç, `claimMs` ile sahiplenilmiş satıra göre). */
const events: readonly ReferralEvent[] = [
  { kind: "joined" },
  { kind: "join_rejected" },
  { kind: "qualified" },
  { kind: "canceled_before_payment" },
  { kind: "payment_reversed", reason: "refunded" },
  { kind: "referrer_deleted" },
  { kind: "reward_claimed", nowMs: claimMs },
  { kind: "reward_settled", outcome: "granted", claimedAtMs: claimMs },
  { kind: "reward_settled", outcome: "capped", claimedAtMs: claimMs },
  { kind: "reward_settled", outcome: "refunded", claimedAtMs: claimMs },
];

function changeKey(from: ReferralStatus, to: ReferralStatus): string {
  return `${from}->${to}`;
}

/** Satır ekler (tetikleyiciler yalnızca güncellemeyi denetler) ve kimliğini döndürür. */
async function insertRow(status: ReferralStatus, claimedAt: number | null): Promise<string> {
  const id: string = randomId();
  await env.DB.prepare(
    `INSERT INTO referral_redemptions (id, referred_user_id, referred_identity_hash, referrer_user_id, code, status, void_reason, created_at,
       updated_at, reward_claimed_at) VALUES (?, NULL, ?, NULL, 'CODE2345', ?, ?, 0, 0, ?)`,
  )
    .bind(id, `hash_${id}`, status, status === "void" ? "refunded" : null, claimedAt)
    .run();
  return id;
}

/** Durumu değiştirmeyi dener (dolu bakiye hareketi, ödül anı ve düşme nedeniyle); tetikleyici durdurursa false. */
async function tryStatusChange(id: string, to: ReferralStatus): Promise<boolean> {
  try {
    await env.DB.prepare("UPDATE referral_redemptions SET status = ?, void_reason = 'refunded', stripe_balance_transaction_id = 'cbtxn_1', rewarded_at = 1 WHERE id = ?")
      .bind(to, id)
      .run();
    return true;
  } catch (error: unknown) {
    expect(String(error)).toContain("referral_redemptions:");
    return false;
  }
}

describe("davet durum makinesi", () => {
  it("saf geçiş fonksiyonunun üretebildiği durum değişimleri izin listesiyle aynı", () => {
    const produced: Set<string> = new Set();
    for (const status of statuses) {
      for (const rewardClaimedAtMs of [null, claimMs]) {
        for (const event of events) {
          const next: ReferralState | null = referralTransition({ status, rewardClaimedAtMs, pendingVoidReason: null }, event);
          if (next !== null && next.status !== status) {
            produced.add(changeKey(status, next.status));
          }
        }
      }
    }
    expect([...produced].sort()).toEqual(allowedReferralStatusChanges.map(([from, to]: readonly [ReferralStatus, ReferralStatus]): string => changeKey(from, to)).sort());
  });

  it("sahiplenme: iade ve itiraz sahiplenilmiş satırı düşürmez, bekleyen düşme yazar; sahiplenme süre dolana dek tekrar alınamaz; sonuç yalnızca kendi sahiplenmesine yazılır", () => {
    const unclaimed: ReferralState = { status: "qualified", rewardClaimedAtMs: null, pendingVoidReason: null };
    const claimed: ReferralState = { status: "qualified", rewardClaimedAtMs: claimMs, pendingVoidReason: null };
    expect(referralTransition(unclaimed, { kind: "payment_reversed", reason: "refunded" })).toEqual({ ...unclaimed, status: "void" });
    const disputed: ReferralState | null = referralTransition(claimed, { kind: "payment_reversed", reason: "disputed" });
    expect(disputed).toEqual({ ...claimed, pendingVoidReason: "disputed" });
    // İlk neden kalır.
    expect(disputed === null ? null : referralTransition(disputed, { kind: "payment_reversed", reason: "refunded" })).toEqual(disputed);
    expect(referralTransition(claimed, { kind: "referrer_deleted" })).toEqual({ ...claimed, status: "void" });
    expect(referralTransition(unclaimed, { kind: "reward_claimed", nowMs: claimMs })).toEqual(claimed);
    expect(referralTransition(claimed, { kind: "reward_claimed", nowMs: claimMs + referralClaimLeaseMs - 1 })).toBeNull();
    expect(referralTransition(claimed, { kind: "reward_claimed", nowMs: claimMs + referralClaimLeaseMs })).toEqual({
      ...claimed,
      rewardClaimedAtMs: claimMs + referralClaimLeaseMs,
    });
    expect(referralTransition({ ...unclaimed, status: "void" }, { kind: "reward_claimed", nowMs: claimMs })).toBeNull();
    expect(referralTransition(unclaimed, { kind: "reward_settled", outcome: "granted", claimedAtMs: claimMs })).toBeNull();
    expect(referralTransition(claimed, { kind: "reward_settled", outcome: "granted", claimedAtMs: claimMs + 1 })).toBeNull();
    expect(referralTransition(claimed, { kind: "reward_settled", outcome: "self_referral", claimedAtMs: claimMs })).toEqual({ ...claimed, status: "void" });
  });

  it("tetikleyiciler izin listesi dışındaki durum değişimini durdurur", async () => {
    const allowed: Set<string> = new Set(allowedReferralStatusChanges.map(([from, to]: readonly [ReferralStatus, ReferralStatus]): string => changeKey(from, to)));
    for (const from of statuses) {
      for (const to of statuses) {
        const id: string = await insertRow(from, null);
        expect({ change: changeKey(from, to), applied: await tryStatusChange(id, to) }).toEqual({ change: changeKey(from, to), applied: from === to || allowed.has(changeKey(from, to)) });
      }
    }
  });

  it("tetikleyiciler: granted bakiye hareketi ve ödül anı, void düşme nedeni ister; yalnızca qualified satır sahiplenilir", async () => {
    const grantedWithoutCredit: string = await insertRow("qualified", claimMs);
    await expect(env.DB.prepare("UPDATE referral_redemptions SET status = 'granted', rewarded_at = 1 WHERE id = ?").bind(grantedWithoutCredit).run()).rejects.toThrow(
      "granted needs stripe_balance_transaction_id and rewarded_at",
    );
    await expect(
      env.DB.prepare("UPDATE referral_redemptions SET status = 'granted', stripe_balance_transaction_id = 'cbtxn_1' WHERE id = ?").bind(grantedWithoutCredit).run(),
    ).rejects.toThrow("granted needs stripe_balance_transaction_id and rewarded_at");
    await expect(env.DB.prepare("UPDATE referral_redemptions SET status = 'void' WHERE id = ?").bind(grantedWithoutCredit).run()).rejects.toThrow("void needs void_reason");

    for (const status of statuses.filter((candidate: ReferralStatus): boolean => candidate !== "qualified")) {
      const id: string = await insertRow(status, null);
      await expect(env.DB.prepare("UPDATE referral_redemptions SET reward_claimed_at = ? WHERE id = ?").bind(claimMs, id).run()).rejects.toThrow(
        "only a qualified row can be claimed",
      );
    }
    const qualified: string = await insertRow("qualified", null);
    await env.DB.prepare("UPDATE referral_redemptions SET reward_claimed_at = ? WHERE id = ?").bind(claimMs, qualified).run();
    // Sahiplenilmiş satır sonuçlanınca sahiplenme kalır (tetikleyici yalnızca değişen sahiplenmeyi denetler).
    await env.DB.prepare("UPDATE referral_redemptions SET status = 'capped' WHERE id = ?").bind(qualified).run();
  });
});
