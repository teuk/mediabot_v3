# Cinq commandes Mediabot à essayer et à adapter

Ces trois scripts à manifeste **API v2** prolongent le
[tutoriel du premier script](https://github.com/teuk/mediabot_v3/blob/master/docs/WRITE_A_MEDIABOT_SCRIPT.md).
Ils montrent comment compter du texte en Perl, conserver un mémo de canal
en Python et répondre en NOTICE en Tcl. Chaque exemple comprend le script,
son manifeste et un scénario de test.

| Commande IRC | Langage | Résultat |
| --- | --- | --- |
| `!pmesure Élodie Martin` | Perl | `Mots : 2 \| Caractères : 13` |
| `!pnote Démo jeudi à 20 h.` | Python | Enregistre ou remplace la note du canal |
| `!plirenote` | Python | `Note du canal : Démo jeudi à 20 h.` |
| `!peffacenote` | Python | Efface la note du canal |
| `!plien wiki` | Tcl | Envoie l’adresse du wiki en NOTICE au demandeur |

## 1. Tester les trois scripts hors ligne

Depuis la racine du dépôt Mediabot 3.8dev, avec les dépendances
de l’atelier, lance les commandes suivantes. Tcl utilise `tclsh` et
les modules `json` et `json::write` de Tcllib.

```bash
perl tools/plugin_v3_workshop.pl --test-script examples-v2/tutorial/tutorial-mesure.pl
perl tools/plugin_v3_workshop.pl --test-script examples-v2/tutorial/tutorial-note.py
perl tools/plugin_v3_workshop.pl --test-script examples-v2/tutorial/tutorial-liens.tcl
```

L’atelier vérifie respectivement **3, 10 et 4 étapes**. Il capture les
réponses et utilise un stockage temporaire. Chaque scénario repart avec
un stockage vide.

## 2. Perl · Lire et mesurer les arguments

Dans ton canal de test, essaie `!pmesure` seul pour afficher l’usage,
puis `!pmesure Élodie Martin` pour compter le texte. Le script reconstruit
le texte à partir de `data.args`. Un mot est une suite de caractères
hors espace. Le total inclut les espaces du texte reconstruit et compte
les points de code Unicode.

```perl
my $text = join ' ', @{ $request->{data}{args} };
my @words = $text =~ /\S+/g;
```

Pour adapter la commande, modifie le format de la réponse puis ajoute un
cas avec ponctuation ou caractères accentués dans le scénario. Compare la
sortie attendue dans le triplet `["PRIVMSG", "#atelier", "..."]`.

[Script Perl](https://github.com/teuk/mediabot_v3/blob/master/plugins/scripts/examples-v2/tutorial/tutorial-mesure.pl) · [Scénario Perl](https://github.com/teuk/mediabot_v3/blob/master/plugins/scripts/examples-v2/tutorial/tutorial-mesure.pl.test.json)

## 3. Python · Écrire, lire et effacer la note d’un canal

Le fichier `tutorial-note.py.manifest.json` déclare les trois commandes. Le
script distingue les opérations grâce à `data.command`.

Dans `#atelier`, essaie cette séquence.

```irc
!pnote Démo jeudi à 20 h.
!plirenote
!pnote Nouvelle date.
!plirenote
!peffacenote
!plirenote
```

Les trois lectures renvoient successivement `Note du canal : Démo jeudi
à 20 h.`, `Note du canal : Nouvelle date.`, puis `Aucune note pour ce
canal.`. Les écritures et suppressions réussies restent silencieuses.
La lecture permet de vérifier l’état enregistré.

Le script lit le document courant dans `data.storage`. Il modifie
seulement la clé de son canal, puis renvoie une action `store` avec le
document complet. Mediabot écrit ce document. Une action qui renverrait
seulement la nouvelle note écraserait les notes des autres canaux.

```json
{"type": "store", "data": {"#atelier": "Démo jeudi à 20 h.", "#ailleurs": "Atelier vendredi."}}
```

Les clés suivent la casse IRC RFC1459. Le scénario vérifie qu’un second
nick peut lire la note, qu’un autre canal conserve la sienne et que
l’effacement touche seulement le canal courant. Les notes sont communes
aux membres du canal. Dans cet exemple, le niveau `0` autorise chacun
à lire, écrire et effacer. Le script accepte au plus 12 notes de
120 octets UTF-8 chacune.

Pour adapter le mémo, ajoute un test qui dépasse la limite de taille.
Fais suivre le refus d’une lecture de la note précédente pour vérifier
que la validation a protégé les données.

[Script Python](https://github.com/teuk/mediabot_v3/blob/master/plugins/scripts/examples-v2/tutorial/tutorial-note.py) · [Manifeste Python](https://github.com/teuk/mediabot_v3/blob/master/plugins/scripts/examples-v2/tutorial/tutorial-note.py.manifest.json) · [Scénario Python](https://github.com/teuk/mediabot_v3/blob/master/plugins/scripts/examples-v2/tutorial/tutorial-note.py.test.json)

## 4. Tcl · Envoyer un lien en NOTICE

Essaie `!plien docs`, `!plien wiki` ou `!plien issues`. Le script
cherche l’argument dans un dictionnaire de liens prédéfinis. Il envoie
une action `notice` dont la cible est `data.nick`. Le canal ne reçoit
donc aucune réponse publique. Une clé inconnue ou plusieurs arguments
déclenchent un message d’usage, lui aussi en NOTICE.

Pour ajouter une destination, complète le dictionnaire Tcl, le message
d’usage et l’aide du manifeste. Dans le scénario, fixe un nick
différent du canal et vérifie le destinataire, par exemple
`["NOTICE", "Mina", "https://github.com/teuk/mediabot_v3/wiki"]`.

[Script Tcl](https://github.com/teuk/mediabot_v3/blob/master/plugins/scripts/examples-v2/tutorial/tutorial-liens.tcl) · [Scénario Tcl](https://github.com/teuk/mediabot_v3/blob/master/plugins/scripts/examples-v2/tutorial/tutorial-liens.tcl.test.json)

## 5. Charger un exemple sur l’instance de développement

Dans sa Partyline, avec le rôle Owner, utilise la ligne correspondant à
l’exemple choisi. Tape ensuite sa commande dans un canal de test.

```text
.plugins loadscript examples-v2/tutorial/tutorial-mesure.pl
.plugins loadscript examples-v2/tutorial/tutorial-note.py
.plugins loadscript examples-v2/tutorial/tutorial-liens.tcl
```

Quand tu as terminé, décharge les scripts que tu as chargés.

```text
.plugins unload tutorial-mesure
.plugins unload tutorial-note
.plugins unload tutorial-liens
```

Pour réutiliser un exemple comme base, copie son script et ses deux
fichiers JSON dans un nouveau répertoire sous `plugins/scripts`.
Garde le nom complet du script devant `.manifest.json` et `.test.json`.
Choisis un nom de plugin et des commandes libres avant de les charger.
