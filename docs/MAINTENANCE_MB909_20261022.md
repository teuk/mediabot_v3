# MB909 — API v3 : services rattachés à leur inscription

Date : 22 octobre 2026. Base : `snap_mediabot_v3_teuk_20261022_154550.zip`,
VERSION `3.6dev-20261022_134529`.

## Défaut confirmé

Les huit callbacks de services créés par RuntimeV3 capturaient le gestionnaire
et le nom du paquet. Les grants de l'ancien PluginContext restaient en mémoire.
Après unload/reload, ces callbacks pouvaient atteindre l'entrée du successeur,
même si celui-ci ne possédait plus les capacités concernées. Un contexte issu
d'un échec de montage pouvait également atteindre un chargement ultérieur.

## Changement

Une fabrique locale commune crée les passerelles HTTP, snapshot/commit KV,
lecture/écriture de citations, lecture/écriture de factoids et lecture d'activité.
Elle vérifie l'identité de l'inscription avant délégation, avec le garde MB908.
L'inscription est liée après register_plugin et avant le montage/enable.
La référence est faible pour que le contexte seul ne retienne pas une entrée
déchargée ou échouée. Les scopes non liés ou périmés lèvent une erreur constante
et bornée, avant l'appel du service.

Les signatures, arguments et contextes de retour des services ne changent pas.
Un contexte courant désactivé reste soumis aux refus existants ; il fonctionne
de nouveau après enable. Observe conserve les lectures et supprime les mutations.
Les métadonnées des capacités restent un snapshot ; aucune modification de
PluginContext, du manager ou des domaines de données n'est nécessaire.

Le garde porte sur les passerelles créées par RuntimeV3, pas sur tous les appels
Perl possibles d'un plugin de confiance. Les contrôles d'origine/principal,
les services de données et HTTP, les opérations déjà acceptées et leurs règles
de rollback ne sont pas redéfinis. Ce changement n'est pas une sandbox Perl.

## Validation

Treize critères complètent le cas existant 1068, sans nouveau cas numéroté.
Le fixture emploie le vrai chargement de paquet, les vrais PluginContext,
PluginManager, CommandRegistry, InvocationV3 et PrincipalV3. Un témoin temporaire
conserve les invocations ; HTTP, repository et services de domaine sont contrôlés
et ne font qu'enregistrer les appels. Il ne s'agit pas d'un essai SQL ou HTTP réel.

Les huit passerelles sont exercées avant et après remplacement sans grants,
avec une invocation ancienne et une nouvelle. Le nouveau contexte sans grants
reste refusé ; un chargement suivant avec grants fonctionne. Les autres critères
couvrent un échec de montage, disable/enable, observe, le chemin courant et la
libération de l'entrée lorsque seul le contexte est conservé.

Les critères passent 13/13 candidat, 4/13 référence. Les neuf critères corrigés
sont les huit passerelles périmées et le contexte issu d'un montage échoué.
Douze vecteurs nominaux, soit 96 appels de façade, comparent résultats, erreurs,
arguments et traces dans les modes off/observe/on, avec activation et grants
variables. Ils sont identiques, sans warning. Cinq mutations sont détectées.

Le groupe plugins/API v3 passe 2 692 assertions sur 133 fichiers. L'audit réel
des 37 invariants et l'intégrité de démarrage passent. Les résultats des full
suites locales et de la livraison figurent dans QUALIFICATION.md. Le validateur
exige toute la suite sur le serveur, sans exemption.

Six chemins, quatre modifiés et deux nouveaux. Les 1 156 cas sont conservés.
Aucun schéma de base/API, SQL de production, paquet de plugin, configuration
privée, VERSION, service, Partyline, manager, domaine de données, runner ou audit
n'est modifié. Le paquet ne commit, ne push et ne redémarre rien automatiquement.
