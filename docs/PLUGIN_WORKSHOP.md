# Du premier plugin à son retrait

L’atelier génère des paquets API v3 en Perl, Python et Tcl. Les scripts à
manifeste adjacent API v2 en Perl, Python et Tcl gardent leur parcours de test.
Les deux formats de scripts utilisent le protocole `mediabot-script-v1`.

## Écrire une commande API v3 en Python ou Tcl

```bash
perl tools/plugin_v3_workshop.pl --create hello-python-v3 \
  --language python --command hello_python
perl tools/plugin_v3_workshop.pl --validate hello-python-v3 --grant irc.reply
perl tools/plugin_v3_workshop.pl --test hello-python-v3 --grant irc.reply
```

Le paquet contient `plugin.json`, `lib/greeting.py`, `workshop.test.json` et un
README avec les commandes de chargement et de retrait. Pour Tcl, utilise `--language tcl` et
modifie `lib/greeting.tcl`. L’exemple Tcl utilise `tclsh` et les modules
`json` et `json::write` de Tcllib. L’exemple Python utilise `python3` et sa
bibliothèque standard. `--validate` vérifie le montage et les collisions hors
ligne. `--test` lance la commande et vérifie ses réponses dans une instance
isolée.

Sur l’instance de développement, charge le paquet depuis la Partyline en tant
qu’Owner et active-le sur le canal voulu.

```text
.plugins loadv3 hello-python-v3 irc.reply
.plugins policy hello-python-v3 #test on
.plugins enable hello-python-v3
```

