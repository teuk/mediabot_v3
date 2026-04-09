-- =============================================================================
--  mediabot_v3 — Full database schema
--  Updated: 2026-04 — Schema corrections vs production DB
--
--  Changes from previous version:
--   - USER.hostmasks removed → replaced by USER_HOSTMASK table
--   - USER.auth: int(11) → TINYINT(1)
--   - USER.*: BIGINT UNSIGNED + utf8mb4
--   - USER_HOSTMASK: new table (hostmask storage, FK to USER)
--   - CHANNEL_LOG.publictext: varchar(400) → TEXT
--   - WEBLOG.password: removed
--   - 19 foreign keys added (CASCADE / SET NULL)
--   - 12 indexes added
--   - All bigint(20) PKs → BIGINT UNSIGNED where appropriate
--   - CHANSET_LIST + CHANNEL_SET: added
--   [2026-04] RESPONDERS: corrected columns (command/response → responder/answer/chance/hits)
--   [2026-04] TIMEZONE: corrected column name (timezone → tz, aligned with prod and code)
--   [2026-04] TIMERS: removed undeployed columns (id_channel, enabled) — kept as comments
--   [2026-04] PUBLIC_COMMANDS.active: already present in schema — apply to prod:
--             ALTER TABLE PUBLIC_COMMANDS ADD COLUMN active TINYINT(1) NOT NULL DEFAULT 1;
--
--  Usage:
--   mysql -u root -p < install/mediabot.sql
--   (or sourced by install/db_install.sh and install/configure.pl)
-- =============================================================================

SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;
SET CHARACTER SET utf8mb4;
SET SQL_MODE = "NO_AUTO_VALUE_ON_ZERO";
SET AUTOCOMMIT = 0;
START TRANSACTION;
SET time_zone = "+00:00";
SET FOREIGN_KEY_CHECKS = 0;

