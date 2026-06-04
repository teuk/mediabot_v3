-- 20260604_achievement_announce_chanset.sql
-- Data-only migration: adds a chanset to control public achievement unlock spam.
-- No schema change.
--
-- Usage:
--   mysql -u root -p --default-character-set=utf8mb4
--   SET NAMES utf8mb4;
--   USE <mediabot_database>;
--   SOURCE install/migrations/20260604_achievement_announce_chanset.sql;

SET NAMES utf8mb4;

INSERT INTO CHANSET_LIST (chanset)
SELECT 'AchievementAnnounce'
WHERE NOT EXISTS (
  SELECT 1 FROM CHANSET_LIST WHERE chanset = 'AchievementAnnounce'
);

SELECT id_chanset_list, chanset
FROM CHANSET_LIST
WHERE chanset = 'AchievementAnnounce';
