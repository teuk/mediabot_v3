-- 20260816_achievements_db.sql
-- mb646 — durable DB-backed achievements with resilient IRC identity aliases.
--
-- Safe/idempotent structural migration. Existing JSON state is imported by
-- Mediabot on first startup after these tables exist; the source JSON is then
-- renamed to achievements.json.migrated-<timestamp>.

SET NAMES utf8mb4;

CREATE TABLE IF NOT EXISTS `ACHIEVEMENT_PROFILE` (
  `id_achievement_profile` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `id_channel`             BIGINT UNSIGNED NOT NULL,
  `id_user`                BIGINT UNSIGNED DEFAULT NULL,
  `display_nick`           VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL,
  `created_at`             DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `last_seen_at`           DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id_achievement_profile`),
  UNIQUE KEY `uq_achievement_profile_user_channel` (`id_user`, `id_channel`),
  KEY `idx_achievement_profile_channel` (`id_channel`),
  KEY `idx_achievement_profile_display_nick` (`display_nick`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `ACHIEVEMENT_IDENTITY` (
  `id_achievement_identity` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `id_achievement_profile`  BIGINT UNSIGNED NOT NULL,
  `id_channel`              BIGINT UNSIGNED NOT NULL,
  `nick`                    VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL,
  `userhost`                VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '',
  `first_seen_at`           DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `last_seen_at`            DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id_achievement_identity`),
  UNIQUE KEY `uq_achievement_identity_triplet` (`id_channel`, `nick`, `userhost`),
  KEY `idx_achievement_identity_profile` (`id_achievement_profile`),
  KEY `idx_achievement_identity_userhost` (`id_channel`, `userhost`),
  KEY `idx_achievement_identity_nick` (`id_channel`, `nick`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `ACHIEVEMENT_UNLOCK` (
  `id_achievement_unlock`  BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `id_achievement_profile` BIGINT UNSIGNED NOT NULL,
  `achievement_id`         VARCHAR(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL,
  `unlocked_at`            DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id_achievement_unlock`),
  UNIQUE KEY `uq_achievement_unlock_profile_id` (`id_achievement_profile`, `achievement_id`),
  KEY `idx_achievement_unlock_achievement` (`achievement_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `ACHIEVEMENT_PROGRESS` (
  `id_achievement_progress` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `id_achievement_profile`  BIGINT UNSIGNED NOT NULL,
  `progress_kind`           VARCHAR(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL,
  `progress_value`          BIGINT UNSIGNED NOT NULL DEFAULT 0,
  `updated_at`              DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id_achievement_progress`),
  UNIQUE KEY `uq_achievement_progress_profile_kind` (`id_achievement_profile`, `progress_kind`),
  KEY `idx_achievement_progress_kind` (`progress_kind`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
