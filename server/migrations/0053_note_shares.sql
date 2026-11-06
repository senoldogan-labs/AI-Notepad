-- Notu bağlantıyla paylaşma (src/shares.ts): uçtan uca şifreli not. Sunucu yalnızca şifreli bloğu (`ciphertext`,
-- `GSS1` biçimi, en çok 512 KiB), boyutunu, sahibini ve zamanlarını saklar; anahtar yalnızca bağlantının `#` parçasında
-- olduğu için içeriği okuyamaz. Kaldırılan paylaşımın satırı hemen silinir (iz bırakmaz); süresi dolanları günlük
-- temizlik siler (`cleanup.ts`), hesap silinince hepsi aynı işlemde silinir (`account.ts`).
CREATE TABLE note_shares (
  share_id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id),
  ciphertext BLOB NOT NULL,
  size INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);

CREATE INDEX note_shares_user ON note_shares (user_id, expires_at);
CREATE INDEX note_shares_expires ON note_shares (expires_at);
