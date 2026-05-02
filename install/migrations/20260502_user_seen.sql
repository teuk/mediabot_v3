-- =============================================================================
-- Mediabot v3 migration
-- 2026-05-02 - USER_SEEN
--
-- Adds persistent seen tracking for IRC users.
--
-- Used for:
--   - !seen / seen command
--   - persisted last activity across bot restarts
--   - message / join / part / quit / nick tracking
--
-- Import recommendation:
--   mysql --default-character-set=utf8mb4 -u <user> -p <database>
--   SOURCE /home/mediabot/mediabot_v3/install/migrations/20260502_user_seen.sql;
-- =============================================================================

SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;
SET CHARACTER SET utf8mb4;

CREATE TABLE IF NOT EXISTS `USER_SEEN` (
  `nick`        VARCHAR(64)   CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL,
  `channel`     VARCHAR(64)   CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '',
  `userhost`    VARCHAR(128)  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '',
  `event_type`  ENUM('message','join','part','quit','nick') NOT NULL DEFAULT 'message',
  `last_msg`    VARCHAR(512)  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `new_nick`    VARCHAR(64)   CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `seen_at`     DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

  PRIMARY KEY (`nick`),
  KEY `idx_user_seen_seen_at` (`seen_at`),
  KEY `idx_user_seen_channel` (`channel`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Last known activity for each nick - one row per nick';
