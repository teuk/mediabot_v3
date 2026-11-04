# MB1092 — Sessions MariaDB restaurées et initialisation confirmée

## Source et périmètre

Snapshot snap_mediabot_v3_teuk_20261103_221804.zip, MB1091 présent,
VERSION 3.8dev-20261103_211742. Quatre chemins : DB.pm, cas744 existant,
changelog et cette note. Aucun schéma, donnée, configuration, dépendance ou
VERSION modifié. README racine, radio, YouTube, DDG, Wikipédia et code Hailo
inchangés ; commit.sh privé conservé.

## Défauts corrigés

Les connexions canoniques autorisent historiquement la reconnexion automatique
DBD::MariaDB. Celle-ci peut rouvrir une session sans repasser dans les helpers
applicatifs SET NAMES/time_zone. Les handles conservés par d'anciens composants
restent utilisables, mais leurs réglages de session peuvent être perdus.

Les trois appels DBI transmettent mariadb_init_command dans le hash
d’attributs de connexion, avec une seule instruction
SET SESSION : UTC, character_set_client, character_set_results et
collation_connection selon le mode configuré. La collation définit aussi le
jeu de caractères de connexion. Les valeurs SQL sont choisies dans les modes
internes connus ; aucune valeur de configuration libre n'entre dans cette
instruction. Aucun multi-statements n'est activé.

La reconnexion transparente canonique reste active pour préserver les handles
historiques, notamment d'authentification. Le pilote rejoue son init_command
sur le même handle, puis impose son propre UTF-8. L’UTC est restauré par le
hook ; le mode latin1 reste appliqué aux connexions explicitement initialisées,
mais sa perte lors d’une reconnexion transparente du pilote est une limite
préexistante conservée, pas une correction revendiquée ici. Les connexions isolées des workers conservent leur
reconnexion automatique désactivée. Ce mécanisme n'ajoute pas de rejeu
applicatif de requête ou de transaction.

Par ailleurs, startup/_connect continuaient après certains échecs de SET.
Les trois chemins partagent désormais une initialisation explicite vérifiée :
prepare, execute et err sont contrôlés avant finish. Le premier échec arrête
la séquence. La connexion candidate est fermée sans être publiée. Startup
échoue explicitement ; reconnexion renvoie undef et garde l'état DB-down ;
worker renvoie une erreur bornée sans remplacer le handle parent.

Un acquittement 0E0 reste une réussite. Une erreur de nettoyage ne masque pas
un SET raté ni ne transforme un SET confirmé en échec. Les modes utf8mb4,
latin1, off et repli d'un mode inconnu sont conservés ; off laisse le charset
inchangé mais conserve l'UTC déjà imposé auparavant.

## Références et qualification

Le contrat du pilote précise que mariadb_init_command est exécuté à la
connexion et rejoué lors d'une reconnexion :
https://metacpan.org/pod/DBD::MariaDB#mariadb_init_command

Les variables de charset/collation et la syntaxe SET sont documentées ici :
https://mariadb.com/docs/server/reference/sql-statements/administrative-sql-statements/set-commands/set
https://mariadb.com/docs/server/reference/data-types/string-data-types/character-sets/setting-character-sets-and-collations

Qualification r1 : cinq assertions groupées ajoutées au cas744 existant,
aucun nouveau fichier ou processus de test. Transport DBI simulé, sans serveur
ni identifiants.
Démarrage/reconnexion/worker, quatre modes, reconnexion transparente,
60 scénarios d'échec de SET et reprise après panne sont exercés. Les249
contrôles ciblés de sept fichiers passent en deux secondes. Le contrat de
rejeu du pilote est utilisé ; aucun basculement MariaDB réel n'est annoncé
comme testé ici. Résultats détaillés de full et du paquet : QUALIFICATION.md.

Application idempotente, contenus cumulés et suppressions précédentes qualifiés
conservés. Full visible --progress/ETA, audits sécurité/startup, inventaire et
whitespace avant staging/restart/commit. Dev seul : nouveau PID stable dix
secondes. commit.sh --skip-preflight reste interactif, VERSION3.8dev automatique.
Aucun contrôle WorkingDirectory. Aucun service réel, SSH ou commit/push
exécuté pendant la préparation ; un PID stable ne prouve pas la reconnexion IRC.

## Correction r2 — DSN et récupération du dev (2026-11-04)

Le journal réel a révélé `Unknown attribute 00', character_set_client`.
Le parseur DBD::MariaDB sépare le DSN sur les deux-points, y compris ceux de
`+00:00` à l’intérieur du SQL. Le faux transport r1 ne reproduisait pas ce
parseur ; la full suite verte n’a donc pas détecté la panne de démarrage.

La r2 retire le SQL des trois DSN et le passe via le hash d’attributs DBI.
Contre-épreuve native : même erreur reproduite avec la r1, puis45 contrôles
validés avec DBD::MariaDB1.24 et MariaDB10.11 temporaire : trois chemins,
quatre modes et reconnexion transparente après KILL de la connexion de test.
L’UTC reste confirmé ; la politique UTF-8 du pilote sur reconnexion latin1
est observée explicitement sans prétendre la corriger. Le contrôle DB livré
a également été exécuté contre ce serveur temporaire.
Le contrat de rejeu, les timeouts et les réglages de reconnexion restent
identiques. Le cas744 lit maintenant cet attribut et refuse tout SQL
init_command dans le DSN. Aucun test supplémentaire ni processus ajouté.

Le paquet r2 s’applique uniquement à la r1 qualifiée ou se reconnaît déjà
appliqué. Il n’exige pas un dev actif : contrôle DB réel en lecture/SET de
session, redémarrage dev et attente bornée d’un nouveau PID stable avant la
full suite visible --progress/ETA, les audits et commit.sh. Une erreur donne
la phase et les journaux du dev. VERSION reste gérée par commit.sh.
