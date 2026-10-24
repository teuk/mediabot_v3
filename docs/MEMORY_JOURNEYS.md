# Parcours de mémoire du salon

MB946 ajoute un point de départ reproductible dans les fonctions historiques
existantes. Aucun nouveau chanset ou schéma de base.

```irc
!memory
!memory 2024-02-29
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
onthisday répondent en privé. Ce lot ne recherche pas les textes des citations
ou des factoids et ne transforme pas une ligne d'historique en citation stockée.

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
