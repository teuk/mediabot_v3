# MB915 — Liquidsoap : traiter une coupure d'écriture sans arrêt du processus

Date : 22 octobre 2026. Base : `snap_mediabot_v3_teuk_20261022_183238.zip`,
VERSION `3.6dev-20261022_163225`.

## Défaut reproduit

Le client TCP pouvait se connecter, puis rencontrer une connexion déjà coupée
lors du print de la commande. Avec le gestionnaire SIGPIPE par défaut, le signal
13 terminait le processus avant que le bloc d'erreur d'écriture puisse répondre.
Un eval ne contient pas à lui seul un signal dont l'action est de terminer.

Le chemin radio _push_cached appelle ce client directement. Dans une sonde
native, il ne pouvait donc pas afficher son message d'échec de mise en file.
Le défaut est reproduit avec une connexion TCP réelle à un serveur loopback,
coupée par reset juste avant que le constructeur rende le socket au client.

## Correction limitée

Liquidsoap::command ignore SIGPIPE dans sa portée locale. L'écriture en erreur
utilise alors le résultat existant : statut faux, diagnostic write failed,
fermeture du socket et log de niveau 1. Le gestionnaire de signal de l'appelant
est restauré au retour ou à la sortie de cette portée. Aucun gestionnaire global
n'est installé, aucune nouvelle tentative d'envoi n'est ajoutée.

Seules trois lignes de production s'ajoutent, dont deux commentaires. Les
commandes envoyées, l'ajout de quit, le décodage END, les identifiants de requête
y compris zéro, les erreurs serveur, délais, limite de réponse et wrappers
restent identiques. La correction ne rend pas les opérations asynchrones et ne
réécrit pas leurs mécanismes de délai ou de lecture.

## Contrôles

Six assertions complètent le cas 582 existant. Les 17 anciennes assertions sont
conservées. Pour command, push, queue, skip et flush_and_skip, les sondes utilisent
de vrais sockets TCP et les vrais print/sysread/close du client. Un wrapper du
constructeur organise la coupure avant le retour du socket, sans remplacer le
transport. Les sous-processus isolent le signal fatal du runner.

Chaque méthode est vérifiée avec SIGPIPE DEFAULT, IGNORE et un callback. Les
critères contrôlent l'échec, son diagnostic et son log existants, la fermeture,
l'absence de warning et la restauration exacte du gestionnaire appelant. Un
dernier critère couvre quinze échanges sains sur les cinq méthodes : résultat,
protocole command-plus-quit, erreur serveur et request ID zéro sont conservés.
Le candidat passe les six critères ; la référence échoue sur les cinq coupures
par signal 13. Le contrôle sain et les 17 anciennes assertions passent des deux
côtés, soit 23/23 contre 18/23 avec le cas étendu.

Une comparaison distincte de 120 échanges natifs par arbre croise cinq méthodes,
huit réponses et trois gestionnaires. Réponses, octets envoyés, logs et état des
sockets/signaux restent identiques, y compris sur une réponse incomplète ou
dépassant la limite. La sonde radio _push_cached confirme aussi le retour à son
message d'échec existant après reset et préserve sa réponse nominale.

Trois mutations sont détectées : protection retirée, gestionnaire global modifié
sans restauration, échec d'écriture annoncé comme succès. Aucun nouveau fixture
ou cas numéroté. Les 1 156 fichiers de tests restent présents. Le groupe ciblé
radio/Icecast/Liquidsoap passe 422/422 ; audit des 37 invariants et intégrité de
démarrage passent. QUALIFICATION.md détaille les suites complètes et la livraison.

Aucun schéma de base/API, SQL de production, plugin, configuration privée,
VERSION, service, Partyline, runner ou audit n'est modifié. Les sondes n'utilisent
aucune base ou sortie IRC réelle, ni service Liquidsoap/Icecast installé. Le
serveur doit toujours passer toute la suite avant commit.
