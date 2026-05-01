-- =============================================================================
-- Mediabot v3 migration
-- 2026-05-02 - CHANNEL_BAN
--
-- Adds persistent channel bans with optional expiration and ban levels.
--
-- Used for:
--   - ban / kickban commands
--   - timed bans
--   - ban level enforcement
--   - automatic unban on expiration
--
-- Import recommendation:
--   mysql --default-character-set=utf8mb4 -u <user> -p <database>
--   SOURCE /home/mediabot/mediabot_v3/install/migrations/20260502_channel_ban.sql;
-- =============================================================================

SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;
SET CHARACTER SET utf8mb4;

CREATE TABLE IF NOT EXISTS `CHANNEL_BAN` (
  `id_channel_ban` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT,

  `id_channel` bigint(20) UNSIGNED NOT NULL,

  `mask` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL,

  `ban_level` int(10) UNSIGNED NOT NULL DEFAULT 75,

  `reason` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,

  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_by_nick` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),

  `expires_at` datetime DEFAULT NULL,

  `active` tinyint(1) NOT NULL DEFAULT 1,

  `removed_by` bigint(20) UNSIGNED DEFAULT NULL,
  `removed_by_nick` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `removed_at` datetime DEFAULT NULL,
  `remove_reason` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,

  `source` varchar(32) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT 'irc',

  PRIMARY KEY (`id_channel_ban`),

  KEY `idx_channel_ban_channel_active` (`id_channel`, `active`),
  KEY `idx_channel_ban_channel_mask` (`id_channel`, `mask`),
  KEY `idx_channel_ban_active_expires` (`active`, `expires_at`),
  KEY `idx_channel_ban_level` (`ban_level`),
  KEY `idx_channel_ban_created_by` (`created_by`),
  KEY `idx_channel_ban_removed_by` (`removed_by`),

  CONSTRAINT `fk_channel_ban_channel`
    FOREIGN KEY (`id_channel`)
    REFERENCES `CHANNEL` (`id_channel`)
    ON DELETE CASCADE
    ON UPDATE CASCADE,

  CONSTRAINT `fk_channel_ban_created_by`
    FOREIGN KEY (`created_by`)
    REFERENCES `USER` (`id_user`)
    ON DELETE SET NULL
    ON UPDATE CASCADE,

  CONSTRAINT `fk_channel_ban_removed_by`
    FOREIGN KEY (`removed_by`)
    REFERENCES `USER` (`id_user`)
    ON DELETE SET NULL
    ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
