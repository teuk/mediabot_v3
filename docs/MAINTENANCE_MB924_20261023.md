# MB924 — Citations par auteur : un second tirage qui exclut la précédente

Date : 2026-10-23. Base : snap_mediabot_v3_teuk_20261023_122635.zip.

## Défaut reproduit

Dans mbQuoteByNick, lorsque le premier tirage retrouvait la citation précédente,
le code essayait jusqu'à quatre tirages supplémentaires sur le même ensemble.
S'ils retombaient tous sur la position initiale, la boucle se terminait sans
nouvelle lecture et la citation précédente était tout de même affichée.

La sonde native reproduit ce cas avec deux citations aux ids 10 et 21 : les
cinq tirages (initial + quatre essais) à zéro renvoient encore l'id 10.
Après correction, le second tirage sélectionne l'id 21. Le chemin public
!quote <nick> appelle ce handler, également disponible via l'alias Mediabot.

## Correction limitée au choix du second offset

Si la précédente revient et que count > 1, le second rang est tiré dans
[0, count-2]. Les rangs à partir de la position exclue sont décalés de un.
Chaque autre position possède ainsi exactement un rang correspondant : une
alternative est choisie en un seul tirage, sans boucle de rejet.

Les requêtes SQL, leur texte et l'ordre des binds restent exactement les mêmes.
Seule la valeur du second offset et le nombre de tirages changent dans ce cas.
Les recherches par préfixe puis correspondance partielle, échappements de !/%/_,
clé du cache canal/auteur, sortie, extrait UTF-8 et retours sont conservés.
Avec une seule citation, la répétition reste autorisée, sans second SELECT.
Les ids peuvent être non consécutifs : le choix porte toujours sur un offset
dans le résultat ordonné existant, pas sur un calcul d'identifiant persistant.

La garantie d'alternative suppose un ensemble stable et un second SELECT
réussi. Si cette lecture échoue ou n'a plus de ligne après une modification
concurrente, le repli historique sur la première ligne est conservé. Aucune
transaction, répétition SQL, nouvelle requête ou verrou n'est introduit.

Aucun schéma, migration, configuration privée, VERSION, autre fonction de
production ou module partagé ne change. q random, RandomQuote et les services
v3 de citations gardent leurs algorithmes actuels.

## Vérification native et régression

Le cas 255 existant conserve ses six critères et reçoit quatre assertions
regroupées. Un enfant Perl appelle la vraie fonction et son alias public,
avec le vrai Mediabot::Context, sur DBI/SQLite privé. Les fractions du générateur
aléatoire sont contrôlées uniquement dans l'enfant ; aucune modification du
générateur de production. Les résultats SQL ne sont pas simulés.

Les 56 cas de rangs parcourent toutes les alternatives pour chaque position
exclue avec 2, 3 et 5 citations, via les deux entrées. Ils contrôlent l'id choisi,
les offsets réellement bindés, le nombre borné de requêtes, la sortie exacte,
les caractères accentués, le cache et toutes les lignes. Chaque autre id est
atteint une fois. Les citations d'un autre canal et d'un autre auteur restent.
Les extrêmes zéro et presque un couvrent aussi le bord supérieur du tirage.

Vingt appels nominaux ont des traces JSON strictement identiques avant/après :
premier appel, premier tirage déjà différent, une seule citation, id précédent
supprimé, préfixe, correspondance partielle, pseudos avec !/%/_, absence de résultat.
Six scénarios de repli conservent résultats, sorties, cache, SQL/binds, finish
et lignes observées, hors nouvelle borne du tirage : préparation refusée,
exécution refusée et alternative supprimée entre les lectures, via deux entrées.
Les refus proviennent d'erreurs SQLite réelles réservées à la sonde.

Le cas étendu donne 8/10 sur la source et 10/10 sur le candidat. Huit mutations
sont détectées par les nouveaux critères, les six anciens restant valides.
Aucun nouveau cas ou fixture partagé : les 1 156 fichiers restent. Les suites
complètes et limites locales sont détaillées dans QUALIFICATION.md du paquet.
