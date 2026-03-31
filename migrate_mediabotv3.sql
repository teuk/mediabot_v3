-- =============================================================================
-- Mediabot v3 — Database Migration Script
-- Generated: 2026-03-29
-- MariaDB 10.11+
--
-- Run as: sudo mysql mediabotv3 < migrate_mediabotv3.sql
--
-- Corrections in order:
--   P3  WEBLOG.password         → drop column (plaintext password in logs)
--   P7  USER.auth               → TINYINT(1)
--   P4  CHANNEL_LOG.publictext  → TEXT
--   P6  Missing indexes         → 12 indexes on frequently joined columns
--   P5  Mixed charsets in USER  → utf8mb4 throughout
--   P2  Foreign keys            → explicit FK constraints
--   P8  bigint(20) display width → BIGINT UNSIGNED (deprecated display width)
--   P1  USER.hostmasks CSV      → new table USER_HOSTMASK + data migration
-- =============================================================================

SET FOREIGN_KEY_CHECKS = 0;
SET sql_mode = 'NO_AUTO_VALUE_ON_ZERO';

-- =============================================================================
-- P3 — Drop WEBLOG.password (plaintext password stored in web login logs)
-- =============================================================================
ALTER TABLE `WEBLOG`
    DROP COLUMN `password`;

-- =============================================================================
-- P7 — USER.auth: INT(11) → TINYINT(1) DEFAULT 0
-- =============================================================================
ALTER TABLE `USER`
    MODIFY COLUMN `auth` TINYINT(1) NOT NULL DEFAULT 0;

-- =============================================================================
-- P4 — CHANNEL_LOG.publictext: VARCHAR(400) → TEXT
--       IRC messages can be up to 512 bytes; TEXT handles that safely
-- =============================================================================
ALTER TABLE `CHANNEL_LOG`
    MODIFY COLUMN `publictext` TEXT DEFAULT NULL;

-- =============================================================================
-- P6 — Missing indexes on frequently joined/filtered columns
-- =============================================================================

-- ACTIONS_LOG
ALTER TABLE `ACTIONS_LOG`
    ADD INDEX `idx_actions_log_id_channel` (`id_channel`),
    ADD INDEX `idx_actions_log_id_user`    (`id_user`),
    ADD INDEX `idx_actions_log_ts`         (`ts`);

-- CHANNEL_SET
ALTER TABLE `CHANNEL_SET`
    ADD INDEX `idx_channel_set_id_channel`      (`id_channel`),
    ADD INDEX `idx_channel_set_id_chanset_list` (`id_chanset_list`);

-- USER_CHANNEL
ALTER TABLE `USER_CHANNEL`
    ADD INDEX `idx_user_channel_id_user`    (`id_user`),
    ADD INDEX `idx_user_channel_id_channel` (`id_channel`);

-- CHANNEL_LOG
ALTER TABLE `CHANNEL_LOG`
    ADD INDEX `idx_channel_log_id_channel` (`id_channel`),
    ADD INDEX `idx_channel_log_ts`         (`ts`);

-- BADWORDS
ALTER TABLE `BADWORDS`
    ADD INDEX `idx_badwords_id_channel` (`id_channel`);

-- IGNORES
ALTER TABLE `IGNORES`
    ADD INDEX `idx_ignores_id_channel` (`id_channel`);

-- QUOTES
ALTER TABLE `QUOTES`
    ADD INDEX `idx_quotes_id_channel` (`id_channel`),
    ADD INDEX `idx_quotes_id_user`    (`id_user`);

-- RESPONDERS
ALTER TABLE `RESPONDERS`
    ADD INDEX `idx_responders_id_channel` (`id_channel`);

-- MP3
ALTER TABLE `MP3`
    ADD INDEX `idx_mp3_id_user` (`id_user`);

-- HAILO_CHANNEL
ALTER TABLE `HAILO_CHANNEL`
    ADD INDEX `idx_hailo_channel_id_channel` (`id_channel`);

