# Écrire son premier script Mediabot en Perl, Python ou Tcl

Dans ce tutoriel, tu vas créer une commande IRC qui salue la personne
qui l’appelle ou le nom donné en argument. Les trois versions ont le même
comportement. Tu peux suivre le langage de ton choix ou installer les trois
sur la même instance de développement.

| Langage | Commande dans IRC | Exemple de réponse |
| --- | --- | --- |
| Perl | `!bonjour_perl` | `Bonjour, Pablo!` si ton nick est Pablo |
| Python | `!bonjour_python Élodie Martin` | `Bonjour, Élodie Martin!` |
| Tcl | `!bonjour_tcl Élodie Martin` | `Bonjour, Élodie Martin!` |

## 1. Préparer l’atelier

Pars de la racine d’un checkout **Mediabot 3.8dev** avec les dépendances
habituelles du bot. La création et les tests ci-dessous fonctionnent hors
ligne, sans démarrer Mediabot, IRC ni MariaDB. Les scripts s’exécutent avec
les permissions du compte qui lance l’atelier. Utilise du code de confiance.

| Langage du script | Prérequis |
| --- | --- |
| Perl | `perl` et `JSON::PP` |
| Python | `python3` et sa bibliothèque standard |
| Tcl | `tclsh` et Tcllib pour `json` et `json::write` |

Sous Debian, le modèle Tcl utilise les paquets `tcl` et `tcllib`.

Ce parcours crée des **scripts externes à manifeste API v2** avec
`--create-script`. Le nom du fichier `plugin_v3_workshop.pl` vient du
fait que l’atelier gère aussi les paquets API v3. Le protocole JSON sur
l’entrée et la sortie standard s’appelle `mediabot-script-v1`.

## 2. Générer et tester la première version

Choisis la commande de génération pour ton langage. Les noms sont distincts
pour pouvoir charger les trois scripts ensemble.

```bash
perl tools/plugin_v3_workshop.pl --create-script bonjour-perl \
  --language perl --command bonjour_perl
perl tools/plugin_v3_workshop.pl --create-script bonjour-python \
  --language python --command bonjour_python
perl tools/plugin_v3_workshop.pl --create-script bonjour-tcl \
  --language tcl --command bonjour_tcl
```

Avec Python, tu obtiens cette arborescence. Perl utilise l’extension `.pl`
et Tcl l’extension `.tcl`.

```text
plugins/scripts/bonjour-python/
├── bonjour-python.py
├── bonjour-python.py.manifest.json
├── bonjour-python.py.test.json
└── README.md
```

Le script contient la logique. Le manifeste déclare le nom du plugin, sa
version, la commande publique de niveau `0` et le texte `GREETING`.
Mediabot transmet ce texte au script dans `data.config.GREETING`. Le
fichier `.test.json` décrit les appels et les réponses à vérifier.

Voici le manifeste Python généré. Le nom sous `commands` s’écrit sans
préfixe IRC.

```json
{
  "api": 2,
  "name": "bonjour-python",
  "version": "0.1.0",
  "description": "A script plugin greeting with an editable test fixture.",
  "commands": {
    "bonjour_python": {"help": "Show a greeting for an optional name.", "level": 0}
  },
  "config": {"GREETING": "Bonjour"}
}
```

Teste les fichiers que tu viens de générer. Donne à `--test-script` un
chemin relatif à `plugins/scripts`.

```bash
perl tools/plugin_v3_workshop.pl --test-script bonjour-perl/bonjour-perl.pl
perl tools/plugin_v3_workshop.pl --test-script bonjour-python/bonjour-python.py
perl tools/plugin_v3_workshop.pl --test-script bonjour-tcl/bonjour-tcl.tcl
```

Pour chaque script, tu dois voir `passed 2 offline test step(s).`

## 3. Accepter un nom de plusieurs mots

Le modèle généré utilise le premier élément de `data.args`. Remplace
le contenu du script de ton langage par l’exemple correspondant pour
reconstituer un nom complet. Quand il n’y a aucun argument, le script
utilise `data.nick`.

Mediabot écrit une requête JSON sur **STDIN**. Le script lit les arguments
et renvoie un seul objet JSON sur **STDOUT**. L’action `reply` demande à
Mediabot de répondre sur le canal de la commande. Envoie les traces de
débogage sur **STDERR** pour garder la sortie JSON lisible.

### Perl

Fichier `plugins/scripts/bonjour-perl/bonjour-perl.pl`.

```perl
use strict;
use warnings;
use JSON::PP qw(decode_json encode_json);

binmode STDIN, ':raw';
binmode STDOUT, ':raw';

my $request = decode_json(do { local $/; <STDIN> });
my $data = $request->{data};
my $greeting = $data->{config}{GREETING};
my $name = @{ $data->{args} } ? join(' ', @{ $data->{args} }) : $data->{nick};

print encode_json({
    protocol => 'mediabot-script-v1',
    ok => JSON::PP::true,
    actions => [{ type => 'reply', text => "$greeting, $name!" }],
});
```

### Python

Fichier `plugins/scripts/bonjour-python/bonjour-python.py`.

