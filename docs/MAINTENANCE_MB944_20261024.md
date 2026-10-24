# MB944 — Spark revérifie la cadence avant publication

## Défaut observé

MB943 rend les propres sorties du bot visibles à Spark. L'admission d'une
génération utilisait cette observation, mais sa livraison relisait uniquement
les droits, bras, état IRC, génération et autres portes existantes. Une réponse
Hailo, IA ou ordinaire pouvait ainsi arriver pendant le calcul, puis être
immédiatement suivie de la réponse spontanée Spark devenue superflue.

La façade Spark demandait aussi un botPrivmsg ordinaire : sous antiflood,
l'accusé de mise en file pouvait être pris pour une livraison contextuelle.

## Correction

Orchestrator expose une lecture des deux pressions de livraison, avec les
fenêtres et politiques adaptatives déjà utilisées à l'admission. Cette lecture
ne choisit aucun événement, ne modifie aucun probe et ne crée aucun observateur.
Le runtime refuse avant la création de l'événement si la pause est active ;
Sender relit aussi cette porte au dernier état courant. Une lecture en erreur
refuse la sortie spontanée. Le motif journalisé reste un code, sans texte IA.

La façade de transport Spark emploie l'option no_defer existante. Un refus
antiflood reste un refus, sans sortie différée ni faux événement livré.
Les lots !vdm/!dtc sont contrôlés avant leur première ligne, pas entre chaque
ligne en réaction à leur propre pression.

La continuation unique Portal/Mosaic appartient à une interaction déjà ouverte :
elle ne reçoit pas cette nouvelle porte de cadence. Ses contrôles de droits,
génération, état IRC, jeu, Wit, antiflood, cadence et bras restent applicables.
Les réponses aux commandes explicites et le runtime Hailo ne changent pas.
Ce correctif n'annule pas le calcul fournisseur et ne crée pas d'arbitre global.

## Qualification

Le test 1318 utilise les vrais DryRun, Observer, State, Orchestrator et Sender,
ainsi que les fonctions extraites du vrai mediabot.pl et la façade Helpers.
Seuls fournisseur, horloge, lecture des flags et transport sont capturés.
Sur MB943 intact, 14 assertions sur 48 reproduisent les lacunes ; après
correction, 48/48 passent. Les cas vérifient les deux familles, autre salon,
privé, limites exactes et pause configurée, observation en erreur, conclusion
promise, lot VDM, antiflood et libération des états en attente.
Les résultats complets et limites locales figurent dans QUALIFICATION.md.

## Livraison

Base serveur : fc5ed6d, VERSION 3.6dev-20261024_110350. MB943 est validé sur
teuk : 30 771 assertions, sécurité GO/37 et intégrité de démarrage OK.
Le paquet applique des hashes avant/après, conserve une sauvegarde et exige
les contrôles ciblés, la suite complète sans exclusion, sécurité et intégrité.
Un contrôle en échec restaure les fichiers de la tentative. Aucun schéma,
réglage privé ou service n'est modifié. Le chargement intervient au prochain
redémarrage normal ; ce paquet ne déploie aucune instance de production.
