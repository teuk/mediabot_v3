-- =============================================================================
-- Mediabot v3 migration
-- 2026-06-04 - Chansets mb115-mb118 (Achievements + Games)
--
-- Ajout idempotent de deux chansets dans CHANSET_LIST :
--   - AchievementAnnounce (id 15) — gate les annonces publiques d'achievements
--     mb115. Présent dans `install/mediabot.sql` mais à insérer pour les DB
--     existantes.
--   - Games (id 16) — gate les commandes ludiques mb116-mb117
--     (!duel, !quotegame, !horoscope, !compat). Sans ce chanset, ces commandes
--     répondent un poli "Games not enabled on this channel".
--
-- Comportement réel :
--   - si le chanset existe dans CHANSET_LIST, le canal décide via CHANNEL_SET
--   - AchievementAnnounce est donc opt-in : sans +AchievementAnnounce, pas d'annonce
--   - Games reste opt-out côté code via default=>1 : actif sauf si -Games est posé
--   - le default=>1 ne sert qu'en compatibilité si la DB n'a pas encore le chanset
--
-- Pour DÉSACTIVER les annonces d'achievements sur un canal:
--   chanset #channel -AchievementAnnounce
--
-- Pour DÉSACTIVER les jeux sur un canal:
--   chanset #channel -Games
--
-- Safe for existing databases: INSERT IGNORE.
--
-- Import :
--   mysql --default-character-set=utf8mb4 -u <user> -p <database>
--   SOURCE /home/mediabot/mediabot_v3/install/migrations/20260604_chansets_mb115_mb118.sql;
-- =============================================================================

SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;

INSERT IGNORE INTO `CHANSET_LIST` (`id_chanset_list`, `chanset`) VALUES
  (15, 'AchievementAnnounce'),
  (16, 'Games');

-- Vérification après import :
--   SELECT * FROM CHANSET_LIST ORDER BY id_chanset_list;
