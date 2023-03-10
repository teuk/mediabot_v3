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
(11, 'chatGPT');

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

COMMIT;
