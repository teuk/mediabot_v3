# Parcours de mémoire du salon

MB946 ajoute un point de départ reproductible dans les fonctions historiques
existantes. Aucun nouveau chanset ou schéma de base.

```irc
!memory
!memory 2024-02-29
!memory find café
```

Sans argument, memory conserve son choix borné d'une ancienne journée.
Avec YYYY-MM-DD, il consulte uniquement cette date du salon courant. La date
doit exister dans le calendrier grégorien : 2024-02-29 et 2000-02-29 sont
valides, 2023-02-29 et 1900-02-29 ne le sont pas. Les 30 derniers jours,
le jour courant et les dates futures ne produisent aucun souvenir.
La limite d'âge vient du calendrier de la base, comme le parcours aléatoire.

La réponse arrive en NOTICE à la personne qui a lancé la commande : résumé,
éventuel extrait d'une ligne déjà conservée, puis une navigation compacte.
L'extrait peut varier ; la journée demandée ne change pas. Une journée vide
n'est jamais remplacée silencieusement par une autre.

```text
Explore: !memory 2024-02-29 | !onthisday 02-29 | !yearbook 2024
```

Les renvois emploient le préfixe de l'instance. Ils proposent des commandes ;
ils ne les exécutent pas. onthisday compare le même jour dans les années passées.
yearbook situe le souvenir dans l'activité annuelle et compte les citations
et factoids créés cette année. Son renvoi n'est proposé que pour une année
prise en charge par la commande actuelle (depuis 2000 jusqu'à l'année courante).
yearbook répond publiquement, selon son comportement existant ; memory et
onthisday répondent en privé. Le parcours de journée ne transforme pas une
ligne d'historique en citation stockée.

## Retrouver une référence enregistrée

MB947 ajoute `!memory find <texte>`. La recherche porte sur les textes des
citations, et sur les clés et valeurs des factoids du salon courant. Chaque
mot doit être présent ; pour un factoid, un mot peut être dans sa clé et un
autre dans sa valeur. La casse et les accents suivent la collation de la base.
Les caractères `%`, `_` et `!` sont recherchés littéralement, sans joker.
Le texte contient au moins deux caractères, au plus six mots et 160 octets UTF-8.

```text
!q view 42 | 2024-02-29 | by Alice | Le café du salon
!factoid cafe | 2026-10-24 | by Pablo | Notre référence café
```

Les résultats arrivent uniquement en NOTICE au demandeur. Chaque collection
montre au plus trois références ; un résultat supplémentaire produit une
invitation à préciser la recherche, sans total prétendument exhaustif.
La priorité va aux ajouts les plus récents, séparément pour chaque collection.
La date affichée est celle de l'enregistrement, et l'auteur suit l'attribution
existante ; une citation anonyme reste `Unknown`. Les extraits sont courts et
sans codes de mise en forme. Les commandes proposées utilisent le vrai préfixe.

`+OnThisDay` ouvre ce parcours, comme les journées memory. `-Factoids` retire
la collection factoid de la recherche ; une politique illisible ne l'autorise
pas. Les citations suivent l'accès de lecture du salon de `!q`. Aucun autre
salon ne peut être passé en argument et une invocation privée ne choisit pas
de salon de repli. Les références enregistrées récentes sont consultables :
la limite des 30 jours concerne les souvenirs de conversations, pas ces tables.

La recherche n'exécute aucune commande de rappel et ne change pas les compteurs
de consultation. Cliquer/copier un renvoi reste un choix explicite : `!q view`
répond publiquement et compte un rappel selon son comportement actuel ;
`!factoid` répond en privé. Leurs droits sont évalués lors de leur invocation.
Un enregistrement supprimé entre recherche et rappel peut ne plus exister.

Deux SELECT au maximum lisent QUOTES et, si autorisé, FACTOID. Chaque SELECT
retourne au plus quatre lignes et des extraits SQL limités à 512 caractères.
Cela borne les résultats transférés, pas le travail du serveur SQL pour un
LIKE contenant ; l'exécution conserve le worker et les délais CommandAsync de
memory. Une collection en panne est indiquée comme indisponible, tandis que
l'autre peut répondre. Aucun historique CHANNEL_LOG, archive de conversation,
profil utilisateur ou données d'un autre salon n'est interrogé par find.

## Périmètre et limites

- Salon courant uniquement, avec son identité interne ; aucun choix d'un autre
  salon en argument, aucun repli vers des données globales.
- Porte +OnThisDay conservée, ainsi que l'exécution CommandAsync et la livraison
  privée. Aucune publication automatique ou nouvelle fréquence.
- Lecture via channel_log_gather en périmètre content : seuls les historiques
  encore conservés et les archives autorisées par la politique existante sont
  disponibles. Une période purgée ne peut pas être reconstruite.
- La journée ciblée utilise des plages de dates paramétrées, sans tri aléatoire
  de l'ensemble des lignes. Au plus quatre lectures logiques sont nécessaires
  pour résumé, voix la plus active et extrait avec son éventuel repli.
- Un échec de lecture courant renvoie « history lookup unavailable », sans
  annoncer à tort une journée vide. Une sélection vide reste explicite.
- Les comptages et le choix représentatif suivent le moteur mémoire existant ;
  ils décrivent l'historique disponible, pas une restitution exhaustive du salon.

Les contrôles de rétention, droits et validité de livraison des commandes
proposées continuent de s'appliquer au moment où elles sont invoquées.
