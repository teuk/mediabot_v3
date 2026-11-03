# MB1080 — Confirmer les lectures RSS avant publication

Base : snap_mediabot_v3_teuk_20261103_093727.zip.
VERSION : 3.8dev-20261103_083703. Les 403 chemins précédemment qualifiés
correspondent exactement à MB1079 final ; les correctifs antérieurs sont conservés.

## Défaut

Les sept lectures du repository RSS vérifiaient prepare et execute, puis
assimilaient la fin du fetch à un succès sans vérifier err. Avec RaiseError
désactivé, une panne pouvait devenir une liste vide, un flux absent/inactif ou
une liste partielle acceptée. Avec RaiseError actif, une exception sautait
le finish. Les callers protègent déjà ces lectures par eval, mais un échec
silencieux n'atteignait pas leur traitement d'erreur.

Le cas le plus gênant concerne paced_pending_items : après avoir obtenu une
ligne sans confirmer la fin du curseur, il pouvait marquer les articles plus
anciens comme annoncés. Le poller recevait alors un résultat accepté malgré
l'erreur de lecture. Les articles ainsi supprimés du pending ne seraient plus
proposés par un poll ultérieur.

## Correction

Un lecteur privé commun prépare, exécute et copie toutes les lignes. Il
vérifie err avant le cleanup et tente finish sur chaque statement acquis,
qu'il y ait succès, retour faux ou exception. Il ne transmet une liste que
si la lecture est confirmée. Une erreur remonte sous la forme fixe
RSS <opération> <étape> failed ; l'exception brute du driver n'est pas reprise
dans ce message. Le comportement de PrintError configuré par l'appelant
n'est pas modifié. Une exception de finish ne change pas la décision de lecture.

channel_id, list_feeds, get_feed, list_due_feeds, is_feed_enabled,
pending_items et la lecture de paced_pending_items emploient ce même chemin.
Les SELECT, binds, limites, ordre et valeurs d'absence restent identiques.
Les résultats retournés sont des copies détachées des buffers du curseur.
Les requêtes LIMIT 1 sont également lues jusqu'à leur fin confirmée.

Le mode espacé ne lance son UPDATE de suppression qu'après cette lecture
complète. Il ne publie ni candidat ni suppression si la lecture échoue.
Le poller existant produit alors repository_error et réessaie normalement
lors d'un poll suivant. Aucun poll n'est rejoué automatiquement par ce correctif.

Ce lecteur n'ajoute pas de transaction : un UPDATE de suppression reste une
opération distincte après lecture, avec les garanties antérieures. Les writes
du repository et la logique HTTP/validators/pacing ne sont pas modifiés.
Une erreur de lecture ne restaure pas les articles éventuellement supprimés
par une ancienne exécution ; aucune réparation de données n'est effectuée.

## Tests

Le cas 902 conserve les vrais fetches conditionnels 200/304 et l'allowlist
des headers, en regroupant les assertions connexes. Deux pins de lecture
sont remplacés par des requêtes réelles ; les cinq contrats de write restent
dans un groupe. Deux pins HTTP redondants avec les scénarios réels sont retirés.

Cinq groupes natifs ajoutés dans le même fichier, sans nouveau processus :

- les sept lecteurs avec de vrais SELECT DBI/SQLite : isolation par canal,
  compteurs, ordre des flux dus, limites, absences, copies et suppression
  ciblée des anciens candidats ;
- prepare refusé par l'authorizer SQLite et execute refusé par une fonction
  SQL, dans les sept lecteurs avec RaiseError 0/1 ;
- erreurs DBI au premier fetch ou après une ligne, injectées par set_err sur
  les vrais statements, avec RaiseError 0/1 : pas de résultat partiel ni de
  suppression, finish tenté, y compris quand il efface err ;
- finish natif suivi d'une exception : succès ou échec de lecture préservé ;
- vrai poller 304 en mode ordinaire/espacé : repository_error sans articles
  transmis ni suppression, puis reprise saine au poll suivant.

Seules les fonctions de date et l'unité SECOND sont adaptées à SQLite dans
la fixture. Aucune règle de lecture ou d'éviction n'y est réimplémentée.
Le cas passe de 18 à 9 assertions ; quatre des nouveaux groupes échouent
sur le module intact puis réussissent avec le correctif. Aucun nouveau cas,
délai, fork ou accès réseau externe. QUALIFICATION.md donne les mesures locales.

## Exploitation

Quatre chemins changent : repository RSS, cas 902, changelog et cette note.
Pas de schéma, dépendance, configuration ou migration de données. VERSION,
README racine, commit.sh privé, runner/ETA, radio, YouTube et correctifs
précédents sont conservés.

Le paquet contrôle les contenus exacts avant/après et les changements
qualifiés en attente. Full visible --progress/ETA sans redirection, audits
sécurité/startup, inventaire et whitespace avant staging/restart. Après
réussite complète : dev seul, nouveau PID stable dix secondes, commit.sh
natif --skip-preflight et VERSION 3.8dev automatique. Un PID stable ne prouve
pas la reconnexion IRC. Aucune intervention en production.
