# MB902 — Partyline : séparer le cadrage Telnet des lignes utilisateur

Date : 22 octobre 2026.

## Défauts reproduits

Le lecteur Telnet nettoyait le buffer IO::Async complet à chaque lecture, puis
laissait la ligne partielle déjà décodée dans ce même buffer. Deux octets IAC
échappés en données pouvaient donc être redécodés comme un nouveau contrôle.
Le résultat dépendait du découpage des lectures réseau : deux IAC littéraux
pouvaient devenir un seul, ou des octets de données suivants disparaître.

Les commandes à deux octets comme IAC NOP n'étaient pas filtrées. Les
sous-négociations IAC SB ... IAC SE n'étaient pas distinguées des lignes de
commande : un LF dans leurs paramètres produisait une fausse ligne et pouvait
perturber le parcours de login.

Les reproductions montrent avant/après :

| Entrée sur le fil | Référence | Candidat |
| --- | --- | --- |
| `a`, deux IAC échappés, puis `b`, en trois lectures | `a`, un IAC, `b` | Les deux IAC sont conservés |
| IAC littéral suivi des données FB 01 | Données supprimées comme WILL ECHO | Données conservées |
| Sous-négociation avec LF suivie de `tester` | Deux fausses lignes contenant le cadrage | Une seule ligne `tester` |
| `tes`, IAC NOP, `ter` | Octets de contrôle dans le pseudo | `tester` |

## Module et intégration

`Mediabot::Partyline::Telnet` expose en import optionnel
`decode_input($state_hash, $wire_bytes)`. Le module est indépendant du bot, de
DBI et d'IO::Async. Il filtre les commandes IAC de base, consomme les paramètres
WILL/WONT/DO/DONT, restitue IAC IAC comme donnée et ignore le contenu SB jusqu'à
IAC SE, y compris les IAC échappés dans ce contenu. Les paires IAC inconnues
restent littérales pour conserver le repli historique.

Le cadrage est fondé sur la [RFC 854, section TELNET COMMAND STRUCTURE](https://www.rfc-editor.org/rfc/rfc854.html).
Il s'agit d'un filtre de cadrage, pas d'une implémentation complète du terminal
NVT, d'un éditeur de ligne ou d'une nouvelle politique d'acceptation des options.
Le traitement CR/LF et les commandes applicatives conservent leurs propriétaires.

Chaque connexion Telnet possède son état de décodage et son buffer de texte.
Le buffer réseau est consommé une seule fois ; les lignes partielles décodées
ne repassent plus par le filtre. L'état conserve uniquement un petit entier de
mode, jamais le contenu d'une sous-négociation. Le même extracteur commun limite
toujours les lignes utilisateur à 4 096 octets, avec la même tolérance au CR final.

Le lecteur continue de passer par `$self->_strip_telnet_iac`, avec un état
explicite. L'appel historique sans état garde exactement son algorithme.
Les exports de la façade Partyline et de SessionAuth sont conservés. Le chemin
DCC reste brut et n'appelle pas le décodeur Telnet ; les gardes de cycle de vie
MB901 restent présentes dans les deux transports.

## Contrôles de comportement

Le fixture existant MB901 est étendu et réutilisé, sans ajouter de fichier de
cas numéroté. Les vingt-quatre assertions nouvelles du cas 07 couvrent :

- octets ordinaires, UTF-8 fragmenté, paires IAC connues/inconnues, quatre formes
  de négociation, contrôles à deux octets et IAC littéraux ;
- sous-négociation avec LF ou texte ressemblant à des commandes, IAC échappés
  dans SB, contenu SB de 256 Kio et connexions indépendantes ;
- borne exacte de 4 096 octets, dépassement, données DCC inchangées et vraie
  lecture IO::Async par socketpair ;
- les 25 positions de coupure en deux lectures de deux exemples de protocole,
  regroupées dans une assertion de propriété ;
- six scénarios avec les vrais dispatcher, requête SQL de login et nettoyage,
  sur une base SQLite privée en mémoire et des identifiants de fixture.

Les cas de cadrage capturent les lignes remises au dispatcher, sans recopier
le décodeur. Les contrôles de login utilisent son implémentation réelle. Les
lectures sont pilotées explicitement pour imposer les fragments ; le scénario
natif passe les fragments par le vrai socket et le vrai lecteur IO::Async.
L'acceptation du listener, les sorties de log/statut, les métriques et le
vérificateur d'identifiants sont des fixtures. Aucun port public ou service réel
n'est sollicité.

Le même fixture donne **11/24 sur la référence, 24/24 sur le candidat**. Les
32 scénarios MB901 continuent de passer. Les six sorties nominales réelles de
login Telnet/DCC sont identiques avant/après après neutralisation de l'heure et
de la colonne fd.

Quatre mutations sont détectées : perte de l'état entre lectures, fuite du
contenu SB, perte de l'IAC littéral et redécodage de la ligne déjà décodée.
Un probe du module seul filtre une sous-négociation de 1 Mio et vérifie un état
réduit à une clé entière, puis la reprise du texte après SE ; il confirme aussi
que le module se charge sans Partyline, DBI ou IO::Async.

Le cas 585 conserve toutes ses assertions ; son contrat d'appel reconnaît le
buffer décodé Telnet et le buffer brut DCC passés au même extracteur borné.

## Qualification locale

| Contrôle | Résultat |
| --- | --- |
| Quatre syntaxes : trois modules et fixture | OK |
| Groupe Partyline/DCC | 1 971/1 971, 71 fichiers, 5 s |
| Audit de sécurité | GO, 37 invariants |
| Intégrité de démarrage | OK |
| Full suite référence | 30 279 réussites, 1 échec / 30 280, 1 156 fichiers, 134 s |
| Full suite candidat | 30 306 réussites, 1 échec / 30 307, 1 156 fichiers, 130 s |

Les deux suites complètes sont lancées sans filtre ou exclusion. MB786 échoue
dans les deux sur le rehearsal d'updater (exit 1 au lieu de 0), dans cet exécuteur.
MB647 passe dans les deux suites. Les 27 assertions supplémentaires se composent
des 24 assertions nouvelles et des trois contrôles structurels automatiques du
nouveau module dans le cas 86. Aucun gain de vitesse de la suite n'est revendiqué.

Le warning isolé DBI::errstr reste celui de la référence, ligne 604 puis 608 ;
l'expression DBI n'est pas modifiée. Le validateur livré exige la full suite
serveur verte, y compris MB786, puis les audits, sans exemption. Ces tests ne
prouvent pas l'absence de toute régression ni la compatibilité de tous les clients
Telnet externes ; ils contrôlent les cas et fragments décrits ci-dessus.

## Livraison

Huit chemins : Telnet, Transport, SessionAuth, le fixture existant, les cas 07
et 585, cette note et CHANGELOG. Aucun schéma, migration, SQL de production,
configuration privée, VERSION, service, runner ou outil d'audit n'est modifié.
L'installateur conserve les préimages et sauvegardes, l'aperçu, la réapplication
sans réécriture et la restauration gardée. Aucun commit ou redémarrage automatique.
