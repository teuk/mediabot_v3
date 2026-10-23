# MB938 — Première étape de la roadmap actualisée

Base : snap_mediabot_v3_teuk_20261023_231334(1).zip,
VERSION 3.6dev-20261023_211143, après MB937 validé sur le serveur.

## Résultat

La roadmap est actualisée autour de cinq objectifs : administration lisible,
personnalité de salon, mémoire communautaire reliée, contribution par plugins
et adoption. Le premier lot est un diagnostic privé `.diagnose #salon`, avec un
modèle structuré réutilisable par de futurs consommateurs autorisés.

Deux modules nouveaux séparent collecte et adaptateur partyline. Le collecteur
lit CHANNEL, CHANSET_LIST et CHANNEL_SET avec deux SELECT paramétrés, puis le
transport IRC et le snapshot ConversationRuntimeState existant. Il distingue
on/off/missing/unknown, conserve les erreurs comme inconnues et finit les handles.
Une erreur du propriétaire de connexion ne provoque pas de repli sur un ancien
handle. Aucun cache, worker, timer, transaction ou état de fonction n'est changé.

La commande exige une session authentifiée Master/Owner avant toute lecture.
Elle valide le canal, décode strictement UTF-8, borne le nom à 200 octets, réserve
le rapport à la connexion demandeuse et encode sa sortie une seule fois. Le
dispatch ne diffuse pas la requête aux autres sessions. L'historique privé et
l'anti-flood existants restent en place ; `.help diagnose` découvre la commande.

## Limites explicites

On/off désignent les lignes persistées, pas une disponibilité fournisseur ou une
sortie confirmée. Missing ne remplace pas les défauts spécialisés. La présence
d'un Channel configuré ne prouve pas un JOIN. Les observations SQL et runtime
sont prises pendant la demande, sans promesse de snapshot atomique entre systèmes.
Le rapport ne lit pas les dernières erreurs, quotas, conversations, versions
chargées, cadences RSS ou état d'ordonnancement RandomQuote. Ces observations
sont prévues pour des lots ultérieurs. Aucune route HTTP ou permission mbweb
n'est ajoutée, aucune activation de module ou migration n'est effectuée.

Les relations AppleMusicFallback/AppleMusic et les portes indépendantes Reddit,
Youtube et UrlTitle sont descriptives : le diagnostic ne décide pas à la place
des fonctions existantes. Voir docs/CHANNEL_DIAGNOSTICS.md pour le contrat.

## Validation

Le cas 07 existant lance sept groupes natifs dans un interpréteur enfant :
DBI/SQLite sans traduction SQL, erreurs partielles avec RaiseError à 0 et à 1,
authorizer refusant les écritures, transaction appelante conservée, vraies
transitions de runtime, droits et transports natifs Telnet/DCC sur socketpair.
La sortie Unicode est lue sur les sockets, avec une autre session vérifiant
l'absence de diffusion. Le catalogue reste à 1 158 cas ; huit assertions sont
ajoutées au cas 07 et six contrôles de structure existants suivent automatiquement
les deux modules nouveaux, soit quatorze assertions au total. La qualification du paquet consigne
les mutations, suites complètes et vérifications d'installation/restauration.

La procédure serveur conserve les compilations, le groupe ciblé, la suite
complète sans filtre, l'audit sécurité et l'intégrité de démarrage. Un échec de
validation restaure les seuls fichiers écrits. Source appliquée, processus
chargé et production déployée restent des états distincts.
