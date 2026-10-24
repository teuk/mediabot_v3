# Mediabot 3.6dev — roadmap clôturée

**Statut : cycle de développement terminé le 24 octobre 2026, de MB938 à
MB949.** Dernier lot fonctionnel installé, validé et poussé : MB949,
commit `b010abe`, VERSION `3.6dev-20261024_164906`.

La suite exécutée sur teuk réussit **31 105/31 105 assertions dans 1 166
fichiers**, avec inventaire conforme, sécurité GO/37 et intégrité de démarrage
OK. MB950 consigne cette clôture dans la documentation ; il n'ajoute aucune
fonction et ne revendique aucune nouvelle recette terrain.

La stable publiée reste **3.5**. Cette clôture ne publie pas une stable et ne
fixe aucune date pour 3.7.

## Les cinq axes livrés

| Axe | Résultat livré | Références |
| --- | --- | --- |
| Administration lisible | Diagnostic privé par salon, réglages et observations, cadence, derniers échecs retenus, état des plugins ; publication et vues mbweb avec droits par salon | MB938–MB941 ; [diagnostics](CHANNEL_DIAGNOSTICS.md) |
| Personnalité du salon | Contexte Hailo frais, autorisation tardive, prise en compte des sorties du bot, profils quiet/balanced/animated avec retour contrôlé ; replay fidèle aux neuf seuils configurés | MB942–MB945, MB948–MB949 ; [profils](CONVERSATION_PROFILES.md), [replay](SPARK_OFFLINE_REPLAY.md) |
| Mémoire reliée | Journée explicite et navigation memory/onthisday/yearbook ; recherche privée de citations et factoids du salon | MB946–MB947 ; [parcours mémoire](MEMORY_JOURNEYS.md) |
| Contribution accessible | Générateur de plugin API v3 minimal, désactivé par défaut ; atelier natif de chargement, observation, activation et retrait | MB948 ; [atelier](PLUGIN_WORKSHOP.md) |
| Adoption facilitée | Parcours documenté de l'installation au premier salon, à la découverte, au diagnostic, à la mémoire et à la contribution | MB948 ; [premier salon](FIRST_CHANNEL_3.6DEV.md) |

Les livrables sont présents dans le dépôt installé et les lots ont passé leurs
contrôles sur teuk. Une fonction installée n'implique pas son activation ou son
déploiement dans chaque instance.

## Ce que ce cycle laisse au projet

- L'administration expose des observations bornées et explique les états
  inconnus ; un réglage activé ne devient pas une preuve de livraison.
- Les réponses différées revérifient leur contexte et leurs droits. Les profils
  conservent les portes maîtresses, exclusions, quotas et arming global.
- La mémoire donne des références réutilisables en privé, avec un périmètre
  limité au salon et une distinction entre absence de résultat et panne.
- L'atelier permet de contribuer hors ligne avant toute activation explicite.
- Les procédures existantes sont reliées dans un parcours d'adoption unique.

## Vérifications d'exploitation conservées à part

Trois observations réelles restent non validées : une installation neuve de
développement, la recette mbweb avec comptes autorisé/refusé sur #i/o Epiknet,
et l'observation des profils en situation. Leur état et leurs critères figurent
dans [RELEASE_ACCEPTANCE_3.6DEV.md](RELEASE_ACCEPTANCE_3.6DEV.md).

Elles restent à vérifier avant les décisions de déploiement ou de publication
qui en dépendent. Elles ne sont pas comptées comme réussies et ne prolongent
pas ce cycle de développement. Aucun nouvel outil de recette n'est prévu pour
remplacer ces observations.

## Preuves de livraison

| Lot | Commit poussé | Résultat serveur lorsqu'il est rappelé ici |
| --- | --- | --- |
| MB938 | `05d171b` | diagnostic du salon |
| MB939 | `932e749` | activité et cadence observables |
| MB940 | `7f025e7` | échecs, plugins et projection mbweb |
| MB941 | `18f9fc5` | dépendances mbweb corrigées, déploiement vérifié |
| MB942 | `ea1d467` | fraîcheur du contexte Hailo |
| MB943 | `fc5ed6d` | pression des sorties du bot |
| MB944 | `81755ac` | cadence revérifiée avant livraison Spark |
| MB945 | `7ddc6f7` | autorisation Hailo à la prise en charge |
| MB946 | `f308ddb` | 30 927/30 927 assertions |
| MB947 | `73972f2` | 31 006/31 006 assertions |
| MB948 | `8ec1d43` | 31 065/31 065 assertions |
| MB949 | `b010abe` | 31 105/31 105 assertions |

Ces résultats proviennent des retours d'exécution et de commit fournis par
l'opérateur. Le snapshot `snap_mediabot_v3_teuk_20261024_185553.zip` confirme
VERSION et les dix fichiers du lot MB949. Il ne prouve pas l'état actuel des
processus. Les tests ne constituent pas une certification exhaustive.

## Hors de ce chapitre

Les écritures mbweb RSS/RandomQuote, l'effacement Hailo sélectif avec corpus
autorisé et reconstruction isolée, la promotion MetaAI, les nouveaux déploiements
de plugins et la prochaine stable sont des chantiers distincts. Aucun n'est
engagé par la clôture de cette roadmap.

**Décision : le périmètre MB938–MB949 est livré et fermé.** La suite du projet
se définit dans un autre chapitre, sans ajouter de nouveaux objectifs à celui-ci.
