# MB1084 — Chansets de recherche et DuckDuckGo au format IRC

Source : snap_mediabot_v3_teuk_20261103_131215.zip.
VERSION : 3.8dev-20261103_114432. Les 421 chemins précédemment qualifiés
correspondent exactement à MB1083 final.

## Commandes et activation

Dans le salon concerné, avec les droits chanset habituels :

```text
!chanset +Wikipedia
!chanset +ddg
!wikipedia Marie Curie
!ddg Debian 13 installation
```

Utiliser le préfixe configuré sur l'instance (`#` si les autres commandes
utilisent `#`). Les deux fonctions sont indépendantes et désactivées par
défaut. Wikipedia exige désormais +Wikipedia, y compris après une mise à
jour d'une instance où la commande MB1083 fonctionnait sans chanset. Aucun
salon n'est activé automatiquement.

Les variantes de casse sont normalisées vers Wikipedia et ddg. Les commandes
`!chanset -Wikipedia` et `!chanset -ddg` arrêtent chacune la fonction concernée.
Une désactivation, même suivie d'une réactivation avant la fin d'un worker,
révoque sa réponse. L'activation sur un salon ne s'étend pas aux autres.

L'enregistrement du nom manquant s'effectue dans la branche native autorisée
de chanset, comme pour MixCloud. Il utilise un INSERT paramétré conditionnel
dans CHANSET_LIST, puis la procédure CHANNEL_SET existante. Pas de DDL, de
migration SQL, de modification de table ou de commande administrateur SQL
à exécuter. Une recherche n'enregistre jamais de chanset.

## Langue et affichage

Politique conservée : LangFR, sinon LangES, sinon main.LANG ; anglais si absent
ou invalide. LangFR reste prioritaire si les deux flags sont actifs. Les tags
régionaux sont normalisés à leur base. Pour le français, avec les droits requis :

```text
!chanset +LangFR
```

Ce réglage est commun aux autres fonctions du salon. Wikipédia conserve son
titre, résumé français/espagnol/etc. et lien d'article. Aucun changement à ses
résultats ni à sa sélection d'édition ; une recherche française vide n'est
pas relancée en anglais.

DDG renvoie jusqu'à deux résultats, dans l'ordre du moteur : badge 🦆 DDG en
blanc sur fond bleu marine, numéro, titre en gras, bref extrait et lien en
bleu clair IRC 12 souligné. Le séparateur est gris ; les resets terminent les
styles. Chaque message reste <=400 octets UTF-8, commandes de style comprises.
Les textes distants sont nettoyés et les URLs restent intactes. NoColors et
les politiques habituelles de sortie restent appliquées par botPrivmsg.

Le service shorturl privé déjà configuré est utilisé dans le fils, avec son
cache, circuit et contrat de destination existants. Pas de nouvelle clé ni
de modification de configuration. Ce nouveau service ne sélectionne pas
l'ancien raccourcisseur TinyURL. Si shorturl est absent ou en panne, le lien
original est conservé s'il tient ; un lien trop long produit un message
explicite, jamais un lien coupé ou un autre site présenté comme destination.

## Recherche DDG et disponibilité

Un seul GET HTTPS à html.duckduckgo.com/html/ utilise la requête échappée une
seule fois et le paramètre de région kl (fr-fr, es-es, etc., wt-wt en défaut).
TLS vérifié, redirections HTTP refusées, huit secondes côté client et corps
limité à 256 Kio. Le User-Agent identifie Mediabot et son dépôt.

Le parseur HTML existant dans les dépendances du projet extrait seulement les
liens de résultats et leurs extraits. Les annonces, liens de navigation et
doublons sont ignorés. Les redirections DDG sont décodées localement, avec un
seul paramètre uddg et un hôte DDG exact ; aucun accès aux sites des résultats.
Seules des URLs HTTP(S) sans credentials/contrôles sont conservées. Le parent
revalide également les destinations et les liens courts de sa propre instance.

Une page explicite sans résultat donne un message localisé. Une erreur réseau,
une page de vérification ou un HTML inconnu ne devient pas un faux résultat
vide : le worker propose un lien vers la recherche DuckDuckGo, raccourci si
le service est disponible, et signale que les résultats sont indisponibles.
Pas de contournement de vérification ni de retry automatique sur un autre hôte.

Le test réseau manuel local a reçu une vérification HTTP 202 ; le chemin de
repli a été vérifié. Les résultats organiques et le contrat shorturl sont
testés avec des fixtures, sans prétendre que DDG est disponible depuis chaque
serveur. Documentation primaire :

- https://duckduckgo.com/duckduckgo-help-pages/features/non-javascript
- https://duckduckgo.com/duckduckgo-help-pages/settings/params

## Architecture et limites

SearchCommand partage la validation et le cycle worker entre les deux
providers. Deux recherches simultanées par service et par bot au plus ; pas
de fallback HTTP bloquant dans la boucle IRC. Wikipedia garde 12 secondes,
DDG dispose de 16 secondes incluant jusqu'à deux appels shorturl. Les fils
marquent les handles DB hérités InactiveDestroy ; aucun accès DB de recherche
ni envoi IRC dans le fils.

Le parent effectue une lecture directe du chanset avant lancement et livraison,
sans cache de permission. Les erreurs prepare/execute/fetch/err ou les lignes
invalides ferment la fonction ; les statements acquis sont terminés. Connexion,
génération de salon, arrêt du bot et epoch de politique révoquent les retours
obsolètes. Réservations et callbacks restent à usage unique, y compris après
échec de démarrage ou d'envoi. Les workers restent visibles et annulables sous
wikipedia lookup et ddg search avec les outils internes existants.

Un nouveau cas comporte huit assertions groupées : vrai chanset autorisé et
SQL sans DDL, indépendance/default-off et lectures défaillantes, révocation,
parsing/liens, pages vides/contrôles, HTTP et shorturl réels sur transport simulé,
thème/budget/destination et véritable fork/pipe du handler DDG. Les dix groupes
Wikipedia sont conservés ; une fixture active explicitement sa politique.
Quatre anciens cas ajustent les compteurs à 245 commandes publiques, 344 entrées
et 252 entrées d'aide ; les 234 commandes migrables restent inchangées.

Full --progress/ETA, sécurité/startup, inventaire et whitespace avant staging,
restart du dev seul et commit.sh interactif. VERSION 3.8dev automatique ; aucun
contrôle WorkingDirectory. Un PID stable ne prouve pas la reconnexion IRC.
README racine, commit.sh privé, radio, YouTube et correctifs précédents conservés.
QUALIFICATION.md du paquet donne les résultats et limites locaux exacts.
