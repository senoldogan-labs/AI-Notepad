-- Davet ödülünün sahiplenilmesi ve durum geçişlerinin veritabanında zorlanması (src/referralState.ts).
--
-- `reward_claimed_at`: ödül Cron'u (src/referralRewards.ts) Stripe'a bakiye alacağı yazdırmadan önce `qualified` satırı
-- koşullu bir UPDATE ile sahiplenir. İade ve itiraz webhook'ları yalnızca sahiplenilmemiş satırı düşürür; Cron iade ve
-- itirazı sahiplendikten sonra Stripe'tan okur. Böylece Stripe'ta alacak yazılıp satırın `void` kaldığı yarış oluşmaz.
-- Sahiplenme bir saat sonra düşer: çöken çalışmanın satırı sonraki Cron'da yeniden sahiplenilir. NULL: sahiplenilmedi.
--
-- `reward_void_pending`: sahiplenilmiş satıra gelen iade ya da itiraz webhook'unun nedeni (aboneliğin herhangi bir
-- faturası). Satır düşmez; Cron sonuçlandırmadan önce okur ve satırı bu nedenle düşürür (Stripe'ta alacak zaten
-- yazılmışsa satır `granted` olur). NULL: bekleyen düşme yok.
--
-- Tetikleyiciler yalnızca durum değişen güncellemeleri denetler (var olan satırlar ve aynı durumda kalan güncellemeler
-- serbest): izin verilen geçişler `allowedReferralStatusChanges` ile aynıdır; `granted` olan satırın bakiye hareketi ve
-- ödül anı, `void` olan satırın düşme nedeni dolu olmalıdır. Sahiplenme yalnızca `qualified` satıra yazılabilir.
ALTER TABLE referral_redemptions ADD COLUMN reward_claimed_at INTEGER;
ALTER TABLE referral_redemptions ADD COLUMN reward_void_pending TEXT CHECK (reward_void_pending IN ('refunded', 'disputed'));

CREATE TRIGGER referral_redemptions_status_transition BEFORE UPDATE OF status ON referral_redemptions
WHEN OLD.status <> NEW.status AND NOT (
  (OLD.status = 'checkout' AND NEW.status IN ('joined', 'void'))
  OR (OLD.status = 'joined' AND NEW.status IN ('qualified', 'void'))
  OR (OLD.status = 'qualified' AND NEW.status IN ('granted', 'capped', 'void'))
)
BEGIN
  SELECT RAISE(ABORT, 'referral_redemptions: status transition not allowed');
END;

CREATE TRIGGER referral_redemptions_granted_has_credit BEFORE UPDATE OF status ON referral_redemptions
WHEN NEW.status = 'granted' AND OLD.status <> 'granted'
  AND (NEW.stripe_balance_transaction_id IS NULL OR NEW.rewarded_at IS NULL)
BEGIN
  SELECT RAISE(ABORT, 'referral_redemptions: granted needs stripe_balance_transaction_id and rewarded_at');
END;

CREATE TRIGGER referral_redemptions_void_has_reason BEFORE UPDATE OF status ON referral_redemptions
WHEN NEW.status = 'void' AND OLD.status <> 'void' AND NEW.void_reason IS NULL
BEGIN
  SELECT RAISE(ABORT, 'referral_redemptions: void needs void_reason');
END;

CREATE TRIGGER referral_redemptions_claim_only_qualified BEFORE UPDATE OF reward_claimed_at ON referral_redemptions
WHEN NEW.reward_claimed_at IS NOT NULL AND NEW.reward_claimed_at IS NOT OLD.reward_claimed_at AND OLD.status <> 'qualified'
BEGIN
  SELECT RAISE(ABORT, 'referral_redemptions: only a qualified row can be claimed');
END;
