-- 20260707_factoids_chanset.sql
-- Data-only migration: adds the +Factoids chanset (per-channel opt-out of the
-- shared learn/whatis factoid feature). No schema change. [mb476]
--
-- Defaults to ENABLED in code (chanset_enabled default => 1). To silence on a
-- channel: `chanset #channel -Factoids`.
--
-- Usage:
--   mysql -u root -p --default-character-set=utf8mb4
--   SET NAMES utf8mb4;
--   USE <mediabot_database>;
--   SOURCE install/migrations/20260707_factoids_chanset.sql;

SET NAMES utf8mb4;

INSERT INTO CHANSET_LIST (chanset)
SELECT 'Factoids'
WHERE NOT EXISTS (
  SELECT 1 FROM CHANSET_LIST WHERE chanset = 'Factoids'
);

SELECT id_chanset_list, chanset
FROM CHANSET_LIST
WHERE chanset = 'Factoids';