-- =============================================================================
-- P5 — Mixed charsets in USER table: latin1/utf8mb3 → utf8mb4
--       Nicknames, hostmasks, passwords, info fields all need proper Unicode
-- =============================================================================
ALTER TABLE `USER`
    MODIFY COLUMN `hostmasks`  VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '',
    MODIFY COLUMN `nickname`   VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '',
    MODIFY COLUMN `password`   VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
    MODIFY COLUMN `username`   VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
    MODIFY COLUMN `info1`      VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
    MODIFY COLUMN `info2`      VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL;

ALTER TABLE `USER_LEVEL`
    MODIFY COLUMN `description` VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL;

ALTER TABLE `USER_CHANNEL`
    MODIFY COLUMN `greet`    VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
    MODIFY COLUMN `automode` VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT 'NONE';

-- =============================================================================
-- P2 — Foreign Key constraints
--       Using ON DELETE RESTRICT by default — explicit CASCADE/SET NULL where safe
-- =============================================================================

-- USER_CHANNEL → USER and CHANNEL
ALTER TABLE `USER_CHANNEL`
    ADD CONSTRAINT `fk_user_channel_user`
        FOREIGN KEY (`id_user`) REFERENCES `USER`(`id_user`)
        ON DELETE CASCADE ON UPDATE CASCADE,
    ADD CONSTRAINT `fk_user_channel_channel`
        FOREIGN KEY (`id_channel`) REFERENCES `CHANNEL`(`id_channel`)
        ON DELETE CASCADE ON UPDATE CASCADE;

-- CHANNEL_SET → CHANNEL and CHANSET_LIST
ALTER TABLE `CHANNEL_SET`
    ADD CONSTRAINT `fk_channel_set_channel`
        FOREIGN KEY (`id_channel`) REFERENCES `CHANNEL`(`id_channel`)
        ON DELETE CASCADE ON UPDATE CASCADE,
    ADD CONSTRAINT `fk_channel_set_chanset_list`
        FOREIGN KEY (`id_chanset_list`) REFERENCES `CHANSET_LIST`(`id_chanset_list`)
        ON DELETE CASCADE ON UPDATE CASCADE;

-- CHANNEL → USER (owner) — SET NULL on delete (channel survives if owner deleted)
ALTER TABLE `CHANNEL`
    ADD CONSTRAINT `fk_channel_owner`
        FOREIGN KEY (`id_user`) REFERENCES `USER`(`id_user`)
        ON DELETE SET NULL ON UPDATE CASCADE;

-- USER → USER_LEVEL
ALTER TABLE `USER`
    ADD CONSTRAINT `fk_user_level`
        FOREIGN KEY (`id_user_level`) REFERENCES `USER_LEVEL`(`id_user_level`)
        ON DELETE RESTRICT ON UPDATE CASCADE;

-- ACTIONS_LOG → USER and CHANNEL (SET NULL — log survives if user/channel deleted)
ALTER TABLE `ACTIONS_LOG`
    ADD CONSTRAINT `fk_actions_log_user`
        FOREIGN KEY (`id_user`) REFERENCES `USER`(`id_user`)
        ON DELETE SET NULL ON UPDATE CASCADE,
    ADD CONSTRAINT `fk_actions_log_channel`
        FOREIGN KEY (`id_channel`) REFERENCES `CHANNEL`(`id_channel`)
        ON DELETE SET NULL ON UPDATE CASCADE;

-- BADWORDS → CHANNEL
ALTER TABLE `BADWORDS`
    ADD CONSTRAINT `fk_badwords_channel`
        FOREIGN KEY (`id_channel`) REFERENCES `CHANNEL`(`id_channel`)
        ON DELETE CASCADE ON UPDATE CASCADE;

-- IGNORES → CHANNEL (id_channel=0 means global — skip FK for those)
-- Note: IGNORES.id_channel can be 0 (global ignore), so FK not applicable as-is

