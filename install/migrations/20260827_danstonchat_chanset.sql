-- 20260827_danstonchat_chanset.sql
-- Data-only migration: registers the opt-in +DansTonChat channel capability.
-- [mb707]
--
-- This migration intentionally does NOT enable +DansTonChat on any channel.

SET NAMES utf8mb4;

INSERT INTO CHANSET_LIST (chanset)
SELECT 'DansTonChat'
WHERE NOT EXISTS (
  SELECT 1 FROM CHANSET_LIST WHERE chanset = 'DansTonChat'
);

SELECT id_chanset_list, chanset
FROM CHANSET_LIST
WHERE chanset = 'DansTonChat';