Dans `#test`, `!hello_python Élodie` affiche `Bonjour, Élodie!`. Pour observer
l’exécution sans publier de message, sélectionne `observe`. Les canaux sans
politique restent à `off`. Le [contrat API v3](PLUGIN_API_V3.md#python-and-tcl-command-packages)
décrit le contexte, la réponse et les limites du processus.

## Tester une commande API v3 hors ligne

`--test NAME` lit `workshop.test.json` dans le répertoire du paquet, ou le
fichier fourni par `--fixture FILE`. Tu peux utiliser un fichier explicite pour
tester un paquet Perl, Python ou Tcl déjà créé. Le test exécute le code local de
confiance avec les permissions du compte qui lance l’atelier.

```json
{
  "steps": [
    {
      "command": "hello_python",
      "data": {"channel": "#atelier", "args": ["Élodie"]},
      "config": {"greeting": "Salut"},
      "replies": [["PRIVMSG", "#atelier", "Salut, Élodie!"]]
    },
    {"command": "hello_python", "mode": "observe", "replies": []},
    {"command": "hello_python", "mode": "off", "replies": []}
  ]
}
```

Les commandes publiques et leurs alias sont acceptés. Les valeurs par défaut
sont `on`, `#workshop`, `Pablo` et aucun argument. Chaque étape
applique sa propre politique et ses propres réglages typés. L’atelier compare
les messages dans l’ordre par triplets `[verbe, cible, texte]`. Un `reply`
donne un `PRIVMSG` vers le canal, un `notice` donne un `NOTICE` vers le nick.
Accorde les capacités correspondantes avec `--grant irc.reply` ou
`--grant irc.notice` si le paquet les déclare. Un échec indique l’étape et
l’erreur d’exécution, ou les réponses attendues et capturées. Quand le plugin
est activé, une étape `observe` exécute la commande sans réponse et une étape
`off` reste inactive.

Pour une commande réservée à un rôle, ajoute `caller` et utilise
`"expect": "denied"` dans les scénarios qui doivent être refusés.

```json
{
  "steps": [
    {
      "command": "master_greet",
      "caller": {"role": "Owner", "authenticated": false},
      "expect": "denied",
      "replies": []
    },
    {
      "command": "master_greet",
      "caller": {"role": "Master", "authenticated": true},
      "replies": [["PRIVMSG", "#workshop", "Bonjour, Pablo!"]]
    }
  ]
}
```

Sans `caller`, l’atelier simule un invité. Les rôles `Owner`, `Master`,
`Administrator` et `User` suivent l’ordre de la base standard. Chaque étape
repart avec sa propre identité simulée. Le registre contrôle la permission et
l’atelier vérifie le refus effectif, y compris en mode `observe`.
Ces scénarios couvrent les rôles globaux avec des utilisateurs simulés.

## Tester les événements API v3 d’un canal

`--test` accepte une étape `event` entre deux étapes `command`. Le nom et
la version de l’événement doivent figurer dans le manifeste du paquet.
Accorde `--grant events.subscribe` pour monter l’abonnement. Le même
paquet reçoit les événements et les commandes, ce qui permet de vérifier
l’état observé après un événement.

```json
{
  "steps": [
    {
      "event": "irc.channel.join",
      "version": 1,
      "data": {"nick": "Élodie", "is_self": false},
      "replies": []
    },
    {
      "command": "last_workshop_join",
      "replies": [["PRIVMSG", "#workshop", "Bonjour, Élodie [on]"]]
    }
  ]
}
```

La version par défaut vaut `1`, le canal `#workshop` et le nick `Pablo`.
Les champs de `data` suivent le [catalogue des événements](../plugins/API_V3_EVENTS.json).
L’atelier vérifie le passage par le bus, attend la fin du traitement, et
compare les messages capturés. En `observe`, le gestionnaire s’exécute,
avec les sorties filtrées par sa politique. En `off`, l’événement ne doit
pas entrer dans la file. Une erreur de gestionnaire échoue même avec
`"replies": []`. Cette recette couvre les événements rattachés à un canal
dans les paquets Perl natifs.

```bash
perl tools/plugin_v3_workshop.pl --test channel-observer-v3 \
  --directory plugins/examples-v3 --grant events.subscribe --grant irc.reply
```

## Tester une tâche planifiée API v3

Une étape `job` déclenche une échéance de la tâche périodique déclarée
dans le manifeste. Accorde `scheduler.jobs` pour enregistrer la tâche et
`irc.channel_message` si elle publie un message. L’atelier pilote l’échéance
hors ligne, sans attendre l’intervalle réel. Les étapes de commande et
d’événement peuvent précéder ou suivre l’échéance dans la même instance.

```json
{
  "steps": [
    {
      "job": "pulse",
      "channels": {
        "#atelier": {"mode": "on", "config": {"greeting": "Salut"}},
        "#observation": {"mode": "observe"},
        "#eteint": {"mode": "off"}
      },
      "replies": [["PRIVMSG", "#atelier", "Salut, passage 1"]]
    }
  ]
}
```

`channels` remplace les politiques de canal pour cette étape. Le mode par
défaut vaut `on`. Un objet vide vérifie une échéance sans canal actif. En
`observe`, la tâche s’exécute sans publier de message. En `off`, le canal
ne reçoit aucune exécution de cette tâche. L’atelier vérifie le passage par
l’ordonnanceur, le nombre d’exécutions et les messages capturés dans l’ordre.

```bash
perl tools/plugin_v3_workshop.pl --test channel-observer-v3 \
  --directory plugins/examples-v3 \
  --fixture plugins/examples-v3/channel-observer-v3/jobs.test.json \
  --grant events.subscribe --grant irc.reply --grant scheduler.jobs --grant irc.channel_message
```

## Vérifier le stockage d’un plugin API v3

Accorde `--grant storage.kv` si le plugin déclare cette capacité. Chaque
lancement de l’atelier part d’un répertoire temporaire vide. Les étapes d’un
même scénario partagent ce répertoire et passent par les dépôts habituels.

Le champ facultatif `storage` vérifie l’état sur disque après une commande,
un événement ou une tâche. `global` désigne les données du plugin,
`channels` les données de chaque canal indiqué. Chaque état contient la
révision entière et toutes les valeurs attendues, sous forme de chaînes.
Un état absent correspond à la révision `0` et à un objet `values` vide.

```json
{
  "steps": [
    {
      "command": "workshop_remember",
      "data": {"args": ["channel", "Café"]},
      "replies": [],
      "storage": {
        "channels": {"#workshop": {"revision": 1, "values": {"note": "Café"}}},
        "global": {"revision": 0, "values": {}}
      }
    }
  ]
}
```

Le scénario fourni vérifie aussi deux canaux indépendants, les noms
équivalents en IRC et l’absence de modification en mode `observe` ou `off`.

```bash
perl tools/plugin_v3_workshop.pl --test channel-observer-v3 \
  --directory plugins/examples-v3 \
  --fixture plugins/examples-v3/channel-observer-v3/storage.test.json \
  --grant storage.kv
```

## Simuler le redémarrage d’un plugin API v3

Ajoute une étape `"restart": true` après avoir produit l’état à tester.
L’atelier sauvegarde sur disque l’activation du plugin, ses capacités
accordées et ses politiques de canal, puis le décharge et le restaure via
le mécanisme normal de démarrage. Il compare l’état restauré à l’état
sauvegardé. Les étapes suivantes s’exécutent dans l’instance rechargée et
gardent le même répertoire temporaire.

```json
{
  "restart": true,
  "replies": [],
  "storage": {"global": {"revision": 1, "values": {"note": "Café"}}}
}
```

`storage` reste facultatif et utilise les mêmes assertions que pour les
autres étapes. L’exemple vérifie que les données globales et par canal
traversent le redémarrage, que la mémoire du plugin repart à vide et que
les commandes, événements et tâches fonctionnent après restauration.

```bash
perl tools/plugin_v3_workshop.pl --test channel-observer-v3 \
  --directory plugins/examples-v3 \
  --fixture plugins/examples-v3/channel-observer-v3/restart.test.json \
  --grant events.subscribe --grant irc.reply --grant scheduler.jobs \
  --grant irc.channel_message --grant storage.kv
```

## Désactiver et réactiver un plugin API v3

Insère une étape `lifecycle` avec l’action `disable` ou `enable` pour
exercer le cycle de vie du paquet chargé dans le scénario.

```json
{"lifecycle": "disable", "replies": []}
```

Le gestionnaire appelle les hooks `stop` et `start` lorsque le paquet les
définit et que son état change. Pendant la désactivation, l’atelier vérifie
que les commandes ne s’exécutent pas, que les événements n’entrent pas en
file et que la tâche testée reste arrêtée, même sur un canal en mode `on`.
Une commande peut déclarer explicitement `"expect": "disabled"`. La réactivation
reprend avec la même instance du plugin. Une étape `restart` propage aussi
l’état désactivé à l’instance rechargée.

L’exemple vérifie la mémoire des arrivées, le stockage par canal, la reprise
des événements et la continuité de la séquence de la tâche périodique.

```bash
perl tools/plugin_v3_workshop.pl --test channel-observer-v3 \
  --directory plugins/examples-v3 \
  --fixture plugins/examples-v3/channel-observer-v3/lifecycle.test.json \
  --grant events.subscribe --grant irc.reply --grant scheduler.jobs \
  --grant irc.channel_message --grant storage.kv
```

## Vérifier une erreur attendue et la reprise du plugin

Ajoute `failure.contains` à une étape de commande, d’événement ou de tâche.
L’atelier exige exactement un nouvel échec inscrit dans le registre du
plugin pour la ressource et le canal de l’étape. Il cherche le fragment
littéral dans le diagnostic de cet échec.

```json
{
  "command": "workshop_remember",
  "data": {"channel": "#atelier", "args": ["unknown", "Café"]},
  "failure": {"contains": "Expected a global or channel value"},
  "replies": []
}
```

Pour une tâche, indique aussi `failure.channel` pour identifier le canal en
échec. Les autres canaux actifs de ce même passage doivent réussir. L’erreur
doit provenir d’une exécution en mode `on` ou `observe`. Une erreur absente,
différente ou supplémentaire fait échouer le scénario. L’atelier vérifie
toujours les réponses et les assertions de stockage de l’étape.

Le scénario fourni enregistre une note, vérifie qu’une commande invalide
la laisse intacte, puis enregistre une nouvelle valeur sur le même canal.

```bash
perl tools/plugin_v3_workshop.pl --test channel-observer-v3 \
  --directory plugins/examples-v3 \
  --fixture plugins/examples-v3/channel-observer-v3/failures.test.json \
  --grant storage.kv
```

## Écrire et tester un script API v2 en Perl, Python ou Tcl

Depuis le dépôt, choisis un langage et un nom de commande libre. Ce parcours
utilise `perl` et `JSON::PP`, `python3` et sa bibliothèque standard, ou `tclsh`
avec les modules `json` et `json::write` de Tcllib.

```bash
perl tools/plugin_v3_workshop.pl --create-script welcome-python \
  --language python --command welcome_python
perl tools/plugin_v3_workshop.pl --test-script welcome-python/welcome-python.py
```

Le générateur crée le script, son manifeste `<script>.manifest.json`, son test
`<script>.test.json` et un README dans `plugins/scripts/welcome-python/`. Pour
une version Perl, utilise `--language perl` et l’extension `.pl`. Pour Tcl,
utilise `--language tcl` et `.tcl`. `--directory DIR` choisit un autre répertoire
racine pour la génération et le test.

Modifie la logique du script, puis ajuste les étapes du test. `--fixture FILE`
sélectionne un autre fichier de test. Chaque étape exécute une commande publique
de niveau `0` ou émet un événement déclaré dans le manifeste. L’atelier compare
les messages IRC capturés, dans l’ordre, par triplet `[verbe, cible, texte]`.

```json
{
  "steps": [
    {
      "command": "welcome_python",
      "data": {"args": ["Élodie"]},
      "replies": [["PRIVMSG", "#workshop", "Bonjour, Élodie!"]]
    }
  ]
}
```

Le nick de test est `Pablo` et le canal `#workshop` par défaut. Pour un événement,
remplace `command` par `event` et ajoute les données utiles à `data`. Une étape
qui doit rester silencieuse déclare `"replies": []`. Toutes les étapes d’un test
partagent un stockage temporaire. Tu peux donc faire écrire une valeur par un
événement et vérifier qu’une commande la relit. Chaque lancement repart avec
un stockage vide.

Le test exécute le script sous le compte qui lance l’atelier. Il utilise un
registre, un bus d’événements et un transport IRC de test avec le moteur d’actions
du bot. Réserve ce parcours au code local de confiance.

Après validation, un Owner peut charger le script sur l’instance de développement
avec `.plugins loadscript welcome-python/welcome-python.py` puis essayer
`!welcome_python Élodie` dans un canal de test. Cette commande charge le script
en actif. `.plugins unload welcome-python` le retire. Pour ajouter des événements
ou utiliser l’état persistant, consulte le [guide des scripts](../plugins/scripts/README.md)
et son [cookbook](../plugins/scripts/COOKBOOK.md).

## Écrire un module Perl natif

### Vérifier sans serveur IRC ou base

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

### Créer son paquet

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
refusés. Le générateur écrit `plugin.json`, `README.md`, `lib/Greeting.pm`
et `workshop.test.json`. La seule capacité est `irc.reply` et la configuration typée
`greeting` limite le texte à 160 caractères. Aucun timer, événement, HTTP,
stockage ou SQL n'est demandé. Remplacer le texte métier dans cette petite
surface, puis ajouter un test de comportement avant d'étendre les capacités.

### Valider le paquet après modification

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

### Première activation supervisée

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

### Retrait et erreurs

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
