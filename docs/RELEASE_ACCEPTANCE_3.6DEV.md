# Mediabot 3.6dev — vérifications avant déploiement ou publication

État au 24 octobre 2026, après MB949 / `b010abe`.
Le [cycle de développement MB938–MB949 est clôturé](ROADMAP_3.6DEV.md).
Cette checklist conserve les preuves terrain manquantes ; elle ne les transforme
pas en validations acquises et n'engage aucune opération sur les instances.

## État des trois vérifications

| Vérification | Preuve déjà disponible | Preuve manquante | Statut |
| --- | --- | --- | --- |
| Installation neuve de développement | Guide premier salon, outils et CI Debian 13 du dépôt | Exécution réelle sur le commit choisi : connexion, JOIN, premier Owner, découverte, diagnostic, mémoire privée ou absence explicite, retrait du plugin de démonstration | À réaliser avant de qualifier ce parcours d'installation |
| Diagnostic mbweb en situation | Tests de droits et de projection ; mbweb déployé et vérifié ; refus anonyme HTTP 401 ; pilote R3 sur #test avec deux publications successives | Comptes réels autorisé et refusé sur #i/o Epiknet, puis comportement face à une publication absente ou périmée | À réaliser avant de déclarer cette recette de production réussie |
| Profils conversationnels en situation | Tests natifs Hailo/Spark/profils et replay configuré MB949 | Observation réelle de pertinence, répétitions et chevauchements sur développement ; décision explicite avant tout changement de profil en production | À réaliser avant de qualifier les profils pour le salon visé |

Le succès de la suite sur teuk ne remplace pas ces observations. Aucun résultat
de CI distante supplémentaire n'est revendiqué.

## Références utilisables

- Installation : [FIRST_CHANNEL_3.6DEV.md](FIRST_CHANNEL_3.6DEV.md).
- Droits et publication : [CHANNEL_DIAGNOSTICS.md](CHANNEL_DIAGNOSTICS.md).
- Profils : [CONVERSATION_PROFILES.md](CONVERSATION_PROFILES.md).
- Simulation hors ligne : [SPARK_OFFLINE_REPLAY.md](SPARK_OFFLINE_REPLAY.md).
- Contribution et retrait : [PLUGIN_WORKSHOP.md](PLUGIN_WORKSHOP.md).

Le pilote R3 reste limité à #test. Le prochain essai de production demandé
concerne #i/o sur Epiknet, instance nbot.soyou.rocks. Les anciennes recettes de
création de User et le probe Epiknet non validé restent retirés. Ne pas les
relancer. Toute commande Ansible doit partir du compte ansible.

## Consigner un résultat réel

Pour chaque vérification, noter le commit et VERSION, l'instance et le salon,
la date, les actions réellement réalisées, le résultat attendu et observé,
puis la remise en état éventuelle. Ne pas conserver de mot de passe, cookie,
jeton de session ou contenu privé dans cette preuve.

Un cas non exécuté reste « non exécuté ». Une panne ou un refus inattendu reste
un échec à expliquer. Un défaut reproductible peut justifier un correctif
distinct ; il ne rouvre pas automatiquement le périmètre de la roadmap close.

Une promotion stable demande une décision de publication et les contrôles de
livraison applicables au commit choisi. La stable reste 3.5.
