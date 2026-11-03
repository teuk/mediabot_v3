# MB1083 — Wikipédia dans la langue du salon

Source : snap_mediabot_v3_teuk_20261103_113944.zip, complété par le correctif
MB1082 livré. VERSION conservée : 3.8dev-20261103_103839. Les 412 chemins
précédemment qualifiés correspondent à MB1082 final.

## Utilisation

Dans un salon, avec le préfixe de commandes configuré sur l'instance :

```text
!wikipedia Marie Curie
!wikipedia informatique quantique
```

Le bot répond publiquement sur le salon : badge, titre, bref résumé et lien
vers l'article. Exemple de forme, avec un résumé raccourci ici :

```text
[📚 Wikipédia/fr] Marie Curie — Marie Curie (…) est une physicienne et chimiste (…) · https://fr.wikipedia.org/?curid=4493780
```

La commande est une commande publique native, visible dans l'aide et
l'inventaire. Elle n'ajoute pas de commande privée ni de nouveau chanset.
Le préfixe `!` des exemples reste celui de l'instance : si le salon utilise
`#` pour ses autres commandes, utiliser `#wikipedia Marie Curie`.

## Langue

Réutilisation de `Helpers::channel_lang`, sans deuxième configuration :

1. `+LangFR` sur le salon : édition française et messages français ;
2. sinon `+LangES` : édition espagnole et messages espagnols ;
3. sinon `main.LANG` ; anglais si absent ou invalide.

Si LangFR et LangES sont tous deux actifs, LangFR garde la priorité historique.
Pour configurer le salon en français avec les droits habituels :

```text
!chanset +LangFR
!wikipedia Marie Curie
```

Ce chanset règle déjà la langue commune du salon et peut donc concerner ses
autres fonctions. Le correctif ne l'active pas automatiquement. Il ignore
`tmdb_lang`, qui appartient aux recherches de films. Les tags régionaux
comme fr-FR, es_ES et pt-BR sont ramenés à fr, es et pt. Les autres codes
simples de deux ou trois lettres sont utilisés comme édition Wikipédia ;
les messages d'erreur hors français/espagnol restent en anglais.

Une recherche sans résultat dans l'édition choisie reste un résultat vide
localisé. Elle ne relance pas une recherche anglaise. Une édition inexistante,
une erreur API ou une panne réseau produit une indisponibilité, sans exception
brute ni fausse affirmation qu'aucun article n'existe.

## Implémentation

`Mediabot::External::Wikipedia` possède la validation, le transport, le
formatage et le handler Context. Le registre natif appelle le handler et
l'aide décrit la commande ; aucun dispatch parallèle ni fallback legacy.

Un seul appel HTTPS à l'Action API de l'édition choisie combine le générateur
de recherche et TextExtracts : namespace encyclopédique, un résultat, introduction
en texte brut, extrait demandé de 600 caractères. Aucun HTML à parser, aucune
clé API ni nouvelle dépendance. Le User-Agent identifie Mediabot et son dépôt.
Documentation primaire :

- https://www.mediawiki.org/wiki/API:Search
- https://www.mediawiki.org/wiki/Extension:TextExtracts

Le client HTTP existant vérifie TLS, refuse les redirections HTTP, limite le
corps à 128 Kio et attend huit secondes au maximum par opération réseau.
Le worker impose en plus sa limite globale de 12 secondes. L'API peut résoudre
un titre redirigé à l'intérieur de la requête ; ce n'est pas une redirection
HTTP. Le lien publié est construit avec l'édition validée et le pageid positif,
jamais avec une URL fournie par le serveur.

La recherche accepte 32 arguments au plus, 160 caractères et 320 octets UTF-8.
Les contrôles et UTF-8 invalide sont refusés. Les accents sont encodés une
seule fois. La sortie nettoie les contrôles IRC, préserve le lien entier et
respecte 400 octets UTF-8, titre et marque d'abréviation compris. Un article
sans extrait conserve son titre et son lien.

Deux recherches simultanées au plus par bot, tous salons confondus. Un refus
de syntaxe, un argument invalide, l'absence de boucle ou la capacité pleine
donne une réponse privée sans worker supplémentaire. Les résultats et erreurs
de recherche reviennent publiquement. Un démarrage refusé/exceptionnel ou une
annulation libère la réservation une seule fois. Les erreurs d'envoi restent
contenues. La connexion et, si disponible, la génération du salon sont capturées
avant lancement ; un résultat devenu obsolète n'est pas envoyé.

Le worker existant reste observable et annulable via les outils internes sous
le libellé `wikipedia lookup`. Le fils effectue la requête et renvoie seulement
le texte ; les réponses IRC restent exclusivement dans le parent. Aucune requête
HTTP synchrone de secours dans la boucle IRC, pas de cache ni de persistance.

## Vérifications

Un nouveau cas natif de dix assertions groupées couvre les langues, le fallback,
les accents/limites, la requête HTTPS, le format/budget, les résultats vides,
les échecs réseau/API, le handler du véritable registre et le Context, la
capacité partagée, l'ordre de retour et les callbacks dupliqués, les échecs
de lancement/envoi, les résultats obsolètes et l'annulation. Un vrai fork/pipe
avec transport HTTP simulé confirme le retour dans le parent et la réactivité
de la boucle sans TCP. Aucun service distant dans la suite de tests.

Quatre cas existants actualisent les compteurs : 243 à 244 commandes publiques,
342 à 343 entrées public/private et 250 à 251 entrées d'aide. Les 234 commandes
migrables existantes ne changent pas. Inventaire régénéré. Les résultats locaux complets
et limites de l'environnement figurent dans QUALIFICATION.md du paquet.

## Exploitation

Onze chemins changent : module Wikipédia, deux sources de câblage, quatre cas
de catalogue existants, nouveau cas Wikipédia, inventaire, changelog et cette
note. Schéma, données, configuration, VERSION, README projet, commit.sh privé,
runner/ETA, radio, YouTube et correctifs précédents sont conservés.

Le paquet contrôle les contenus avant/après, applique de façon idempotente et
préserve les changements qualifiés en attente. Full visible --progress/ETA,
audits sécurité/startup, inventaire et whitespace avant staging/restart.
Après réussite complète : dev seul, nouveau PID stable dix secondes, puis
commit.sh natif interactif --skip-preflight, VERSION 3.8dev automatique.
Un PID stable ne prouve pas la reconnexion IRC. Aucun déploiement production.
