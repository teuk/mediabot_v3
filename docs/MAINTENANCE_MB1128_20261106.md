# MB1128 — Réponses Wiktionnaire sur IRC

`!define café` pouvait interroger le bon article et répondre avec un mot
mal encodé. Le mot venu d’IRC restait en octets UTF-8 tandis que la définition
JSON était déjà en caractères. Les arguments sont maintenant décodés
séparément avant assemblage. La limite de 64 octets s’applique au texte
normalisé et une séquence UTF-8 invalide reçoit une notice privée.

Le sélecteur nettoie chaque définition avant de la juger utilisable.
Une entrée comme `<span>&nbsp;</span>` ne masque donc ni la définition
suivante ni le repli vers une autre langue. Les accents issus d’entités
HTML restent encodables en UTF-8 sur IRC.

La recherche reste asynchrone et conserve `main.DEFINE_LANG`, l’ordre de
repli, l’échappement de l’URL et le routage public ou privé. Aucun changement
de configuration, de schéma ou de dépendance.

Les tests utilisent le vrai worker et une réponse HTTP simulée. Ils
vérifient les URL, les réponses IRC, le repli et le rejet des entrées invalides.
