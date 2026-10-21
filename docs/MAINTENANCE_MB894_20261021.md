# MB894 — Compteurs X/Twitter indépendants

## Défaut reproduit

Le gestionnaire vérifiait qu'au moins un compteur était un entier positif.
Une fois dans le bloc, les deux compteurs scalaires étaient comparés
numériquement sans refaire cette vérification pour chacun. Si likes valait
`"999oops"` et retweets valait 3, le code émettait un avertissement numérique
et composait `(0 likes, 3 RTs)`. L'inverse pouvait produire `0 RTs`. Un texte
sans préfixe numérique pouvait aussi déclencher un avertissement.

Le message ainsi composé était ensuite mémorisé dans le cache, puis réémis.
La correction concerne donc la composition initiale et les relectures des
entrées créées après correction. Les messages déjà présents en mémoire ne
sont pas purgés par ce changement ; ils gardent leur échéance habituelle.

## Correction et périmètre

Chaque compteur passe maintenant séparément l'expression d'éligibilité déjà
présente : défini, correspondant à `^\d+$`, puis strictement positif. Seul un
compteur admissible atteint le formateur historique. La liste des compteurs
est composée une fois et ajoutée uniquement lorsqu'elle contient un élément.
Aucune nouvelle règle de plage numérique ou de syntaxe n'est introduite.

Le formateur `_x_compact_count` et son hook URL sont conservés, de même que les
champs optionnels, le décodeur JSON, le texte/titre, les couleurs, limites,
retours, récupération FxTwitter/Chromium et cache de 600 secondes. Les cinq
autres corps de fonctions du module sont identiques. Aucun autre module
applicatif, SQL, schéma, migration, configuration privée, VERSION, runner,
audit ou service ne change.

## Vérification

Le cas de chemin rapide existant ajoute six assertions : trois réponses avec
un compteur mal formé et un autre valide, chacune vérifiée sur la livraison
et sa relecture du cache, avec absence d'avertissement pour ces entrées.
Avant correction, cinq de ces six assertions échouent, tandis que les 23
assertions précédentes restent vertes. Après correction, le cas passe à 29
assertions réussies. Aucun nouveau cas numéroté ni nouveau module de fixture.

Le groupe ciblé garde aussi les contrats X/Twitter, les caches, anciens hooks,
replis, rendu et autres fournisseurs. Des probes externes comparent les vrais
modules de référence/candidat avec réponses locales ; les différences
attendues sont séparées des scénarios conservés. Voir `QUALIFICATION.md` dans
le paquet pour les résultats et limites.

La base est reconstruite depuis le dernier snapshot et le payload MB893
validé sur le serveur, faute de nouveau snapshot depuis cette validation.
Le runtime local présente déjà l'échec MB786 du répétiteur de mise à jour.
L'installateur exige zéro échec dans la suite complète serveur, puis les
audits sécurité et démarrage.
