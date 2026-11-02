# MB1074 — Une seule mémoire de jeu pour les variantes de casse du salon

## Défaut et correction

roll, flip et choose utilisaient directement la chaîne de salon comme clé de
leur état en mémoire. Un lancer envoyé à #test puis un history sur #TEST
consultait un autre historique. Les statistiques de flip, le dernier choix et
l'historique de choose pouvaient aussi être séparés en plusieurs compartiments.
Le même défaut existait dans les handlers natifs et dans playful-v3.

Chaque handler dérive maintenant une clé lc(channel) pour les quatre tables
de jeu. Cela suit l'identité par casse des lettres déjà utilisée dans le cache
salon du projet. Ce correctif n'étend pas le casemapping spécial RFC1459.
La variable de cible et les contextes d'appel ne sont pas modifiés : réponses
et audits gardent l'orthographe reçue.

Les tirages, bornes, modificateurs, choix pondérés, déduplication, zéro et Unicode
restent identiques. Les historiques gardent cinq résultats, dans l'ordre réel,
et les autres salons restent séparés. Aucune commande privée n'est ajoutée ;
manifest, capacités, grants, modes d'activation et métadonnées sont inchangés.

Ces états sont transitoires, sans stockage SQL ni fichier. Le restart dev du
modop les reconstruit comme auparavant. Les anciens compartiments avec casse
variable ne sont pas fusionnés lors d'un simple reload en place ; les clés
historiques déjà en minuscules restent compatibles.

## Vérifications natives

Le cas 1381 garde dix assertions. Ses trois groupes de positions de chiffres
Unicode sont regroupés en un, en conservant tous les cas et toutes les données
attendues. Les deux places libérées couvrent les séquences d'historique et de
compteurs avec le vrai registry natif et les vraies invocations/autorités v3.
Pas de nouveau fichier de test, attente ou augmentation du nombre d'assertions.

Pour chaque implémentation : six lancers répartis sur #MiXeD/#mixed/#MIXED,
lecture sous une autre casse, limite de cinq éléments et ordre inverse attendu ;
six choix dont zéro, Unicode et poids, recall de zéro sous une autre casse,
last/history final et isolation d'un autre salon. Pour flip, Heads puis Tails
sur deux casses, statistiques cumulées sur une troisième et compteur séparé
sur un autre salon. Les réponses, audits, arguments, bornes/nombre de tirages,
absence de tirage ou audit sur les lectures et absence de warnings sont vérifiés.

Les deux nouvelles assertions échouent sur le snapshot intact et passent avec
le correctif. Les détails de qualification et la full locale figurent dans
QUALIFICATION.md du paquet.

## Livraison

Empreintes et états exacts avant/après, réapplication, staging qualifié et
conservation des changements précédents en attente. Full visible --progress/ETA
puis sécurité/startup/inventaire et diff --check. Après réussite seulement :
restart mediabot@dev.service seul, PID nouveau stable dix secondes, puis ton
commit.sh installé/interactif. VERSION reste automatique en 3.8dev.
Le PID stable ne prouve pas la reconnexion IRC. Aucun schéma SQL, configuration,
README racine, radio/YouTube ou service de production modifié.
