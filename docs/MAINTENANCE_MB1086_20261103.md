# MB1086 — Trois résultats DDG, de l'extraction à l'envoi IRC

Source : snap_mediabot_v3_teuk_20261103_142515.zip.
Les 427 chemins précédemment qualifiés correspondent exactement à MB1085 final.
VERSION source conservée ; le timestamp de commit reste géré par commit.sh.

## Comportement demandé

Avec +ddg dans le salon, la commande conserve sa syntaxe et affiche jusqu'à
trois résultats organiques distincts, dans l'ordre renvoyé par DuckDuckGo :

```text
!ddg la roi lion
[🦆 DDG] 1. titre — extrait · lien-court
[🦆 DDG] 2. titre — extrait · lien-court
[🦆 DDG] 3. titre — extrait · lien-court
```

Il s'agit d'un exemple de forme, pas de résultats recherchés ou inventés.
Les titres restent en gras et les URLs en bleu clair souligné. Chaque ligne
respecte 400 octets UTF-8, styles compris, avec une URL entière. Le quatrième
résultat, les doublons, publicités, liens de navigation et URLs invalides sont
exclus. Si DuckDuckGo fournit moins de trois résultats valides, seuls ceux-ci
sont affichés ; le bot ne complète pas artificiellement la liste.

Le choix confirmé est DuckDuckGo exclusivement. Une page de vérification ou
une réponse non exploitable conserve le lien de recherche unique de MB1085 :

```text
[🦆 DDG] Recherche : la roi lion · lien-court
```

Ce lien ouvre la recherche dans le navigateur ; ce n'est pas un résultat
organique. Augmenter le plafond ne rend pas une réponse bloquée lisible.
Aucun autre moteur ni appel Tavily, nouvelle clé, nouveau coût de recherche,
contournement ou changement automatique d'hôte n'est ajouté.

## Correction des trois plafonds

Trois limites indépendantes empêchaient un troisième résultat : extraction
HTML, validation de la liste dans le renderer et validation des messages par
le parent asynchrone. Les deux premières partagent maintenant MAX_RESULTS=3.
SearchCommand accepte trois lignes uniquement pour ddg ; Wikipedia garde son
plafond antérieur de deux lignes. La boucle continue de vérifier la politique
et le contexte avant chacun des envois, y compris le troisième.

Le worker DDG passe de 16 à 32 Kio de sortie structurée maximale pour couvrir
trois titres, extraits et paires d'URLs bornés. Le corps HTML reste limité à
256 Kio, le GET à huit secondes et le worker à 16 secondes. Deux recherches
DDG simultanées maximum, et un raccourcissement privé par résultat, dans le
fils. Les trois réponses IRC restent dans le parent.

Langue et région du salon, +ddg/+Wikipedia, droits, désactivation/réactivation,
transport et génération de salon, arrêt du bot, callbacks uniques, erreurs,
contrat shorturl et repli MB1085 sont conservés. Pas de changement de schéma,
de données, de configuration, de registre/aide/inventaire ou de VERSION.

## Vérification

Le cas natif 1439 reste à huit assertions groupées. Sa fixture contient des
annonces, de la navigation, un doublon, une URL invalide et quatre résultats
valides : exactement les trois premiers sont extraits. Les groupes suivants
vérifient les trois destinations shorturl, les trois rangs et budgets, le
refus d'une quatrième ligne, et le repli unique dans les trois langues.

Le vrai handler DDG, son parser, son renderer et SearchCommand passent par
un vrai fork/pipe : un GET et trois requêtes shorturl simulés dans le fils,
trois réponses IRC observées dans le parent. Ses trois résultats Unicode
produisent un payload JSON vérifié supérieur à 16 Kio, pour couvrir aussi
le nouveau budget du worker. Aucun nouveau cas ni assertion,
aucun service externe dans la suite. QUALIFICATION.md donne la contre-épreuve
et les résultats locaux exacts.

Un diagnostic HTTP distinct a interrogé l'interface officielle Lite avec
« la roi lion » : réponse 202 contenant une page de vérification, aucun résultat
exploitable. Cela confirme la limite de disponibilité dans cet environnement ;
aucune recherche live réussie n'est revendiquée. La disponibilité depuis les
instances réelles reste à observer. DuckDuckGo documente ses deux interfaces
sans JavaScript : https://duckduckgo.com/duckduckgo-help-pages/features/non-javascript.

## Exploitation

Cinq chemins changent : DDG, SearchCommand, cas existant 1439, changelog et
cette note. Wikipedia, Helpers, client shorturl, README racine, commit.sh privé,
runner/ETA, radio, YouTube et correctifs précédents restent conservés.

Full visible --progress/ETA, audits sécurité/startup, inventaire et whitespace
avant staging/restart/commit. Après réussite complète : dev seul, PID nouveau
et stable dix secondes, commit.sh interactif --skip-preflight, VERSION 3.8dev
automatique. Aucun contrôle WorkingDirectory. Un PID stable ne prouve pas la
reconnexion IRC. Aucun chanset à réactiver.
