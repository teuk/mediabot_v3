# De l'installation au premier salon 3.6dev

Ce parcours rassemble les outils existants. Il ne déploie pas une instance
supplémentaire et ne remplace pas la procédure Debian 13 du README.
La stable reste 3.5 ; un développement utilise une identité IRC, un répertoire,
une configuration, une base et une unité systemd distincts de la production.

1. Préparer Debian et le compte dédié avec le README, section « Quick
   installation on Debian 13 ». Les paquets système demandent l'administrateur ;
   le bot et la suite s'exécutent ensuite comme mediabot.
2. Choisir la branche de développement, puis lancer `./configure` pour une
   installation fraîche. Ne jamais recopier le sample sur une configuration
   active. Le wizard installe les dépendances et prépare la base fraîche ;
   cette étape crée des données uniquement sur l'installation choisie.
3. Garder mediabot.conf privé (0600). Contrôler schéma, compilation, inventaire,
   suite et intégrité avant le premier démarrage.

```bash
(
  set -Eeuo pipefail
  test "$(id -un)" = mediabot
  perl tools/check_schema_drift.pl --conf=mediabot.conf --strict --types --indexes
  perl -I. -c mediabot.pl
  perl tools/mb_architecture_inventory.pl --check docs/generated/COMMAND_INVENTORY.md
  perl tools/plugin_v3_workshop.pl --check
  perl t/test_commands.pl --progress
  perl tools/security_audit.pl --quiet
  perl tools/startup_integrity_check.pl --quiet
)
```

Ne pas contourner un contrôle en échec. La CI Debian 13 du dépôt reproduit une
installation fraîche en conteneur ; son dernier résultat doit être vérifié sur
le commit visé. Le présent lot ne revendique aucun nouveau run CI distant ou
installation Debian réelle.

4. Suivre le premier démarrage au premier plan du README et son enregistrement
   privé du premier Owner. Vérifier identité et droits avant toute activation.
   L'enregistrement du premier Owner ne se refait pas sur une instance existante.
5. Sur le salon de développement déjà configuré, vérifier la découverte :

```irc
!version
!uptime
!help
!features
```

Puis, comme Master/Owner : `!chanset #test profile show`. La commande ne change
aucun réglage. Consulter docs/CONVERSATION_PROFILES.md avant de sélectionner
un profil. Dans la partyline Master/Owner, `.diagnose #test` explique les portes
persistées et observations disponibles. Une porte on ne prouve pas une livraison.

6. Démonstration sobre, uniquement si les fonctions sont activées et si le salon
   dispose de références autorisées :

```irc
!memory
!memory find café
!factoids
```

memory/find et factoids répondent en privé. Aucun résultat sur une base fraîche
est normal. Ne pas importer d'historique privé pour fabriquer la démonstration.
Une date rendue par memory peut être reprise avec `!memory YYYY-MM-DD`, puis
onthisday et yearbook selon leurs droits et destinations documentés.

7. Pour contribuer, exécuter l'atelier docs/PLUGIN_WORKSHOP.md. Le chargement,
   observe, on et le retrait sont des choix explicites, uniquement sur le
   développement pour ce premier essai.

**Critère de fin terrain :** connexion et JOIN confirmés, Owner reconnu,
découverte fonctionnelle, diagnostic lisible, commande mémoire privée ou absence
explicite, puis retrait du plugin de démonstration sans commande résiduelle.
Conserver le résultat réel de ce parcours ; les tests hors ligne ne le remplacent
pas. Le passage à #i/o en production et une publication stable restent des
opérations séparées. Toute commande Ansible part du compte ansible.
