-- =============================================================================
-- Migration P8 + P1 — version corrigée
-- Ordre : DROP FK → MODIFY colonnes → ADD FK → CREATE USER_HOSTMASK → INSERT
-- =============================================================================

SET names 'utf8mb4';

-- =============================================================================
-- Étape 1 : DROP toutes les FK existantes
-- =============================================================================

ALTER TABLE `ACTIONS_LOG`    DROP FOREIGN KEY `fk_actions_log_channel`;
ALTER TABLE `ACTIONS_LOG`    DROP FOREIGN KEY `fk_actions_log_user`;
ALTER TABLE `BADWORDS`       DROP FOREIGN KEY `fk_badwords_channel`;
ALTER TABLE `CHANNEL`        DROP FOREIGN KEY `fk_channel_owner`;
ALTER TABLE `CHANNEL_FLOOD`  DROP FOREIGN KEY `fk_channel_flood_channel`;
ALTER TABLE `CHANNEL_LOG`    DROP FOREIGN KEY `fk_channel_log_channel`;
ALTER TABLE `CHANNEL_SET`    DROP FOREIGN KEY `fk_channel_set_channel`;
ALTER TABLE `CHANNEL_SET`    DROP FOREIGN KEY `fk_channel_set_chanset_list`;
ALTER TABLE `HAILO_CHANNEL`  DROP FOREIGN KEY `fk_hailo_channel_channel`;
ALTER TABLE `MP3`            DROP FOREIGN KEY `fk_mp3_user`;
ALTER TABLE `PUBLIC_COMMANDS` DROP FOREIGN KEY `fk_public_commands_category`;
ALTER TABLE `PUBLIC_COMMANDS` DROP FOREIGN KEY `fk_public_commands_user`;
ALTER TABLE `QUOTES`         DROP FOREIGN KEY `fk_quotes_channel`;
ALTER TABLE `QUOTES`         DROP FOREIGN KEY `fk_quotes_user`;
ALTER TABLE `SERVERS`        DROP FOREIGN KEY `fk_servers_network`;
ALTER TABLE `USER`           DROP FOREIGN KEY `fk_user_level`;
ALTER TABLE `USER_CHANNEL`   DROP FOREIGN KEY `fk_user_channel_channel`;
ALTER TABLE `USER_CHANNEL`   DROP FOREIGN KEY `fk_user_channel_user`;

-- =============================================================================
-- Étape 2 : MODIFY colonnes → BIGINT UNSIGNED
-- =============================================================================

ALTER TABLE `ACTIONS_LOG`
    MODIFY COLUMN `id_actions_log` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    MODIFY COLUMN `id_user`        BIGINT UNSIGNED DEFAULT NULL,
    MODIFY COLUMN `id_channel`     BIGINT UNSIGNED DEFAULT NULL;

ALTER TABLE `BADWORDS`
    MODIFY COLUMN `id_badwords` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    MODIFY COLUMN `id_channel`  BIGINT UNSIGNED NOT NULL DEFAULT 0;

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
    MODIFY COLUMN `id_channel_set`  BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    MODIFY COLUMN `id_channel`      BIGINT UNSIGNED NOT NULL,
    MODIFY COLUMN `id_chanset_list` BIGINT UNSIGNED NOT NULL;

ALTER TABLE `CHANSET_LIST`
    MODIFY COLUMN `id_chanset_list` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT;

ALTER TABLE `CONSOLE`
    MODIFY COLUMN `id_console` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    MODIFY COLUMN `id_parent`  BIGINT UNSIGNED DEFAULT NULL;

ALTER TABLE `HAILO_CHANNEL`
    MODIFY COLUMN `id_hailo_channel` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    MODIFY COLUMN `id_channel`       BIGINT UNSIGNED NOT NULL;

ALTER TABLE `HAILO_EXCLUSION_NICK`
    MODIFY COLUMN `id_hailo_exclusion_nick` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT;