```python
import json
import sys

request = json.load(sys.stdin.buffer)
data = request["data"]
greeting = data["config"]["GREETING"]
name = " ".join(data["args"]) if data["args"] else data["nick"]

print(json.dumps({
    "protocol": "mediabot-script-v1",
    "ok": True,
    "actions": [{"type": "reply", "text": f"{greeting}, {name}!"}],
}))
```

### Tcl

Fichier `plugins/scripts/bonjour-tcl/bonjour-tcl.tcl`.

```tcl
package require json
package require json::write
fconfigure stdin -encoding utf-8
fconfigure stdout -encoding utf-8

set request [json::json2dict [read stdin]]
set data [dict get $request data]
set greeting [dict get $data config GREETING]
set arguments [dict get $data args]
set name [dict get $data nick]
if {[llength $arguments]} {
    set name [join $arguments " "]
}

set reply [json::write object type [json::write string reply] \
    text [json::write string "$greeting, $name!"]]
puts [json::write object protocol [json::write string mediabot-script-v1] \
    ok true actions [json::write array $reply]]
```

## 4. Vérifier le nouveau comportement

Pour Python, remplace le contenu de `bonjour-python.py.test.json` par ce
scénario. Il teste le nick par défaut, les caractères accentués et le nom
reçu en deux arguments.

```json
{
  "steps": [
    {
      "command": "bonjour_python",
      "replies": [["PRIVMSG", "#workshop", "Bonjour, Pablo!"]]
    },
    {
      "command": "bonjour_python",
      "data": {"args": ["Élodie \"IRC\""]},
      "replies": [["PRIVMSG", "#workshop", "Bonjour, Élodie \"IRC\"!"]]
    },
    {
      "command": "bonjour_python",
      "data": {"channel": "#atelier", "args": ["Élodie", "Martin"]},
      "replies": [["PRIVMSG", "#atelier", "Bonjour, Élodie Martin!"]]
    }
  ]
}
```

Pour Perl, utilise `bonjour-perl.pl.test.json` et remplace chaque
`bonjour_python` par `bonjour_perl`. Pour Tcl, utilise
`bonjour-tcl.tcl.test.json` et remplace par `bonjour_tcl`. Chaque réponse
est un triplet `[verbe IRC, cible, texte]`. Le canal de test par défaut
est `#workshop` et le nick est `Pablo`.

Relance le test de l’étape 2. Avec le nouveau script et le nouveau scénario,
le résultat attendu est `passed 3 offline test step(s).` Si tu conserves
le script généré, l’étape 3 échoue avec `Bonjour, Élodie!` au lieu de
`Bonjour, Élodie Martin!`.

Essaie ensuite de passer `GREETING` de `Bonjour` à `Salut` dans le
manifeste et mets à jour les réponses attendues. Le même code utilisera
la nouvelle configuration.

## 5. Essayer la commande sur une instance de développement

Quand le test passe, mets le script et son manifeste dans le répertoire
`plugins/scripts` de l’instance de développement. Connecte-toi à sa
Partyline avec le rôle **Owner**. Charge uniquement les scripts que tu as
créés.

```text
.plugins loadscript bonjour-perl/bonjour-perl.pl
.plugins loadscript bonjour-python/bonjour-python.py
.plugins loadscript bonjour-tcl/bonjour-tcl.tcl
.plugins loaded
```

`loadscript` monte et active la commande publique dès le chargement.
Elle est disponible dans les canaux de l’instance de développement où
le bot reçoit les commandes. Essaie-la dans un canal de test, avec le
préfixe configuré sur ton bot.

```irc
!bonjour_perl Élodie Martin
!bonjour_python Élodie Martin
!bonjour_tcl Élodie Martin
```

Chaque commande doit produire une seule réponse `Bonjour, Élodie Martin!`
si tu as gardé le manifeste initial. Pour reprendre l’exercice après une
modification locale, décharge le plugin puis recharge-le avec `loadscript`.
Pour terminer, décharge les scripts essayés.

```text
.plugins unload bonjour-perl
.plugins unload bonjour-python
.plugins unload bonjour-tcl
.plugins loaded
```

## Si le test échoue

| Symptôme | Vérification |
| --- | --- |
| Le générateur refuse la destination | Réutilise les fichiers déjà générés ou choisis un autre nom. |
| Le manifeste est introuvable | Laisse `<script>.manifest.json` à côté du script, avec son extension complète. |
| Tcl affiche `can't find package json` ou `json::write` | Vérifie l’installation de Tcllib pour le `tclsh` qui exécute le script. |
| La sortie JSON est invalide | Garde un seul objet sur STDOUT et déplace les traces vers STDERR. |
| Le test affiche `reply mismatch` | Compare le verbe, le canal et le texte capturés avec le triplet de l’étape. |
| Le chargement signale une collision | Choisis un nom de commande libre et change-le dans le manifeste et le scénario. |

## Pour aller plus loin

- [Cookbook des scripts API v2](https://github.com/teuk/mediabot_v3/blob/master/plugins/scripts/COOKBOOK.md) pour ajouter des événements et du stockage.
- [Atelier des plugins API v3](https://github.com/teuk/mediabot_v3/blob/master/docs/PLUGIN_WORKSHOP.md) pour créer un paquet avec des droits explicites et une activation par canal. Le paquet Perl v3 utilise un module natif. Les paquets Python et Tcl v3 exécutent leurs commandes dans un processus séparé.
