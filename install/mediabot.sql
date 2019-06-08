SET SQL_MODE = "NO_AUTO_VALUE_ON_ZERO";
SET AUTOCOMMIT = 0;
START TRANSACTION;
SET time_zone = "+00:00";

-- --------------------------------------------------------

--
-- Structure de la table `ACTIONS_LOG`
--

CREATE TABLE `ACTIONS_LOG` (
  `id_actions_log` bigint(20) NOT NULL,
  `ts` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  `id_user` bigint(20) DEFAULT NULL,
  `id_channel` bigint(20) DEFAULT NULL,
  `hostmask` varchar(255) NOT NULL,
  `action` varchar(255) NOT NULL,
  `args` varchar(255) DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

-- --------------------------------------------------------

--
-- Structure de la table `ACTIONS_QUEUE`
--

CREATE TABLE `ACTIONS_QUEUE` (
  `id_actions_queue` bigint(20) NOT NULL,
  `ts` datetime NOT NULL,
  `command` varchar(255) NOT NULL,
  `params` varchar(255) NOT NULL,
  `result1` varchar(255) DEFAULT NULL,
  `result2` varchar(255) DEFAULT NULL,
  `result3` varchar(255) DEFAULT NULL,
  `result4` varchar(255) DEFAULT NULL,
  `result5` varchar(255) DEFAULT NULL,
  `result6` varchar(255) DEFAULT NULL,
  `status` int(11) NOT NULL DEFAULT '0'
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

-- --------------------------------------------------------

--
-- Structure de la table `CHANNEL`
--

CREATE TABLE `CHANNEL` (
  `id_channel` bigint(20) NOT NULL,
  `name` varchar(255) NOT NULL,
  `creation_date` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `description` varchar(255) DEFAULT NULL,
  `key` varchar(255) DEFAULT NULL,
  `chanmode` varchar(255) DEFAULT NULL,
  `auto_join` tinyint(1) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

-- --------------------------------------------------------

--
-- Structure de la table `CHANNEL_LOG`
--

CREATE TABLE `CHANNEL_LOG` (
  `id_channel_log` bigint(20) NOT NULL,
  `id_channel` bigint(20) DEFAULT NULL,
  `ts` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  `event_type` varchar(255) CHARACTER SET latin1 NOT NULL,
  `nick` varchar(255) CHARACTER SET latin1 NOT NULL,
  `userhost` varchar(255) NOT NULL,
  `publictext` varchar(255) CHARACTER SET latin1 DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

-- --------------------------------------------------------

--
-- Structure de la table `CHANNEL_PURGED`
--

CREATE TABLE `CHANNEL_PURGED` (
  `id_channel_purged` bigint(20) NOT NULL,
  `id_channel` bigint(20) NOT NULL,
  `name` varchar(255) NOT NULL,
  `purge_date` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `description` varchar(255) DEFAULT NULL,
  `key` varchar(255) DEFAULT NULL,
  `chanmode` varchar(255) DEFAULT NULL,
  `auto_join` tinyint(1) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

-- --------------------------------------------------------

--
-- Structure de la table `CONSOLE`
--

CREATE TABLE `CONSOLE` (
  `id_console` bigint(20) NOT NULL,
  `id_parent` bigint(20) DEFAULT NULL,
  `position` int(11) NOT NULL DEFAULT '1',
  `level` int(11) NOT NULL DEFAULT '0',
  `description` varchar(255) CHARACTER SET utf8 COLLATE utf8_unicode_ci NOT NULL,
  `url` varchar(255) CHARACTER SET utf8 COLLATE utf8_unicode_ci NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

--
-- Déchargement des données de la table `CONSOLE`
--

INSERT INTO `CONSOLE` (`id_console`, `id_parent`, `position`, `level`, `description`, `url`) VALUES
(16, NULL, 0, 999999, 'Profil', 'profile.php'),
(39, 41, 0, 0, 'Utilisateurs système', 'system_users.php'),
(41, NULL, 3, 0, 'Système', 'system.php'),
(45, NULL, 1, 1, 'Administration', 'admin.php'),
(46, 45, 0, 1, 'Utilisateurs', 'users.php'),
(49, 45, 1, 1, 'Channels', 'channels.php'),
(51, 45, 2, 0, 'Live', 'live.php'),
(52, NULL, 2, 3, 'Aide', 'help.php'),
(53, 52, 0, 3, 'Utilisateurs', 'help_users.php'),
(54, 52, 1, 2, 'Administrateurs', 'help_admins.php');

-- --------------------------------------------------------

--
-- Structure de la table `NETWORK`
--

CREATE TABLE `NETWORK` (
  `id_network` bigint(20) NOT NULL,
  `network_name` varchar(255) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

-- --------------------------------------------------------

--
-- Structure de la table `PUBLIC_COMMANDS`
--

CREATE TABLE `PUBLIC_COMMANDS` (
  `id_public_commands` bigint(20) NOT NULL,
  `id_user` bigint(20) DEFAULT NULL,
  `id_public_commands_category` bigint(20) NOT NULL,
  `creation_date` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `command` varchar(255) CHARACTER SET utf8 COLLATE utf8_unicode_ci NOT NULL,
  `description` varchar(255) CHARACTER SET utf8 COLLATE utf8_unicode_ci NOT NULL,
  `action` varchar(255) CHARACTER SET utf8 COLLATE utf8_unicode_ci NOT NULL,
  `hits` bigint(20) NOT NULL DEFAULT '0'
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

--
-- Déchargement des données de la table `PUBLIC_COMMANDS`
--

INSERT INTO `PUBLIC_COMMANDS` (`id_public_commands`, `id_user`, `id_public_commands_category`, `creation_date`, `command`, `description`, `action`, `hits`) VALUES
(2, NULL, 1, '2018-02-04 06:06:55', 'dice', 'Play dice', 'PRIVMSG %c The dice rolls... Result : %d', 1),
(3, NULL, 1, '2018-02-11 04:25:40', 'coffee', 'Coffee', 'ACTION %c serves 8,1c(05,01_08,01)15,01~ to %n', 1);

-- --------------------------------------------------------

--
-- Structure de la table `PUBLIC_COMMANDS_CATEGORY`
--

CREATE TABLE `PUBLIC_COMMANDS_CATEGORY` (
  `id_public_commands_category` bigint(20) NOT NULL,
  `description` varchar(255) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

--
-- Déchargement des données de la table `PUBLIC_COMMANDS_CATEGORY`
--

INSERT INTO `PUBLIC_COMMANDS_CATEGORY` (`id_public_commands_category`, `description`) VALUES
(1, 'General');

-- --------------------------------------------------------

--
-- Structure de la table `SERVERS`
--

CREATE TABLE `SERVERS` (
  `id_server` bigint(20) NOT NULL,
  `id_network` bigint(20) NOT NULL,
  `server_hostname` varchar(255) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

-- --------------------------------------------------------

--
-- Structure de la table `TIMERS`
--

CREATE TABLE `TIMERS` (
  `id_timers` bigint(20) NOT NULL,
  `name` varchar(255) CHARACTER SET utf8 NOT NULL,
  `duration` bigint(20) NOT NULL,
  `command` varchar(255) CHARACTER SET utf8 NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=latin1;

-- --------------------------------------------------------

--
-- Structure de la table `USER`
--

CREATE TABLE `USER` (
  `id_user` bigint(20) NOT NULL,
  `creation_date` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `hostmasks` varchar(255) CHARACTER SET latin1 NOT NULL DEFAULT '',
  `nickname` varchar(255) CHARACTER SET latin1 NOT NULL DEFAULT '',
  `password` varchar(255) CHARACTER SET latin1 DEFAULT NULL,
  `username` varchar(255) CHARACTER SET latin1 DEFAULT NULL,
  `id_user_level` bigint(20) NOT NULL,
  `info1` varchar(255) CHARACTER SET latin1 DEFAULT NULL,
  `info2` varchar(255) CHARACTER SET latin1 DEFAULT NULL,
  `last_login` timestamp NULL DEFAULT NULL,
  `auth` int(11) NOT NULL DEFAULT '0'
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

-- --------------------------------------------------------

--
-- Structure de la table `USER_CHANNEL`
--

CREATE TABLE `USER_CHANNEL` (
  `id_user_channel` bigint(20) NOT NULL,
  `id_user` bigint(20) NOT NULL,
  `id_channel` bigint(20) NOT NULL,
  `level` bigint(20) NOT NULL DEFAULT '0',
  `greet` varchar(255) CHARACTER SET latin1 DEFAULT NULL,
  `automode` varchar(255) CHARACTER SET latin1 NOT NULL DEFAULT 'NONE'
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

-- --------------------------------------------------------

--
-- Structure de la table `USER_LEVEL`
--

CREATE TABLE `USER_LEVEL` (
  `id_user_level` bigint(20) NOT NULL,
  `level` int(11) NOT NULL,
  `description` varchar(255) CHARACTER SET latin1 NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

--
-- Déchargement des données de la table `USER_LEVEL`
--

INSERT INTO `USER_LEVEL` (`id_user_level`, `level`, `description`) VALUES
(1, 0, 'Owner'),
(2, 1, 'Master'),
(3, 2, 'Administrator'),
(4, 3, 'User');

-- --------------------------------------------------------

--
-- Structure de la table `WEBLOG`
--

CREATE TABLE `WEBLOG` (
  `id_weblog` bigint(20) NOT NULL,
  `login_date` datetime NOT NULL,
  `nickname` varchar(255) NOT NULL,
  `password` varchar(255) DEFAULT NULL,
  `ip` varchar(255) NOT NULL,
  `hostname` varchar(255) DEFAULT NULL,
  `logresult` tinyint(1) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

--
-- Index pour les tables déchargées
--

--
-- Index pour la table `ACTIONS_LOG`
--
ALTER TABLE `ACTIONS_LOG`
  ADD PRIMARY KEY (`id_actions_log`);

--
-- Index pour la table `CHANNEL`
--
ALTER TABLE `CHANNEL`
  ADD PRIMARY KEY (`id_channel`),
  ADD UNIQUE KEY `name` (`name`);

--
-- Index pour la table `CHANNEL_LOG`
--
ALTER TABLE `CHANNEL_LOG`
  ADD PRIMARY KEY (`id_channel_log`),
  ADD KEY `ts` (`ts`),
  ADD KEY `nick` (`nick`),
  ADD KEY `userhost` (`userhost`);

--
-- Index pour la table `CHANNEL_PURGED`
--
ALTER TABLE `CHANNEL_PURGED`
  ADD PRIMARY KEY (`id_channel_purged`);

--
-- Index pour la table `CONSOLE`
--
ALTER TABLE `CONSOLE`
  ADD PRIMARY KEY (`id_console`);

--
-- Index pour la table `NETWORK`
--
ALTER TABLE `NETWORK`
  ADD PRIMARY KEY (`id_network`),
  ADD UNIQUE KEY `network_name` (`network_name`);

--
-- Index pour la table `PUBLIC_COMMANDS`
--
ALTER TABLE `PUBLIC_COMMANDS`
  ADD PRIMARY KEY (`id_public_commands`),
  ADD UNIQUE KEY `command` (`command`);

--
-- Index pour la table `PUBLIC_COMMANDS_CATEGORY`
--
ALTER TABLE `PUBLIC_COMMANDS_CATEGORY`
  ADD PRIMARY KEY (`id_public_commands_category`);

--
-- Index pour la table `SERVERS`
--
ALTER TABLE `SERVERS`
  ADD PRIMARY KEY (`id_server`);

--
-- Index pour la table `TIMERS`
--
ALTER TABLE `TIMERS`
  ADD PRIMARY KEY (`id_timers`),
  ADD UNIQUE KEY `name` (`name`);

--
-- Index pour la table `USER`
--
ALTER TABLE `USER`
  ADD PRIMARY KEY (`id_user`),
  ADD UNIQUE KEY `nickname` (`nickname`);

--
-- Index pour la table `USER_CHANNEL`
--
ALTER TABLE `USER_CHANNEL`
  ADD PRIMARY KEY (`id_user_channel`);

--
-- Index pour la table `USER_LEVEL`
--
ALTER TABLE `USER_LEVEL`
  ADD PRIMARY KEY (`id_user_level`);

--
-- Index pour la table `WEBLOG`
--
ALTER TABLE `WEBLOG`
  ADD PRIMARY KEY (`id_weblog`);

--
-- AUTO_INCREMENT pour les tables déchargées
--

--
-- AUTO_INCREMENT pour la table `ACTIONS_LOG`
--
ALTER TABLE `ACTIONS_LOG`
  MODIFY `id_actions_log` bigint(20) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT pour la table `CHANNEL`
--
ALTER TABLE `CHANNEL`
  MODIFY `id_channel` bigint(20) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT pour la table `CHANNEL_LOG`
--
ALTER TABLE `CHANNEL_LOG`
  MODIFY `id_channel_log` bigint(20) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT pour la table `CHANNEL_PURGED`
--
ALTER TABLE `CHANNEL_PURGED`
  MODIFY `id_channel_purged` bigint(20) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT pour la table `CONSOLE`
--
ALTER TABLE `CONSOLE`
  MODIFY `id_console` bigint(20) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=55;

--
-- AUTO_INCREMENT pour la table `NETWORK`
--
ALTER TABLE `NETWORK`
  MODIFY `id_network` bigint(20) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT pour la table `PUBLIC_COMMANDS`
--
ALTER TABLE `PUBLIC_COMMANDS`
  MODIFY `id_public_commands` bigint(20) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=12;

--
-- AUTO_INCREMENT pour la table `PUBLIC_COMMANDS_CATEGORY`
--
ALTER TABLE `PUBLIC_COMMANDS_CATEGORY`
  MODIFY `id_public_commands_category` bigint(20) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=4;

--
-- AUTO_INCREMENT pour la table `SERVERS`
--
ALTER TABLE `SERVERS`
  MODIFY `id_server` bigint(20) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT pour la table `TIMERS`
--
ALTER TABLE `TIMERS`
  MODIFY `id_timers` bigint(20) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=8;

--
-- AUTO_INCREMENT pour la table `USER`
--
ALTER TABLE `USER`
  MODIFY `id_user` bigint(20) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT pour la table `USER_CHANNEL`
--
ALTER TABLE `USER_CHANNEL`
  MODIFY `id_user_channel` bigint(20) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT pour la table `USER_LEVEL`
--
ALTER TABLE `USER_LEVEL`
  MODIFY `id_user_level` bigint(20) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=5;

--
-- AUTO_INCREMENT pour la table `WEBLOG`
--
ALTER TABLE `WEBLOG`
  MODIFY `id_weblog` bigint(20) NOT NULL AUTO_INCREMENT;

--
-- Structure de la table `CHANNEL_SET`
--

CREATE TABLE `CHANNEL_SET` (
  `id_channel_set` bigint(20) NOT NULL,
  `id_channel` bigint(20) NOT NULL,
  `id_chanset_list` bigint(20) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=latin1;

-- --------------------------------------------------------

--
-- Structure de la table `CHANSET_LIST`
--

CREATE TABLE `CHANSET_LIST` (
  `id_chanset_list` bigint(20) NOT NULL,
  `chanset` varchar(255) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=latin1;

--
-- Index pour les tables déchargées
--

--
-- Index pour la table `CHANNEL_SET`
--
ALTER TABLE `CHANNEL_SET`
  ADD PRIMARY KEY (`id_channel_set`);

--
-- Index pour la table `CHANSET_LIST`
--
ALTER TABLE `CHANSET_LIST`
  ADD PRIMARY KEY (`id_chanset_list`);

--
-- AUTO_INCREMENT pour les tables déchargées
--

--
-- AUTO_INCREMENT pour la table `CHANNEL_SET`
--
ALTER TABLE `CHANNEL_SET`
  MODIFY `id_channel_set` bigint(20) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT pour la table `CHANSET_LIST`
--
ALTER TABLE `CHANSET_LIST`
  MODIFY `id_chanset_list` bigint(20) NOT NULL AUTO_INCREMENT;

INSERT INTO `CHANSET_LIST` (`id_chanset_list`, `chanset`) VALUES (1, 'Youtube');
COMMIT;
