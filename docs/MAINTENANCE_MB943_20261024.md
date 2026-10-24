# MB943 — Spark observe les sorties de Mediabot

## Problème et correction

Spark observait les messages entrants des humains, bots connus et commandes.
Les sorties normales de Mediabot signalaient déjà leur activité à Wit/Quip,
mais pas à Spark. Sans écho IRC du serveur, une réponse Hailo ou IA pouvait
ainsi rester invisible à la politique Spark et être suivie d'une intervention
spontanée jugée à tort admissible.

Le transport public botPrivmsg/botAction notifie désormais l'observateur Spark
existant après acceptation de sa sortie. L'observateur ajoute un événement
bot_pressure horodaté, sans texte ni nick. Les politiques de reprise après
silence et de momentum réutilisent leurs pauses déjà définies. Aucun nouveau
réglage, quota ou chanset. Les notifications Wit/Quip restent indépendantes.

## Frontières

Un message privé, vide, bloqué par badword, refusé par antiflood ou qui provoque
une exception de transport ne reçoit pas de notification de réussite. Une mise
en file seule n'est pas une sortie ; la notification a lieu au retour par la
façade lors de sa livraison. Un message logique découpé en plusieurs fragments
produit un événement après acceptation de ce chemin, pas un par fragment.
Cela signifie acceptation par le transport local, pas accusé de lecture IRC.

Aucun observateur n'est créé par une sortie. Un salon inconnu de Spark ne crée
pas d'état et ne chasse pas un salon observé. Le texte des sorties ne rentre
pas dans le contexte humain et les compteurs de participants restent exacts.
Un échec d'observation ne modifie pas l'acceptation d'une sortie déjà effectuée.

Ce lot porte sur les prochaines évaluations de Spark. Il n'introduit pas de
réservation universelle entre Hailo/Spark/IA, n'annule pas une requête déjà
partie et n'observe pas les chemins bas niveau qui contournent la façade.
Les garde-fous de livraison tardive existants restent en place.

## Qualification et livraison

Le nouveau test 1317 exécute la vraie façade Helpers/IRC avec un transport
capturé et les vrais Observer, State et Orchestrator Spark. Sur MB942 inchangé,
huit assertions sur trente-cinq reproduisent le défaut ; le correctif les
fait passer. Les scénarios couvrent message, ACTION, découpage, refus, file,
échec de transport/observateur, isolation du salon et absence d'activation.
Aucun message, fournisseur ou compte réel n'est utilisé dans ces tests.

Référence serveur : MB942, commit ea1d467, VERSION 3.6dev-20261024_095231.
Il est validé sur teuk : 30 736 assertions, sécurité GO/37 et intégrité OK.
MB943 utilise l'installateur à hashes avant/après et sauvegarde dédiée ; il
exige les suites ciblées puis la suite complète sans exclusion, sécurité et
intégrité. Un contrôle en échec restaure les seuls fichiers de cette tentative.
Aucune commande Ansible, écriture de base ou relance de service. Le code sera
chargé au prochain redémarrage normal après validation et commit.
