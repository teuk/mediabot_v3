# MB1085 — Un lien de recherche DDG utilisable, clairement présenté

Base : snap_mediabot_v3_teuk_20261103_131215.zip complété par MB1084 livré.
Les 426 chemins précédemment qualifiés correspondent exactement à MB1084 final.
VERSION source conservée : 3.8dev-20261103_114432 ; commit.sh gère automatiquement
la prochaine version 3.8dev.

## Défaut signalé

Une réponse HTML DDG non exploitable produisait un lien vers la recherche.
Le service shorturl raccourcissait correctement ce lien. Le rendu présentait
pourtant ce lien comme le premier résultat :

```text
[🦆 DDG] 1. DuckDuckGo — ddg : résultats temporairement indisponibles. · lien-court
```

Le message mélangeait deux états : les résultats n'avaient pas pu être lus
automatiquement, mais la recherche restait accessible dans le navigateur.
Un lien de recherche était ainsi affiché comme un résultat en panne.

## Correction

Le worker renvoie désormais un état search_link explicite, avec les mots-clés
et une seule URL de recherche. Le parent utilise un libellé localisé et retire
le classement et l'extrait de panne. Exemple de forme :

```text
[🦆 DDG] Recherche : la vitesse de la lumière · lien-court
```

Le libellé devient Search: en anglais et Búsqueda: en espagnol. Le texte de la
requête est nettoyé et abrégé dans le même budget que les titres existants.
Le lien garde sa couleur bleu clair, son soulignement et ses resets ; les
styles compris, une ligne reste limitée à 400 octets UTF-8. L'URL n'est jamais
coupée. Le parent refuse plusieurs entrées pour un seul lien de recherche.

Le paramètre de région kl est partagé entre la requête HTML et le lien destiné
au navigateur : fr-fr, es-es, etc., wt-wt par défaut. Les accents sont échappés
une seule fois. Le service shorturl conserve son contrat de destination et
son comportement de repli vers l'URL originale ; aucune nouvelle configuration.

Les véritables résultats restent classés et accompagnés de leurs extraits.
Une page explicitement vide conserve le message aucun résultat. Un worker
en échec, sans lien construit, conserve le message d'indisponibilité.
Les vérifications DDG et pannes réseau ne sont pas contournées et ne deviennent
pas des résultats prétendument récupérés. Ce correctif traite leur présentation.

## Tests

Le cas natif 1439 conserve huit assertions groupées et son vrai fork/pipe.
Le groupe HTTP/shortener vérifie l'état search_link, les mots-clés d'origine
et la destination complète contenant la région. Le groupe de rendu ajoute
les trois langues et vérifie l'absence de faux rang et d'extrait d'erreur,
en conservant ses contrôles de style, taille et destination.

Les deux groupes de régression échouent avec le module MB1084 intact (6/8)
et passent avec MB1085 (8/8). Les tests existants des flags, droits, révocation,
lectures de politique, parsing, résultats organiques, protocole shorturl et
retour dans le parent restent exécutés. Aucun nouveau cas, attente ou réseau
externe dans les tests. QUALIFICATION.md donne les résultats locaux exacts.

## Périmètre et exploitation

Quatre chemins changent : provider DDG, cas existant 1439, changelog et cette
note. Wikipedia, SearchCommand, chansets, registre/aide/inventaire, client
shorturl, schéma, configuration, données persistantes, VERSION, README racine,
commit.sh privé, runner/ETA, radio, YouTube et correctifs précédents conservés.

Le paquet vérifie les états exacts avant/après et les changements qualifiés
en attente. Full visible --progress/ETA, audits sécurité/startup, inventaire
et whitespace avant staging/restart. Après réussite complète seulement :
dev seul, nouveau PID stable dix secondes, puis commit.sh natif interactif
--skip-preflight avec VERSION 3.8dev automatique. Aucun contrôle WorkingDirectory.
Un PID stable ne prouve pas la reconnexion IRC. Les chansets déjà stockés
restent utilisés ; aucune activation ou commande SQL supplémentaire nécessaire.
