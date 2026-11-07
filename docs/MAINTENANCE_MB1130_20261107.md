# MB1130 — API de statut radio résistante aux erreurs

Une référence CODE ou une structure circulaire dans le résultat du fournisseur
faisait sortir une exception JSON de la route HTTP. Une exception objet pouvait
être ignorée si elle était fausse en contexte booléen, ou provoquer une seconde
exception par surcharge de conversion.

Le résultat de chaque eval est désormais contrôlé par un témoin de réussite.
L'encodage JSON est protégé comme l'appel fournisseur. Les exceptions objets ne
sont ni converties en chaîne ni évaluées comme booléens. Les détails des erreurs
scalaires restent dans le journal local ; le client reçoit un message stable.
Le contrat HTTP existant (200 avec ok=0 en cas d'erreur métier) reste inchangé.

Les tests couvrent erreurs scalaires, objets faux et hostiles, référence CODE,
cycle, réponse invalide, reprise Unicode et disponibilité de /metrics. Ils
utilisent aussi le véritable serveur HTTP sur un port local éphémère.

Aucun changement de schéma, de playRadio(), de YouTube ou de Grafana.
Le correctif nécessite un prochain redémarrage habituel du bot pour être chargé.
Il ne résout pas les compteurs d'activité absents sur les autres instances.
