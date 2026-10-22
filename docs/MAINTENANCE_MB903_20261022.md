# MB903 — Aide ciblée et outils d'historique Partyline

Date : 22 octobre 2026.

## Fonctionnalités pour Telnet et DCC

Ce lot ajoute des outils d'utilisation quotidienne à partir de l'aide et de la
mémoire de session existantes, sans évolution du schéma ni nouvelle requête SQL.

| Commande | Comportement |
| --- | --- |
| `.help` | Liste complète des commandes. |
| `.help plugins` | Lignes d'aide de cette commande exacte. |
| `.help .PING` | Même recherche, point initial facultatif, casse ignorée. |
| `.help dcc` | Aide de l'alias existant dccstat/dcc. |
| `.help search timer` | Recherche littérale dans noms, syntaxes et descriptions. |
| `.history` | Sortie historique des dix commandes retenues dans cette session. |
| `.history 5` | Les cinq plus récentes, affichées de la plus ancienne à la plus récente. |
| `.history find café` | Recherche littérale dans les entrées retenues, casse ignorée. |
| `.history clear` | Effacement de l'historique de cette connexion uniquement. |

L'aide ciblée renvoie au plus douze lignes et signale une troncature avec une
invitation à affiner la recherche. Les textes de recherche sont limités à
128 caractères. La recherche n'interprète pas les métacaractères d'expressions
régulières. Le helper existant IRC::Text::decode_irc_text est réutilisé pour les
comparaisons UTF-8 sans changer les octets stockés ou affichés.

La capacité de l'historique reste à dix commandes : pas de nouveau stockage,
pas de récupération d'anciennes connexions, pas d'accès à l'historique d'un
autre utilisateur et pas de réexécution de commande. Les requêtes `.history`,
y compris les arguments invalides, ne s'enregistrent pas elles-mêmes et ne
sont pas annoncées aux autres utilisateurs. La politique de log serveur reste
celle de la référence ; il ne s'agit pas d'un effacement des logs du bot.

## Nettoyage de l'aide et compatibilité

Les doublons `.seen`, `.top` et `.remind` sont supprimés de l'aide complète.
La syntaxe `.top <#chan|all> [n]` suit le comportement actuel sans scan implicite.
L'aide `.remind <nick> <msg>` suit le parseur actuel ; le canal n'est pas un
argument séparé de cette commande. Le KV existant est décrit comme partagé en
mémoire, sans promesse de persistance. Les implémentations de top, remind, seen
et KV ne changent pas.

Les 62 noms de commandes déjà documentés et les six lignes d'aide plugin sont
conservés. La sortie de `.history` sans argument reste identique octet pour
octet. Les API historiques _cmd_help/_cmd_history restent aux mêmes endroits
et acceptent un argument optionnel ; le dispatcher continue de passer par
`$self`, conserve les métriques, l'authentification et les limites de débit.
Aucune permission de commande existante n'est modifiée par l'aide.

## Tests de comportement

Vingt-six assertions complètent le cas 07, avec le fixture Partyline existant :

- aide complète/ciblée, casse et point facultatif, alias dcc, recherche littérale,
  absence de résultat, usage incomplet, taille maximale et limite de douze lignes ;
- descriptions corrigées, historique par défaut/récent, recherche avec accents,
  métacaractères littéraux, absence de résultat, arguments invalides et effacement ;
- historique vide, capacité de dix entrées, isolation des sessions, absence
  d'annonce aux autres utilisateurs, absence d'auto-enregistrement ;
- maintien de la porte d'authentification et de la limite de commandes ;
- appels depuis les vrais lecteurs IO::Async Telnet et DCC sur socketpairs.

Les tests de logique appellent les vrais propriétaires et le dispatcher, avec
des sorties mémoire. Des objets qui lèvent une exception au moindre accès
DB/IRC sont placés aux interfaces de données : les outils doivent rester locaux.
Les deux scénarios natifs émettent quatre commandes par le socket réel et
vérifient l'aide, la recherche UTF-8, l'effacement et le destinataire des annonces.
Le fixture utilise son SQLite privé préexistant pour son montage, mais remplace
les interfaces DB/IRC du bot par ces gardes avant les commandes testées.

La matrice d'acceptation donne **26/26 sur le candidat**. Sur la référence,
seule la garde d'authentification satisfait déjà ces nouveaux critères ; les
25 autres critères portent sur les fonctionnalités ou changements d'annonce
introduits ici. Ce chiffre n'est pas présenté comme 25 anciens bugs.

Les 32 scénarios MB901 et les 24 scénarios Telnet MB902 sont conservés. Les
six sorties nominales réelles de login restent identiques après neutralisation
heure/fd. La sortie par défaut de l'historique, la liste des noms de commandes et
les lignes d'aide plugin sont également comparées aux vrais propriétaires de
référence. Six mutations sont détectées : perte des arguments, enregistrement
ou annonce des requêtes d'historique, recherche regex, aide sans borne et lecture
de l'historique d'une autre session.

## Qualification locale

| Contrôle | Résultat |
| --- | --- |
| Trois syntaxes : Commands, Dispatcher, fixture | OK |
| Groupe Partyline/DCC | 1 997/1 997, 71 fichiers, 7 s |
| Audit réel | GO, 37 invariants |
| Intégrité de démarrage | OK |
| Full suite référence, sans exclusion | 30 306 réussites, 1 échec / 30 307, 1 156 fichiers, 129 s |
| Full suite candidat, sans exclusion | 30 331 réussites, 2 échecs / 30 333, 1 156 fichiers, 134 s |

Les 26 assertions supplémentaires expliquent l'écart de total. Aucun gain de
vitesse n'est revendiqué. MB786 échoue dans les deux suites sur le rehearsal de
l'updater (exit 1 au lieu de 0). MB647 échoue aussi dans la suite candidate sur
l'identité du processus, alors qu'il passe dans la full suite de référence.
Ces ensembles d'échecs ne sont donc pas présentés comme identiques.

Une sonde séparée des vrais collecteurs Doctor des deux arbres observe PID 8
vivant selon kill 0 mais absent de `/proc/8`. Les deux rendent UID et fait
propriétaire absents de manière identique. Doctor et les cas concernés sont
byte-identiques. Cela étaye la limitation locale ; le candidat n'est pas déclaré
vert. Le validateur livré exige la full suite serveur sans exemption, puis les
audits. Les comptes peuvent varier avec les dépendances installées.

Ces contrôles ne prouvent pas l'absence de toute régression. Aucun service,
configuration réelle, base existante ou réseau IRC n'est sollicité.

## Livraison

Sept chemins : Commands, Dispatcher, fixture existant, cas 07, guide Partyline,
cette note et CHANGELOG. Un seul nouveau fichier, la note. Aucun module ou
fichier de cas numéroté ajouté. Aucun schéma, migration, SQL de production,
configuration privée, VERSION, service, runner ou outil d'audit modifié.
L'installateur préserve les préimages, sauvegardes, modes, absence initiale,
réapplication sans réécriture et restauration gardée. Aucun commit, push ou
redémarrage automatique.
