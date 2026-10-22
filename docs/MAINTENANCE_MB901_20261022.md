# MB901 — Partyline : une session fermée doit rester fermée

Date : 22 octobre 2026.

## Bugs reproduits

Telnet et DCC extraient toutes les lignes d'une lecture avant de les distribuer.
Une commande comme `.quit` ou le trentième message d'un flood supprimait la
session, mais les lignes déjà extraites continuaient vers le logger puis le
dispatcher. L'accès à l'état utilisateur recréait alors une entrée vide ; le
flux, déjà en fermeture, pouvait recevoir de nouvelles invites d'authentification
et tenter de nouvelles vérifications. Les reproductions produisent aussi des
warnings « Cannot write data to a Stream that is closing ».

Les callbacks de lecture, EOF et fermeture ne vérifiaient que le numéro de
connexion capturé. Un ancien callback pouvait donc agir sur une session plus
récente enregistrée sous le même numéro, supprimer son état, ses confirmations
ou son hook console et décrémenter sa métrique.

Enfin, les deux refus qui imposent une déconnexion dans `_do_login` demandaient
la fermeture après vidange, mais conservaient l'état jusqu'au callback de
fermeture. D'autres lignes du même buffer pouvaient encore atteindre le login.

## Correction ciblée

- Les deux chemins `on_read` vérifient que l'utilisateur existe et que le flux
  enregistré sous cet identifiant est bien celui du callback, avant tout
  traitement et après chaque distribution de ligne.
- Les deux callbacks `on_closed` font la même vérification. Ils utilisent le
  flux fourni par IO::Async au callback, sans capturer une référence forte du
  flux dans son propre callback.
- Les refus pour trop d'échecs par session ou adresse retirent immédiatement
  l'état via `_close_session`, après avoir demandé la vidange du message de
  déconnexion. Cette suppression existante est idempotente et annule également
  le timeout DCC et le hook console.

Le correctif ajoute 24 lignes dans Transport et SessionAuth, sans déplacer de
méthode ni ajouter d'API. Les commandes, exports, seuils, permissions, SQL,
politiques de mot de passe, timers, bornes de lignes et traitement Telnet restent
ceux de la référence. Les traces des callbacks devenus obsolètes sont ignorées.
Le départ déjà traité ne produit pas de second nettoyage.

## Tests de comportement

Le même fixture appelle les vrais propriétaires sur la référence et le candidat.
Il utilise des socketpairs locaux, de vrais IO::Async::Stream/Loop/timers et une
base SQLite privée en mémoire pour la vraie requête de login. L'acceptation du
listener est injectée sans ouvrir de port public ; le vérificateur d'identifiants,
le logger, les métriques et la publication du statut sont des fixtures.
Aucun mot de passe réel, service IRC, configuration privée ou base existante
n'est utilisé ; aucune migration n'est livrée.

Les callbacks de production installés sont invoqués directement pour contrôler
les groupes de lignes et l'ordre des événements tardifs. Quatre scénarios
supplémentaires passent les octets par le socket et le vrai lecteur IO::Async.
La réaffectation d'identifiant est simulée par remplacement de l'entrée de
session et du flux ; elle ne dépend pas d'une course aléatoire de l'OS.

| Scénarios par transport | Référence | Candidat |
| --- | --- | --- |
| `.quit`, flood, `.quit` suivi d'une ligne trop longue | 0/3 | 3/3 |
| `.quit` et flood par lecture IO::Async native | 0/2 | 2/2 |
| Ancienne lecture sans session ou avec session remplacée | 0/2 | 2/2 |
| Ancien EOF et ancienne fermeture avec session remplacée | 0/2 | 2/2 |
| Déconnexion pour limite d'authentification par session/adresse | 0/2 | 2/2 |
| Fermeture et EOF normaux, libération du flux | 2/2 | 2/2 |
| Login groupé, fragmenté et syntaxe historique | 3/3 | 3/3 |
| **Total Telnet + DCC** | **10/32** | **32/32** |

Les contrôles portent sur l'état utilisateur et le flux, le nombre de
vérifications d'identifiants, les sorties et logs, l'absence de warnings, le
compteur de sessions, le nettoyage unique et les données de la session de
remplacement. Les trente-deux assertions sont ajoutées au cas existant 585 ;
aucun nouveau fichier de cas n'est créé et les anciennes assertions restent.

Les six sorties nominales réelles de login (trois formes, deux transports) sont
identiques avant/après, en neutralisant seulement l'heure et la colonne de
numéro de descripteur. Quatre mutations indépendantes sont détectées : retrait
de la garde d'entrée, de la garde après distribution, de la garde de fermeture,
et du nettoyage immédiat des refus d'authentification.

## Qualification locale et limites

- Trois syntaxes : OK. L'avertissement isolé DBI::errstr dans SessionAuth existait
  déjà sur la référence ; le correctif ne change pas cette expression.
- Groupe Partyline/DCC : **1 947/1 947**, 71 fichiers, 6 s.
- Audit : **GO, 37 invariants** ; intégrité de démarrage : OK.
- Suite complète référence : **30 247 réussites, 1 échec / 30 248**, 1 156 fichiers,
  135 s.
- Suite complète candidat : **30 278 réussites, 2 échecs / 30 280**, 1 156 fichiers,
  146 s.

Les deux suites sont lancées sans filtre ni exclusion. MB786 échoue sur la
référence et le candidat avec un exit 1 du rehearsal réel de l'updater. MB647
échoue également dans la suite candidate sur l'identité du processus. Une sonde
séparée des vrais collecteurs Doctor dans les deux arbres montre le même
résultat : PID 8 vivant selon kill 0, `/proc/8` absent, UID et fait propriétaire
indisponibles. Doctor et son cas n'ont pas changé. Les ensembles d'échecs des
suites complètes ne sont pas présentés comme identiques et la suite locale
candidate n'est pas présentée comme verte.

Le validateur serveur conserve la full suite sans exclusion et exige sa réussite,
puis les audits. Les nombres d'assertions peuvent varier avec les dépendances.
Ces contrôles ne prouvent pas l'absence de toute régression et ne constituent
pas un test d'un client Telnet réel ou d'un réseau DCC distant.

## Livraison

Six chemins : Transport, SessionAuth, le cas 585, un fixture partagé, cette note
et CHANGELOG. Aucun schéma, configuration privée, VERSION, service, runner ou
audit n'est modifié. L'installateur vérifie les préimages, sauvegarde contenus,
modes et absences, et restaure les chemins écrits si un contrôle échoue. Une
réapplication identique valide sans réécrire ; aucun commit ni redémarrage
n'est automatique.
