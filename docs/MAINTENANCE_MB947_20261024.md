# MB947 — Relier les références enregistrées du salon

## Bénéfice

`!memory find <texte>` retrouve les citations et les factoids sans devoir
connaître leur identifiant ou leur clé. Les résultats privés donnent une
commande de rappel, la date d'enregistrement, l'auteur et un court extrait.
Ce prolongement du parcours MB946 relie les références enregistrées ; il
n'effectue aucune recherche dans les conversations brutes.

## Mise en œuvre

Le nouveau module Memory::Search concentre les SELECT et leur projection.
Le handler memory existant conserve sa route CommandAsync ; les réponses
sont des intents NOTICE directs, sans timer de worker ou appel aux commandes
qui publient un rappel. Les journées ciblées et le tirage aléatoire gardent
leur parcours. L'aide native et son inventaire généré incluent find.

Chaque mot est lié à un placeholder SQL avec échappement littéral des jokers
LIKE. Le texte est limité à six mots / 160 octets UTF-8, avec deux caractères
minimum. Les deux collections sont liées à l'identité du salon courant.
Le handle courant du wrapper DB est préféré ; une reconnexion échouée ne
réutilise pas un ancien handle. Les SELECT retournent au plus quatre lignes
et tronquent les champs d'extrait à 512 caractères avant transfert.
Trois résultats au plus sont présentés par collection ; le quatrième sert
uniquement à proposer d'affiner la recherche. Ces limites ne garantissent
pas un coût SQL constant pour les recherches contenant un mot.

+OnThisDay ouvre find ; Factoids conserve sa propre porte. Une erreur de
politique bloque la lecture concernée. Chaque collection distingue absence,
échec et exclusion, sans exposer les erreurs SQL. Les clés proposées sont
validées, et les extraits/attributions sont nettoyés et bornés en UTF-8.
Une recherche ne change ni hits ni données. Les destinations et droits de
`!q view` et `!factoid` s'appliquent lorsqu'ils sont invoqués explicitement.

## Qualification et livraison

Le test 1321 utilise Context et le handler natifs, avec seulement les
frontières DB/NOTICE capturées. Ses 76 assertions couvrent les deux collections,
salon courant, paramètres littéraux, attribution anonyme, préfixe réel, bornes,
Unicode, révocation de portes, PM, reconnexion, panne partielle et fetch en
échec. Sur MB946 intact, 44 attentes de cette fonctionnalité échouent ; elles
passent après MB947. Trois mutations valides sont détectées : retirer
l'échappement %, contourner -Factoids, transformer une panne en tableau vide.
La qualification complète et ses limites sont détaillées dans QUALIFICATION.md.

Base fournie : snap_mediabot_v3_teuk_20261024_170406.zip, 1 852 entrées,
SHA-256 27d2e2f94dd66421b141113a186e60c31247c20e863bd8d871a5d4a13a1d9e22.
VERSION : 3.6dev-20261024_150306 ; MB946 poussé dans f308ddb et validé sur teuk
avec 30 927 assertions, sécurité GO/37 et intégrité de démarrage OK.
Les dix chemins sont protégés par hashes avant/après et sauvegardés ; un
contrôle en échec restaure les fichiers de la tentative. Aucun schéma, réglage
privé, service ou fréquence n'est modifié. Aucun déploiement de production,
Ansible ou redémarrage n'est lancé par ce paquet.