-- ---------------------------------------------------------------------------
-- ACTIONS_LOG
-- ---------------------------------------------------------------------------
CREATE TABLE `ACTIONS_LOG` (
  `id_actions_log` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `ts`             TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  `id_user`        BIGINT UNSIGNED DEFAULT NULL,
  `id_channel`     BIGINT UNSIGNED DEFAULT NULL,
  `hostmask`       VARCHAR(255) NOT NULL,
  `action`         VARCHAR(255) NOT NULL,
  `args`           VARCHAR(255) DEFAULT NULL,
  PRIMARY KEY (`id_actions_log`),
  KEY `idx_actions_log_id_user`    (`id_user`),
  KEY `idx_actions_log_id_channel` (`id_channel`),
  KEY `idx_actions_log_ts`         (`ts`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- ACTIONS_QUEUE
-- ---------------------------------------------------------------------------
CREATE TABLE `ACTIONS_QUEUE` (
  `id_actions_queue` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `ts`               DATETIME NOT NULL,
  `command`          VARCHAR(255) NOT NULL,
  `params`           VARCHAR(255) NOT NULL,
  `result1`          VARCHAR(255) DEFAULT NULL,
  `result2`          VARCHAR(255) DEFAULT NULL,
  `result3`          VARCHAR(255) DEFAULT NULL,
  `result4`          VARCHAR(255) DEFAULT NULL,
  `result5`          VARCHAR(255) DEFAULT NULL,
  `result6`          VARCHAR(255) DEFAULT NULL,
  `status`           INT(11) NOT NULL DEFAULT 0,
  PRIMARY KEY (`id_actions_queue`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- BADWORDS
-- ---------------------------------------------------------------------------
CREATE TABLE `BADWORDS` (
  `id_badwords` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `id_channel`  BIGINT UNSIGNED NOT NULL DEFAULT 0,
  `badword`     VARCHAR(255) NOT NULL,
  PRIMARY KEY (`id_badwords`),
  KEY `idx_badwords_channel` (`id_channel`),
  KEY `badword` (`badword`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- CHANNEL
-- ---------------------------------------------------------------------------
CREATE TABLE `CHANNEL` (
  `id_channel`    BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `name`          VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `creation_date` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `description`   VARCHAR(255) DEFAULT NULL,
  `key`           VARCHAR(255) DEFAULT NULL,
  `chanmode`      VARCHAR(255) DEFAULT NULL,
  `auto_join`     TINYINT(1) NOT NULL DEFAULT 0,
  `notice`        VARCHAR(255) DEFAULT NULL,
  `tmdb_lang`     VARCHAR(255) NOT NULL DEFAULT 'en-US',
  `topic`         VARCHAR(400) DEFAULT NULL,
  `id_user`       BIGINT UNSIGNED DEFAULT NULL,
  PRIMARY KEY (`id_channel`),
  UNIQUE KEY `name` (`name`),
  KEY `idx_channel_id_user` (`id_user`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- CHANNEL_FLOOD
-- ---------------------------------------------------------------------------
CREATE TABLE `CHANNEL_FLOOD` (
  `id_channel_flood` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `id_channel`       BIGINT UNSIGNED NOT NULL,
  `nbmsg_max`        INT(11) NOT NULL DEFAULT 5,
  `nbmsg`            INT(11) NOT NULL DEFAULT 0,
  `duration`         INT(11) NOT NULL DEFAULT 30,
  `first`            INT(11) DEFAULT 0,
  `latest`           BIGINT(20) NOT NULL DEFAULT 0,
  `timetowait`       INT(11) NOT NULL DEFAULT 300,
  `notification`     INT(11) NOT NULL DEFAULT 0,
  PRIMARY KEY (`id_channel_flood`),
  KEY `idx_channel_flood_id_channel` (`id_channel`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- CHANNEL_LOG
-- ---------------------------------------------------------------------------
CREATE TABLE `CHANNEL_LOG` (
  `id_channel_log` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `id_channel`     BIGINT UNSIGNED DEFAULT NULL,
  `ts`             DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `event_type`     VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL,
  `nick`           VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL,
  `userhost`       VARCHAR(255) NOT NULL,
  `publictext`     TEXT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  PRIMARY KEY (`id_channel_log`),
  KEY `ts`      (`ts`),
  KEY `nick`    (`nick`(191)),
  KEY `userhost`(`userhost`(191)),
  KEY `idx_channel_log_id_channel` (`id_channel`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- CHANNEL_PURGED
-- ---------------------------------------------------------------------------
CREATE TABLE `CHANNEL_PURGED` (
  `id_channel_purged` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `id_channel`        BIGINT UNSIGNED NOT NULL,
  `name`              VARCHAR(255) NOT NULL,
  `purge_date`        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `description`       VARCHAR(255) DEFAULT NULL,
  `key`               VARCHAR(255) DEFAULT NULL,
  `chanmode`          VARCHAR(255) DEFAULT NULL,
  `auto_join`         TINYINT(1) NOT NULL DEFAULT 0,
  `purged_by`         VARCHAR(255) DEFAULT NULL,
  `purged_at`         DATETIME DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id_channel_purged`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- CHANNEL_SET
-- ---------------------------------------------------------------------------
CREATE TABLE `CHANNEL_SET` (
  `id_channel_set`  BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `id_channel`      BIGINT UNSIGNED NOT NULL,
  `id_chanset_list` BIGINT UNSIGNED NOT NULL,
  PRIMARY KEY (`id_channel_set`),
  KEY `idx_channel_set_channel`     (`id_channel`),
  KEY `idx_channel_set_chanset_list`(`id_chanset_list`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- CHANSET_LIST
-- ---------------------------------------------------------------------------
CREATE TABLE `CHANSET_LIST` (
  `id_chanset_list` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `chanset`         VARCHAR(255) NOT NULL,
  PRIMARY KEY (`id_chanset_list`),
  UNIQUE KEY `chanset` (`chanset`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- CONSOLE
-- ---------------------------------------------------------------------------
CREATE TABLE `CONSOLE` (
  `id_console`  BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `id_parent`   BIGINT UNSIGNED DEFAULT NULL,
  `position`    INT(11) NOT NULL DEFAULT 1,
  `level`       INT(11) NOT NULL DEFAULT 0,
  `description` VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL,
  `url`         VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL,
  PRIMARY KEY (`id_console`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- HAILO_CHANNEL
-- ---------------------------------------------------------------------------
CREATE TABLE `HAILO_CHANNEL` (
  `id_hailo_channel` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `id_channel`       BIGINT UNSIGNED NOT NULL,
  `ratio`            INT(11) NOT NULL,
  PRIMARY KEY (`id_hailo_channel`),
  UNIQUE KEY `id_channel` (`id_channel`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- HAILO_EXCLUSION_NICK
-- ---------------------------------------------------------------------------
CREATE TABLE `HAILO_EXCLUSION_NICK` (
  `id_hailo_exclusion_nick` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `nick`                    VARCHAR(255) NOT NULL,
  PRIMARY KEY (`id_hailo_exclusion_nick`),
  KEY `nick` (`nick`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- IGNORES
-- ---------------------------------------------------------------------------
CREATE TABLE `IGNORES` (
  `id_ignores` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `id_channel` BIGINT UNSIGNED NOT NULL DEFAULT 0,
  `hostmask`   VARCHAR(255) NOT NULL,
  PRIMARY KEY (`id_ignores`),
  KEY `hostmask` (`hostmask`),
  KEY `idx_ignores_id_channel` (`id_channel`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- MP3
-- ---------------------------------------------------------------------------
CREATE TABLE `MP3` (
  `id_mp3`      BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `id_user`     BIGINT UNSIGNED NOT NULL,
  `id_youtube`  VARCHAR(255) NOT NULL,
  `folder`      VARCHAR(255) NOT NULL,
  `filename`    VARCHAR(255) NOT NULL,
  `artist`      VARCHAR(255) NOT NULL,
  `title`       VARCHAR(255) NOT NULL,
  PRIMARY KEY (`id_mp3`),
  KEY `idx_mp3_id_user` (`id_user`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- NETWORK
-- ---------------------------------------------------------------------------
CREATE TABLE `NETWORK` (
  `id_network`   BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `network_name` VARCHAR(255) NOT NULL,
  PRIMARY KEY (`id_network`),
  UNIQUE KEY `network_name` (`network_name`(191))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- PUBLIC_COMMANDS
-- ---------------------------------------------------------------------------
CREATE TABLE `PUBLIC_COMMANDS` (
  `id_public_commands`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `id_user`                     BIGINT UNSIGNED DEFAULT NULL,
  `id_public_commands_category` BIGINT UNSIGNED NOT NULL,
  `creation_date`               TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `command`     VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL,
  `description` VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL,
  `action`      VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL,
  `hits`        BIGINT UNSIGNED NOT NULL DEFAULT 0,
  `active`      TINYINT(1) NOT NULL DEFAULT 1,
  PRIMARY KEY (`id_public_commands`),
  UNIQUE KEY `command` (`command`(191)),
  KEY `idx_pc_id_user`     (`id_user`),
  KEY `idx_pc_id_category` (`id_public_commands_category`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- PUBLIC_COMMANDS_CATEGORY
-- ---------------------------------------------------------------------------
CREATE TABLE `PUBLIC_COMMANDS_CATEGORY` (
  `id_public_commands_category` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `description`                 VARCHAR(255) NOT NULL,
  PRIMARY KEY (`id_public_commands_category`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- QUOTES
-- ---------------------------------------------------------------------------
CREATE TABLE `QUOTES` (
  `id_quotes`  BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `id_channel` BIGINT UNSIGNED NOT NULL,
  `id_user`    BIGINT UNSIGNED NOT NULL,
  `ts`         TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `quotetext`  VARCHAR(255) NOT NULL,
  PRIMARY KEY (`id_quotes`),
  KEY `idx_quotes_id_channel` (`id_channel`),
  KEY `idx_quotes_id_user`    (`id_user`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- RESPONDERS
-- ---------------------------------------------------------------------------
CREATE TABLE `RESPONDERS` (
  `id_responders` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `id_channel`    BIGINT UNSIGNED NOT NULL DEFAULT 0,
  `hits`          BIGINT UNSIGNED NOT NULL DEFAULT 0,
  `chance`        BIGINT UNSIGNED NOT NULL DEFAULT 95,
  `responder`     VARCHAR(255) DEFAULT NULL,
  `answer`        TEXT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  PRIMARY KEY (`id_responders`),
  KEY `idx_responders_id_channel` (`id_channel`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- SERVERS
-- ---------------------------------------------------------------------------
CREATE TABLE `SERVERS` (
  `id_server`       BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `id_network`      BIGINT UNSIGNED NOT NULL,
  `server_hostname` VARCHAR(255) NOT NULL,
  PRIMARY KEY (`id_server`),
  KEY `idx_servers_id_network` (`id_network`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- TIMERS
-- ---------------------------------------------------------------------------
CREATE TABLE `TIMERS` (
  `id_timers`  BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `name`       VARCHAR(255) NOT NULL,
  `duration`   INT(11) NOT NULL,
  `command`    VARCHAR(255) NOT NULL,
  -- Future columns (not yet deployed to production):
  -- `id_channel` BIGINT UNSIGNED DEFAULT NULL,
  -- `enabled`    TINYINT(1) NOT NULL DEFAULT 1,
  PRIMARY KEY (`id_timers`),
  UNIQUE KEY `name` (`name`(191))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- TIMEZONE
-- ---------------------------------------------------------------------------
CREATE TABLE `TIMEZONE` (
  `id_timezone` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `tz`          VARCHAR(255) NOT NULL,
  PRIMARY KEY (`id_timezone`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- USER
-- NOTE: USER.hostmasks removed — hostmasks now stored in USER_HOSTMASK table
-- ---------------------------------------------------------------------------
CREATE TABLE `USER` (
  `id_user`       BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `creation_date` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `nickname`      VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '',
  `password`      VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `username`      VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `id_user_level` BIGINT UNSIGNED NOT NULL,
  `info1`         VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `info2`         VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `last_login`    DATETIME NULL DEFAULT NULL,
  `auth`          TINYINT(1) NOT NULL DEFAULT 0,
  `tz`            VARCHAR(255) DEFAULT NULL,
  `birthday`      VARCHAR(255) DEFAULT NULL,
  `fortniteid`    VARCHAR(255) DEFAULT NULL,
  PRIMARY KEY (`id_user`),
  UNIQUE KEY `nickname` (`nickname`),
  KEY `idx_user_id_user_level` (`id_user_level`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- USER_CHANNEL
-- ---------------------------------------------------------------------------
CREATE TABLE `USER_CHANNEL` (
  `id_user_channel` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `id_user`         BIGINT UNSIGNED NOT NULL,
  `id_channel`      BIGINT UNSIGNED NOT NULL,
  `level`           BIGINT UNSIGNED NOT NULL DEFAULT 0,
  `greet`           VARCHAR(255) DEFAULT NULL,
  `automode`        VARCHAR(255) NOT NULL DEFAULT 'NONE',
  PRIMARY KEY (`id_user_channel`),
  UNIQUE KEY `uc_user_channel` (`id_user`, `id_channel`),
  KEY `idx_user_channel_id_channel` (`id_channel`),
  KEY `idx_user_channel_id_user`    (`id_user`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- USER_HOSTMASK  (NEW — replaces USER.hostmasks CSV column)
-- ---------------------------------------------------------------------------
CREATE TABLE `USER_HOSTMASK` (
  `id_user_hostmask` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `id_user`          BIGINT UNSIGNED NOT NULL,
  `hostmask`         VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL,
  `created_at`       DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id_user_hostmask`),
  KEY `idx_user_hostmask_id_user`  (`id_user`),
  KEY `idx_user_hostmask_hostmask` (`hostmask`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- USER_LEVEL
-- ---------------------------------------------------------------------------
CREATE TABLE `USER_LEVEL` (
  `id_user_level` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `level`         INT(11) NOT NULL,
  `description`   VARCHAR(255) NOT NULL,
  PRIMARY KEY (`id_user_level`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- WEBLOG  (NOTE: password column removed)
-- ---------------------------------------------------------------------------
CREATE TABLE `WEBLOG` (
  `id_weblog`    BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `login_date`   DATETIME NOT NULL,
  `nickname`     VARCHAR(255) NOT NULL,
  `ip`           VARCHAR(255) NOT NULL,
  `hostname`     VARCHAR(255) DEFAULT NULL,
  `logresult`    TINYINT(1) NOT NULL,
  PRIMARY KEY (`id_weblog`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- YOMOMMA
-- ---------------------------------------------------------------------------
CREATE TABLE `YOMOMMA` (
  `id_yomomma` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `yomomma`    VARCHAR(255) NOT NULL,
  PRIMARY KEY (`id_yomomma`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ===========================================================================
-- FOREIGN KEYS
-- ===========================================================================

SET FOREIGN_KEY_CHECKS = 1;

ALTER TABLE `ACTIONS_LOG`
  ADD CONSTRAINT `fk_actions_log_user`    FOREIGN KEY (`id_user`)    REFERENCES `USER`    (`id_user`)    ON DELETE SET NULL ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_actions_log_channel` FOREIGN KEY (`id_channel`) REFERENCES `CHANNEL` (`id_channel`) ON DELETE SET NULL ON UPDATE CASCADE;

ALTER TABLE `BADWORDS`
  ADD CONSTRAINT `fk_badwords_channel` FOREIGN KEY (`id_channel`) REFERENCES `CHANNEL` (`id_channel`) ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE `CHANNEL`
  ADD CONSTRAINT `fk_channel_user` FOREIGN KEY (`id_user`) REFERENCES `USER` (`id_user`) ON DELETE SET NULL ON UPDATE CASCADE;

ALTER TABLE `CHANNEL_FLOOD`
  ADD CONSTRAINT `fk_channel_flood_channel` FOREIGN KEY (`id_channel`) REFERENCES `CHANNEL` (`id_channel`) ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE `CHANNEL_LOG`
  ADD CONSTRAINT `fk_channel_log_channel` FOREIGN KEY (`id_channel`) REFERENCES `CHANNEL` (`id_channel`) ON DELETE SET NULL ON UPDATE CASCADE;

ALTER TABLE `CHANNEL_SET`
  ADD CONSTRAINT `fk_channel_set_channel`      FOREIGN KEY (`id_channel`)      REFERENCES `CHANNEL`      (`id_channel`)      ON DELETE CASCADE ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_channel_set_chanset_list`  FOREIGN KEY (`id_chanset_list`) REFERENCES `CHANSET_LIST` (`id_chanset_list`) ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE `HAILO_CHANNEL`
  ADD CONSTRAINT `fk_hailo_channel_channel` FOREIGN KEY (`id_channel`) REFERENCES `CHANNEL` (`id_channel`) ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE `MP3`
  ADD CONSTRAINT `fk_mp3_user` FOREIGN KEY (`id_user`) REFERENCES `USER` (`id_user`) ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE `PUBLIC_COMMANDS`
  ADD CONSTRAINT `fk_pc_user`     FOREIGN KEY (`id_user`)                     REFERENCES `USER`                     (`id_user`)                     ON DELETE SET NULL ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_pc_category` FOREIGN KEY (`id_public_commands_category`) REFERENCES `PUBLIC_COMMANDS_CATEGORY` (`id_public_commands_category`) ON DELETE RESTRICT  ON UPDATE CASCADE;

ALTER TABLE `QUOTES`
  ADD CONSTRAINT `fk_quotes_channel` FOREIGN KEY (`id_channel`) REFERENCES `CHANNEL` (`id_channel`) ON DELETE CASCADE ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_quotes_user`    FOREIGN KEY (`id_user`)    REFERENCES `USER`    (`id_user`)    ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE `SERVERS`
  ADD CONSTRAINT `fk_servers_network` FOREIGN KEY (`id_network`) REFERENCES `NETWORK` (`id_network`) ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE `TIMERS`
  ADD CONSTRAINT `fk_timers_channel` FOREIGN KEY (`id_channel`) REFERENCES `CHANNEL` (`id_channel`) ON DELETE SET NULL ON UPDATE CASCADE;

ALTER TABLE `USER`
  ADD CONSTRAINT `fk_user_level` FOREIGN KEY (`id_user_level`) REFERENCES `USER_LEVEL` (`id_user_level`) ON DELETE RESTRICT ON UPDATE CASCADE;

ALTER TABLE `USER_CHANNEL`
  ADD CONSTRAINT `fk_user_channel_user`    FOREIGN KEY (`id_user`)    REFERENCES `USER`    (`id_user`)    ON DELETE CASCADE ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_user_channel_channel` FOREIGN KEY (`id_channel`) REFERENCES `CHANNEL` (`id_channel`) ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE `USER_HOSTMASK`
  ADD CONSTRAINT `fk_user_hostmask_user` FOREIGN KEY (`id_user`) REFERENCES `USER` (`id_user`) ON DELETE CASCADE ON UPDATE CASCADE;

-- ===========================================================================
-- REFERENCE DATA
-- ===========================================================================

--
-- USER_LEVEL hierarchy
--
INSERT INTO `USER_LEVEL` (`id_user_level`, `level`, `description`) VALUES
(1, 0, 'Owner'),
(2, 1, 'Master'),
(3, 2, 'Administrator'),
(4, 3, 'User');

--
-- CHANSET_LIST — available channel settings
--
INSERT INTO `CHANSET_LIST` (`id_chanset_list`, `chanset`) VALUES
(1,  'Youtube'),
(2,  'UrlTitle'),
(3,  'Weather'),
(4,  'YoutubeSearch'),
(5,  'NoColors'),
(6,  'AntiFlood'),
(7,  'Hailo'),
(8,  'HailoChatter'),
(9,  'RadioPub'),
(10, 'Twitter'),
(11, 'chatGPT'),
(12, 'AppleMusic'),
(13, 'RandomQuote');

--
-- PUBLIC_COMMANDS_CATEGORY — default categories
--
INSERT INTO `PUBLIC_COMMANDS_CATEGORY` (`id_public_commands_category`, `description`) VALUES
(1, 'General');

--
-- PUBLIC_COMMANDS — built-in commands
--
INSERT INTO `PUBLIC_COMMANDS` (`id_public_commands`, `id_user`, `id_public_commands_category`, `creation_date`, `command`, `description`, `action`, `hits`, `active`) VALUES
(2, NULL, 1, '2018-02-04 06:06:55', 'dice',   'Play dice', 'PRIVMSG %c The dice rolls... Result : %d', 1, 1),
(3, NULL, 1, '2018-02-11 04:25:40', 'coffee', 'Coffee',    'ACTION %c serves \x02\x038,1c(\x0f\x02\x0305,01_\x0f\x02\x0308,01)\x0f\x02\x0315,01~\x0f to %n', 1, 1);

--
-- CONSOLE — web interface navigation
--
INSERT INTO `CONSOLE` (`id_console`, `id_parent`, `position`, `level`, `description`, `url`) VALUES
(16, NULL, 0, 999999, 'Profil',               'profile.php'),
(39, 41,   0, 0,      'Utilisateurs système', 'system_users.php'),
(41, NULL, 3, 0,      'Système',              'system.php'),
(45, NULL, 1, 1,      'Administration',       'admin.php'),
(46, 45,   0, 1,      'Utilisateurs',         'users.php'),
(49, 45,   1, 1,      'Channels',             'channels.php'),
(51, 45,   2, 0,      'Live',                 'live.php'),
(52, NULL, 2, 3,      'Aide',                 'help.php'),
(53, 52,   0, 3,      'Utilisateurs',         'help_users.php'),
(54, 52,   1, 2,      'Administrateurs',      'help_admins.php');

COMMIT;

-- ===========================================================================
-- END OF SCHEMA
-- ===========================================================================