ALTER TABLE `IGNORES`
    MODIFY COLUMN `id_ignores` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    MODIFY COLUMN `id_channel` BIGINT UNSIGNED NOT NULL DEFAULT 0;

ALTER TABLE `MP3`
    MODIFY COLUMN `id_mp3`  BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    MODIFY COLUMN `id_user` BIGINT UNSIGNED NOT NULL;

ALTER TABLE `NETWORK`
    MODIFY COLUMN `id_network` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT;

ALTER TABLE `PUBLIC_COMMANDS`
    MODIFY COLUMN `id_public_commands`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    MODIFY COLUMN `id_user`                     BIGINT UNSIGNED DEFAULT NULL,
    MODIFY COLUMN `id_public_commands_category` BIGINT UNSIGNED NOT NULL,
    MODIFY COLUMN `hits`                        BIGINT UNSIGNED NOT NULL DEFAULT 0;

ALTER TABLE `PUBLIC_COMMANDS_CATEGORY`
    MODIFY COLUMN `id_public_commands_category` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT;

ALTER TABLE `QUOTES`
    MODIFY COLUMN `id_quotes`  BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    MODIFY COLUMN `id_channel` BIGINT UNSIGNED NOT NULL,
    MODIFY COLUMN `id_user`    BIGINT UNSIGNED NOT NULL;

ALTER TABLE `RESPONDERS`
    MODIFY COLUMN `id_responders` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    MODIFY COLUMN `id_channel`    BIGINT UNSIGNED NOT NULL DEFAULT 0,
    MODIFY COLUMN `hits`          BIGINT UNSIGNED NOT NULL DEFAULT 0,
    MODIFY COLUMN `chance`        BIGINT UNSIGNED NOT NULL DEFAULT 95;

ALTER TABLE `SERVERS`
    MODIFY COLUMN `id_server`  BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    MODIFY COLUMN `id_network` BIGINT UNSIGNED NOT NULL;

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

-- =============================================================================
-- Étape 3 : ADD FK — mêmes contraintes qu'avant
-- =============================================================================

ALTER TABLE `ACTIONS_LOG`
    ADD CONSTRAINT `fk_actions_log_channel`
        FOREIGN KEY (`id_channel`) REFERENCES `CHANNEL`(`id_channel`)
        ON DELETE SET NULL ON UPDATE CASCADE,
    ADD CONSTRAINT `fk_actions_log_user`
        FOREIGN KEY (`id_user`) REFERENCES `USER`(`id_user`)
        ON DELETE SET NULL ON UPDATE CASCADE;

ALTER TABLE `BADWORDS`
    ADD CONSTRAINT `fk_badwords_channel`
        FOREIGN KEY (`id_channel`) REFERENCES `CHANNEL`(`id_channel`)
        ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE `CHANNEL`
    ADD CONSTRAINT `fk_channel_owner`
        FOREIGN KEY (`id_user`) REFERENCES `USER`(`id_user`)
        ON DELETE SET NULL ON UPDATE CASCADE;

ALTER TABLE `CHANNEL_FLOOD`
    ADD CONSTRAINT `fk_channel_flood_channel`
        FOREIGN KEY (`id_channel`) REFERENCES `CHANNEL`(`id_channel`)
        ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE `CHANNEL_LOG`
    ADD CONSTRAINT `fk_channel_log_channel`
        FOREIGN KEY (`id_channel`) REFERENCES `CHANNEL`(`id_channel`)
        ON DELETE SET NULL ON UPDATE CASCADE;

