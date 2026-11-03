# MB1087 — De vrais aperçus DDG pour les recherches de sujets

Source : snap_mediabot_v3_teuk_20261103_142515.zip + MB1086 livré.
Les 428 chemins précédemment qualifiés correspondent exactement à MB1086 final.
VERSION 3.8dev-20261103_132244 conservée ; commit.sh gère le prochain timestamp.

## Comportement

La recherche HTML de DuckDuckGo retourne parfois une page de vérification,
une erreur ou du balisage inexploitable. MB1085/MB1086 affichaient alors
seulement « Recherche : mots-clés · lien ». Cette réponse n'avait aucun aperçu.

DDG possède aussi une interface officielle de réponses instantanées :
https://api.duckduckgo.com/. MB1087 l'interroge uniquement lorsque les résultats
HTML sont indisponibles. Il exige Heading, AbstractText et AbstractURL : un
vrai titre, un résumé non vide et une source HTTP(S) valide. Le titre et le
résumé proviennent de la réponse du service, sans génération de texte.

Forme des deux lignes, et non exemple de résultats inventés :

```text
[🦆 DDG] Aperçu : titre — résumé du sujet… · lien-court-source
[🦆 DDG] Recherche : mots-clés · lien-court-recherche
```

Le lien de l'aperçu ouvre sa source. La seconde ligne conserve la recherche
complète sur DDG. Les titres sont en gras, les liens en bleu clair souligné,
chaque ligne reste sous 400 octets UTF-8, styles compris, et les URLs sont
entières. Les deux raccourcissements suivent le service privé existant et
son contrôle de destination. Sans raccourcisseur, les URLs originales restent
utilisées dans la limite d'affichage existante.

Le paramètre kl et Accept-Language suivent la langue du salon. Si une source
Wikipedia appartient à une autre édition, l'étiquette affiche sa langue,
par exemple « Aperçu (EN) ». Cela ne prétend pas traduire un résumé anglais.

Les trois résultats organiques de MB1086 restent inchangés quand la recherche
HTML fonctionne. Une réponse instantanée n'est pas une API de recherche web :
elle fournit ici un aperçu de sujet, jamais trois résultats inventés. Les
champs Redirect, Answer/Abstract HTML et RelatedTopics ne sont pas utilisés.
Une vraie page « aucun résultat » reste « aucun résultat ». Si l'interface
instantanée ne fournit aucun résumé exploitable ou échoue, le lien de recherche
reste disponible. Certaines requêtes n'auront donc pas d'aperçu.

## Implémentation bornée

Le worker effectue le GET HTML (8 s, 256 Kio), puis au besoin le GET JSON
(8 s, 128 Kio), et les raccourcissements privés (2 s par lien). Son plafond
passe de 16 à 24 secondes ; sa sortie reste limitée à 32 Kio. Aucune opération
réseau bloquante dans la boucle IRC. Deux recherches simultanées maximum,
vérification du chanset/contexte avant chaque réponse, annulation et callbacks
uniques restent gérés par SearchCommand sans modification de ce module.

TLS vérifié, hôtes de requête fixes, aucun suivi automatique de redirection.
Une réponse 2xx est acceptée seulement si le JSON et les trois champs requis
sont valides : l'API a réellement renvoyé des résumés sous HTTP 202, tandis
qu'une page HTML de vérification sous le même statut reste inexploitable.
Le décodeur partagé Mediabot::JSON traite correctement les octets UTF-8 et
les chaînes déjà décodées. Entrées, corps, champs et URLs restent bornés.
Le parent rejette aussi un aperçu sans extrait ou sans lien de recherche.

Aucun nouveau moteur, clé, configuration, coût contractuel, schéma ou chanset.
Le choix DuckDuckGo uniquement est conservé. Aucun appel Tavily.

## Vérification

Le cas natif 1439 conserve huit assertions groupées et un seul vrai fork/pipe.
Deux groupes couvrent désormais : réponse JSON 202, résumé français, région,
TLS/délais/tailles, destinations shorturl source/recherche, JSON invalide,
corps surdimensionné, champs de mauvais type, URL non HTTP, redirection seule,
statut d'échec, rendu explicite sans rang et marqueur d'édition étrangère.
Ils échouent contre le code MB1086 intact, puis passent avec la correction.

Les autres groupes vérifient les droits, le chanset et sa révocation,
l'extraction de trois résultats organiques uniques, l'exclusion d'un quatrième,
les budgets/styles et la livraison réelle de trois lignes par fork/pipe avec
les trois raccourcissements simulés dans le fils. Les tests Wikipedia,
shorturl et contexte de livraison sont également exécutés.

Des requêtes manuelles séparées ont confirmé des titres, résumés français et
sources fr.wikipedia.org pour « eggdrop » et « samsung galaxy » dans l'API DDG.
La disponibilité et les délais du réseau restent variables ; QUALIFICATION.md
précise les observations de bout en bout et les résultats locaux exacts.
Aucune requête réseau réelle dans les tests automatisés.

## Exploitation

Quatre chemins changent : DDG, cas existant 1439, changelog et cette note.
Les autres sources, client shorturl, Wikipedia, SearchCommand, registre/aide/
inventaire, README racine, commit.sh privé, runner/ETA, radio, YouTube,
configuration, données et VERSION restent inchangés.

Full visible --progress/ETA, audits sécurité/startup, inventaire et whitespace
avant staging/restart/commit. Après réussite complète : dev seul, PID nouveau
et stable dix secondes, commit.sh interactif --skip-preflight, VERSION 3.8dev
automatique. Aucun contrôle WorkingDirectory. Un PID stable ne prouve pas la
reconnexion IRC. Aucun chanset à réactiver.
