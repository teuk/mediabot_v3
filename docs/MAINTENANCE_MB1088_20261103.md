# MB1088 — Trois cibles DDG compactes, aucun lien de recherche fabriqué

Source : snap_mediabot_v3_teuk_20261103_180827.zip.
Les 429 chemins qualifiés précédents correspondent exactement à MB1087 final.
VERSION source 3.8dev-20261103_164851 conservée ; commit.sh gère le timestamp.

## Ce qui est corrigé, et ce qui reste bloqué

Ce paquet corrige la présentation et les destinations. Il ne garantit pas
les trois premiers résultats web quand DuckDuckGo bloque sa page de recherche.
Le choix précédent DuckDuckGo exclusivement est conservé en l'absence d'un
nouveau choix de fournisseur. Aucun secours Tavily n'est activé ni ajouté.

Une sonde manuelle pour linux a renvoyé HTTP 202 avec une page de vérification,
zéro résultat HTML, et un résumé dans l'API instantanée. Cette API n'est pas
une API de résultats web : sa réponse contient ici un lien de site officiel
et trois liens de catégories internes DDG, pas les trois premiers résultats.
Ces liens ne sont donc pas convertis en faux résultats classés. Documentation
primaire : source officielle DuckDuckGo de sa page API :
https://github.com/duckduckgo/duckduckgo-publisher/blob/master/share/site/duckduckgo/api.tx

Obtenir les trois vraies cibles malgré un blocage DDG nécessitera un service
de recherche distinct, choisi explicitement. Les tests de classement utilisent
des pages HTML réalistes locales ; aucune réussite live de recherche web à
trois résultats n'est revendiquée ici.

## Affichage compact sur une vraie réponse web

Forme d'affichage, sans inventer de résultats recherchés :

```text
[🦆 DDG] Aperçu : premier titre — court extrait du premier résultat…
[🦆 DDG] 1. titre · lien-court-cible | 2. titre · lien-court-cible | 3. titre · lien-court-cible
```

L'aperçu utilise le premier résultat et son extrait, sans GET supplémentaire.
Son attribution est donnée par la première cible située sur la ligne suivante.
Les titres classés sont bornés à 48 octets UTF-8 et l'extrait à 160 octets ;
le budget réel de chaque ligne est toujours recalculé, styles compris.
Le premier résultat n'est plus répété avec un long extrait dans sa carte.
Titres en gras, badge existant et liens bleu clair soulignés restent présents.

Les trois premières cibles organiques uniques sont conservées dans l'ordre
DDG, avec leurs rangs. Ni le quatrième résultat, ni annonce, navigation,
doublon ou URL invalide. S'il n'y a qu'un ou deux résultats valides, seuls
ceux-ci sont affichés. Une liste plus courte n'est jamais complétée artificiellement.

Les cartes sont regroupées dans une ligne quand elles tiennent en 400 octets.
Si le raccourcisseur échoue et les URLs originales sont longues, une carte
entière passe à la ligne suivante : aucune URL n'est coupée et la troisième
cible n'est pas supprimée pour réduire le nombre de lignes. Cela peut donner
une ligne d'aperçu et trois lignes de résultats. Le parent accepte donc au
maximum quatre lignes uniquement pour DDG ; Wikipedia conserve son plafond
de deux. Une URL qui dépasse à elle seule le budget reçoit le diagnostic
existant de raccourcisseur indisponible, sans lien tronqué.

## Plus de lien vers la requête elle-même

Le constructeur de lien https://duckduckgo.com/?q=mots-clés est supprimé,
ainsi que son état search_link et son appel de raccourcissement. Le renderer
n'accepte plus cet ancien état. Les destinations de résultat et de résumé
refusent aussi les requêtes q et routes HTML/Lite/catégories/redirections
internes DDG. Le contrôle est répété dans le parent avant tout affichage.
Les véritables redirections DDG uddg sont toujours décodées une seule fois
vers leur cible externe validée.

Si le HTML est indisponible mais l'API fournit un résumé, une seule ligne
« Aperçu seul : sujet — résumé · lien-court-source » est affichée. Ce lien
ouvre bien la source du résumé, pas la recherche par mots-clés. Si aucun
résumé n'est exploitable, le message localisé d'indisponibilité est conservé.
Un aperçu seul reste une réponse dégradée, pas la résolution de la demande
« systématiquement trois premiers résultats ».

## Contrats préservés

Langue/région du salon, signalement d'une édition Wikipedia étrangère,
chanset et droits, révocation après désactivation/réactivation, contexte de
livraison, annulation et libération unique des réservations restent inchangés.
Tous les GET et POST privés restent dans le fils ; aucune I/O réseau bloquante
dans la boucle IRC. HTML 256 Kio/8 s, JSON 128 Kio/8 s, sortie 32 Kio et worker
24 s ; deux jobs DDG simultanés maximum. Aucun nouveau réseau de recherche,
clé, dépendance, configuration, schéma, données ou modification manuelle de VERSION.

Cinq chemins changent : DDG, plafond DDG du parent partagé, cas existant 1439,
changelog et cette note. Les autres sources, Wikipedia, client shorturl,
registre/aide/inventaire, README racine, commit.sh privé, runner/ETA, radio,
YouTube et changements précédents sont conservés.

## Vérification et exploitation

Les huit assertions groupées et le seul vrai fork/pipe du cas 1439 restent.
Vérification des trois destinations exactes raccourcies, d'un seul POST pour
le résumé dégradé, de l'absence totale de POST pour une requête de recherche,
des deux lignes compactes et de la troisième cible, des URLs longues entières
sur quatre lignes, des budgets UTF-8/styles, des cibles étrangères/refusées,
des JSON invalides et des traductions. Les scénarios droits/chanset/révocation
et les trois premiers résultats uniques restent exécutés. Le vrai worker
transmet toujours un payload >16 Kio et les trois POST simulés, puis le parent
envoie deux lignes contenant aperçu et trois cibles. Aucun nouveau processus
ni nouveau fichier de test. QUALIFICATION.md détaille les résultats et limites.

Full visible --progress/ETA, audits sécurité/startup, inventaire et whitespace
avant staging/restart/commit. Après réussite complète : dev seul, PID nouveau
et stable dix secondes, commit.sh interactif --skip-preflight, VERSION 3.8dev
automatique. Aucun contrôle WorkingDirectory. Un PID stable ne prouve pas la
reconnexion IRC. Aucun chanset à réactiver, aucune modification de production.
