-- =============================================================================
-- mediabot_v3 migration — fun commands support tables
-- Date: 2026-05-12
--
-- Usage from mysql/mariadb client:
--   SET NAMES utf8mb4;
--   SOURCE /path/to/mediabot_fun_commands_migration_20260512.sql;
-- =============================================================================

SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;
SET FOREIGN_KEY_CHECKS = 0;

CREATE TABLE IF NOT EXISTS `REMINDERS` (
  `id_reminder` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `id_channel`  BIGINT UNSIGNED NOT NULL,
  `from_nick`   VARCHAR(64) NOT NULL,
  `to_nick`     VARCHAR(64) NOT NULL,
  `message`     VARCHAR(512) NOT NULL,
  `created_at`  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `delivered`   TINYINT UNSIGNED NOT NULL DEFAULT 0,
  PRIMARY KEY (`id_reminder`),
  KEY `idx_reminders_channel_to_delivered` (`id_channel`, `to_nick`, `delivered`),
  KEY `idx_reminders_from_channel_delivered` (`from_nick`, `id_channel`, `delivered`),
  KEY `idx_reminders_created_at` (`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `BOT_ALIAS` (
  `id_alias`   BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `alias`      VARCHAR(32) NOT NULL,
  `command`    VARCHAR(64) NOT NULL,
  `created_by` VARCHAR(64) DEFAULT NULL,
  `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id_alias`),
  UNIQUE KEY `uniq_bot_alias_alias` (`alias`),
  KEY `idx_bot_alias_command` (`command`),
  KEY `idx_bot_alias_created_by` (`created_by`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `KARMA` (
  `id_karma`   BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `id_channel` BIGINT UNSIGNED NOT NULL,
  `nick`       VARCHAR(64) NOT NULL,
  `score`      INT NOT NULL DEFAULT 0,
  `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id_karma`),
  UNIQUE KEY `uniq_karma_channel_nick` (`id_channel`, `nick`),
  KEY `idx_karma_channel_score` (`id_channel`, `score`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

SET FOREIGN_KEY_CHECKS = 1;

-- Add foreign keys only if they do not already exist.
SET @db := DATABASE();

SET @sql := (
  SELECT IF(COUNT(*) = 0,
    'ALTER TABLE `REMINDERS` ADD CONSTRAINT `fk_reminders_channel` FOREIGN KEY (`id_channel`) REFERENCES `CHANNEL` (`id_channel`) ON DELETE CASCADE ON UPDATE CASCADE',
    'SELECT "fk_reminders_channel already exists"')
  FROM information_schema.TABLE_CONSTRAINTS
  WHERE CONSTRAINT_SCHEMA = @db
    AND TABLE_NAME = 'REMINDERS'
    AND CONSTRAINT_NAME = 'fk_reminders_channel'
);
PREPARE stmt FROM @sql; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @sql := (
  SELECT IF(COUNT(*) = 0,
    'ALTER TABLE `KARMA` ADD CONSTRAINT `fk_karma_channel` FOREIGN KEY (`id_channel`) REFERENCES `CHANNEL` (`id_channel`) ON DELETE CASCADE ON UPDATE CASCADE',
    'SELECT "fk_karma_channel already exists"')
  FROM information_schema.TABLE_CONSTRAINTS
  WHERE CONSTRAINT_SCHEMA = @db
    AND TABLE_NAME = 'KARMA'
    AND CONSTRAINT_NAME = 'fk_karma_channel'
);
PREPARE stmt FROM @sql; EXECUTE stmt; DEALLOCATE PREPARE stmt;

