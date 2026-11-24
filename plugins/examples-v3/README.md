# Exemples de plugins API v3

Chaque paquet contient un manifeste `plugin.json`, son code dans `lib/`
et un scénario d’atelier `workshop.test.json`. Les trois paquets exposent
des commandes publiques de niveau `0` et démarrent désactivés.

| Paquet | Langage | Essai en IRC | Capacités à accorder |
| --- | --- | --- | --- |
| [counter-v3](counter-v3) | Perl natif | `!v3compteur` lit le compteur du canal. `!v3compteur +1` l’incrémente. | `irc.reply`, `storage.kv` |
| [estimate-v3](estimate-v3) | Python | `!v3estime 7` estime la durée de sept tâches, à raison de cinq minutes par défaut. | `irc.reply` |
| [duty-notice-v3](duty-notice-v3) | Tcl | `!v3permanence` donne le contact et les horaires du canal en NOTICE. | `irc.notice` |

## Tester et modifier un exemple

Depuis la racine du dépôt, utilise l’atelier. Perl utilise les dépendances
habituelles de Mediabot, Python sa bibliothèque standard et Tcl les
modules `json` et `json::write` de Tcllib.

```bash
perl tools/plugin_v3_workshop.pl --test counter-v3 \
  --directory plugins/examples-v3 --grant irc.reply --grant storage.kv
perl tools/plugin_v3_workshop.pl --test estimate-v3 \
  --directory plugins/examples-v3 --grant irc.reply
perl tools/plugin_v3_workshop.pl --test duty-notice-v3 \
  --directory plugins/examples-v3 --grant irc.notice
```

**Compteur Perl.** Lis d’abord la révision et la valeur par
`channel_storage_snapshot`. Passe cette révision à
`channel_storage_commit` pour détecter une modification concurrente.
Le scénario vérifie l’isolation de deux canaux, le silence en `observe` et
`off`, puis le maintien du compteur après un redémarrage simulé. Le
compteur est partagé et les utilisateurs du canal peuvent l’incrémenter
jusqu’à 999 999. Le stockage expose la valeur comme une chaîne décimale
et la révision comme un entier.

**Estimation Python.** Le manifeste borne `minutes_per_task` de 1 à 120.
Le script reçoit cet entier dans `data.config` et valide séparément le
nombre de tâches saisi sur IRC. Modifie le réglage dans une étape du
scénario pour changer l’estimation de ce canal.

**Permanence Tcl.** Les réglages de canal `contact` et `hours` alimentent
une action JSON `notice`. Mediabot cible le nick qui a invoqué la commande.
`!v3permanence contact` et `!v3permanence horaires` affichent une seule
information. Le scénario vérifie aussi une option inconnue et le silence
en `observe` ou `off`.

Dans `workshop.test.json`, les triplets `[verbe IRC, cible, texte]`
permettent de vérifier où et comment la réponse est délivrée. Utilise
`--validate` à la place de `--test` avec les mêmes arguments pour
vérifier le montage et les collisions sans exécuter les commandes.

## Essayer un paquet sur l’instance de développement

Pour prendre l’estimation comme exemple, copie le paquet dans le
répertoire `plugins/` de ton checkout de développement, depuis sa racine.

```bash
test ! -e plugins/estimate-v3 && cp -a plugins/examples-v3/estimate-v3 plugins/
```

Dans la Partyline de développement, avec le rôle Owner, charge-le,
applique la politique du canal `#test` et active-le.

```text
.plugins loadv3 estimate-v3 irc.reply
.plugins policy estimate-v3 #test observe minutes_per_task=20
.plugins enable estimate-v3
```

Dans `#test`, `!v3estime 3` reste silencieux. Passe ensuite la politique
du canal à `on` pour obtenir `3 tâches : 60 min (20 min par tâche).`

```text
.plugins policy estimate-v3 #test on minutes_per_task=20
```

Après l’essai, décharge le paquet.

```text
.plugins unload estimate-v3
```

Pour le compteur ou la permanence, utilise le nom et les capacités du
tableau. Sépare les capacités par des virgules dans la commande
`loadv3`, par exemple `.plugins loadv3 counter-v3 irc.reply,storage.kv`.
Les canaux sans politique explicite restent à `off`.
Le [guide de l’atelier](../../docs/PLUGIN_WORKSHOP.md) détaille les
scénarios. Le [contrat API v3](../../docs/PLUGIN_API_V3.md) décrit
les capacités et les différences entre les modules natifs et les scripts.