-- QUOTES → CHANNEL and USER
ALTER TABLE `QUOTES`
    ADD CONSTRAINT `fk_quotes_channel`
        FOREIGN KEY (`id_channel`) REFERENCES `CHANNEL`(`id_channel`)
        ON DELETE CASCADE ON UPDATE CASCADE,
    ADD CONSTRAINT `fk_quotes_user`
        FOREIGN KEY (`id_user`) REFERENCES `USER`(`id_user`)
        ON DELETE CASCADE ON UPDATE CASCADE;

-- HAILO_CHANNEL → CHANNEL
ALTER TABLE `HAILO_CHANNEL`
    ADD CONSTRAINT `fk_hailo_channel_channel`
        FOREIGN KEY (`id_channel`) REFERENCES `CHANNEL`(`id_channel`)
        ON DELETE CASCADE ON UPDATE CASCADE;

-- CHANNEL_LOG → CHANNEL (SET NULL — logs survive if channel deleted)
ALTER TABLE `CHANNEL_LOG`
    ADD CONSTRAINT `fk_channel_log_channel`
        FOREIGN KEY (`id_channel`) REFERENCES `CHANNEL`(`id_channel`)
        ON DELETE SET NULL ON UPDATE CASCADE;

-- PUBLIC_COMMANDS → USER and CATEGORY
ALTER TABLE `PUBLIC_COMMANDS`
    ADD CONSTRAINT `fk_public_commands_user`
        FOREIGN KEY (`id_user`) REFERENCES `USER`(`id_user`)
        ON DELETE SET NULL ON UPDATE CASCADE,
    ADD CONSTRAINT `fk_public_commands_category`
        FOREIGN KEY (`id_public_commands_category`)
        REFERENCES `PUBLIC_COMMANDS_CATEGORY`(`id_public_commands_category`)
        ON DELETE RESTRICT ON UPDATE CASCADE;

-- SERVERS → NETWORK
ALTER TABLE `SERVERS`
    ADD CONSTRAINT `fk_servers_network`
        FOREIGN KEY (`id_network`) REFERENCES `NETWORK`(`id_network`)
        ON DELETE CASCADE ON UPDATE CASCADE;

-- MP3 → USER
ALTER TABLE `MP3`
    ADD CONSTRAINT `fk_mp3_user`
        FOREIGN KEY (`id_user`) REFERENCES `USER`(`id_user`)
        ON DELETE CASCADE ON UPDATE CASCADE;

-- CHANNEL_FLOOD → CHANNEL
ALTER TABLE `CHANNEL_FLOOD`
    ADD CONSTRAINT `fk_channel_flood_channel`
        FOREIGN KEY (`id_channel`) REFERENCES `CHANNEL`(`id_channel`)
        ON DELETE CASCADE ON UPDATE CASCADE;

-- RESPONDERS → CHANNEL (id_channel=0 means global — same issue as IGNORES)
-- Note: skip FK on RESPONDERS for same reason as IGNORES

