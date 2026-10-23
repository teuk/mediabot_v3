# Mediabot 3.6dev — roadmap actualisée

Date : 24 octobre 2026. Base confirmée : MB939, commit `932e749`,
`3.6dev-20261023_221453`. Cette feuille de route traduit les orientations
retenues avec Christophe ; elle ne programme aucune mise à jour de production.
La version stable publiée reste 3.5. Aucune date de publication 3.7 n'est fixée.

## Le cap

Faire de Mediabot un compagnon de salon utile, discret, doté d'une mémoire
communautaire facile à retrouver et dont l'opérateur comprend les décisions.
Les améliorations techniques servent désormais des objectifs d'usage précis.

Les rounds MB877 à MB937 ont notamment renforcé les modules IRC partagés,
les budgets de texte, les sorties différées, les timers, les reconnexions,
l'Unicode, les transactions, la partyline et le cycle de vie des plugins.
Apple Music et Reddit ont également reçu de nouvelles fonctions visibles.
MB939 est validé sur le serveur : 30 707 assertions, sécurité GO/37 et intégrité
de démarrage OK. Cette validation ne constitue pas une certification exhaustive.

## Les cinq directions

| Priorité | Direction | Bénéfice recherché | Premier résultat observable |
| --- | --- | --- | --- |
| 1 | Administration lisible | Comprendre la configuration et l'état réellement observé de chaque salon | Un diagnostic privé explique les réglages, observations et inconnues sans modifier le bot |
| 2 | Personnalité du salon | Accorder Hailo, Spark et les conversations IA au rythme du salon | Des scénarios montrent des interventions mieux choisies, avec moins de chevauchements |
| 3 | Mémoire communautaire reliée | Retrouver les références et souvenirs déjà conservés | Des parcours relient citations, factoids, mémoire et portraits du salon |
| 4 | Plugins accessibles | Faciliter une contribution indépendante et maintenable | Un exemple complet accompagne création, validation, activation et retrait d'une extension |
| 5 | Adoption facilitée | Rendre installation, découverte et exploitation plus simples | Un parcours vérifié mène une nouvelle installation à son premier salon fonctionnel |

## Étape 1 — Comprendre un salon

**MB938 : installé, validé sur le serveur et poussé dans `05d171b`.**

Ajouter `.diagnose #salon` dans la partyline, réservée aux sessions Master/Owner.
Un module commun retourne un rapport structuré, indépendant de sa présentation,
qui pourra ensuite alimenter mbweb.

Ce premier lot distingue :

- les chansets persistés, relus au moment de la demande : on, off, absent du
  catalogue ou inconnu après une erreur ;
- la connexion IRC et le JOIN connus du runtime ; un objet Channel en mémoire
  ne suffit pas à prouver un JOIN ;
- quelques relations utiles entre previews : AppleMusicFallback dépend de
  l'entrée AppleMusic ; Reddit et Youtube ont leurs propres portes d'activation ;
- les limites : un réglage on ne prouve ni l'accès à un fournisseur distant,
  ni l'absence de quota, ni une sortie effectivement livrée.

Le diagnostic ne recharge aucun cache, ne lance aucun fetch et n'active aucune
fonction. Les commandes existantes `!features`, `.stat` et `.plugins why` gardent
leur comportement. Les erreurs brutes, secrets et historiques de conversation
ne font pas partie du rapport.

**Critères de réussite :** lecture seule démontrée ; droits contrôlés avant SQL ;
sortie privée et bornée ; erreurs présentées comme inconnues ; distinction
configuration/runtime testée ; configuration et schéma inchangés.

## Étape 2 — Enrichir puis présenter le diagnostic

Étendre progressivement le rapport avec les observations des composants
existants : cadence RSS, état RandomQuote, tâches attendues et présentes,
fraîcheur des observations, motifs d'échec bornés et état des plugins.
Chaque indicateur doit avoir une source identifiable et une valeur inconnue.

**MB939 : installé, validé sur le serveur et poussé dans `932e749`.**
Le même `.diagnose` observe les politiques RSS et RandomQuote via les objets
du runtime, sans créer, réparer ou réécrire leurs fichiers d'état. Il distingue
un fichier absent, occupé, invalide ou illisible, montre la date du fichier et
sépare un intervalle par défaut d'une tentative réellement planifiée.
Les tâches d'instance `rss_poll_dispatch` et `randomquote_dispatch` indiquent
présence, démarrage, nombre de ticks et prochaines échéances observées.
Les réservations RSS, tickets RandomQuote et ticks ne prouvent aucune livraison.

**MB940 : deuxième enrichissement et présentation web préparés dans le code,
à installer et valider sur le serveur.** Le diagnostic ajoute les erreurs RSS
encore retenues, les exceptions des deux callbacks de scheduler et les
politiques, capacités manquantes, quarantaines et échecs API v3 du seul salon.
La lecture ne crée pas de registre ; la rétention et les limites restent visibles.
Les plugins v1/v2, les erreurs non enregistrées et les versions chargées restent
inconnus lorsqu'aucune source fiable ne les observe.

