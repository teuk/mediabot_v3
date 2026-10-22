# MB913 — Garder les résultats asynchrones dans leur budget de transport

Date : 22 octobre 2026. Base : `snap_mediabot_v3_teuk_20261022_173929.zip`,
VERSION `3.6dev-20261022_153812`.

## Défauts reproduits hors plugins

Les commandes lourdes utilisent CommandAsync pour collecter leurs messages dans
un enfant et les restituer depuis le parent. Un résultat trop grand déclenchait
un repli sur les dix premières intentions, sans revérifier sa taille sérialisée.
Un seul message de 70 000 caractères ou dix intentions encore volumineuses
dépassaient les 64 KiB. Le parent bornait son buffer, recevait du JSON incomplet
et annonçait Database error malgré une commande réussie.

Quand les logs seuls déclenchaient ce repli, un tableau de moins de dix intentions
était complété par des entrées nulles. Le rejeu pouvait alors lever après les
premiers messages. Le cas de trois messages et un gros log le reproduit avec
un vrai worker et son vrai pipe.

## Correction

Le helper privé _encode_worker_result garde le résultat normal si son JSON UTF-8
tient dans MAX_PAYLOAD. Sinon, le repli conserve au plus dix intentions réelles,
puis retire les dernières jusqu'à obtenir un préfixe ordonné dont le JSON tient.
La limite reste 64 KiB et les autres métadonnées du repli restent comme avant.
Les textes ne sont pas coupés au milieu d'un caractère ou d'une intention.

Si la première intention dépasse à elle seule le budget, elle et les suivantes
sont écartées ; l'avis de troncature existant est adressé à l'appelant. Les gros
logs restent écartés au repli. Le correctif ne promet pas la livraison intégrale
des résultats excessifs et n'ajoute pas de fragmentation ou de reprise automatique.

Seul le sérialiseur enfant est extrait et appelé. Le parent, son buffer, les
facades, quotas, délais TERM/KILL, barrière reap/EOF, verrou par canal, contexte
de livraison et pacing news ne sont pas réécrits. Les commandes métier et leurs
requêtes ne changent pas ; aucun changement de schéma SQL ou d'API plugin.

## Validation

Huit assertions complètent le cas isolé 1226. Le fixture MB840 est réutilisé sans
modification. Les scénarios couvrent Unicode nominal, budget exact, première
intention énorme, préfixe avant une intention énorme, 60 grandes intentions,
logs excessifs avec trois messages, connexion remplacée et exception métier.

Les fork/pipe/Stream/watch_process et le reap sont natifs ; un wrapper observe
les octets sans remplacer le traitement du stream. Les critères contrôlent
JSON complet dans le budget, ordre des messages conservés, avis de troncature,
absence d'entrées nulles, contexte, code de sortie enfant, compteurs et libération
du verrou. Le connecteur DB et les Helpers terminaux du fixture sont contrôlés :
aucune connexion SQL ou sortie IRC réelle n'est effectuée par ces scénarios.

Les huit nouveaux critères passent 8/8 candidat, 3/8 référence ; les anciennes
48 assertions passent dans les deux arbres. Quatre mutations sont détectées.
Une sonde native supplémentaire confirme le cas de 20 000 emojis (80 000 octets
de texte UTF-8) après un premier message : le candidat garde ce premier message
et annonce la troncature, tandis que la référence annonçait Database error.

Quarante-trois scénarios nominaux comparent le vrai transport enfant/parent :
0/1/3/10/60 messages, types mélangés, texte ASCII/Unicode, logs, exception métier,
borne d'intentions et deux anciens replis sur dix messages qui tenaient déjà.
JSON décodé, réponses ordonnées et compteurs restent identiques ; aucun Stream
ou timer de délai ne reste après finalisation. Aucun gain de temps n'est revendiqué.

Les régressions ciblées passent 988 assertions sur 26 fichiers. Audit des 37
invariants et intégrité de démarrage réussis. QUALIFICATION.md détaille les full
suites locales et le paquet ; toute la suite reste obligatoire sur le serveur.

Quatre chemins : trois modifications et cette note nouvelle. Les 1 156 cas sont
conservés ; aucun nouveau fixture ou cas numéroté. Aucun schéma de base, SQL de
production, plugin, configuration privée, VERSION, service, Partyline, runner
ou audit n'est modifié. Le paquet ne commit, ne push et ne restart pas.
