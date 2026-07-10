-- 20260708_onthisday_digest_chanset.sql
-- Data-only migration: adds the +OnThisDayDigest chanset (per-channel OPT-IN
-- for the daily automatic "on this day" digest). No schema change. [mb496]
--
-- Defaults to DISABLED in code (chanset_enabled default => 0): a spontaneous
-- daily post is opt-in. To enable on a channel:
--   chanset #channel +OnThisDayDigest
--
-- The digest fires once a day at main.ONTHISDAY_DIGEST_HOUR (default 12h local;
-- set < 0 to disable the task entirely).
--
-- Usage:
--   mysql -u root -p --default-character-set=utf8mb4
--   SET NAMES utf8mb4;
--   USE <mediabot_database>;
--   SOURCE install/migrations/20260708_onthisday_digest_chanset.sql;

SET NAMES utf8mb4;

INSERT INTO CHANSET_LIST (chanset)
SELECT 'OnThisDayDigest'
WHERE NOT EXISTS (
  SELECT 1 FROM CHANSET_LIST WHERE chanset = 'OnThisDayDigest'
);

SELECT id_chanset_list, chanset
FROM CHANSET_LIST
WHERE chanset = 'OnThisDayDigest';
