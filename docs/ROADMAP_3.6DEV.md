# Mediabot 3.6dev — bilan de livraison et clôture du cycle

Mise à jour : 24 octobre 2026. Base serveur confirmée : MB947, commit 73972f2,
3.6dev-20261024_152222, 31 006/31 006 assertions, sécurité GO/37 et intégrité
OK. MB948 rassemble les livrables de finalisation ; il reste candidat jusqu'aux
contrôles et au commit sur teuk. La stable publiée reste 3.5, sans date de 3.7.

## Cap et règle de fin

Un compagnon de salon utile et discret, une mémoire facile à retrouver et une
administration compréhensible. On termine les parcours annoncés, sans ouvrir
une nouvelle série de micro-refactorisations. MB948 regroupe profils,
contribution et adoption dans une même livraison réversible.

La fin du développement de ce cycle signifie : les cinq directions ont un
parcours documenté, un résultat observable et des contrôles locaux, puis le
lot final passe la suite complète sur teuk. La clôture opérationnelle demande
les quelques vérifications terrain listées plus bas. Une simulation ne valide
ni une installation Debian réelle, ni les droits HTTP de vrais comptes, ni
la pertinence d'une conversation sur #i/o.

## Les cinq directions et leur résultat

| Direction | Livraison | Résultat concret | État |
| --- | --- | --- | --- |
| Administration lisible | MB938–MB941 | `.diagnose #salon`, cadence et erreurs retenues, plugins du salon, publication et vues mbweb avec droits | code installé et mbweb déployé ; recette complète de comptes encore ouverte |
| Personnalité du salon | MB942–MB945 puis MB948 | contexte frais, refus tardif, pression de sortie ; profils quiet/balanced/animated et retour contrôlé | garanties installées ; profils candidats ; mesure d'usage terrain à faire |
| Mémoire reliée | MB946–MB947 | journée explicite, navigation memory/onthisday/yearbook, recherche privée de quotes et factoids | installé, suite serveur validée et poussé |
| Contribution accessible | API v3 existante et MB948 | générateur minimal et atelier natif load/observe/on/off/disable/unload | candidat, aucune activation automatique |
| Adoption facilitée | installation/CI existantes et MB948 | parcours unique installation → premier salon → diagnostic → mémoire → contribution | guide candidat ; installation réelle à enregistrer |

## Livrables de finalisation MB948

### Profils utilisables

La commande existante chanset reçoit `profile show`, quiet, balanced, animated
et restore, réservés aux Master/Owner identifiés. Ils changent seulement
HailoChatter, Spark, SparkAction et, pour animated, un ratio Hailo de base de 3 %.
Hailo maître, réponses explicites, apprentissage, arming global, exclusions,
quotas et vérifications de livraison gardent leurs portes.
L'application est transactionnelle. Restore vérifie l'état attendu et retrouve
les réglages précédents ; une édition concurrente ou une connexion différente
refuse la restauration. Le point de retour est volatil et à un seul niveau.
Voir [CONVERSATION_PROFILES.md](CONVERSATION_PROFILES.md) pour les limites et
les scénarios calme, solo, animé et technique.

### Contribution et retrait prouvés

`perl tools/plugin_v3_workshop.pl --check` génère un paquet dans un répertoire
temporaire et le fait passer par le véritable runtime API v3. Il ne crée aucune
connexion IRC/DB ni activation réelle. `--create` génère un paquet default-off
avec irc.reply seulement, une configuration typée et un exemple de commande.
Les collisions et parents symlinks sont refusés. Le retrait et le refus d'un
ancien callback sont vérifiés. Les paquets acceptés et leur ledger ne sont pas
modifiés. Voir [PLUGIN_WORKSHOP.md](PLUGIN_WORKSHOP.md).

### Parcours d'adoption et démonstration

[FIRST_CHANNEL_3.6DEV.md](FIRST_CHANNEL_3.6DEV.md) relie la procédure Debian du
README aux contrôles existants, au premier Owner, à help/features, au diagnostic,
à une mémoire privée et à l'atelier. Il distingue une base fraîche vide d'une
panne et conserve la séparation développement/production. Le résultat d'une
nouvelle installation réelle doit être enregistré ; aucun run CI distant n'est
revendiqué par le seul changement des fichiers.

## Trois recettes terrain pour clôturer l'exploitation

1. **Installation neuve de développement.** Suivre FIRST_CHANNEL_3.6DEV et
   enregistrer connexion, JOIN, premier Owner, découverte et retrait du plugin.
   La CI Debian 13 est une preuve complémentaire à vérifier sur le commit visé.
2. **Diagnostic mbweb avec droits.** Lors du prochain essai autorisé sur #i/o
   Epiknet, vérifier un accès permis et un accès refusé avec des comptes réels,
   puis publication absente/périmée. Les anciennes recettes de création de User
   et le probe Epiknet non validé restent retirés ; ne pas les relancer.
3. **Rythme en situation.** Observer les profils sur développement avant tout
   choix explicite en production : pertinence, répétitions, chevauchements.
   Le replay Spark garde le vrai préfixe et une configuration autorisée.

Le pilote de diagnostic R3 demeure sur #test. Ce lot ne change ni sa
configuration ni les services. La production Epiknet est nbot.soyou.rocks ;
toute commande Ansible part directement du compte ansible. Ces recettes
n'impliquent aucune nouvelle modification de code tant qu'aucun défaut réel
n'est observé. Ne pas leur substituer une série de nouveaux outils de recette.

## Chantiers ultérieurs, séparés de cette livraison

- Les écritures mbweb RSS/RandomQuote restent un chantier distinct : actions
  nommées exécutées par le bot, droits revérifiés, CSRF et résultat audité.
  Le diagnostic actuel reste en lecture seule ; aucun éditeur SQL arbitraire.
- L'effacement Hailo sélectif forget/forgetword demande un corpus fidèle et
  autorisé, une reconstruction isolée et un retour prouvé. Un cerveau ancien
  sans ce corpus ne reçoit aucune promesse d'effacement sélectif.
- La promotion MetaAI, les nouveaux déploiements de plugins et une publication
  stable sont des décisions séparées. Les postures existantes sont conservées.

## Preuves et discipline

MB938 : 05d171b ; MB939 : 932e749 ; MB940 : 7f025e7 ; MB941 : 18f9fc5.
MB942 : ea1d467 ; MB943 : fc5ed6d ; MB944 : 81755ac ; MB945 : 7ddc6f7.
MB946 : f308ddb, 30 927 assertions sur teuk ; MB947 : 73972f2, 31 006.
Ces résultats ne constituent pas une certification exhaustive.

Le paquet MB948 garde hashes, sauvegarde et retour des fichiers. Il exige
syntaxes, inventaire, atelier, contrôles ciblés et suite complète
`perl t/test_commands.pl --progress`, puis sécurité et intégrité. Les limites
locales restent documentées et ne deviennent pas des exclusions serveur.
Aucun schéma, réglage privé, activation, fréquence ou service n'est changé par
l'installation. Les profils n'agissent qu'après une commande explicite.
