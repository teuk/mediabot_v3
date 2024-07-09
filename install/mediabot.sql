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
  `auto_join` tinyint(1) NOT NULL,
  `notice` varchar(255) DEFAULT NULL
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
  `auth` int(11) NOT NULL DEFAULT '0',
  `tz` varchar(255) DEFAULT NULL,
  `birthday` varchar(255) DEFAULT NULL,
  `fortniteid` varchar(255) DEFAULT NULL
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

INSERT INTO `CHANSET_LIST` (`id_chanset_list`, `chanset`) VALUES
(1, 'Youtube'),
(2, 'UrlTitle'),
(3, 'Weather'),
(4, 'YoutubeSearch'),
(5, 'NoColors'),
(6, 'AntiFlood'),
(7, 'Hailo'),
(8, 'HailoChatter'),
(9, 'RadioPub'),
(10, 'Twitter'),
(11, 'chatGPT'),
(11, 'AppleMusic');

-- --------------------------------------------------------

--
-- Structure de la table `RESPONDERS`
--

CREATE TABLE `RESPONDERS` (
  `id_responders` bigint(20) NOT NULL,
  `id_channel` bigint(20) NOT NULL DEFAULT '0',
  `hits` bigint(20) NOT NULL DEFAULT '0',
  `chance` bigint(20) NOT NULL DEFAULT '95',
  `responder` varchar(255) NOT NULL,
  `answer` varchar(255) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

--
-- Index pour les tables déchargées
--

--
-- Index pour la table `RESPONDERS`
--
ALTER TABLE `RESPONDERS`
  ADD PRIMARY KEY (`id_responders`);

--
-- AUTO_INCREMENT pour les tables déchargées
--

--
-- AUTO_INCREMENT pour la table `RESPONDERS`
--
ALTER TABLE `RESPONDERS`
  MODIFY `id_responders` bigint(20) NOT NULL AUTO_INCREMENT;
  
-- --------------------------------------------------------

--
-- Structure de la table `BADWORDS`
--

CREATE TABLE `BADWORDS` (
  `id_badwords` bigint(20) NOT NULL,
  `id_channel` bigint(20) NOT NULL DEFAULT '0',
  `badword` varchar(255) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

--
-- Index pour les tables déchargées
--

--
-- Index pour la table `BADWORDS`
--
ALTER TABLE `BADWORDS`
  ADD PRIMARY KEY (`id_badwords`),
  ADD KEY `badword` (`badword`);

--
-- AUTO_INCREMENT pour les tables déchargées
--

--
-- AUTO_INCREMENT pour la table `BADWORDS`
--
ALTER TABLE `BADWORDS`
  MODIFY `id_badwords` bigint(20) NOT NULL AUTO_INCREMENT;
  
CREATE TABLE `IGNORES` (
  `id_ignores` bigint(20) NOT NULL,
  `id_channel` bigint(20) NOT NULL DEFAULT '0',
  `hostmask` varchar(255) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

--
-- Index pour les tables déchargées
--

--
-- Index pour la table `IGNORES`
--
ALTER TABLE `IGNORES`
  ADD PRIMARY KEY (`id_ignores`),
  ADD KEY `hostmask` (`hostmask`);

--
-- AUTO_INCREMENT pour les tables déchargées
--

--
-- AUTO_INCREMENT pour la table `IGNORES`
--
ALTER TABLE `IGNORES`
  MODIFY `id_ignores` bigint(20) NOT NULL AUTO_INCREMENT;
  
CREATE TABLE `QUOTES` (
  `id_quotes` bigint(20) NOT NULL,
  `id_channel` bigint(20) NOT NULL,
  `id_user` bigint(20) NOT NULL,
  `ts` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `quotetext` varchar(255) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

--
-- Index pour les tables déchargées
--

--
-- Index pour la table `QUOTES`
--
ALTER TABLE `QUOTES`
  ADD PRIMARY KEY (`id_quotes`);

--
-- AUTO_INCREMENT pour les tables déchargées
--

--
-- AUTO_INCREMENT pour la table `QUOTES`
--
ALTER TABLE `QUOTES`
  MODIFY `id_quotes` bigint(20) NOT NULL AUTO_INCREMENT;
  
--
-- Structure de la table `CHANNEL_FLOOD`
--

CREATE TABLE `CHANNEL_FLOOD` (
  `id_channel_flood` bigint(20) NOT NULL,
  `id_channel` bigint(20) NOT NULL,
  `nbmsg_max` int(11) NOT NULL DEFAULT '5',
  `nbmsg` int(11) NOT NULL DEFAULT '0',
  `duration` int(11) NOT NULL DEFAULT '30',
  `first` int(11) DEFAULT '0',
  `latest` bigint(20) NOT NULL DEFAULT '0',
  `timetowait` int(11) NOT NULL DEFAULT '300',
  `notification` int(11) NOT NULL DEFAULT '0'
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

--
-- Index pour les tables déchargées
--

--
-- Index pour la table `CHANNEL_FLOOD`
--
ALTER TABLE `CHANNEL_FLOOD`
  ADD PRIMARY KEY (`id_channel_flood`);

--
-- AUTO_INCREMENT pour les tables déchargées
--

--
-- AUTO_INCREMENT pour la table `CHANNEL_FLOOD`
--
ALTER TABLE `CHANNEL_FLOOD`
  MODIFY `id_channel_flood` bigint(20) NOT NULL AUTO_INCREMENT;

CREATE TABLE `MP3` (
  `id_mp3` bigint(20) NOT NULL,
  `id_user` bigint(20) NOT NULL,
  `id_youtube` varchar(255) NOT NULL,
  `folder` varchar(255) NOT NULL,
  `filename` varchar(255) NOT NULL,
  `artist` varchar(255) NOT NULL,
  `title` varchar(255) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

--
-- Index pour les tables déchargées
--

--
-- Index pour la table `MP3`
--
ALTER TABLE `MP3`
  ADD PRIMARY KEY (`id_mp3`);

--
-- AUTO_INCREMENT pour les tables déchargées
--

--
-- AUTO_INCREMENT pour la table `MP3`
--
ALTER TABLE `MP3`
  MODIFY `id_mp3` bigint(20) NOT NULL AUTO_INCREMENT;

--
-- Structure de la table `HAILO_EXCLUSION_NICK`
--

CREATE TABLE `HAILO_EXCLUSION_NICK` (
  `id_hailo_exclusion_nick` bigint(20) NOT NULL,
  `nick` varchar(255) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

--
-- Index pour les tables déchargées
--

--
-- Index pour la table `HAILO_EXCLUSION_NICK`
--
ALTER TABLE `HAILO_EXCLUSION_NICK`
  ADD PRIMARY KEY (`id_hailo_exclusion_nick`),
  ADD KEY `nick` (`nick`);

--
-- AUTO_INCREMENT pour les tables déchargées
--

--
-- AUTO_INCREMENT pour la table `HAILO_EXCLUSION_NICK`
--
ALTER TABLE `HAILO_EXCLUSION_NICK`
  MODIFY `id_hailo_exclusion_nick` bigint(20) NOT NULL AUTO_INCREMENT;

--
-- Structure de la table `HAILO_CHANNEL`
--

CREATE TABLE `HAILO_CHANNEL` (
  `id_hailo_channel` bigint(20) NOT NULL,
  `id_channel` bigint(20) NOT NULL,
  `ratio` int(11) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

--
-- Index pour les tables déchargées
--

--
-- Index pour la table `HAILO_CHANNEL`
--
ALTER TABLE `HAILO_CHANNEL`
  ADD PRIMARY KEY (`id_hailo_channel`),
  ADD UNIQUE KEY `id_channel` (`id_channel`);

--
-- AUTO_INCREMENT pour les tables déchargées
--

--
-- AUTO_INCREMENT pour la table `HAILO_CHANNEL`
--
ALTER TABLE `HAILO_CHANNEL`
  MODIFY `id_hailo_channel` bigint(20) NOT NULL AUTO_INCREMENT;

--
-- Structure de la table `TIMEZONE`
--

CREATE TABLE `TIMEZONE` (
  `id_timezone` bigint(20) NOT NULL,
  `tz` varchar(255) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

--
-- Déchargement des données de la table `TIMEZONE`
--

INSERT INTO `TIMEZONE` (`id_timezone`, `tz`) VALUES
(1, 'Africa/Abidjan'),
(2, 'Africa/Accra'),
(3, 'Africa/Addis_Ababa'),
(4, 'Africa/Algiers'),
(5, 'Africa/Bangui'),
(6, 'Africa/Bissau'),
(7, 'Africa/Blantyre'),
(8, 'Africa/Casablanca'),
(9, 'Africa/Ceuta'),
(10, 'Africa/El_Aaiun'),
(11, 'Africa/Johannesburg'),
(12, 'Africa/Juba'),
(13, 'Africa/Khartoum'),
(14, 'Africa/Monrovia'),
(15, 'Africa/Ndjamena'),
(16, 'Africa/Sao_Tome'),
(17, 'Africa/Tunis'),
(18, 'Africa/Windhoek'),
(19, 'America/Adak'),
(20, 'America/Anchorage'),
(21, 'America/Anguilla'),
(22, 'America/Araguaina'),
(23, 'America/Argentina/La_Rioja'),
(24, 'America/Argentina/Rio_Gallegos'),
(25, 'America/Argentina/Salta'),
(26, 'America/Argentina/San_Juan'),
(27, 'America/Argentina/San_Luis'),
(28, 'America/Argentina/Tucuman'),
(29, 'America/Argentina/Ushuaia'),
(30, 'America/Aruba'),
(31, 'America/Asuncion'),
(32, 'America/Atikokan'),
(33, 'America/Bahia'),
(34, 'America/Bahia_Banderas'),
(35, 'America/Barbados'),
(36, 'America/Belem'),
(37, 'America/Belize'),
(38, 'America/Blanc-Sablon'),
(39, 'America/Boa_Vista'),
(40, 'America/Bogota'),
(41, 'America/Boise'),
(42, 'America/Buenos_Aires'),
(43, 'America/Cambridge_Bay'),
(44, 'America/Campo_Grande'),
(45, 'America/Cancun'),
(46, 'America/Caracas'),
(47, 'America/Catamarca'),
(48, 'America/Cayenne'),
(49, 'America/Cayman'),
(50, 'America/Chicago'),
(51, 'America/Chihuahua'),
(52, 'America/Cordoba'),
(53, 'America/Costa_Rica'),
(54, 'America/Creston'),
(55, 'America/Cuiaba'),
(56, 'America/Danmarkshavn'),
(57, 'America/Dawson'),
(58, 'America/Dawson_Creek'),
(59, 'America/Detroit'),
(60, 'America/Edmonton'),
(61, 'America/Eirunepe'),
(62, 'America/El_Salvador'),
(63, 'America/Ensenada'),
(64, 'America/Fortaleza'),
(65, 'America/Fort_Nelson'),
(66, 'America/Fort_Wayne'),
(67, 'America/Glace_Bay'),
(68, 'America/Godthab'),
(69, 'America/Goose_Bay'),
(70, 'America/Grand_Turk'),
(71, 'America/Guatemala'),
(72, 'America/Guayaquil'),
(73, 'America/Guyana'),
(74, 'America/Halifax'),
(75, 'America/Hermosillo'),
(76, 'America/Indiana/Marengo'),
(77, 'America/Indiana/Petersburg'),
(78, 'America/Indiana/Tell_City'),
(79, 'America/Indiana/Vevay'),
(80, 'America/Indiana/Vincennes'),
(81, 'America/Indiana/Winamac'),
(82, 'America/Inuvik'),
(83, 'America/Iqaluit'),
(84, 'America/Jujuy'),
(85, 'America/Juneau'),
(86, 'America/Kentucky/Monticello'),
(87, 'America/Knox_IN'),
(88, 'America/La_Paz'),
(89, 'America/Lima'),
(90, 'America/Los_Angeles'),
(91, 'America/Louisville'),
(92, 'America/Maceio'),
(93, 'America/Managua'),
(94, 'America/Manaus'),
(95, 'America/Martinique'),
(96, 'America/Matamoros'),
(97, 'America/Mazatlan'),
(98, 'America/Mendoza'),
(99, 'America/Menominee'),
(100, 'America/Merida'),
(101, 'America/Metlakatla'),
(102, 'America/Mexico_City'),
(103, 'America/Miquelon'),
(104, 'America/Moncton'),
(105, 'America/Monterrey'),
(106, 'America/Montevideo'),
(107, 'America/Montreal'),
(108, 'America/Nassau'),
(109, 'America/New_York'),
(110, 'America/Nipigon'),
(111, 'America/Nome'),
(112, 'America/Noronha'),
(113, 'America/North_Dakota/Beulah'),
(114, 'America/North_Dakota/Center'),
(115, 'America/North_Dakota/New_Salem'),
(116, 'America/Ojinaga'),
(117, 'America/Pangnirtung'),
(118, 'America/Paramaribo'),
(119, 'America/Phoenix'),
(120, 'America/Port-au-Prince'),
(121, 'America/Porto_Acre'),
(122, 'America/Porto_Velho'),
(123, 'America/Puerto_Rico'),
(124, 'America/Punta_Arenas'),
(125, 'America/Rainy_River'),
(126, 'America/Rankin_Inlet'),
(127, 'America/Recife'),
(128, 'America/Regina'),
(129, 'America/Resolute'),
(130, 'America/Santarem'),
(131, 'America/Santiago'),
(132, 'America/Santo_Domingo'),
(133, 'America/Sao_Paulo'),
(134, 'America/Scoresbysund'),
(135, 'America/Sitka'),
(136, 'America/St_Johns'),
(137, 'America/Swift_Current'),
(138, 'America/Tegucigalpa'),
(139, 'America/Thule'),
(140, 'America/Thunder_Bay'),
(141, 'America/Vancouver'),
(142, 'America/Whitehorse'),
(143, 'America/Winnipeg'),
(144, 'America/Yakutat'),
(145, 'America/Yellowknife'),
(146, 'Antarctica/Casey'),
(147, 'Antarctica/Davis'),
(148, 'Antarctica/DumontDUrville'),
(149, 'Antarctica/Macquarie'),
(150, 'Antarctica/Mawson'),
(151, 'Antarctica/Palmer'),
(152, 'Antarctica/Rothera'),
(153, 'Antarctica/Syowa'),
(154, 'Antarctica/Troll'),
(155, 'Antarctica/Vostok'),
(156, 'Arctic/Longyearbyen'),
(157, 'Asia/Aden'),
(158, 'Asia/Almaty'),
(159, 'Asia/Amman'),
(160, 'Asia/Anadyr'),
(161, 'Asia/Aqtau'),
(162, 'Asia/Aqtobe'),
(163, 'Asia/Ashgabat'),
(164, 'Asia/Atyrau'),
(165, 'Asia/Baghdad'),
(166, 'Asia/Bahrain'),
(167, 'Asia/Baku'),
(168, 'Asia/Bangkok'),
(169, 'Asia/Barnaul'),
(170, 'Asia/Beirut'),
(171, 'Asia/Bishkek'),
(172, 'Asia/Brunei'),
(173, 'Asia/Calcutta'),
(174, 'Asia/Chita'),
(175, 'Asia/Choibalsan'),
(176, 'Asia/Colombo'),
(177, 'Asia/Dacca'),
(178, 'Asia/Damascus'),
(179, 'Asia/Dili'),
(180, 'Asia/Dubai'),
(181, 'Asia/Dushanbe'),
(182, 'Asia/Famagusta'),
(183, 'Asia/Gaza'),
(184, 'Asia/Hebron'),
(185, 'Asia/Ho_Chi_Minh'),
(186, 'Asia/Hovd'),
(187, 'Asia/Irkutsk'),
(188, 'Asia/Jakarta'),
(189, 'Asia/Jayapura'),
(190, 'Asia/Kabul'),
(191, 'Asia/Kamchatka'),
(192, 'Asia/Karachi'),
(193, 'Asia/Kashgar'),
(194, 'Asia/Kathmandu'),
(195, 'Asia/Khandyga'),
(196, 'Asia/Krasnoyarsk'),
(197, 'Asia/Kuala_Lumpur'),
(198, 'Asia/Kuching'),
(199, 'Asia/Macao'),
(200, 'Asia/Magadan'),
(201, 'Asia/Makassar'),
(202, 'Asia/Manila'),
(203, 'Asia/Nicosia'),
(204, 'Asia/Novokuznetsk'),
(205, 'Asia/Novosibirsk'),
(206, 'Asia/Omsk'),
(207, 'Asia/Oral'),
(208, 'Asia/Pontianak'),
(209, 'Asia/Pyongyang'),
(210, 'Asia/Qostanay'),
(211, 'Asia/Qyzylorda'),
(212, 'Asia/Rangoon'),
(213, 'Asia/Sakhalin'),
(214, 'Asia/Samarkand'),
(215, 'Asia/Srednekolymsk'),
(216, 'Asia/Tashkent'),
(217, 'Asia/Tbilisi'),
(218, 'Asia/Thimbu'),
(219, 'Asia/Tomsk'),
(220, 'Asia/Ulaanbaatar'),
(221, 'Asia/Ust-Nera'),
(222, 'Asia/Vladivostok'),
(223, 'Asia/Yakutsk'),
(224, 'Asia/Yekaterinburg'),
(225, 'Asia/Yerevan'),
(226, 'Atlantic/Azores'),
(227, 'Atlantic/Bermuda'),
(228, 'Atlantic/Canary'),
(229, 'Atlantic/Cape_Verde'),
(230, 'Atlantic/Faeroe'),
(231, 'Atlantic/Madeira'),
(232, 'Atlantic/South_Georgia'),
(233, 'Atlantic/Stanley'),
(234, 'Australia/ACT'),
(235, 'Australia/Adelaide'),
(236, 'Australia/Brisbane'),
(237, 'Australia/Broken_Hill'),
(238, 'Australia/Currie'),
(239, 'Australia/Darwin'),
(240, 'Australia/Eucla'),
(241, 'Australia/LHI'),
(242, 'Australia/Lindeman'),
(243, 'Australia/Melbourne'),
(244, 'Australia/Perth'),
(245, 'CET'),
(246, 'Chile/EasterIsland'),
(247, 'CST6CDT'),
(248, 'Cuba'),
(249, 'EET'),
(250, 'Egypt'),
(251, 'Eire'),
(252, 'EST'),
(253, 'EST5EDT'),
(254, 'Etc/GMT-1'),
(255, 'Etc/GMT+1'),
(256, 'Etc/GMT-10'),
(257, 'Etc/GMT+10'),
(258, 'Etc/GMT-11'),
(259, 'Etc/GMT+11'),
(260, 'Etc/GMT-12'),
(261, 'Etc/GMT+12'),
(262, 'Etc/GMT-13'),
(263, 'Etc/GMT-14'),
(264, 'Etc/GMT-2'),
(265, 'Etc/GMT+2'),
(266, 'Etc/GMT-3'),
(267, 'Etc/GMT+3'),
(268, 'Etc/GMT-4'),
(269, 'Etc/GMT+4'),
(270, 'Etc/GMT-5'),
(271, 'Etc/GMT+5'),
(272, 'Etc/GMT-6'),
(273, 'Etc/GMT+6'),
(274, 'Etc/GMT-7'),
(275, 'Etc/GMT+7'),
(276, 'Etc/GMT-8'),
(277, 'Etc/GMT+8'),
(278, 'Etc/GMT-9'),
(279, 'Etc/GMT+9'),
(280, 'Europe/Amsterdam'),
(281, 'Europe/Andorra'),
(282, 'Europe/Astrakhan'),
(283, 'Europe/Athens'),
(284, 'Europe/Belgrade'),
(285, 'Europe/Berlin'),
(286, 'Europe/Bratislava'),
(287, 'Europe/Brussels'),
(288, 'Europe/Bucharest'),
(289, 'Europe/Budapest'),
(290, 'Europe/Busingen'),
(291, 'Europe/Chisinau'),
(292, 'Europe/Copenhagen'),
(293, 'Europe/Gibraltar'),
(294, 'Europe/Helsinki'),
(295, 'Europe/Kaliningrad'),
(296, 'Europe/Kiev'),
(297, 'Europe/Kirov'),
(298, 'Europe/Luxembourg'),
(299, 'Europe/Madrid'),
(300, 'Europe/Malta'),
(301, 'Europe/Minsk'),
(302, 'Europe/Monaco'),
(303, 'Europe/Paris'),
(304, 'Europe/Riga'),
(305, 'Europe/Rome'),
(306, 'Europe/Samara'),
(307, 'Europe/Saratov'),
(308, 'Europe/Simferopol'),
(309, 'Europe/Sofia'),
(310, 'Europe/Stockholm'),
(311, 'Europe/Tallinn'),
(312, 'Europe/Tirane'),
(313, 'Europe/Ulyanovsk'),
(314, 'Europe/Uzhgorod'),
(315, 'Europe/Vienna'),
(316, 'Europe/Vilnius'),
(317, 'Europe/Volgograd'),
(318, 'Europe/Zaporozhye'),
(319, 'Factory'),
(320, 'GB'),
(321, 'GMT'),
(322, 'Hongkong'),
(323, 'HST'),
(324, 'Iceland'),
(325, 'Indian/Chagos'),
(326, 'Indian/Christmas'),
(327, 'Indian/Cocos'),
(328, 'Indian/Kerguelen'),
(329, 'Indian/Mahe'),
(330, 'Indian/Maldives'),
(331, 'Indian/Mauritius'),
(332, 'Indian/Reunion'),
(333, 'Iran'),
(334, 'Israel'),
(335, 'Jamaica'),
(336, 'Japan'),
(337, 'Kwajalein'),
(338, 'leap-seconds.list'),
(339, 'Libya'),
(340, 'MET'),
(341, 'MST'),
(342, 'MST7MDT'),
(343, 'Navajo'),
(344, 'NZ'),
(345, 'NZ-CHAT'),
(346, 'Pacific/Apia'),
(347, 'Pacific/Bougainville'),
(348, 'Pacific/Chuuk'),
(349, 'Pacific/Efate'),
(350, 'Pacific/Enderbury'),
(351, 'Pacific/Fakaofo'),
(352, 'Pacific/Fiji'),
(353, 'Pacific/Funafuti'),
(354, 'Pacific/Galapagos'),
(355, 'Pacific/Gambier'),
(356, 'Pacific/Guadalcanal'),
(357, 'Pacific/Guam'),
(358, 'Pacific/Honolulu'),
(359, 'Pacific/Kiritimati'),
(360, 'Pacific/Kosrae'),
(361, 'Pacific/Majuro'),
(362, 'Pacific/Marquesas'),
(363, 'Pacific/Midway'),
(364, 'Pacific/Nauru'),
(365, 'Pacific/Niue'),
(366, 'Pacific/Norfolk'),
(367, 'Pacific/Noumea'),
(368, 'Pacific/Palau'),
(369, 'Pacific/Pitcairn'),
(370, 'Pacific/Pohnpei'),
(371, 'Pacific/Port_Moresby'),
(372, 'Pacific/Rarotonga'),
(373, 'Pacific/Tahiti'),
(374, 'Pacific/Tarawa'),
(375, 'Pacific/Tongatapu'),
(376, 'Pacific/Wake'),
(377, 'Pacific/Wallis'),
(378, 'Poland'),
(379, 'Portugal'),
(380, 'posixrules'),
(381, 'PRC'),
(382, 'PST8PDT'),
(383, 'ROC'),
(384, 'ROK'),
(385, 'Singapore'),
(386, 'Turkey'),
(387, 'UCT'),
(388, 'WET'),
(389, 'W-SU');

--
-- Index pour les tables déchargées
--

--
-- Index pour la table `TIMEZONE`
--
ALTER TABLE `TIMEZONE`
  ADD PRIMARY KEY (`id_timezone`);

--
-- AUTO_INCREMENT pour les tables déchargées
--

--
-- AUTO_INCREMENT pour la table `TIMEZONE`
--
ALTER TABLE `TIMEZONE`
  MODIFY `id_timezone` bigint(20) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=390;

--
-- Structure de la table `YOMOMMA`
--

CREATE TABLE `YOMOMMA` (
  `id_yomomma` bigint(20) NOT NULL,
  `yomomma` varchar(255) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=latin1;

--
-- Déchargement des données de la table `YOMOMMA`
--

INSERT INTO `YOMOMMA` (`id_yomomma`, `yomomma`) VALUES
(1, 'Yo\' momma\'s so fat, she\'s on both sides of the family!'),
(2, 'Yo\' momma\'s so fat, she gets stuck in her dreams!'),
(3, 'Yo\' momma\'s so fat, she uses the swimming pool as a toilet!'),
(4, 'Yo\' momma\'s so fat, she uses a basketball as a hackey sack!'),
(5, 'Yo\' momma\'s so fat, when she says \"no one can eat just one,\" she means large, deep dish pizzas!'),
(6, 'Yo\' momma\'s so fat, she keeps her extra change in one of her folds!'),
(7, 'Yo\' momma\'s so fat, when yo\' daddy makes love to her, he never makes love to the same fold twice!'),
(8, 'Yo\' momma\'s so fat, NASA hauls her to the top of a tower, pushes her off, she falls 300 feet, hits a board and launches the space shuttle...!'),
(9, 'Yo\' momma\'s so fat, she says her job title is Spoon and Fork Operator!'),
(10, 'Yo\' momma\'s so fat, she put on a gray dress, and an admiral boarded her!'),
(11, 'Yo\' momma\'s so fat, she can lay down and stand up, and her height doesn\'t change!'),
(12, 'Yo\' momma\'s so fat, she\'s taller lying down!'),
(13, 'Yo\' momma\'s so fat, when she works at the theater, she works as the screen!'),
(14, 'Yo\' momma\'s so fat, her belly jiggle is the first perpetual motion machine!'),
(15, 'Yo\' momma\'s so fat, when she gets in an elevator, it HAS to go down!'),
(16, 'Yo\' momma\'s so fat, when I said I wanted \'pigs in a blanket,\' she got back in bed!'),
(17, 'Yo\' momma\'s so fat, when she was diagnosed with the flesh eating disease, the doctor gave her five YEARS to live!'),
(18, 'Yo\' momma\'s so fat, she was born with a silver shovel in her mouth!'),
(19, 'Yo\' momma\'s so fat, she\'s got smaller fat women orbiting around her!'),
(20, 'Yo\' momma\'s so fat, she could sell shade!'),
(21, 'Yo\' momma\'s so fat, her cereal bowl came with a lifeguard!'),
(22, 'Yo\' momma\'s so fat, she makes a Zephlin look like a toy!'),
(23, 'Yo\' momma\'s so fat, when she crosses the street, cars look out for her!'),
(24, 'Yo\' momma\'s so fat, she got hit by a car and the car sued for damages!'),
(25, 'Yo\' momma\'s so fat, she has been declared a natural habitat for condors!'),
(26, 'Yo\' momma\'s so fat, she puts mayonnaise on aspirin!'),
(27, 'Yo\' momma\'s so fat, I ran around her twice and got lost!'),
(28, 'Yo\' momma\'s so fat, I gotta take three steps back just to see all of her!'),
(29, 'Yo\' momma\'s so fat, her *ss has its own congressman!'),
(30, 'Yo\' momma\'s so fat, when she stepped on a train track, the warning lights went on!'),
(31, 'Yo\' momma\'s so fat, she wears a train as a belt!'),
(32, 'Yo\' momma\'s so fat, she shops for clothes in the local tent shop!'),
(33, 'Yo\' momma\'s so fat, when she goes to the circus, she sees the big top and asks, \"Where can I try that on?!\"'),
(34, 'Yo\' momma\'s so fat, when she brought her dress to the cleaners, they said, \"Sorry, we don\'t do curtains!\"'),
(35, 'Yo\' momma\'s so fat, when she goes to the circus, she takes up all the rings!'),
(36, 'Yo\' momma\'s so fat, \"Place Your Ad Here\" is printed on each of her butt cheeks!'),
(37, 'Yo\' momma\'s so fat, she\'s got Amtrak tattooed on her leg!'),
(38, 'Yo\' momma\'s so fat, when she leaves the beach, everybody shouts, \"The coast is clear!\"'),
(39, 'Yo\' momma\'s so fat, they used her for a trampoline at the Olympics!'),
(40, 'Yo\' momma\'s so fat, she went on a light diet...as soon as it\'s light, she starts eating!'),
(41, 'Yo\' momma\'s so fat, she went on a seafood diet...whenever she saw food, she ate it!'),
(42, 'Yo\' momma\'s so fat, when she bends over, we go into daylight savings time!'),
(43, 'Yo\' momma\'s so fat, she\'s half Indian, half Irish, and half French!'),
(44, 'Yo\' momma\'s so fat, when I climbed up on top of her, I burned my *ss on the light bulb!'),
(45, 'Yo\' momma\'s so fat, when she turns around, people throw her a welcome back party!'),
(46, 'Yo\' momma\'s so fat, she can\'t even jump to a conclusion!'),
(47, 'Yo\' momma\'s so fat, she\'s moving the Earth out of its orbit!'),
(48, 'Yo\' momma\'s so fat, I gain weight just by watching her eat!'),
(49, 'Yo\' momma\'s so fat, when she takes a shower, her feet don\'t get wet!'),
(50, 'Yo\' momma\'s so fat, when she comes down the stairs, she measures on the Richter scale!'),
(51, 'Yo\' momma\'s so fat, when she walks down the street, everyone yells \"Earthquake!\"'),
(52, 'Yo\' momma\'s so fat, when she fills up the tub, she FILLS UP the tub!'),
(53, 'Yo\' momma\'s so fat, she fills up the bathtub - THEN puts the water in!'),
(54, 'Yo\' momma\'s so fat, she gets stuck in the bathtub! And that\'s when she\'s standing up!'),
(55, 'Yo\' momma\'s so fat, it takes a forklift to help her stand up!'),
(56, 'Yo\' momma\'s so fat, they\'re going to use her to fill that hole in the ozone layer!'),
(57, 'Yo\' momma\'s so fat, she looks like the Stay-Puft marshmallow man on steroids!'),
(58, 'Yo\' momma\'s so fat, she has 48 midnight snacks!'),
(59, 'Yo\' momma\'s so fat, when she walks down the street, you can hear her hips saying to each other \"If you let me by, I\'ll let you pass!\"'),
(60, 'Yo\' momma\'s so fat, she jumped in the ocean, and the whales started singing, \"We are family!\"'),
(61, 'Yo\' momma\'s so fat, she plays pool with the planets!'),
(62, 'Yo\' momma\'s so fat, the only thing she can fit into at the clothing store is the dressing rooms!'),
(63, 'Yo\' momma\'s so fat, she uses the carpet as a blanket!'),
(64, 'Yo\' momma\'s so fat, when she wears corduroy pants, the ridges don\'t show!'),
(65, 'Yo\' momma\'s so fat, she made Richard Simmons cry!'),
(66, 'Yo\' momma\'s so fat, when she wears a yellow raincoat, kids think it\'s the school bus!'),
(67, 'Yo\' momma\'s so fat, when she wore a yellow raincoat, people said, \"Taxi!\"'),
(68, 'Yo\' momma\'s so fat, when she wears a purple sweater, people call her \"Barney\"!'),
(69, 'Yo\' momma\'s so fat, when she went to get a water bed, they put a blanket across Lake Michigan!'),
(70, 'Yo\' momma\'s so fat, she don\'t know whether she\'s walking or rolling!'),
(71, 'Yo\' momma\'s so fat, they had to paint a stripe down her back to see if she was walking or rolling!'),
(72, 'Yo\' momma\'s so fat, when she falls over, she just rolls right back up!'),
(73, 'Yo\' momma\'s so fat, she makes Sumo wrestlers look anorexic!'),
(74, 'Yo\' momma\'s so fat, she makes Big Bird look like a rubber duck!'),
(75, 'Yo\' momma\'s so fat, when she wore a shirt with an AA on it, people thought she was American Airlines\' biggest jet!'),
(76, 'Yo\' momma\'s so fat, if she were an airplane, she\'d be a jumbo jet!'),
(77, 'Yo\' momma\'s so fat, when she sits in a chair, the rolls on her legs cover her feet like a blanket!'),
(78, 'Yo\' momma\'s so fat, she was lifting up her rolls, and a car fell out!'),
(79, 'Yo\' momma\'s so fat, she went into a bakery, and they tried to butter her rolls!'),
(80, 'Yo\' momma\'s so fat, Dr. Martens had to kill three cows just to make her a pair of shoes!'),
(81, 'Yo\' momma\'s so fat, she can\'t stay on a basketball court for three seconds without getting called for a key violation!'),
(82, 'Yo\' momma\'s so fat, she climbed Mt. Fuji with one step!'),
(83, 'Yo\' momma\'s so fat, all the chairs in her house have seat belts!'),
(84, 'Yo\' momma\'s so fat, her belly-button\'s got an echo!'),
(85, 'Yo\' momma\'s got so many rings around her belly, she screws her underwear on!'),
(86, 'Yo\' momma\'s so fat, she roller skates on busses!'),
(87, 'Yo\' momma\'s so fat, she uses bowling balls for earrings!'),
(88, 'Yo\' momma\'s so fat, she was mistaken for God\'s bowling ball!'),
(89, 'Yo\' momma lost at hide n\' seek when I spotted her behind the Himalayas!'),
(90, 'Yo\' momma\'s so fat, when she backs up, she beeps!'),
(91, 'Yo\' momma\'s so fat, when her beeper went off, people thought she was backing up!'),
(92, 'Yo\' momma\'s so fat, she has to use a VCR as a beeper!'),
(93, 'Yo\' momma\'s so fat, she has a refrigerator strapped to her waist, and it looks like a pager!'),
(94, 'Yo\' momma\'s so fat, her nickname is \"D*MN!\"'),
(95, 'Yo\' momma\'s so fat, people jog around her for exercise!'),
(96, 'Yo\' momma\'s so fat, when I tried to drive around her, I ran out of gas!'),
(97, 'Yo\' momma\'s so fat, I have to take a plane, a train, and an automobile just to get on her good side!'),
(98, 'Yo\' momma\'s so fat, when you get on top of her, your ears pop!'),
(99, 'Yo\' momma\'s so fat, when she has sex, she has to give directions!'),
(100, 'Yo\' momma\'s so fat, yo\' daddy\'s idea of foreplay is setting up the on-ramps!'),
(101, 'Yo\' momma\'s so fat, you haveta roll over twice to get off her!'),
(102, 'Yo\' momma\'s so fat, when she goes to a restaurant, she doesn\'t get a menu, she gets an estimate!'),
(103, 'Yo\' momma\'s so fat, she goes to a restaurant, looks at the menu and says, \"Okay!\"'),
(104, 'Yo\' momma\'s so fat, when she goes to a restaurant, she orders everything on the menu, including \"Thank You, Come Again\"!'),
(105, 'Yo\' momma\'s so fat, when she goes to an all-you-can-eat buffet, they have to install speed bumps!'),
(106, 'Yo\' momma\'s so fat, the sign outside one restaurant says \'Maximum occupancy, 512, or YO\' MOMMA!\''),
(107, 'Yo\' momma\'s so fat, she looks like she\'s smuggling a Volkswagon!'),
(108, 'Yo\' momma\'s so fat, the highway patrol made her wear a sign that said, \"Caution! Wide Turn!\"'),
(109, 'Yo\' momma\'s so fat, when she stands in a left-turn lane, it gives her the green arrow!'),
(110, 'Yo\' momma\'s so fat, we went to the drive-in and didn\'t have to pay because we dressed her as a Chevrolet!'),
(111, 'Yo\' momma\'s so fat, she was floating in the ocean and Spain claimed her for their new world!'),
(112, 'Yo\' momma\'s so fat, when she wears one of those X jackets, helicopters try to land on her back!'),
(113, 'Yo\' momma\'s so fat, when she goes to an amusement park, people try to ride HER!'),
(114, 'Yo\' momma\'s so fat, when she goes to an amusement park, kids get on her thinking she\'s the Moon Walk!'),
(115, 'Yo\' momma\'s so fat, when Scorpion did the harpoon throw on her, he got arrested for whaling!'),
(116, 'Yo\' momma\'s so fat, she sat on the beach and Greenpeace threw her in!'),
(117, 'Yo\' momma\'s so fat, whenever she goes to the beach, the tide comes in!'),
(118, 'Yo\' momma\'s so fat, when she lies on the beach, no one else gets sun!'),
(119, 'Yo\' momma\'s so fat, she had to go to Sea World to get baptized!'),
(120, 'Yo\' momma\'s so fat, when she went to Sea World, she came out with a paycheck!'),
(121, 'Yo\' momma\'s so fat, when she bungee jumps, she brings down the bridge too!'),
(122, 'Yo\' momma\'s so fat, they use her underwear elastic for bungee jumping!'),
(123, 'Yo\' momma\'s so fat, when they used her underwear elastic for bungee jumping, they hit the ground!'),
(124, 'Yo\' momma\'s so fat, when she sits around the house, she sits AROUND the house!'),
(125, 'Yo\' momma\'s so fat, she fell in love and broke it!'),
(126, 'Yo\' momma\'s so fat, the last time she saw 90210, it was on a scale!'),
(127, 'Yo\' momma\'s so fat, when she gets on the scale, it says, \"We don\'t do livestock!\"'),
(128, 'Yo\' momma\'s so fat, she stepped on a talking scale and it said, \"Please step out of the car!\"'),
(129, 'Yo\' momma\'s so fat, when she plays hopscotch, she goes \"New York, L.A., Chicago...\"'),
(130, 'Yo\' momma\'s so fat, even Bill Gates couldn\'t pay for her liposuction!'),
(131, 'Yo\' momma\'s so fat, her legs are like spoiled milk - white and chunky!'),
(132, 'Yo\' momma\'s so fat, she rolled over four quarters and it made a dollar!'),
(133, 'Yo\' momma\'s so fat, she\'s got more Chins than a Hong Kong phone book!'),
(134, 'Yo\' momma\'s so fat, her senior pictures had to be aerial views!'),
(135, 'Yo\' momma\'s so fat, every time she walks in high heels, she strikes oil!'),
(136, 'Yo\' momma\'s so fat, she left the house in high heels and when she came back, she had on flip flops!'),
(137, 'Yo\' momma\'s so fat, her toes bleed when she walks!'),
(138, 'Yo\' momma\'s so fat, when she hauls *ss, she has to make two trips!'),
(139, 'Yo\' momma\'s so fat, when she hauls *ss, she has friends come help!'),
(140, 'Yo\' momma\'s so fat, she has a wooden leg with a kick stand!'),
(141, 'Yo\' momma\'s so fat, they have to grease the bath tub to get her out!'),
(142, 'Yo\' momma\'s so fat, you have to grease the door frame and hold a Twinkie on the other side just to get her through!'),
(143, 'Yo\' momma\'s so fat, when she fell over, she rocked herself asleep trying to get up again!'),
(144, 'Yo\' momma\'s so fat, when she dances at a concert, the whole band skips!'),
(145, 'Yo\' momma\'s so fat, when she runs, she makes the CD player skip...at the radio station! '),
(146, 'Yo\' momma\'s so fat, she sets off car alarms when she runs!'),
(147, 'Yo\' momma\'s so fat, the only pictures you have of her are satellite pictures!'),
(148, 'Yo\' momma\'s so fat, she put on some BVD\'s and by the time they reached her waist, they spelled out \"boulevard!\"'),
(149, 'Yo\' momma\'s so fat, instead of Levi\'s 501 jeans, she wears Levi\'s 1002\'s!'),
(150, 'Yo\' momma\'s so fat, she has her own brand of jeans: FA - Fat *ss Jeans!'),
(151, 'Yo\' momma\'s so fat, when she was walking in her jeans, I swear I smelled something burning!'),
(152, 'Yo\' momma\'s so fat, she would have been in E.T., but when she rode the bike across the moon, she caused an eclipse!'),
(153, 'Yo\' momma\'s so fat, they tie a rope around her shoulders and drag her through a tunnel when they want to clean it!'),
(154, 'Yo\' momma\'s so fat, when she got hit by a bus, she said, \"Who threw that rock?\"'),
(155, 'Yo\' momma\'s so fat, even her clothes have stretch marks!'),
(156, 'Yo\' momma\'s so fat that when she was born, she gave the hospital stretch marks!'),
(157, 'Yo\' momma\'s so fat, when she swims, she leaves stretch marks on the swimming pool!'),
(158, 'Yo\' momma\'s so fat, even her stretch marks have names!'),
(159, 'Yo\' momma\'s so fat, they had to let out the shower curtain!'),
(160, 'Yo\' momma\'s so fat, she\'s got shock absorbers on her toilet seat!'),
(161, 'Yo\' momma\'s so fat, her picture fell off the wall!'),
(162, 'Yo\' momma\'s so fat, she don\'t have cellulite, she has celluHEAVY!'),
(163, 'Yo\' momma\'s so fat, she eats Wheat *Thicks*!'),
(164, 'Yo\' momma\'s so fat, when she sweats, people wear raincoats around her!'),
(165, 'Yo\' momma\'s so fat, her waist size is larger than her I.Q.!'),
(166, 'Yo\' momma\'s so fat, at the zoo, the elephants started throwing HER peanuts!'),
(167, 'Yo\' momma\'s so fat, it say on her driver\'s license \"Picture continued on back.\"'),
(168, 'Yo\' momma\'s so fat, NASA orbits a satellite around her!'),
(169, 'Yo\' momma\'s so fat, people use her dandruff as quilts!'),
(170, 'Yo\' momma\'s so fat, she runs on diesel!'),
(171, 'Yo\' momma\'s so fat, she thinks a balanced meal is a ham in each hand!'),
(172, 'Yo\' momma\'s so fat, she was Miss Arizona - class Battleship!'),
(173, 'Yo\' momma\'s so fat, she won Miss Bessie the Cow, 96!'),
(174, 'Yo\' momma\'s so fat, the back of her neck looks like a pack of hot dogs!'),
(175, 'Yo\' momma\'s so fat, the Himalayas are practices runs to prepare for her!'),
(176, 'Yo\' momma\'s so fat, to her, \'light food\' means under four tons!'),
(177, 'Yo\' momma\'s so fat, when she\'s in a jacuzzi, she makes her own gravy!'),
(178, 'Yo\' momma\'s so fat, cars run out of gas before passing her fat *ss!'),
(179, 'Yo\' momma\'s so fat, her doctor\'s a grounds keeper!'),
(180, 'Yo\' momma\'s so fat, McDonald\'s has to change their sign every time she eats there!'),
(181, 'Yo\' momma\'s so fat, she can smell bacon frying in Canada!'),
(182, 'Yo\' momma\'s so fat, she had her ears pierced with a harpoon!'),
(183, 'Yo\' momma\'s so fat, she wears a microwave for a beeper!'),
(184, 'Yo\' momma\'s so fat, she wears pillow cases for socks and hula hoops to hold them up!'),
(185, 'Yo\' momma\'s so fat, she went to the salad bar and pulled up a chair!'),
(186, 'Yo\' momma\'s so fat, when she sits on a chair, she makes paper!'),
(187, 'Yo\' momma\'s so fat, she sits on coal and farts out a diamond!'),
(188, 'Yo\' momma\'s so fat, Neil Armstrong landed on her in 1969!'),
(189, 'Yo\' momma\'s so fat, she has to be fed by slingshot!'),
(190, 'Yo\' momma\'s so fat, she walked in front of the TV, and I missed three commercials!'),
(191, 'Yo\' momma\'s so fat, the shadow of her *ss weighs 50 pounds!'),
(192, 'Yo\' momma\'s so fat, her butt looks like two pigs fighting over a Hershey Kiss! '),
(193, 'Yo\' momma\'s so fat, she has to grease her hands to get into her pockets!'),
(194, 'Yo\' momma\'s so fat, her navel gets home 15 minutes before she does!'),
(195, 'Yo\' momma\'s so fat, if she weighed five more pounds, she could get group insurance!'),
(196, 'Yo\' momma\'s so fat, if she was a super hero, she would be the Incredible Bulk!'),
(197, 'Yo\' momma\'s so fat, when she auditioned for a part in \'Indiana Jones,\' she got the part as the big rolling ball!'),
(198, 'Yo\' momma\'s so fat, when she sat on a dollar bill, blood came out of George Washington\'s nose!'),
(199, 'Yo\' momma\'s so fat, the telephone company gave her two area codes!'),
(200, 'Yo\' momma\'s so fat, when she wears a red dress in the summer, kids run after her yelling, \"Kool Aid! Kool Aid!\"'),
(201, 'Yo\' momma\'s so fat, when I yell \"Kool-Aid,\" she comes crashing through the wall!'),
(202, 'Yo\' momma\'s so fat, she has to sleep in the barn with the rest of the cows!'),
(203, 'Yo\' momma\'s so fat, when she talks to herself, it\'s a long  distance call!'),
(204, 'Yo\' momma\'s so fat, if she put her hand on her hip, she would look like a gallon of milk!'),
(205, 'Yo\' momma\'s so fat, when she stood in front of the HOLLYWOOD letters we thought we were in the hood (HO*****OD)!'),
(206, 'Yo\' momma\'s so fat, she\'s got a zit on her butt that\'s known as Mt. St. Helen!'),
(207, 'Yo\' momma\'s so fat, she uses the freeway as a slip \'n slide!'),
(208, 'Yo\' momma\'s so fat, when she needs a shower, she goes to a car wash!'),
(209, 'Yo\' momma\'s so fat, when she starts a marathon, she\'s already at the finish line!'),
(210, 'Yo\' momma\'s so fat, she pays taxes in three countries!'),
(211, 'Yo\' momma\'s so fat, when she wears a yellow shirt, people wear sunglasses!'),
(212, 'Yo\' momma\'s so fat, she needs to use a boomerang to scratch her fat *ss!'),
(213, 'Yo\' momma\'s so fat, she gets her dresses made by Barnum and Bailey!'),
(214, 'Yo\' momma\'s so fat, when she last went to church, nobody would leave until she sang!'),
(215, 'Yo\' momma\'s so fat, her nickname is the Badyear Blimp!'),
(216, 'Yo\' momma\'s so fat, she was standing at a corner and the cops came over and said, \"Hey! Break it up!\"'),
(217, 'Yo\' momma\'s so fat, I kept trying to leave her, but I couldn\'t escape her gravitational pull!'),
(218, 'Yo\' momma\'s so fat, she has her own asteroid belt!'),
(219, 'Yo\' momma\'s so fat, she can kick start a 747!'),
(220, 'Yo\' momma\'s so fat, if she was two feet taller, she\'d be spherical!'),
(221, 'Yo\' momma\'s so fat, she was kidnapped by a cannibal tribe, and they all died of cholesterol!'),
(222, 'Yo\' momma\'s so fat, she got a ticket for going the wrong way down a one way street when she was walking!'),
(223, 'Yo\' momma\'s so fat, she doesn\'t sit, she spreads!'),
(224, 'Yo\' momma\'s so fat, she was born on the 4th, 5th and 6th of March!'),
(225, 'Yo\' momma\'s so fat, she was stopped by police dogs at the airport for having 300 lbs of crack under her dress!'),
(226, 'Yo\' momma\'s so fat, she lives in two time zones - supper time and dinner time!'),
(227, 'Yo\' momma\'s so fat, in school when she stood up and turned around, she would erase all the black-boards in the room!'),
(228, 'Yo\' momma\'s so fat, it took God one day to create the earth and five days to create yo\' momma!'),
(229, 'Yo\' momma\'s so fat, the local police hired her to be a roadblock!'),
(230, 'Yo\' momma\'s so fat, she bumps into people even when she\'s sitting down!'),
(231, 'Yo\' momma\'s so fat, she don\'t take pictures, she takes posters!'),
(232, 'Yo\' momma\'s so fat, when she walks down the street in a green dress, everybody yells, \"Run for your lives! It\'s GODZILLA!\"'),
(233, 'Yo\' momma\'s so fat, when she sings, it\'s over!'),
(234, 'Yo\' momma\'s so fat, they use her underwear for the screen at the movies!'),
(235, 'Yo\' momma\'s so fat, she hula-hooped the super bowl!'),
(236, 'Yo\' momma\'s so fat, to her, \'light food\' means under four tons!'),
(237, 'Yo\' momma\'s so fat, the Himalayas are practice runs to prepare for her!'),
(238, 'Yo\' momma\'s so fat, she stepped on a talking scale and it told her to get the fuck off!'),
(239, 'Yo\' momma\'s so fat, Thanksgiving Day, she ate dinner for six hours, then said, \"I am going to walk this meal off.\" I said, \"Call me when you get to Brazil!\"'),
(240, 'Yo\' momma\'s so fat, she has to wear a hat with a blinking red light to scare off the airplanes!'),
(241, 'Yo\' momma\'s so fat, if she wears fish-net stockings, they\'d better be fifty pound test!'),
(242, 'Yo\' momma\'s so fat, she gets clothes in three sizes: extra large, jumbo, and oh-my-g*d-it\'s-coming-towards-us!'),
(243, 'Yo\' momma\'s so fat, when she went to the airport and said she wanted to fly, they stamped Goodyear on her and sent her out to the runway!'),
(244, 'Yo\' momma\'s so fat, she bungee jumped and went straight to hell!'),
(245, 'Yo\' momma\'s so fat, she can\'t wear Daisy Dukes - she has to wear Boss Hoggs!'),
(246, 'Yo\' momma\'s so fat, she has more nooks and crannies than Thomas\' English Muffin!'),
(247, 'Yo\' momma\'s so fat, she measures 36-24-36, and the other arm is just as big!'),
(248, 'Yo\' momma\'s so fat, she\'s 36-24-36...but that\'s her forearm, neck, and thigh!'),
(249, 'Yo\' momma\'s so fat, she sat on the corner and the police came and said, \"Break it up!\"'),
(250, 'Yo\' momma\'s so fat, she tried to get an all-over tan, and the sun burned out!'),
(251, 'Yo\' momma\'s so fat, she has to buy two plane tickets, and she doesn\'t even notice the armrest!'),
(252, 'Yo\' momma\'s so fat, when she lays down, stunt men try to jump over her!'),
(253, 'Yo\' momma\'s so fat, she\'s the main ingredient in Ding Dongs!'),
(254, 'Yo\' momma\'s so country, she got in an elevator and thought it was a mobile home!'),
(255, 'Yo\' momma\'s so stupid, when she walked by a cow plop, she laughed, because she knew the fly on top couldn\'t have done all that!'),
(256, 'Yo\' momma\'s so stupid, if she were any more stupid, she\'d have to be watered twice a week!'),
(257, 'Yo\' momma\'s so stupid, if brains were taxed, she\'d get a rebate!'),
(258, 'Yo\' momma\'s so stupid, she worked in a pet store and people kept asking how big she\'d get!'),
(259, 'Yo\' momma\'s so dense, light bends around her!'),
(260, 'Yo\' momma\'s so stupid, she returned a puzzle, and said it was broken!'),
(261, 'Yo\' momma\'s so stupid, she tried to run for the mayor of Circuit City!'),
(262, 'Yo\' momma\'s brain is so small, if I took it and rolled it down the edge of a razor blade, it would be like a lone car going down a six lane highway!'),
(263, 'Yo\' momma\'s brain is so small, if you stuffed it up an ant\'s butt, it would still rattle like a BB in a tin can!'),
(264, 'Yo\' momma\'s so stupid, if brains were dynamite, she wouldn\'t have enough to blow her nose!'),
(265, 'Yo\' momma\'s so stupid, she put on her glasses to watch 20/20!'),
(266, 'Yo\' momma\'s so stupid, she stopped at a stop sign and waited for it to say \'Go\'!'),
(267, 'Yo\' momma\'s so stupid, she gave birth to you!'),
(268, 'Yo\' momma\'s so stupid, she tried to commit suicide by jumping out of the basement window!'),
(269, 'Yo\' momma\'s so stupid, she ran out of gas leaving Texaco!'),
(270, 'Yo\' momma\'s so stupid, she sold the house to pay the mortgage!'),
(271, 'Yo\' momma\'s so stupid, she told me to meet her at the corner of \'Walk\' and \'Don\'t Walk\'!'),
(272, 'Yo\' momma\'s so stupid, when I was drowning and yelled for a life saver, she said, \"Cherry or grape?!\"'),
(273, 'Yo\' momma\'s so stupid, her latest invention was a glass hammer!'),
(274, 'Yo\' momma\'s so stupid, she saw a billboard that said \"Dodge Trucks\" and she started ducking through traffic!'),
(275, 'Yo\' momma\'s so stupid, she was on the corner with a sign that said \"Will eat for food!\"'),
(276, 'Yo\' momma\'s so stupid, she got locked in Furniture World and slept on the floor!'),
(277, 'Yo\' momma\'s so stupid, she got shoved in an oven and froze to death!'),
(278, 'Yo\' momma\'s so stupid, she got locked in a meat locker and sweat to death!'),
(279, 'Yo\' momma\'s so stupid, she thinks fruit punch is a gay boxer!'),
(280, 'Yo\' momma\'s so stupid, she thinks Johnny Cash is a pay toilet!'),
(281, 'Yo\' momma\'s so stupid, she thinks Thailand is a men\'s clothing store!'),
(282, 'Yo\' momma\'s so stupid, she thinks socialism means partying!'),
(283, 'Yo\' momma\'s so stupid, she thinks Sherlock Holmes was a housing project!'),
(284, 'Yo\' momma\'s so stupid, she thinks Delta Airlines is a sorority!'),
(285, 'Yo\' momma\'s so stupid, she thinks a sanitary belt is drinking a shot out of a clean glass!'),
(286, 'Yo\' momma\'s so stupid, she thinks Christmas wrap is Snoop Dogg\'s holiday album!'),
(287, 'Yo\' momma\'s so stupid, she thinks a stereotype is a clock-radio brand!'),
(288, 'Yo\' momma\'s so stupid, she thinks sexual battery is something in a dildo!'),
(289, 'Yo\' momma\'s so stupid, she thinks the Internet is something you catch fish with!'),
(290, 'Yo\' momma\'s so stupid, she thinks a lawsuit is something you wear to court!'),
(291, 'Yo\' momma\'s so stupid, when the judge said, \"Order in the court,\" she said, \"I\'ll have a hamburger and a Coke!\"'),
(292, 'Yo\' momma\'s so stupid, she went to the store to buy a color TV and asked what colors they had!'),
(293, 'Yo\' momma\'s so stupid, she sent me a fax with a stamp on it!'),
(294, 'Yo\' momma\'s so stupid, she tried to mail a letter with food stamps!'),
(295, 'Yo\' momma\'s so stupid, when she worked at McDonald\'s and someone ordered small fries, she said, \"Hey Boss, all the small ones are gone!\"'),
(296, 'Yo\' momma\'s so stupid, if brains were gas, she wouldn\'t have enough to power a flea-mobile around the inside of a Fruit Loop!'),
(297, 'Yo\' momma\'s so stupid, when they said they were playing craps, she went and got toilet paper!'),
(298, 'Yo\' momma\'s so stupid, she couldn\'t tell which way an elevator was going if I gave her two guesses!'),
(299, 'Yo\' momma\'s so stupid, when her husband lost his marbles, she bought him new ones!'),
(300, 'Yo\' momma\'s so stupid, she tried to drown herself in a car pool!'),
(301, 'Yo\' momma\'s so stupid, she tried to drown a fish!'),
(302, 'Yo\' momma\'s so stupid, she studied for a blood test and failed!'),
(303, 'Yo\' momma\'s so stupid, she called the 7-11 to see when they closed!'),
(304, 'Yo\' momma\'s so stupid, she tried to drop acid, but the car battery fell on her foot!'),
(305, 'Yo\' momma\'s so stupid, she got shot running for the border after seeing a Taco Bell commercial!'),
(306, 'Yo\' momma\'s so stupid, she put a quarter in a parking meter and waited for a gumball to come out!'),
(307, 'Yo\' momma\'s so stupid, she got on her knees to drink her Nehi peach drink!'),
(308, 'Yo\' momma\'s so stupid, she needed a tutor to learn how to scribble!'),
(309, 'Yo\' momma\'s so stupid, she ordered her sushi well done!'),
(310, 'Yo\' momma\'s so stupid, it took her two hours to watch 60 minutes!'),
(311, 'Yo\' momma\'s so stupid, when she saw the NC-17 sign, she went home and got 16 friends!'),
(312, 'Yo\' momma\'s so stupid, when yo\' daddy said it was chilly outside, she ran outside with a spoon!'),
(313, 'Yo\' momma\'s so stupid, she told everyone that she was \'illegitiment\' because she couldn\'t read!'),
(314, 'Yo\' momma\'s so stupid that she puts lipstick on her head just to make-up her mind!'),
(315, 'Yo\' momma\'s so stupid, she got locked in a grocery store and starved!'),
(316, 'Yo\' momma\'s so stupid, she sold her car for gasoline money!'),
(317, 'Yo\' momma\'s so stupid, she thinks a quarterback is a refund!'),
(318, 'Yo\' momma\'s so stupid, she took a ruler to bed to see how long she slept!'),
(319, 'Yo\' momma\'s so stupid, she stole free bread!'),
(320, 'Yo\' momma\'s so stupid, she took a spoon to the superbowl!'),
(321, 'Yo\' momma\'s so stupid, she took the Pepsi Challenge and chose Jif!'),
(322, 'Yo\' momma\'s so stupid, she thinks Fleetwood Mac is a new hamburger at McDonald\'s!'),
(323, 'Yo\' momma\'s so stupid, she sits on the TV and watches the couch!'),
(324, 'Yo\' momma\'s so stupid, she took a umbrella to see Purple Rain!'),
(325, 'Yo\' momma\'s so stupid that under \"Education\" on her job application, she put \"Hooked on Phonics!\"'),
(326, 'Yo\' momma\'s so stupid, that under \"Other Languages\" on her job application, she put \"Ebonics\"!'),
(327, 'Yo\' momma\'s so stupid, she put out the cigarette butt that was heating yo\' house!'),
(328, 'Yo\' momma\'s so stupid, she watches \"The Three Stooges\" and takes notes!'),
(329, 'Yo\' momma\'s so stupid, they had to burn down the school to get her out of second grade!'),
(330, 'Yo\' momma\'s so stupid, she bought a Clapper, and she only has one hand! '),
(331, 'Yo\' momma\'s so stupid, she got hit by a parked car!'),
(332, 'Yo\' momma\'s so stupid, she mates out of season!'),
(333, 'Yo\' momma\'s so stupid, her brain cells are on the endangered species list!'),
(334, 'Yo\' momma\'s so stupid, she got hit by a cup and told the cops she got mugged!'),
(335, 'Yo\' momma\'s so stupid, she thinks a hot meal is stolen food!'),
(336, 'Yo\' momma\'s so stupid, she thought Taco Bell was a Mexican phone company!'),
(337, 'Yo\' momma\'s so stupid, she thought the Nazis were saying \"Hi, Hitler!\"'),
(338, 'Yo\' momma\'s so stupid, when she tried to commit suicide, she jumped off the curb!'),
(339, 'Yo\' momma\'s so stupid, she went to a Clippers game to get a hair cut!'),
(340, 'Yo\' momma\'s so stupid, she went to a Whalers game to see Shamu!'),
(341, 'Yo\' momma\'s so stupid, she went to Alpha Beta and asked to buy a vowel!'),
(342, 'Yo\' momma\'s so stupid, when she saw a sign that said \"Wet floor,\" she did!'),
(343, 'Yo\' momma\'s so stupid, she thinks a triple is for extreme alcoholics!'),
(344, 'Yo\' momma\'s so stupid, she tripped over a cordless phone!'),
(345, 'Yo\' momma\'s so stupid, someone yells \"hoe-down,\" she hits the deck!'),
(346, 'Yo\' momma\'s so stupid, if you give her a penny for her thoughts, you\'ll get change back!'),
(347, 'Yo\' momma\'s so stupid, if she spoke her mind, she would be speechless!'),
(348, 'Yo\' momma\'s so stupid, she took you to the airport the sign said, \'Airport left,\' so she turned around and went home!'),
(349, 'Yo\' momma\'s so stupid, on an application it said, \"Don\'t write here,\" and she wrote, \"Why?\"'),
(350, 'Yo\' momma\'s so stupid, when she read on her job application to not write below the dotted line, she put \"O.K.\"'),
(351, 'Yo\' momma\'s so stupid, when she was filling out a job application, when she saw \"sign here,\" she put \"Scorpio\"!'),
(352, 'Yo\' momma\'s so stupid, she saw Jesus walk on water and said, \"It\'s gotta be the shoes!\"'),
(353, 'Yo\' momma\'s so stupid, when asked on an application, \"Sex?\" she marked, \"M, F and sometimes weekends too!\"'),
(354, 'Yo\' momma\'s so stupid, she asked me what kind of jeans I had on, I  said, \"Guess,\" so she said \"Levi\'s!\"'),
(355, 'Yo\' momma\'s so stupid, she called information to get the number for 411 ... and when the operator said \"Hold one minute,\" she counted to 60 and hung up!!!'),
(356, 'Yo\' momma\'s so stupid, she took toilet paper to a craps game!'),
(357, 'Yo\' momma\'s so stupid, she asked for a price check at the dollar store!'),
(358, 'Yo\' momma\'s so stupid, when you were born she looked at the umbilical cord and said, \"Hey, everybody - he comes with cable!\"'),
(359, 'Yo\' momma\'s so stupid, she went to catch the 44 bus but caught the 22 twice instead!'),
(360, 'Yo\' momma\'s so stupid, she thought menopause was a button on her tape deck!'),
(361, 'Yo\' momma\'s so stupid, if her I.Q. was any lower, she\'d trip over it!'),
(362, 'Yo\' momma\'s so stupid, she thinks socialism means partying!'),
(363, 'Yo\' momma\'s so stupid, she thinks MCI is a rapper!'),
(364, 'Yo\' momma\'s so stupid, she had your brother thrown in rehab. \'cause he was Hooked on Phonics!'),
(365, 'Yo\' momma\'s so stupid, she thinks it\'s the ice cubes that keeps the fridge cold!'),
(366, 'Yo\' momma\'s so stupid, she thought gangrene was another golf course!'),
(367, 'Yo\' momma\'s so stupid, it take her a month to get rid of the seven day itch!'),
(368, 'Yo\' momma\'s so stupid, she went to Alpha Beta and asked to buy a vowel!'),
(369, 'Yo\' momma\'s so stupid, she gave your uncle a blowjob cause he said it would help with his unemployment!'),
(370, 'Yo\' momma\'s so stupid, she called the cocaine hotline to order some!'),
(371, 'Yo\' momma\'s so stupid, she cooked her own complimentary breakfast!'),
(372, 'Yo\' momma\'s so stupid, she thinks Johnny Cash is a pay toilet!'),
(373, 'Yo\' momma\'s so stupid, she thinks manual labor is a Mexican!'),
(374, 'Yo\' momma\'s so stupid, she has one toe and bought a pair of flip flops!'),
(375, 'Yo\' momma\'s so stupid, on her job application where it says \'emergency contact,\' she put \'911\'!'),
(376, 'Yo\' momma\'s so stupid, she said \"what\'s that letter after x,\" I said, \'Y\'; she said, \"\'Cause I wanna know!\"'),
(377, 'Yo\' momma\'s so stupid, she thought Hamburger Helper came with another person!'),
(378, 'Yo\' momma\'s so stupid, she thought Meow Mix was a CD for cats!'),
(379, 'Yo\' momma\'s so stupid, she thought Boyz II Men was a daycare center!'),
(380, 'Yo\' momma\'s so stupid, she thought the board of education was a piece of wood!'),
(381, 'Yo\' momma\'s so stupid, I saw her in the frozen food section with a fishing rod!'),
(382, 'Yo\' momma\'s so stupid, I taught her how to do the running man and I haven\'t seen her since!'),
(383, 'Yo\' momma\'s so stupid, when she counts to ten she get stuck at 11!'),
(384, 'Yo\' momma\'s so stupid, when you were born, she looked at the umbilical cord and said, \"Whoa! This thing comes with cable!\"'),
(385, 'Yo\' momma\'s so ugly, once, she was so depressed, she was going to jump out a window on the tenth floor... so they sent a priest up to talk to her. He said, \"On your mark...\"'),
(386, 'Yo\' momma\'s so ugly, she met the surgeon general...he offered her a cigarette!'),
(387, 'Yo\' momma\'s so ugly, a young man phoned her and said, \"Come on over there\'s nobody home.\" She went over...Nobody was home!'),
(388, 'Yo\' momma\'s so ugly, her dentist treats her by mail!'),
(389, 'Yo\' momma\'s so ugly, she looks like you!'),
(390, 'Yo\' momma\'s so ugly, when she looks in the mirror, the reflection ducks!'),
(391, 'Yo\' momma\'s so ugly, even the elephant man paid to see her!'),
(392, 'Yo\' momma\'s so ugly, when your dad wants to have sex in the car, he tells her to get out!'),
(393, 'Yo\' momma\'s so ugly, the last time I saw something that looked like her, I pinned a tail on it!'),
(394, 'Yo\' momma\'s so ugly, we put her in the kennel when we go on vacation!'),
(395, 'Yo\' momma\'s so ugly, people at the circus pay money NOT to see her!'),
(396, 'Yo\' momma\'s so ugly, they only wanted her feet for the freak show!'),
(397, 'Yo\' momma\'s so ugly, when she gets up, the sun goes down!'),
(398, 'Yo\' momma\'s so ugly, she\'d scare the monster out of Loch Ness!'),
(399, 'Yo\' momma\'s so ugly, yo\' daddy tosses the ugly stick, and she fetches it every time!'),
(400, 'Yo\' momma\'s so ugly, they rub tree branches on her face to make ugly sticks!'),
(401, 'Yo\' momma\'s so ugly, the kids call her Lassie and feed the b*tch biscuits!'),
(402, 'Yo\' momma\'s so ugly, I took her to the zoo, and the zookeeper said thanks for bringing her back!'),
(403, 'Yo\' momma\'s so ugly, I took her to the zoo, and the monkeys said, \"D*mn, how\'d you get out so fast!\"'),
(404, 'Yo\' momma\'s so ugly, when she went to Taco Bell, everyone ran for the border!'),
(405, 'Yo\' momma\'s so ugly, I heard that yo\' daddy first met her at the pound!'),
(406, 'Yo\' momma\'s so ugly, I can have sex with her in any position and it\'s still doggy style!'),
(407, 'Yo\' momma\'s so ugly, they use her in prisons to cure sex offenders!'),
(408, 'Yo\' momma\'s so ugly, she entered a dog show and won!'),
(409, 'Yo\' momma\'s so ugly, her doctor is a vet!'),
(410, 'Yo\' momma\'s so ugly, if ugly were bricks, she\'d be a high rise!'),
(411, 'Yo\' momma\'s so ugly, if ugly were an Olympic event, she would be the dream team!'),
(412, 'Yo\' momma\'s so ugly, she gives Freddy Krueger nightmares!'),
(413, 'Yo\' momma\'s so ugly, even a blind man wouldn\'t have sex with her!'),
(414, 'When yo\' momma was born they had to take her out of the trash can, \'cause the doctor said, \"Throw this sh*t away!\"'),
(415, 'Yo\' momma\'s so ugly, when she was born, they tinted the windows of her incubator!'),
(416, 'Yo\' momma\'s so ugly, when she was born, the doctor didn\'t know which end to slap!'),
(417, 'Yo\' momma\'s so ugly, the doctor is still smacking her *ss!'),
(418, 'Yo\' momma\'s so ugly, when she was born, the doctor slapped her mother!'),
(419, 'Yo\' momma\'s so ugly, when she was born, the doctor smacked everyone!'),
(420, 'Yo\' momma\'s so ugly, they threw her away and kept the afterbirth!'),
(421, 'Yo\' momma\'s so ugly, when she was born, the doctor took her and told her mother, \"If this doesn\'t start to cry in ten seconds, it was a tumor!\"'),
(422, 'Yo\' momma\'s so ugly, when she was born the Doctor looked at her *ss and her face and said: \"My God, Siamese twins!\"'),
(423, 'Yo\' momma\'s so ugly, just after her birth, her mother saw the afterbirth and said, \"Twins!\"'),
(424, 'Yo\' momma\'s so ugly, just after she was born, her mother said, \"What a treasure,\" and her father said, \"Yeah, let\'s go bury it!\"'),
(425, 'Yo\' momma\'s so ugly, when she was born, GOD admitted that even HE could make a mistake!'),
(426, 'Yo\' momma\'s so ugly, her mom had to be drunk to breast feed her!'),
(427, 'Yo\' momma\'s so ugly, it makes me wish birth control is retroactive!'),
(428, 'Yo\' momma\'s so ugly, when she joined an ugly contest, they said \"Sorry, no professionals!\"'),
(429, 'Yo\' momma\'s so ugly, she looked out the window and got arrested for mooning!'),
(430, 'Yo\' momma\'s so ugly, they filmed \"Gorillas in the Mist\" in her shower!'),
(431, 'Yo\' momma\'s so ugly, instead of putting the bungee cord around her ankle, they put it around her neck!'),
(432, 'Yo\' momma\'s so ugly, when she walks into a bank, they turn off the surveillance cameras!'),
(433, 'Yo\' momma\'s so ugly, when she walks down the street in September, people say, \"It\'s Halloween already?!\"'),
(434, 'Yo\' momma\'s so ugly, they pay her to put her clothes ON in strip joints!'),
(435, 'Yo\' momma\'s so ugly, when they took her to the beautician, it took twelve hours...for a quote!'),
(436, 'Yo\' momma\'s so ugly, even Rice Krispies won\'t talk to her!'),
(437, 'Yo\' momma\'s so ugly, she turned Medusa to stone!'),
(438, 'Yo\' momma\'s so ugly, she scares the roaches away!'),
(439, 'Yo\' momma\'s so ugly, yo\' daddy takes her to work with him so that he doesn\'t have to kiss her goodbye!'),
(440, 'If my dog had a face as ugly as yo\' momma\'s, I\'d shave his *ss and make him walk backwards!'),
(441, 'Yo\' momma\'s so ugly, her face looks like a blind cobbler\'s thumb!'),
(442, 'Yo\' momma\'s so ugly, her face is like the south end of a north-bound camel!'),
(443, 'Yo\' momma\'s so ugly, Dairy Queen won\'t even treat her right!'),
(444, 'Yo\' momma\'s so ugly, she\'s like 7-UP...never had it, never will!'),
(445, 'Yo\' momma\'s so ugly, she could scare a hungry wolf off a meat truck!'),
(446, 'Yo\' momma\'s so ugly, she had to wear two bags over her head in case one breaks!'),
(447, 'Yo\' momma\'s so ugly, she\'s only had one successful job - being a scarecrow!'),
(448, 'Yo\' momma\'s so ugly, she just got a job at the airport - sniffing for drugs!'),
(449, 'Yo\' momma\'s so ugly, she makes *YOU* look good!'),
(450, 'Yo\' momma\'s so ugly, her psychiatrist makes her lie face down!'),
(451, 'Yo\' momma\'s so ugly, when she goes to the beach, the tide won\'t come in!'),
(452, 'Yo\' momma\'s so ugly, the tide won\'t even take her out!'),
(453, 'Yo\' momma\'s so ugly, when she went to jump in a lake, the lake jumped back!'),
(454, 'Yo\' momma\'s so ugly, her momma had to feed her with a sling shot!'),
(455, 'Yo\' momma\'s so ugly, she practices birth control by leaving the lights on!'),
(456, 'Yo\' momma\'s so ugly, peeping toms break into her house and CLOSE the blinds!'),
(457, 'Yo\' momma\'s so ugly, she has little round marks all over her body from people touching her with 10-foot poles!'),
(458, 'Yo\' momma\'s so ugly, her face could stop a sun dial!'),
(459, 'Yo\' momma\'s so ugly, they push her face into dough to make gorilla cookies!'),
(460, 'Yo\' momma\'s so ugly, they didn\'t make her wear a costume when she tried out for Star Wars!'),
(461, 'Yo\' momma\'s so ugly, when she walked into a haunted house, she came out with a paycheck!'),
(462, 'Yo\' momma\'s so ugly, her face is closed on weekends!'),
(463, 'Yo\' momma\'s so ugly, she has to trick-or-treat over the phone!'),
(464, 'Yo\' momma\'s so ugly, when she gets up, the sun goes down!'),
(465, 'Yo\' momma\'s so ugly, two guys broke into her apt., she yelled \"rape,\" and they yelled \"NO!\"'),
(466, 'Yo\' momma\'s so ugly, when she was lying on the beach, the cat tried to bury her!'),
(467, 'Yo\' momma\'s so ugly, cockroaches go like this: \"HI, MOM!\"'),
(468, 'Yo\' momma\'s so ugly, she frightened away both the beauty and the beast!'),
(469, 'Yo\' momma\'s so ugly, she strips wall paper from walls for a living!'),
(470, 'Yo\' momma\'s so ugly, she dated Jabba the Hut and HE was the looker!'),
(471, 'Yo\' momma\'s so ugly, when she was a baby, her parents had a little yellow sign in their car window that read, \"THING ON BOARD\"!'),
(472, 'Yo\' momma\'s so ugly, she\'s like Taco Bell - when people see her, they run for the border!'),
(473, 'Yo\' momma\'s so ugly, she scares people even with the lights out!'),
(474, 'Yo\' momma\'s so ugly, it looks like her neck threw up!'),
(475, 'Yo\' momma\'s so ugly, her face is registered as a biological weapon!'),
(476, 'Yo\' momma\'s so ugly, the NHL banned her for life!'),
(477, 'Yo\' momma\'s so ugly, your dad\'s breath smells like sh*t because he would rather kiss her ass!'),
(478, 'Yo\' momma\'s so ugly, she\'d make a freight train take a dirt road!'),
(479, 'Yo\' momma\'s so ugly, it looks like her face caught fire and they put it out with an ice pick!'),
(480, 'Yo\' momma\'s so ugly, her mother used to put rubber bands on her ears so people would think the girl was wearing a mask!'),
(481, 'Yo\' momma\'s so ugly, she wasn\'t beaten with an ugly stick...the whole forest fell on her!'),
(482, 'Yo\' momma\'s so ugly, she\'s the cover girl for iodine!'),
(483, 'Yo\' momma\'s so ugly, even Rice Krispies won\'t talk to her!!'),
(484, 'Yo\' momma\'s so ugly, her face is closed on weekends!'),
(485, 'Yo\' momma\'s so ugly, her picture is on the inside of a Roach Motel!'),
(486, 'Yo\' momma\'s so ugly, she can look up a camel\'s butt and scare its hump off!'),
(487, 'Yo\' momma\'s so ugly, the last time she heard a whistle was when she got hit by a train!'),
(488, 'Yo\' momma\'s so ugly, they put her face on box of Ex-Lax and sold it empty!'),
(489, 'Yo\' momma\'s so ugly, when she passes by a bathroom, the toilet flushes!'),
(490, 'Yo\' momma\'s so ugly, she\'s was a three bagger: 1 for her head, 1 for yours in case hers fell off, and 1 by the door in case anyone walked in!'),
(491, 'Yo\' momma\'s so ugly, she has to get her vibrator drunk first!'),
(492, 'Yo\' momma\'s so ugly, her vibrator turned limp!'),
(493, 'Yo\' momma\'s so old, she DJ\'ed the Boston Tea Party!'),
(494, 'Yo\' momma\'s so old, she knew Cap\'n Crunch when he was only a deckhand!'),
(495, 'Yo\' momma\'s so old, she\'s got hieroglyphics on her driver\'s license!'),
(496, 'Yo\' momma\'s so old, the key on Ben Franklin\'s kite was to her apartment!'),
(497, 'Yo\' momma\'s so old, she walked into an antique store and they kept her!'),
(498, 'Yo\' momma\'s so old, when she was young, rainbows were black and white!'),
(499, 'Yo\' momma\'s so old, her memory is in black and white!'),
(500, 'Yo\' momma\'s so old, she has an autographed Bible!'),
(501, 'Yo\' momma\'s so old, the candles cost more than the birthday cake!'),
(502, 'Yo\' momma\'s so old, when she was born, the Dead Sea was just getting sick!'),
(503, 'Yo\' momma\'s so old, her social security number is 1!'),
(504, 'Yo\' momma\'s so old, her birthday\'s expired!'),
(505, 'Yo\' momma\'s so old, her birth certificate says \"expired\" on it!'),
(506, 'Yo\' momma\'s so old, she farts dust!'),
(507, 'Yo\' momma\'s so old, when I told her to act her age, she died!'),
(508, 'Yo\' momma\'s so old, she was there the first day of slavery!'),
(509, 'Yo\' momma\'s so old and fat that when God said \"Let there be light,\" He told her to move her fat *ss!'),
(510, 'Yo\' momma\'s so old, George Burns calls her \'Grandma\'!'),
(511, 'Yo\' momma\'s so old, she\'s older than your grandma!'),
(512, 'Yo\' momma\'s so old, she owes Fred Flintstone a food stamp!'),
(513, 'Yo\' momma\'s so old, she knew Burger King when he was a prince!'),
(514, 'Yo\' momma\'s so old, she\'s blind from the big bang!'),
(515, 'Yo\' momma\'s so old, Jurassic Park brought back memories!'),
(516, 'Yo\' momma\'s so old, she has a picture of Moses in her yearbook!'),
(517, 'Yo\' momma\'s so old, when Moses split the Red Sea, she was on the other side fishing!'),
(518, 'Yo\' momma\'s so old, she knew the Beetles when they were the New Kids on the Block!'),
(519, 'Yo\' momma\'s so old, she owes Jesus a nickel!'),
(520, 'Yo\' momma\'s so old, she used to babysit Jesus!'),
(521, 'Yo\' momma\'s so old, she counseled Adam and Eve!'),
(522, 'Yo\' momma\'s so poor, she had to take out a second mortgage on her cardboard box!'),
(523, 'Yo\' momma\'s so poor, even her BOSS pants are unemployed!'),
(524, 'Yo\' momma\'s so poor, she has to take the trash IN!'),
(525, 'Yo\' momma\'s so poor, I went to her house and took down some cobwebs, and she said, \"Who\'s tearing down the drapes?!\"'),
(526, 'Yo\' momma\'s so poor, when I saw her rolling some trash cans around in an alley, I asked her what she was doing; she said, \"Remodeling!\"'),
(527, 'Yo\' momma\'s so poor, when I saw her kicking a can down the street, I asked what she was doing, and she said \"Moving!\"'),
(528, 'Yo\' momma was in K-Mart with a box of Hefty bags. I said, \"What ya doin\'?\" She said, \"Buying luggage!\"'),
(529, 'Yo\' momma\'s so poor, I came over for dinner and saw three beans on the table; I took one, and she said \"Don\'t be greedy!\"'),
(530, 'Yo\' momma\'s so poor, when I stepped on her door mat, she said, \"Hey, you can\'t go upstairs!\"'),
(531, 'Yo\' momma\'s so poor, I stepped on her skateboard and she said, \"Hey, get off the car!\"'),
(532, 'Yo\' momma\'s so poor, I walked into her house and swatted a firefly and she said, \"Who turned off the lights?!\"'),
(533, 'Yo\' momma\'s so poor, I went into her house and flushed a cockroach down the toilet and she said, \"Hey, where\'d Grandma go?!\"'),
(534, 'Yo\' momma\'s so poor, I walked into her house, asked to use the bathroom, and she said, \"Third tree to your right!\"'),
(535, 'Yo\' momma\'s so poor, after I p*ssed in your yard, she thanked me for watering the lawn!'),
(536, 'Yo\' momma\'s so poor, when I asked what was for dinner, she pulled her shoelaces off and said \"Spaghetti!\"'),
(537, 'Yo\' momma\'s so poor, her face is on the front of a food stamp!'),
(538, 'Yo\' momma\'s so poor, when she heard about the last supper, she thought she had run out of food stamps!'),
(539, 'Yo\' momma\'s so poor, she got arrested for breaking the gum-ball machine because it didn\'t take food stamps!'),
(540, 'Yo\' momma\'s so poor, she puts food stamps in your penny loafers!'),
(541, 'Yo\' momma\'s so poor, when I ring the doorbell, she says \"DING!\"'),
(542, 'Yo\' momma\'s so poor, when I ring the doorbell, I hear the toilet flush!'),
(543, 'Yo\' momma\'s so poor, when she goes to KFC, she has to lick other people\'s fingers!'),
(544, 'Yo\' momma\'s so poor, she went to McDonald\'s and had to put her french fries on lay-a-way!'),
(545, 'Yo\' momma\'s so poor, she waves around a popsicle stick and calls it air conditioning!'),
(546, 'Yo\' momma\'s so poor, burglars break in her house and leave money!'),
(547, 'Yo\' momma\'s so poor, she married young just to get the rice!'),
(548, 'Yo\' momma\'s so poor, the Somalians are sending HER food!'),
(549, 'Yo\' momma\'s so poor, I stepped on a cigarette and she yelled, \"Who turned off the heat?!\"'),
(550, 'Yo\' momma\'s so poor, she can\'t even afford to pay attention!'),
(551, 'Yo\' momma\'s so po\', she can\'t even afford the \'or\'!'),
(552, 'Yo\' momma\'s so poor, she wipes with both sides of the toilet paper!'),
(553, 'Yo\' momma\'s so poor, the only time she\'s smelled hot food was when a rich man farted!');

--
-- Index pour les tables déchargées
--

--
-- Index pour la table `YOMOMMA`
--
ALTER TABLE `YOMOMMA`
  ADD PRIMARY KEY (`id_yomomma`);

--
-- AUTO_INCREMENT pour les tables déchargées
--

--
-- AUTO_INCREMENT pour la table `YOMOMMA`
--
ALTER TABLE `YOMOMMA`
  MODIFY `id_yomomma` bigint(20) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=554;

COMMIT;
