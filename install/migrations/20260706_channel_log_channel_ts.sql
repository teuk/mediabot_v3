-- =============================================================================
-- Mediabot v3 migration
-- 2026-07-06 - CHANNEL_LOG composite index (id_channel, ts)   [A4 / mb470]
--
-- Direction 3.3 §2.4 : « appliquer et vérifier l'index composite prévu pour
-- CHANNEL_LOG » avant d'envisager toute table de compteurs.
--
-- Pourquoi cet index :
--   CHANNEL_LOG est indexée sur `id_channel` SEUL et sur `ts` SEUL. Or les
--   requêtes chaudes filtrent par canal PUIS bornent/trient par temps :
--     - m check / stats : WHERE id_channel = ? (via JOIN) ... MAX(ts), MIN(ts)
--     - achievements hourband : WHERE id_channel = ? AND nick = ? GROUP BY HOUR(ts)
--     - rapports / logs / leaderboards à période : id_channel = ? AND ts >= ?
--   Un index composite (id_channel, ts) sert de préfixe idéal : il localise le
--   canal puis parcourt/borne ts en ordre d'index, au lieu d'un scan filtré.
--   C'est le même motif déjà retenu pour KARMA_LOG (idx_karma_log_channel_ts).
--
-- Ce que cette migration NE fait PAS :
--   - elle ne supprime AUCUN index existant (ts, nick, userhost, id_channel
--     restent en place : d'autres requêtes s'appuient dessus) ;
--   - elle n'ajoute AUCUNE table, colonne, ni table de compteurs ;
--   - elle ne modifie aucune donnée.
--
-- Idempotence :
--   MariaDB/MySQL n'offrent pas d'ADD INDEX IF NOT EXISTS portable. On passe
--   donc par une procédure stockée qui vérifie information_schema.STATISTICS
--   et ne crée l'index que s'il est absent. Rejouer ce fichier est sans effet.
--
-- Import :
--   mysql --default-character-set=utf8mb4 -u <user> -p <database>
--   SOURCE /home/mediabot/mediabot_v3/install/migrations/20260706_channel_log_channel_ts.sql;
--
-- Validation :
--   perl tools/check_schema_drift.pl --conf=mediabot.conf --strict
--   perl tools/measure_channel_log.pl --conf=mediabot.conf   (avant/après)
-- =============================================================================

SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;
SET CHARACTER SET utf8mb4;

-- ---------------------------------------------------------------------------
-- Ajout idempotent de l'index composite (id_channel, ts).
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS `mb_add_channel_log_channel_ts`;

DELIMITER //
CREATE PROCEDURE `mb_add_channel_log_channel_ts`()
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.STATISTICS
        WHERE table_schema = DATABASE()
          AND table_name   = 'CHANNEL_LOG'
          AND index_name   = 'idx_channel_log_channel_ts'
    ) THEN
        ALTER TABLE `CHANNEL_LOG`
            ADD INDEX `idx_channel_log_channel_ts` (`id_channel`, `ts`);
        SELECT 'idx_channel_log_channel_ts created' AS result;
    ELSE
        SELECT 'idx_channel_log_channel_ts already present — nothing to do' AS result;
    END IF;
END //
DELIMITER ;

CALL `mb_add_channel_log_channel_ts`();

DROP PROCEDURE IF EXISTS `mb_add_channel_log_channel_ts`;