ALTER TABLE `CHANNEL_SET`
    ADD CONSTRAINT `fk_channel_set_channel`
        FOREIGN KEY (`id_channel`) REFERENCES `CHANNEL`(`id_channel`)
        ON DELETE CASCADE ON UPDATE CASCADE,
    ADD CONSTRAINT `fk_channel_set_chanset_list`
        FOREIGN KEY (`id_chanset_list`) REFERENCES `CHANSET_LIST`(`id_chanset_list`)
        ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE `HAILO_CHANNEL`
    ADD CONSTRAINT `fk_hailo_channel_channel`
        FOREIGN KEY (`id_channel`) REFERENCES `CHANNEL`(`id_channel`)
        ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE `MP3`
    ADD CONSTRAINT `fk_mp3_user`
        FOREIGN KEY (`id_user`) REFERENCES `USER`(`id_user`)
        ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE `PUBLIC_COMMANDS`
    ADD CONSTRAINT `fk_public_commands_category`
        FOREIGN KEY (`id_public_commands_category`)
        REFERENCES `PUBLIC_COMMANDS_CATEGORY`(`id_public_commands_category`)
        ON DELETE RESTRICT ON UPDATE CASCADE,
    ADD CONSTRAINT `fk_public_commands_user`
        FOREIGN KEY (`id_user`) REFERENCES `USER`(`id_user`)
        ON DELETE SET NULL ON UPDATE CASCADE;

ALTER TABLE `QUOTES`
    ADD CONSTRAINT `fk_quotes_channel`
        FOREIGN KEY (`id_channel`) REFERENCES `CHANNEL`(`id_channel`)
        ON DELETE CASCADE ON UPDATE CASCADE,
    ADD CONSTRAINT `fk_quotes_user`
        FOREIGN KEY (`id_user`) REFERENCES `USER`(`id_user`)
        ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE `SERVERS`
    ADD CONSTRAINT `fk_servers_network`
        FOREIGN KEY (`id_network`) REFERENCES `NETWORK`(`id_network`)
        ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE `USER`
    ADD CONSTRAINT `fk_user_level`
        FOREIGN KEY (`id_user_level`) REFERENCES `USER_LEVEL`(`id_user_level`)
        ON DELETE RESTRICT ON UPDATE CASCADE;

ALTER TABLE `USER_CHANNEL`
    ADD CONSTRAINT `fk_user_channel_channel`
        FOREIGN KEY (`id_channel`) REFERENCES `CHANNEL`(`id_channel`)
        ON DELETE CASCADE ON UPDATE CASCADE,
    ADD CONSTRAINT `fk_user_channel_user`
        FOREIGN KEY (`id_user`) REFERENCES `USER`(`id_user`)
        ON DELETE CASCADE ON UPDATE CASCADE;

-- =============================================================================
-- Étape 4 : CREATE USER_HOSTMASK + migration depuis hostmasks_legacy
-- =============================================================================

CREATE TABLE IF NOT EXISTS `USER_HOSTMASK` (
    `id_user_hostmask` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `id_user`          BIGINT UNSIGNED NOT NULL,
    `hostmask`         VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL,
    `created_at`       DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id_user_hostmask`),
    INDEX `idx_user_hostmask_id_user`  (`id_user`),
    INDEX `idx_user_hostmask_hostmask` (`hostmask`),
    CONSTRAINT `fk_user_hostmask_user`
        FOREIGN KEY (`id_user`) REFERENCES `USER`(`id_user`)
        ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

INSERT INTO `USER_HOSTMASK` (`id_user`, `hostmask`)
SELECT
    u.id_user,
    TRIM(SUBSTRING_INDEX(SUBSTRING_INDEX(u.hostmasks_legacy, ',', n.n), ',', -1)) AS hostmask
FROM `USER` u
JOIN (
    SELECT 1 AS n UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5
    UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9 UNION SELECT 10
) n ON n.n <= 1 + LENGTH(u.hostmasks_legacy) - LENGTH(REPLACE(u.hostmasks_legacy, ',', ''))
WHERE u.hostmasks_legacy != ''
  AND TRIM(SUBSTRING_INDEX(SUBSTRING_INDEX(u.hostmasks_legacy, ',', n.n), ',', -1)) != '';

-- Validation
SELECT u.id_user, u.nickname, u.hostmasks_legacy,
       COUNT(uh.id_user_hostmask) AS nb_migrated
FROM USER u
LEFT JOIN USER_HOSTMASK uh ON uh.id_user = u.id_user
GROUP BY u.id_user
ORDER BY u.id_user;
