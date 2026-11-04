# MB1095 — Rechargement complet des timers SQL

Source : snap_mediabot_v3_teuk_20261104_115531.zip.
VERSION observée : 3.8dev-20261104_095557 ; MB1094 présent.

## Problème et correction

onStartTimers est appelé à la connexion IRC et à la reconnexion. Il préparait
les timers avant leur activation, mais assimilait une fin de fetch en erreur
à une fin de résultat normale. Un échec après une ligne pouvait donc publier
un seul timer et arrêter tous les anciens. Un échec avant la première ligne
pouvait publier un ensemble vide. Les exceptions DBI pouvaient aussi sortir
du rechargement et les erreurs de finish interrompre une lecture réussie.

La préparation, l’exécution et le parcours du curseur sont désormais protégés
ensemble. Le contrôle de err intervient avant finish, qui peut effacer le
diagnostic. Un échec retourne 0, conserve le hash hTimers précédent et ses
objets actifs, et ne rattache aucun timer préparé à la boucle. La fermeture
du curseur est isolée du résultat de la lecture. Le journal n’expose qu’une
phase fixe : prepare, execute ou fetch.

Une lecture complète vide reste une suppression volontaire des anciens timers.
Une lecture complète non vide suit le chemin d’activation et de rollback
existant. La suppression du responder différé à la reconnexion reste placée
avant la lecture SQL ; un échec SQL ne ressuscite pas cette ancienne réponse.

## Vérifications utiles

Le cas natif 403 utilise déjà une vraie boucle IO::Async, de vrais Periodic
et une base SQLite privée. Il couvre maintenant aussi 30 scénarios d’échec :
prepare, execute, fetch avant la première ligne, après une ligne et après les
trois lignes ; RaiseError activé ou non ; finish normal, faux ou levant une
exception. Les erreurs de fetch passent par DBI set_err. Le test contrôle le
hash et les anciens objets, leur rattachement, leurs ticks, la libération des
objets préparés et la reprise complète au rechargement suivant.

Six contrôles couvrent des lectures complètes et vides avec les trois formes
de cleanup. Les anciennes vérifications d’activation partielle, de reprise,
de lignes invalides, de déconnexion et de refus CR/LF/NUL restent dans le même
processus. Le cas 1437 vérifie toujours l’annulation du responder et attend
maintenant le résultat contenu de l’échec SQL.

Les 21 assertions qui inspectaient la forme du source (cas 402 et début du
cas 403) sont remplacées par trois assertions groupées sur ces résultats
natifs : 18 assertions et un fichier de tests en moins. Aucun nouveau
processus, délai ou dépendance n’est ajouté.

## Application

Le paquet vérifie les empreintes du snapshot et des changements précédents
qualifiés, applique le patch ou reconnaît une application identique, puis
exécute les tests ciblés, la full suite visible avec --progress et son ETA,
les audits et l’inventaire. Le script redémarre uniquement mediabot@dev.service,
attend un nouveau PID actif et le vérifie pendant dix secondes. En cas d’échec,
il affiche la phase et les diagnostics du dev et ne lance pas de commit.

Le commit reste interactif via commit.sh --skip-preflight ; VERSION conserve
le format 3.8dev automatique. Si commit.sh demande la confirmation des
suppressions qualifiées, saisir KEEP DELETIONS puis confirmer le commit.
Un PID stable ne prouve pas la reconnexion IRC.

Un seul module applicatif est modifié : Mediabot/DBCommands.pm. Aucun schéma,
configuration, donnée utilisateur, commit.sh privé, README racine, radio ou
YouTube n’est modifié. La préparation locale n’agit sur aucun service réel.
