-- =============================================================================
-- Mediabot live test fixtures
-- =============================================================================
-- This file intentionally contains only test data.
--
-- The schema itself is loaded from:
--   install/mediabot.sql
--
-- Keep this file small. Do not duplicate schema definitions here.
-- =============================================================================

SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- Test network and server
-- The server hostname is replaced dynamically by t/test_live.pl.
-- ---------------------------------------------------------------------------

INSERT INTO `NETWORK` (`id_network`, `network_name`)
VALUES (1, 'TestNetwork')
ON DUPLICATE KEY UPDATE
  `network_name` = VALUES(`network_name`);

INSERT INTO `SERVERS` (`id_server`, `id_network`, `server_hostname`)
VALUES (1, 1, 'irc.libera.chat:6667')
ON DUPLICATE KEY UPDATE
  `id_network` = VALUES(`id_network`),
  `server_hostname` = VALUES(`server_hostname`);

-- ---------------------------------------------------------------------------
-- Test channel
-- The channel name is replaced dynamically by t/test_live.pl.
-- ---------------------------------------------------------------------------

INSERT INTO `CHANNEL` (`id_channel`, `name`, `auto_join`)
VALUES (1, '##mbtest', 1)
ON DUPLICATE KEY UPDATE
  `name` = VALUES(`name`),
  `auto_join` = VALUES(`auto_join`);

-- ---------------------------------------------------------------------------
-- Live test owner account
--
-- The generated bot nick is injected into USER.nickname and USER_HOSTMASK by
-- t/test_live.pl after fixtures are loaded.
-- ---------------------------------------------------------------------------

INSERT INTO `USER` (`id_user`, `nickname`, `password`, `username`, `id_user_level`, `auth`)
VALUES (1, 'mbtest', NULL, '#AUTOLOGIN#', 1, 0)
ON DUPLICATE KEY UPDATE
  `nickname` = VALUES(`nickname`),
  `password` = VALUES(`password`),
  `username` = VALUES(`username`),
  `id_user_level` = VALUES(`id_user_level`),
  `auth` = VALUES(`auth`);

INSERT INTO `USER_HOSTMASK` (`id_user`, `hostmask`)
VALUES (1, '*mbtest@*')
ON DUPLICATE KEY UPDATE
  `hostmask` = VALUES(`hostmask`);

INSERT INTO `USER_CHANNEL` (`id_user_channel`, `id_user`, `id_channel`, `level`, `automode`)
VALUES (1, 1, 1, 0, 'NONE')
ON DUPLICATE KEY UPDATE
  `id_user` = VALUES(`id_user`),
  `id_channel` = VALUES(`id_channel`),
  `level` = VALUES(`level`),
  `automode` = VALUES(`automode`);

-- ---------------------------------------------------------------------------
-- Master test account for explicit authentication scenarios
--
-- password = testpass123
-- Stored as the legacy MariaDB PASSWORD() hash reproduced by make_password_hash().
-- Intentionally no USER_HOSTMASK row for mboper:
-- auth tests must start from a non-autologged state.
-- ---------------------------------------------------------------------------

INSERT INTO `USER` (`id_user`, `nickname`, `password`, `username`, `id_user_level`, `auth`)
VALUES (2, 'mboper', '*AE44FCBF2A029BA0F76B3DF897A0265E9EDB5BF9', 'mboper', 2, 0)
ON DUPLICATE KEY UPDATE
  `nickname` = VALUES(`nickname`),
  `password` = VALUES(`password`),
  `username` = VALUES(`username`),
  `id_user_level` = VALUES(`id_user_level`),
  `auth` = VALUES(`auth`);

INSERT INTO `USER_CHANNEL` (`id_user_channel`, `id_user`, `id_channel`, `level`, `automode`)
VALUES (2, 2, 1, 1, 'NONE')
ON DUPLICATE KEY UPDATE
  `id_user` = VALUES(`id_user`),
  `id_channel` = VALUES(`id_channel`),
  `level` = VALUES(`level`),
  `automode` = VALUES(`automode`);

-- ---------------------------------------------------------------------------
-- Test SQL command used by live tests.
-- ---------------------------------------------------------------------------

INSERT INTO `PUBLIC_COMMANDS`
  (`id_public_commands`, `id_user`, `id_public_commands_category`, `command`, `description`, `action`, `hits`, `active`)
VALUES
  (1, 1, 1, 'check', 'check', 'PRIVMSG %c I''m fine Houston, over.', 0, 1)
ON DUPLICATE KEY UPDATE
  `id_user` = VALUES(`id_user`),
  `id_public_commands_category` = VALUES(`id_public_commands_category`),
  `description` = VALUES(`description`),
  `action` = VALUES(`action`),
  `hits` = VALUES(`hits`),
  `active` = VALUES(`active`);
