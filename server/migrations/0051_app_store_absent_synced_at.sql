-- App Store aboneliğinin "yok" okumasının anı (src/appStore.ts, `appStoreSyncStatements`): RevenueCat okuması hesapta
-- App Store aboneliği bulamayınca (ör. satın alma başka hesaba aktarıldı) satır silinir ve okumanın anı
-- (`request_date_ms`) buraya yazılır. Satır silinince `app_store_subscriptions.synced_at` da gittiği için, bu andan önce
-- başlamış (eski) bir okuma silinmiş satırı yeniden yazamaz. Hiç "yok" okunmamış hesapta NULL.
ALTER TABLE users ADD COLUMN app_store_absent_synced_at INTEGER;
