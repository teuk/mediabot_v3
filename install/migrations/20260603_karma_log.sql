-- =============================================================================
-- Mediabot v3 migration
-- 2026-06-03 - KARMA_LOG
--
-- KARMA_LOG: persistent logging of karma votes (++/--) across sessions.
--
--   Used for:
--     - !karmahist [nick]   — vote history (I8 / mbKarmaHist_ctx)
--     - Prometheus          — future mediabot_karmalog_entries_total metric
--
--   Without this table, mbKarmaHist_ctx silently falls back to the in-memory
--   ring buffer (_karma_log, max 500 entries) and displays the [memory] badge
--   in the header.
--
-- Safe for existing databases: CREATE TABLE IF NOT EXISTS.
--
-- Import recommendation:
--   mysql --default-character-set=utf8mb4 -u <user> -p <database>
--   SOURCE /home/mediabot/mediabot_v3/install/migrations/20260603_karma_log.sql;
-- =============================================================================

SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;
SET CHARACTER SET utf8mb4;
SET FOREIGN_KEY_CHECKS = 0;

-- ---------------------------------------------------------------------------
-- KARMA_LOG
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `KARMA_LOG` (
  `id_karma_log` BIGINT UNSIGNED     NOT NULL AUTO_INCREMENT,

  `id_channel`   BIGINT UNSIGNED     NOT NULL,

  `nick`         VARCHAR(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL
                 COMMENT 'Nick whose karma changed (lowercase)',

  `delta`        TINYINT             NOT NULL COMMENT '+1 or -1',

  `from_nick`    VARCHAR(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL
                 COMMENT 'Nick who cast the vote (lowercase)',

  `score`        BIGINT              NOT NULL DEFAULT 0
                 COMMENT 'Karma score after the vote',

  `ts`           DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP
                 COMMENT 'Vote timestamp',

  PRIMARY KEY (`id_karma_log`),

  KEY `idx_karma_log_channel_nick` (`id_channel`, `nick`),
  KEY `idx_karma_log_channel_ts`   (`id_channel`, `ts`),
  KEY `idx_karma_log_from_nick`    (`from_nick`)

) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Persistent history of karma votes per channel (I8)';

SET FOREIGN_KEY_CHECKS = 1;

-- ---------------------------------------------------------------------------
-- FOREIGN KEY — added conditionally (idempotent)
-- ---------------------------------------------------------------------------

SET @db := DATABASE();

-- fk_karma_log_channel
SET @sql := (
  SELECT IF(COUNT(*) = 0,
    'ALTER TABLE `KARMA_LOG` ADD CONSTRAINT `fk_karma_log_channel` FOREIGN KEY (`id_channel`) REFERENCES `CHANNEL` (`id_channel`) ON DELETE CASCADE ON UPDATE CASCADE',
    'SELECT "fk_karma_log_channel already exists"')
  FROM information_schema.TABLE_CONSTRAINTS
  WHERE CONSTRAINT_SCHEMA = @db
    AND TABLE_NAME        = 'KARMA_LOG'
    AND CONSTRAINT_NAME   = 'fk_karma_log_channel'
);
PREPARE stmt FROM @sql; EXECUTE stmt; DEALLOCATE PREPARE stmt;