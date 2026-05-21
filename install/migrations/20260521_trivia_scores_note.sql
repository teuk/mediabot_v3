-- =============================================================================
-- Mediabot v3 migration
-- 2026-05-21 - TRIVIA_SCORES + NOTE
--
-- TRIVIA_SCORES: persistent trivia score tracking across sessions.
--
--   Used for:
--     - !triviatop [n]     — hall of fame leaderboard (AA1)
--     - !triviareset <nick> — reset a nick's score (BB10)
--     - !trivia             — each correct answer is upserted (score + 1)
--     - Prometheus          — mediabot_trivia_db_saves_total counter
--
-- NOTE: persistent user notes across sessions.
--
--   Used for:
--     - !note <message>    — save a note (BB1)
--     - !notes             — list notes (loads from DB after restart)
--     - !notes del <id>    — delete a note (removes from DB)
--
-- Safe for existing databases: uses CREATE TABLE IF NOT EXISTS and
-- conditional FOREIGN KEY addition via information_schema.
--
-- Import recommendation:
--   mysql --default-character-set=utf8mb4 -u <user> -p <database>
--   SOURCE /home/mediabot/mediabot_v3/install/migrations/20260521_trivia_scores_note.sql;
-- =============================================================================

SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;
SET CHARACTER SET utf8mb4;
SET FOREIGN_KEY_CHECKS = 0;

-- ---------------------------------------------------------------------------
-- TRIVIA_SCORES
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `TRIVIA_SCORES` (
  `id_channel`   BIGINT UNSIGNED NOT NULL,

  `nick`         VARCHAR(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL,

  `score`        BIGINT UNSIGNED NOT NULL DEFAULT 0,

  `last_correct` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
                          ON UPDATE CURRENT_TIMESTAMP,

  PRIMARY KEY (`id_channel`, `nick`),

  KEY `idx_trivia_scores_channel_score` (`id_channel`, `score`)

) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Persistent trivia scores per nick per channel (AA1)';

-- ---------------------------------------------------------------------------
-- NOTE
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `NOTE` (
  `id_note`    BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,

  `nick`       VARCHAR(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL,

  `text`       VARCHAR(256) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL,

  `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,

  PRIMARY KEY (`id_note`),

  KEY `idx_note_nick` (`nick`)

) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Persistent user notes saved via !note command (BB1)';

SET FOREIGN_KEY_CHECKS = 1;

-- ---------------------------------------------------------------------------
-- FOREIGN KEYS — added conditionally (idempotent)
-- ---------------------------------------------------------------------------

SET @db := DATABASE();

-- fk_trivia_scores_channel
SET @sql := (
  SELECT IF(COUNT(*) = 0,
    'ALTER TABLE `TRIVIA_SCORES` ADD CONSTRAINT `fk_trivia_scores_channel` FOREIGN KEY (`id_channel`) REFERENCES `CHANNEL` (`id_channel`) ON DELETE CASCADE ON UPDATE CASCADE',
    'SELECT "fk_trivia_scores_channel already exists"')
  FROM information_schema.TABLE_CONSTRAINTS
  WHERE CONSTRAINT_SCHEMA = @db
    AND TABLE_NAME        = 'TRIVIA_SCORES'
    AND CONSTRAINT_NAME   = 'fk_trivia_scores_channel'
);
PREPARE stmt FROM @sql; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- NOTE has no foreign key (nick is not linked to USER — notes are nick-scoped only)