Présenter ensuite ces informations dans mbweb avec les droits par salon déjà
en place. Distinguer configuration souhaitée, source sur disque et runtime
chargé. Un état non observé ne doit jamais apparaître comme confirmé.
Le source mbweb de MB940 propose des vues HTML/JSON de diagnostic par salon,
avec identité et droits relus avant tout accès à la publication. Il ne montre
pas l'inventaire global des plugins ni les tâches d'instance. Une publication
locale du bot est facultative, bornée à huit salons explicitement choisis et
désactivée par défaut. Les observations trop anciennes, invalides ou d'identité
différente ne sont pas affichées comme courantes.

**Prochain point de validation :** installation et chargement du code, puis
qualification d'un pilote web sur développement avec la procédure canonique,
droits de deux comptes distincts, accès refusé à un autre salon et observation
absente/périmée. Ce paquet ne déploie pas `/opt/mbweb/app`, ne modifie aucune
configuration privée et n'active aucune publication. La convergence entre
source sur disque et code chargé reste à observer dans un lot ultérieur.

Les écritures web viendront dans un lot séparé : actions nommées exécutées par
le bot, droits revérifiés, protection CSRF, résultat explicite et audit.
Commencer par les réglages RSS et RandomQuote. Conserver la séparation entre
lecture et mutation ; aucun éditeur SQL ou exécuteur de commandes arbitraires.

## Étape 3 — Accorder les interventions

Construire des scénarios de salon calme, solo, animé et technique. Observer
comment Hailo, Spark et l'IA sollicitée se répartissent les occasions de réponse.
Réutiliser exclusions, budgets et mécanismes de temporisation existants.
Définir des profils compréhensibles, avec retour simple au comportement courant.

Mesurer la pertinence, les répétitions, les chevauchements et le rythme, puis
faire une observation sur développement avant toute activation en production.
Les replays Spark emploient le véritable préfixe et la configuration visée.
Le pilote collectif MetaAI garde son activation explicite et ses contrôles de
langue, quotas, mémoire, annulation de génération, redémarrage et `/forget`.

La maintenance sélective Hailo reste un chantier spécifique : `forget` et
`forgetword` exigent un corpus fidèle et autorisé, une reconstruction isolée,
une bascule contrôlée et une restauration prouvée. La répétition synthétique
MB805 reste un outil de qualification ; un ancien cerveau sans corpus fidèle
ne reçoit pas de promesse d'effacement sélectif.

## Étape 4 — Relier la mémoire existante

Partir des fonctions déjà présentes : quotes, factoids, recap, memory,
onthisday, awards, yearbook et chronologie. Définir quelques parcours utiles,
avec des renvois clairs entre résultats et commandes plutôt qu'une multiplication
de syntaxes indépendantes. Respecter visibilité du salon, attribution, limites
et possibilités d'effacement déjà définies. Toute annonce automatique demande
un choix explicite du salon et une cadence maîtrisée.

## Étape 5 — Faciliter contribution et adoption

Préparer un petit nombre d'exemples de plugins aboutis : capacités minimales,
permissions expliquées, tests de cycle de vie, gestion des erreurs et retrait
sans ressources résiduelles. Préserver les cinq packages API v3 acceptés,
leurs politiques, capacités, données et ledger de démarrage lors des mises à jour.

Vérifier ensuite le parcours d'installation Debian, la documentation, l'aide
et une démonstration sobre. Une future version stable fera l'objet d'une décision
séparée, avec les contrôles de préservation MB784/MB786 et une répétition de
restauration. Une modification de source ne déploie pas mbweb et ne redémarre
aucune instance IRC.

## Discipline commune à tous les lots

- Garder le schéma actuel de la base ; réutiliser les interfaces existantes.
- Livrer des périmètres courts avec un bénéfice observable et une restauration.
- Choisir des tests de comportement et de frontières ; remplacer les doublons
  et les contrôles de structure devenus peu utiles ; conserver les protections
  importantes plutôt qu'un objectif de nombre d'assertions.
- Exécuter les contrôles ciblés et la suite complète
  `perl t/test_commands.pl --progress`, puis sécurité et intégrité de démarrage.
  Documenter les limites locales ; ne pas les transformer en dérogations serveur.
- Mesurer les coûts et les lenteurs avant optimisation. Poursuivre les
  refactorisations lorsqu'elles débloquent ces objectifs ou corrigent un défaut
  démontré, en conservant les comportements spécialisés nécessaires.

Références dans le dépôt : `docs/CHANNEL_DIAGNOSTICS.md`, `docs/META_AI.md`,
`docs/HAILO_BRAIN_MAINTENANCE.md`, `docs/PLUGIN_API_V3.md`,
`docs/PLUGIN_V3_UPDATE_ACCEPTANCE.md`, `contrib/mbweb/README.md`.
