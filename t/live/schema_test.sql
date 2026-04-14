-- =============================================================================
--  mediabot_test — minimal schema for live IRC tests
--  Generated from mediabotv3.sql (production dump)
--  Used by test_live.pl: DROP DATABASE / CREATE DATABASE / SOURCE this file
-- =============================================================================

SET SQL_MODE = "NO_AUTO_VALUE_ON_ZERO";
SET time_zone = "+00:00";
SET NAMES utf8mb4;

-- ---------------------------------------------------------------------------
-- Structural tables required for bot startup
-- ---------------------------------------------------------------------------

CREATE TABLE `ACTIONS_LOG` (
  `id_actions_log` bigint(20) NOT NULL AUTO_INCREMENT,
  `ts` timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `id_user` bigint(20) DEFAULT NULL,
  `id_channel` bigint(20) DEFAULT NULL,
  `hostmask` varchar(255) NOT NULL,
  `action` varchar(255) NOT NULL,
  `args` varchar(255) DEFAULT NULL,
  PRIMARY KEY (`id_actions_log`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;

CREATE TABLE `ACTIONS_QUEUE` (
  `id_actions_queue` bigint(20) NOT NULL AUTO_INCREMENT,
  `ts` datetime NOT NULL,
  `command` varchar(255) NOT NULL,
  `params` varchar(255) NOT NULL,
  `result1` varchar(255) DEFAULT NULL,
  `result2` varchar(255) DEFAULT NULL,
  `result3` varchar(255) DEFAULT NULL,
  `result4` varchar(255) DEFAULT NULL,
  `result5` varchar(255) DEFAULT NULL,
  `result6` varchar(255) DEFAULT NULL,
  `status` int(11) NOT NULL DEFAULT 0,
  PRIMARY KEY (`id_actions_queue`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;

CREATE TABLE `BADWORDS` (
  `id_badwords` bigint(20) NOT NULL AUTO_INCREMENT,
  `id_channel` bigint(20) NOT NULL DEFAULT 0,
  `badword` varchar(255) NOT NULL,
  PRIMARY KEY (`id_badwords`),
  KEY `badword` (`badword`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;

CREATE TABLE `CHANNEL` (
  `id_channel` bigint(20) NOT NULL AUTO_INCREMENT,
  `name` varchar(255) DEFAULT NULL,
  `creation_date` timestamp NOT NULL DEFAULT current_timestamp(),
  `description` varchar(255) DEFAULT NULL,
  `key` varchar(255) DEFAULT NULL,
  `chanmode` varchar(255) DEFAULT NULL,
  `auto_join` tinyint(1) NOT NULL,
  `notice` varchar(255) DEFAULT NULL,
  `tmdb_lang` varchar(255) NOT NULL DEFAULT 'en-US',
  `topic` varchar(400) DEFAULT NULL,
  `id_user` bigint(20) DEFAULT NULL,
  PRIMARY KEY (`id_channel`),
  UNIQUE KEY `name` (`name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE `CHANNEL_FLOOD` (
  `id_channel_flood` bigint(20) NOT NULL AUTO_INCREMENT,
  `id_channel` bigint(20) NOT NULL,
  `nbmsg_max` int(11) NOT NULL DEFAULT 5,
  `nbmsg` int(11) NOT NULL DEFAULT 0,
  `duration` int(11) NOT NULL DEFAULT 30,
  `first` int(11) DEFAULT 0,
  `latest` bigint(20) NOT NULL DEFAULT 0,
  `timetowait` int(11) NOT NULL DEFAULT 300,
  `notification` int(11) NOT NULL DEFAULT 0,
  PRIMARY KEY (`id_channel_flood`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;

CREATE TABLE `CHANNEL_LOG` (
  `id_channel_log` bigint(20) NOT NULL AUTO_INCREMENT,
  `id_channel` bigint(20) DEFAULT NULL,
  `ts` datetime NOT NULL DEFAULT current_timestamp(),
  `event_type` varchar(255) NOT NULL,
  `nick` varchar(255) NOT NULL,
  `userhost` varchar(255) NOT NULL,
  `publictext` varchar(400) DEFAULT NULL,
  PRIMARY KEY (`id_channel_log`),
  KEY `ts` (`ts`),
  KEY `nick` (`nick`),
  KEY `userhost` (`userhost`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE `CHANNEL_PURGED` (
  `id_channel_purged` bigint(20) NOT NULL AUTO_INCREMENT,
  `id_channel` bigint(20) NOT NULL,
  `name` varchar(255) NOT NULL,
  `purge_date` timestamp NOT NULL DEFAULT current_timestamp(),
  `description` varchar(255) DEFAULT NULL,
  `key` varchar(255) DEFAULT NULL,
  `chanmode` varchar(255) DEFAULT NULL,
  `auto_join` tinyint(1) NOT NULL,
  `purged_by` varchar(255) DEFAULT NULL,
  `purged_at` datetime DEFAULT current_timestamp(),
  PRIMARY KEY (`id_channel_purged`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;

CREATE TABLE `CHANNEL_SET` (
  `id_channel_set` bigint(20) NOT NULL AUTO_INCREMENT,
  `id_channel` bigint(20) NOT NULL,
  `id_chanset_list` bigint(20) NOT NULL,
  PRIMARY KEY (`id_channel_set`)
) ENGINE=InnoDB DEFAULT CHARSET=latin1;

CREATE TABLE `CHANSET_LIST` (
  `id_chanset_list` bigint(20) NOT NULL AUTO_INCREMENT,
  `chanset` varchar(255) NOT NULL,
  PRIMARY KEY (`id_chanset_list`)
) ENGINE=InnoDB DEFAULT CHARSET=latin1;

CREATE TABLE `CONSOLE` (
  `id_console` bigint(20) NOT NULL AUTO_INCREMENT,
  `id_parent` bigint(20) DEFAULT NULL,
  `position` int(11) NOT NULL DEFAULT 1,
  `level` int(11) NOT NULL DEFAULT 0,
  `description` varchar(255) CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci NOT NULL,
  `url` varchar(255) CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci NOT NULL,
  PRIMARY KEY (`id_console`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;

CREATE TABLE `HAILO_CHANNEL` (
  `id_hailo_channel` bigint(20) NOT NULL AUTO_INCREMENT,
  `id_channel` bigint(20) NOT NULL,
  `ratio` int(11) NOT NULL,
  PRIMARY KEY (`id_hailo_channel`),
  UNIQUE KEY `id_channel` (`id_channel`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;

CREATE TABLE `HAILO_EXCLUSION_NICK` (
  `id_hailo_exclusion_nick` bigint(20) NOT NULL AUTO_INCREMENT,
  `nick` varchar(255) NOT NULL,
  PRIMARY KEY (`id_hailo_exclusion_nick`),
  KEY `nick` (`nick`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;

CREATE TABLE `IGNORES` (
  `id_ignores` bigint(20) NOT NULL AUTO_INCREMENT,
  `id_channel` bigint(20) NOT NULL DEFAULT 0,
  `hostmask` varchar(255) NOT NULL,
  PRIMARY KEY (`id_ignores`),
  KEY `hostmask` (`hostmask`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;

CREATE TABLE `MP3` (
  `id_mp3` bigint(20) NOT NULL AUTO_INCREMENT,
  `id_user` bigint(20) NOT NULL,
  `id_youtube` varchar(255) NOT NULL,
  `folder` varchar(255) NOT NULL,
  `filename` varchar(255) NOT NULL,
  `artist` varchar(255) NOT NULL,
  `title` varchar(255) NOT NULL,
  PRIMARY KEY (`id_mp3`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;

CREATE TABLE `NETWORK` (
  `id_network` bigint(20) NOT NULL AUTO_INCREMENT,
  `network_name` varchar(255) NOT NULL,
  PRIMARY KEY (`id_network`),
  UNIQUE KEY `network_name` (`network_name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;

CREATE TABLE `PUBLIC_COMMANDS` (
  `id_public_commands` bigint(20) NOT NULL AUTO_INCREMENT,
  `id_user` bigint(20) DEFAULT NULL,
  `id_public_commands_category` bigint(20) NOT NULL,
  `creation_date` timestamp NOT NULL DEFAULT current_timestamp(),
  `command` varchar(255) CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci NOT NULL,
  `description` varchar(255) CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci NOT NULL,
  `action` varchar(255) CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci NOT NULL,
  `hits` bigint(20) NOT NULL DEFAULT 0,
  PRIMARY KEY (`id_public_commands`),
  UNIQUE KEY `command` (`command`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;

CREATE TABLE `PUBLIC_COMMANDS_CATEGORY` (
  `id_public_commands_category` bigint(20) NOT NULL AUTO_INCREMENT,
  `description` varchar(255) NOT NULL,
  PRIMARY KEY (`id_public_commands_category`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;

CREATE TABLE `QUOTES` (
  `id_quotes` bigint(20) NOT NULL AUTO_INCREMENT,
  `id_channel` bigint(20) NOT NULL,
  `id_user` bigint(20) NOT NULL,
  `ts` timestamp NOT NULL DEFAULT current_timestamp(),
  `quotetext` varchar(255) NOT NULL,
  PRIMARY KEY (`id_quotes`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;

CREATE TABLE `RESPONDERS` (
  `id_responders` bigint(20) NOT NULL AUTO_INCREMENT,
  `id_channel` bigint(20) NOT NULL DEFAULT 0,
  `hits` bigint(20) NOT NULL DEFAULT 0,
  `chance` bigint(20) NOT NULL DEFAULT 95,
  `responder` varchar(255) DEFAULT NULL,
  `answer` text DEFAULT NULL,
  PRIMARY KEY (`id_responders`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE `SERVERS` (
  `id_server` bigint(20) NOT NULL AUTO_INCREMENT,
  `id_network` bigint(20) NOT NULL,
  `server_hostname` varchar(255) NOT NULL,
  PRIMARY KEY (`id_server`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;

CREATE TABLE `TIMERS` (
  `id_timers` bigint(20) NOT NULL AUTO_INCREMENT,
  `name` varchar(255) NOT NULL,
  `duration` bigint(20) NOT NULL,
  `command` varchar(255) NOT NULL,
  PRIMARY KEY (`id_timers`),
  UNIQUE KEY `name` (`name`)
) ENGINE=InnoDB DEFAULT CHARSET=latin1;

CREATE TABLE `TIMEZONE` (
  `id_timezone` bigint(20) NOT NULL AUTO_INCREMENT,
  `tz` varchar(255) NOT NULL,
  PRIMARY KEY (`id_timezone`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;

CREATE TABLE `USER` (
  `id_user` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `creation_date` datetime NOT NULL DEFAULT current_timestamp(),
  `nickname`   VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '',
  `password`   VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `username`   VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `id_user_level` BIGINT UNSIGNED NOT NULL,
  `info1`      VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `info2`      VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `last_login` datetime NULL DEFAULT NULL,
  `auth`       TINYINT(1) NOT NULL DEFAULT 0,
  `tz`         VARCHAR(255) DEFAULT NULL,
  `birthday`   VARCHAR(255) DEFAULT NULL,
  `fortniteid` VARCHAR(255) DEFAULT NULL,
  PRIMARY KEY (`id_user`),
  UNIQUE KEY `nickname` (`nickname`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE `USER_HOSTMASK` (
  `id_user_hostmask` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `id_user`          BIGINT UNSIGNED NOT NULL,
  `hostmask`         VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL,
  `created_at`       DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id_user_hostmask`),
  KEY `idx_user_hostmask_id_user`  (`id_user`),
  KEY `idx_user_hostmask_hostmask` (`hostmask`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE `USER_CHANNEL` (
  `id_user_channel` bigint(20) NOT NULL AUTO_INCREMENT,
  `id_user` bigint(20) NOT NULL,
  `id_channel` bigint(20) NOT NULL,
  `level` bigint(20) NOT NULL DEFAULT 0,
  `greet` varchar(255) CHARACTER SET latin1 DEFAULT NULL,
  `automode` varchar(255) CHARACTER SET latin1 NOT NULL DEFAULT 'NONE',
  PRIMARY KEY (`id_user_channel`),
  KEY `uc_channel_user` (`id_channel`,`id_user`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;

CREATE TABLE `USER_LEVEL` (
  `id_user_level` bigint(20) NOT NULL AUTO_INCREMENT,
  `level` int(11) NOT NULL,
  `description` varchar(255) CHARACTER SET latin1 NOT NULL,
  PRIMARY KEY (`id_user_level`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;

CREATE TABLE `WEBLOG` (
  `id_weblog` bigint(20) NOT NULL AUTO_INCREMENT,
  `login_date` datetime NOT NULL,
  `nickname` varchar(255) NOT NULL,
  `password` varchar(255) DEFAULT NULL,
  `ip` varchar(255) NOT NULL,
  `hostname` varchar(255) DEFAULT NULL,
  `logresult` tinyint(1) NOT NULL,
  PRIMARY KEY (`id_weblog`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;

CREATE TABLE `YOMOMMA` (
  `id_yomomma` bigint(20) NOT NULL AUTO_INCREMENT,
  `yomomma` varchar(255) NOT NULL,
  PRIMARY KEY (`id_yomomma`)
) ENGINE=InnoDB DEFAULT CHARSET=latin1;

-- Base category for tests
INSERT INTO `PUBLIC_COMMANDS_CATEGORY` (`id_public_commands_category`, `description`) VALUES
(1, 'test'),
(2, 'general');

INSERT INTO `PUBLIC_COMMANDS` (`id_public_commands`, `id_user`, `id_public_commands_category`, `command`, `description`, `action`, `hits`) VALUES
(1, 1, 1, 'check', 'check', 'PRIVMSG %c I\\'m fine Houston, over.', 0);

-- ---------------------------------------------------------------------------
-- Reference data required for the bot to work during live tests
-- ---------------------------------------------------------------------------

-- User level hierarchy
INSERT INTO `USER_LEVEL` (`id_user_level`, `level`, `description`) VALUES
(1, 0, 'Owner'),
(2, 1, 'Master'),
(3, 2, 'Administrator'),
(4, 3, 'User');

-- Available chansets
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

-- Test network — server will be replaced dynamically by test_live.pl
INSERT INTO `NETWORK` (`id_network`, `network_name`) VALUES
(1, 'TestNetwork');

INSERT INTO `SERVERS` (`id_server`, `id_network`, `server_hostname`) VALUES
(1, 1, 'irc.libera.chat:6667');

-- Test channel (auto_join=1, replaced dynamically)
INSERT INTO `CHANNEL` (`id_channel`, `name`, `auto_join`) VALUES
(1, '##mbtest', 1);

-- Test bot owner account (autologin via wildcard hostmask)
-- Nick will be replaced dynamically by test_live.pl
INSERT INTO `USER` (`id_user`, `nickname`, `password`, `username`, `id_user_level`, `auth`) VALUES
(1, 'mbtest', NULL, '#AUTOLOGIN#', 1, 0);
INSERT INTO `USER_HOSTMASK` (`id_user`, `hostmask`) VALUES
(1, '*mbtest@*');

-- Bot membership on test channel
INSERT INTO `USER_CHANNEL` (`id_user_channel`, `id_user`, `id_channel`, `level`, `automode`) VALUES
(1, 1, 1, 0, 'NONE');

-- Master test account for explicit authentication scenarios
-- password = 'testpass123'
-- Stored as the same legacy MariaDB PASSWORD() hash reproduced by make_password_hash()
INSERT INTO `USER` (`id_user`, `nickname`, `password`, `username`, `id_user_level`, `auth`) VALUES
(2, 'mboper', '*AE44FCBF2A029BA0F76B3DF897A0265E9EDB5BF9', 'mboper', 2, 0);

-- Intentionally no USER_HOSTMASK row for mboper:
-- auth tests must start from a non-autologged state.

-- Membership of mboper on the test channel (level Master)
INSERT INTO `USER_CHANNEL` (`id_user_channel`, `id_user`, `id_channel`, `level`, `automode`) VALUES
(2, 2, 1, 1, 'NONE');