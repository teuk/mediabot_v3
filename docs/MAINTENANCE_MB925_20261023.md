# MB925 — Timers SQL : raccordement des callbacks et rollback du timer courant

Date : 2026-10-23. Base : snap_mediabot_v3_teuk_20261023_125617.zip.

## Deux défauts reproduits

Les timers SQL rechargés par onStartTimers et ceux créés par mbAddTimer_ctx
appellent _timer_irc_write comme méthode du bot. Ce helper existait dans
DBCommands, avec ses gardes connexion/CR/LF/NUL, mais n'était pas exporté
dans Mediabot. Un vrai tick sur un objet de cette classe échouait par
méthode introuvable, au lieu de transmettre la commande sécurisée.

Lors du rechargement, un deuxième défaut affectait le chemin d'erreur :
le timer courant n'était ajouté à started_fresh qu'après add et start.
Une exception après un effet partiel le laissait hors du nettoyage.
La sonde native retrouve un notifier attaché après add ; après start,
le timer peut même émettre alors que le lot a été refusé et que hTimers
contient toujours les anciens handles. Un rechargement suivant ne connaît
pas ce timer oublié et peut ajouter un deuxième émetteur de la même commande.

## Correction limitée

- Ajouter _timer_irc_write aux exports de DBCommands déjà importés par Mediabot.
- Inscrire le timer courant dans started_fresh avant add/start, afin que la
  boucle de rollback existante le traite aussi en cas d'échec partiel.

Les anciens timers ne sont arrêtés qu'après démarrage réussi de tous les
nouveaux. Sur refus, leur hash, leur identité, leur rattachement et leur
activité sont conservés. Les nouveaux objets non atteints ne sont pas publiés.
Le traitement existant de stop/remove, dans deux eval séparés, reste intact.

Aucun texte SQL, bind, intervalle, commande stockée, schéma/migration,
autorisation, configuration privée ou VERSION modifié. Les règles d'addtimer
restent : Owner authentifié, noms/intervalle/verbe/budget validés et insertion
avant démarrage. Les gardes CR/LF/NUL et connexion sont conservés.
Les autres familles de timers ne changent pas.

## Vérification

Le cas 403 conserve ses onze critères et reçoit cinq assertions regroupées.
L'enfant Perl utilise les vraies fonctions, les vrais Periodic, une vraie
boucle IO::Async et DBI/SQLite privé. Les premiers délais des sondes sont seuls
ramenés à zéro ; les intervalles originaux sont enregistrés et conservés.
Les callbacks s'exécutent via loop_once(0), sans attente ni réseau.

Les contrôles couvrent 24 placements de défauts : avant/après add et start,
sur le premier, deuxième ou troisième timer, via la fonction du module et
l'alias importé. Quatre scénarios injectent une exception après un stop/remove
réel ; deux vérifient le rechargement suivant, sans notifier oublié ni doublon.
Ils contrôlent retours, références faibles, état natif, registre, sorties
accentuées, lignes SQL et maintien des deux anciens timers.

Pour isoler le cycle de vie du défaut de raccordement, ces contrôles utilisent
un propriétaire qui hérite directement de DBCommands. Quatorze traces nominales
complètes sont strictement identiques source/candidat : succès, table vide,
lignes invalides, déconnexion, CR/LF/NUL et refus réels de prepare/execute.

Quatre autres parcours utilisent la classe Mediabot elle-même, sans héritage
ajouté ni helper substitué : chargement, déconnexion, commandes contenant des
contrôles et addtimer avec le vrai Context et un principal Owner de fixture.
La source échoue par méthode introuvable, le candidat exécute les callbacks
et applique les gardes existants. Seuls transport de sortie et journalisation
sont interceptés. Les résultats SQL ne sont pas simulés.

Le cas étendu donne 13/16 sur la source et 16/16 sur le candidat. Huit mutations
sont détectées par les nouvelles assertions. Aucun cas ni fixture partagé
supplémentaire : le catalogue reste à 1 156 fichiers.

Les suites complètes et la limite locale MB786 sont détaillées dans le
QUALIFICATION.md du paquet. Le validateur livré exige la suite sans filtre.
