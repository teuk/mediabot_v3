-- 20260708_onthisday_chanset.sql
-- Data-only migration: adds the +OnThisDay chanset (per-channel opt-out of the
-- !onthisday / !otd history feature). No schema change. [mb489]
--
-- Defaults to ENABLED in code (chanset_enabled default => 1). To silence on a
-- channel: `chanset #channel -OnThisDay`.
--
-- Usage:
--   mysql -u root -p --default-character-set=utf8mb4
--   SET NAMES utf8mb4;
--   USE <mediabot_database>;
--   SOURCE install/migrations/20260708_onthisday_chanset.sql;

SET NAMES utf8mb4;

INSERT INTO CHANSET_LIST (chanset)
SELECT 'OnThisDay'
WHERE NOT EXISTS (
  SELECT 1 FROM CHANSET_LIST WHERE chanset = 'OnThisDay'
);

SELECT id_chanset_list, chanset
FROM CHANSET_LIST
WHERE chanset = 'OnThisDay';