-- =============================================================================
-- P8 — bigint(20) display width → BIGINT UNSIGNED
--       Display width for integer types is deprecated since MariaDB 10.4
--       Using UNSIGNED allows 0..2^64-1 instead of -2^63..2^63-1 for IDs
--       NOTE: only safe to apply if no negative IDs exist (they shouldn't for PKs)
-- =============================================================================

ALTER TABLE `ACTIONS_LOG`
    MODIFY COLUMN `id_actions_log` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    MODIFY COLUMN `id_user`        BIGINT UNSIGNED DEFAULT NULL,
    MODIFY COLUMN `id_channel`     BIGINT UNSIGNED DEFAULT NULL;

ALTER TABLE `ACTIONS_QUEUE`
    MODIFY COLUMN `id_actions_queue` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT;

ALTER TABLE `BADWORDS`
    MODIFY COLUMN `id_badwords`  BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    MODIFY COLUMN `id_channel`   BIGINT UNSIGNED NOT NULL DEFAULT 0;

ALTER TABLE `CHANNEL`
    MODIFY COLUMN `id_channel` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    MODIFY COLUMN `id_user`    BIGINT UNSIGNED DEFAULT NULL;

ALTER TABLE `CHANNEL_FLOOD`
    MODIFY COLUMN `id_channel_flood` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    MODIFY COLUMN `id_channel`       BIGINT UNSIGNED NOT NULL;

ALTER TABLE `CHANNEL_LOG`
    MODIFY COLUMN `id_channel_log` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    MODIFY COLUMN `id_channel`     BIGINT UNSIGNED DEFAULT NULL;

ALTER TABLE `CHANNEL_PURGED`
    MODIFY COLUMN `id_channel_purged` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    MODIFY COLUMN `id_channel`        BIGINT UNSIGNED NOT NULL;

ALTER TABLE `CHANNEL_SET`
    MODIFY COLUMN `id_channel_set`   BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    MODIFY COLUMN `id_channel`       BIGINT UNSIGNED NOT NULL,
    MODIFY COLUMN `id_chanset_list`  BIGINT UNSIGNED NOT NULL;

ALTER TABLE `CHANSET_LIST`
    MODIFY COLUMN `id_chanset_list` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT;

ALTER TABLE `HAILO_CHANNEL`
    MODIFY COLUMN `id_hailo_channel` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    MODIFY COLUMN `id_channel`       BIGINT UNSIGNED NOT NULL;

ALTER TABLE `HAILO_EXCLUSION_NICK`
    MODIFY COLUMN `id_hailo_exclusion_nick` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT;

ALTER TABLE `IGNORES`
    MODIFY COLUMN `id_ignores`  BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    MODIFY COLUMN `id_channel`  BIGINT UNSIGNED NOT NULL DEFAULT 0;

ALTER TABLE `MP3`
    MODIFY COLUMN `id_mp3`    BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    MODIFY COLUMN `id_user`   BIGINT UNSIGNED NOT NULL;

ALTER TABLE `NETWORK`
    MODIFY COLUMN `id_network` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT;

ALTER TABLE `PUBLIC_COMMANDS`
    MODIFY COLUMN `id_public_commands`           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    MODIFY COLUMN `id_user`                      BIGINT UNSIGNED DEFAULT NULL,
    MODIFY COLUMN `id_public_commands_category`  BIGINT UNSIGNED NOT NULL,
    MODIFY COLUMN `hits`                         BIGINT UNSIGNED NOT NULL DEFAULT 0;

ALTER TABLE `PUBLIC_COMMANDS_CATEGORY`
    MODIFY COLUMN `id_public_commands_category` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT;

ALTER TABLE `QUOTES`
    MODIFY COLUMN `id_quotes`   BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    MODIFY COLUMN `id_channel`  BIGINT UNSIGNED NOT NULL,
    MODIFY COLUMN `id_user`     BIGINT UNSIGNED NOT NULL;

ALTER TABLE `RESPONDERS`
    MODIFY COLUMN `id_responders` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    MODIFY COLUMN `id_channel`    BIGINT UNSIGNED NOT NULL DEFAULT 0,
    MODIFY COLUMN `hits`          BIGINT UNSIGNED NOT NULL DEFAULT 0,
    MODIFY COLUMN `chance`        BIGINT UNSIGNED NOT NULL DEFAULT 95;

ALTER TABLE `SERVERS`
    MODIFY COLUMN `id_server`   BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    MODIFY COLUMN `id_network`  BIGINT UNSIGNED NOT NULL;

ALTER TABLE `TIMERS`
    MODIFY COLUMN `id_timers` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT;

ALTER TABLE `TIMEZONE`
    MODIFY COLUMN `id_timezone` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT;

ALTER TABLE `USER`
    MODIFY COLUMN `id_user`       BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    MODIFY COLUMN `id_user_level` BIGINT UNSIGNED NOT NULL;

ALTER TABLE `USER_CHANNEL`
    MODIFY COLUMN `id_user_channel` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    MODIFY COLUMN `id_user`         BIGINT UNSIGNED NOT NULL,
    MODIFY COLUMN `id_channel`      BIGINT UNSIGNED NOT NULL,
    MODIFY COLUMN `level`           BIGINT UNSIGNED NOT NULL DEFAULT 0;

ALTER TABLE `USER_LEVEL`
    MODIFY COLUMN `id_user_level` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT;

ALTER TABLE `WEBLOG`
    MODIFY COLUMN `id_weblog` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT;

ALTER TABLE `YOMOMMA`
    MODIFY COLUMN `id_yomomma` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT;

ALTER TABLE `CONSOLE`
    MODIFY COLUMN `id_console` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    MODIFY COLUMN `id_parent`  BIGINT UNSIGNED DEFAULT NULL;

-- =============================================================================
-- P1 — USER.hostmasks CSV → table USER_HOSTMASK + data migration
--
--   Current: USER.hostmasks = "*nick@*.domain.com,*nick2@*"  (CSV)
--   New:     USER_HOSTMASK(id_user_hostmask, id_user, hostmask, created_at)
--
--   Migration splits existing CSV values into individual rows.
--   The original column is kept temporarily as `hostmasks_legacy` then dropped.
-- =============================================================================

-- 1. Create new table
CREATE TABLE IF NOT EXISTS `USER_HOSTMASK` (
    `id_user_hostmask` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `id_user`          BIGINT UNSIGNED NOT NULL,
    `hostmask`         VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL,
    `created_at`       DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id_user_hostmask`),
    INDEX `idx_user_hostmask_id_user` (`id_user`),
    INDEX `idx_user_hostmask_hostmask` (`hostmask`),
    CONSTRAINT `fk_user_hostmask_user`
        FOREIGN KEY (`id_user`) REFERENCES `USER`(`id_user`)
        ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 2. Migrate existing CSV hostmasks
--    MariaDB doesn't have a native string split, so we use a recursive approach
--    with a numbers table trick limited to a reasonable depth (max 10 hostmasks)
INSERT INTO `USER_HOSTMASK` (`id_user`, `hostmask`)
SELECT
    u.id_user,
    TRIM(SUBSTRING_INDEX(SUBSTRING_INDEX(u.hostmasks, ',', n.n), ',', -1)) AS hostmask
FROM `USER` u
JOIN (
    SELECT 1 AS n UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5
    UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9 UNION SELECT 10
) n ON n.n <= 1 + LENGTH(u.hostmasks) - LENGTH(REPLACE(u.hostmasks, ',', ''))
WHERE u.hostmasks != ''
  AND TRIM(SUBSTRING_INDEX(SUBSTRING_INDEX(u.hostmasks, ',', n.n), ',', -1)) != '';

-- 3. Rename original column to legacy (kept as fallback, drop manually after validation)
ALTER TABLE `USER`
    CHANGE COLUMN `hostmasks` `hostmasks_legacy`
    VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT ''
    COMMENT 'Migrated to USER_HOSTMASK — safe to DROP after validation';

-- =============================================================================
SET FOREIGN_KEY_CHECKS = 1;

-- =============================================================================
-- Post-migration validation queries (run manually to verify)
-- =============================================================================
-- SELECT COUNT(*) FROM USER_HOSTMASK;
-- SELECT u.id_user, u.nickname, u.hostmasks_legacy, COUNT(uh.id_user_hostmask) as migrated
--   FROM USER u LEFT JOIN USER_HOSTMASK uh ON uh.id_user = u.id_user
--   GROUP BY u.id_user ORDER BY u.id_user;
-- =============================================================================
