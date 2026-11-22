# Du premier plugin à son retrait

Cet atelier ajoute un paquet minimal et le fait passer par le véritable
PluginManager API v3. Il ne modifie aucun des paquets déjà installés ni leur
ledger. Le générateur ne charge rien dans un bot.

## Vérifier sans serveur IRC ou base

Depuis le dépôt, comme mediabot :

```bash
(
  set -Eeuo pipefail
  test "$(id -un)" = mediabot
  perl tools/plugin_v3_workshop.pl --check
)
```

Le contrôle génère un paquet dans un répertoire temporaire, le charge désactivé,
l'active sans salon, puis vérifie observe/on/off, l'isolation d'un autre salon,
stop, le démontage du registre et le refus d'un ancien callback après unload.
Les réponses sont capturées ; aucune connexion IRC, DB ou service n'est créée.
Ce résultat qualifie la mécanique locale, pas une activation en production.

## Créer son paquet

Sur le dépôt de développement, choisir un nom et une commande libres :

```bash
(
  set -Eeuo pipefail
  test "$(id -un)" = mediabot
  perl tools/plugin_v3_workshop.pl \
    --create welcome-v3 --command welcome_channel --directory plugins
)
```

Le répertoire doit être existant. Le générateur valide le manifeste avec les mêmes
règles que le chargeur avant de créer le paquet. Le nom de commande ordinaire peut
faire jusqu’à 24 caractères. Utiliser `--command` si le nom dérivé du paquet
dépasse cette limite. Les parents symlinks et les destinations existantes sont
refusés. Le générateur écrit plugin.json, README.md et
lib/Greeting.pm. La seule capacité est irc.reply ; la configuration typée
`greeting` limite le texte à 160 caractères. Aucun timer, événement, HTTP,
stockage ou SQL n'est demandé. Remplacer le texte métier dans cette petite
surface, puis ajouter un test de comportement avant d'étendre les capacités.

## Valider le paquet après modification

Depuis le dépôt, avec les dépendances habituelles de Mediabot, indique le nom du
paquet et son répertoire parent.

```bash
perl tools/plugin_v3_workshop.pl --validate welcome-v3 \
  --directory plugins --grant irc.reply
```

Le chargeur API v3 vérifie le manifeste, instancie le paquet, vérifie les méthodes
déclarées et essaie de monter les commandes et alias dans le registre natif. Une
collision avec une commande intégrée ou une méthode manquante rend le contrôle
en échec. Le paquet reste désactivé et le contrôle le décharge à la fin. Le rapport
indique les ressources montées parmi celles déclarées. Pour tester le montage des
abonnements et des tâches, ajoute respectivement `--grant events.subscribe` et
`--grant scheduler.jobs` si le manifeste les demande.

Utilise cette commande avec du code Perl local de confiance. Le chargement
exécute le code du module et son constructeur dans un processus de test, avec un
registre, un bus d’événements et un planificateur en mémoire. Aucun service live
n’est connecté par l’atelier et aucune commande de plugin n’est invoquée. Garde
les tests de comportement du paquet pour vérifier ses réponses et ses traitements.

## Première activation supervisée

Owner dans la partyline de développement :

```text
.plugins loadv3 welcome-v3 irc.reply
.plugins policy welcome-v3 #test observe
.plugins enable welcome-v3
.plugins doctor welcome-v3
.plugins why welcome-v3 #test
```

Dans #test, `!welcome_channel` reste silencieux en observe. Puis choisir
explicitement `.plugins policy welcome-v3 #test on` et réessayer : une seule
salutation doit apparaître. Adapter le préfixe public réel de l'instance.
Un autre salon sans politique reste off. Une commande déjà réservée provoque
un refus du chargement ; le générateur n'écrase aucun handler.

## Retrait et erreurs

```text
.plugins policy welcome-v3 #test off
.plugins disable welcome-v3
.plugins unload welcome-v3
```

Vérifier le silence et l'absence de commande montée. Les erreurs restent
contenues par le runtime : `.plugins failures welcome-v3` et `.plugins doctor`
sont des observations ; elles ne réparent ni ne donnent de nouvelle permission.
Une erreur de chargement ne justifie pas un grant plus large. Ne supprimer le
répertoire que lorsque le paquet est déchargé et que ses modifications utiles
sont enregistrées. Ne pas écraser les paquets acceptés ni leur stockage.

Pour un exemple avec événements et job, lire plugins/hello-v3 ; pour l'adoption
réversible de commandes existantes, lire plugins/playful-v3. La documentation
complète des services et droits reste docs/PLUGIN_API_V3.md.
