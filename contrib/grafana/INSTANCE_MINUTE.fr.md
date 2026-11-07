# Mediabot · En direct — Grafana pour votre bot

[English guide](INSTANCE_MINUTE.md) · [JSON à importer](grafana_mediabot_instance_minute.json)

Ce tableau permet de suivre **une seule instance** : collecte, connexion IRC,
base du bot, salons rejoints, messages, commandes publiques et analyses de liens
par minute. [Voir la maquette](instance-minute-preview.png) avec des données
fictives.

Il vous faut un Mediabot en fonctionnement, Prometheus et un compte Grafana
autorisé à importer un tableau de bord. Mediabot 3.7 expose déjà les métriques
nécessaires : vous pouvez importer le JSON de ce dépôt sans mettre votre bot à
jour. Grafana utilise ses panneaux intégrés, sans extension.

Les exemples supposent que les trois services tournent sur la même machine
et partagent le même espace réseau. Si Prometheus collecte déjà votre bot,
passez à [l’étape 3](#3-connecter-grafana-et-importer-le-tableau).

## 1. Activer les métriques de votre bot

Ouvrez le fichier de configuration utilisé par votre instance et modifiez
sa section `[metrics]` existante :

```ini
[metrics]
METRICS_ENABLED=1
METRICS_BIND=127.0.0.1
METRICS_PORT=9108
```

Si un autre bot utilise déjà `9108` sur cette machine, choisissez un port
libre. Redémarrez votre bot avec son gestionnaire de service habituel.
Avec le [modèle systemd Mediabot](../../tools/systemd/README.md), remplacez
`mybot` par le nom de **votre** instance :

```bash
sudo systemctl restart mediabot@mybot.service
```

Depuis la machine du bot, vérifiez que l’exporteur répond :

```bash
curl -fsS http://127.0.0.1:9108/metrics | grep '^mediabot_up 1$'
```

Vous devez obtenir `mediabot_up 1`. Cela confirme que l’exporteur répond ;
la connexion à IRC est indiquée séparément dans Grafana.

## 2. Configurer la collecte dans Prometheus

Ajoutez ce job **dans la liste** `scrape_configs:` existante de votre
`prometheus.yml`. Si le job `mediabot` existe déjà, ajoutez-y votre cible
sans définir le job une deuxième fois. Reprenez l’adresse et le port de
l’étape précédente.

```yaml
scrape_configs:
  - job_name: mediabot
    scrape_interval: 30s
    static_configs:
      - targets: ["127.0.0.1:9108"]
```

Validez le fichier avec `promtool check config /etc/prometheus/prometheus.yml`
en adaptant le chemin, puis rechargez Prometheus selon votre installation.
Si l’unité systemd prend en charge le rechargement, utilisez
`sudo systemctl reload prometheus.service`. Ouvrez ensuite **Status → Targets**
(ou `/targets` dans l’interface Prometheus) : votre cible doit être **UP**.
Le tableau est prévu pour une collecte au moins une fois par minute.

Sur une autre machine ou dans un autre conteneur, `127.0.0.1` désigne le
collecteur lui-même. Utilisez une adresse joignable depuis Prometheus sur
un réseau privé ou via un tunnel, et adaptez l’adresse d’écoute du bot.
Ne publiez pas l’exporteur sur Internet : ses métriques peuvent inclure
des noms de salons et des informations sur le fonctionnement du bot.

## 3. Connecter Grafana et importer le tableau

1. Si Grafana connaît déjà le bon Prometheus, gardez cette source. Sinon,
   ouvrez **Connections → Data sources**, ajoutez **Prometheus** et saisissez
   son URL depuis le serveur Grafana, par exemple `http://127.0.0.1:9090`
   si les deux services sont sur la même machine. Cliquez sur **Save & test**.
2. Téléchargez le [JSON du tableau](grafana_mediabot_instance_minute.json).
   Sur GitHub, utilisez **Download raw file** pour obtenir le JSON lui-même.
3. Ouvrez **Dashboards → New → Import** dans Grafana, téléversez le fichier,
   choisissez un dossier et importez.
4. En haut du tableau, choisissez **Source Prometheus**, **Collecte** (le
   job, par exemple `mediabot`), puis **Instance** (le label affiché par
   Prometheus, souvent `127.0.0.1:9108`). Enregistrez ces sélections comme
   valeurs par défaut si vous le souhaitez.

## Lire le tableau

Les cartes et les courbes affichent une **moyenne par minute sur cinq
minutes glissantes** : `0,20/min` représente environ une action toutes
les cinq minutes. Les deux classements montrent jusqu’à six salons ou
commandes publiques avec une activité mesurée sur les quinze dernières
minutes. **Analyses de liens** compte les demandes d’analyse, sans mesurer
la réussite des aperçus. Aucun contenu de message n’est affiché.

Un zéro indique qu’aucune hausse n’a été mesurée. Un tiret ou un trou sur
une courbe indique une mesure indisponible. **Non mesuré** indique un
état que le tableau ne peut pas déterminer.

| Si vous voyez… | Vérifiez… |
| --- | --- |
| `curl` ne répond pas | Le bon fichier de configuration, l’adresse d’écoute et le port. Après une modification, redémarrez uniquement cette instance. |
| La cible est **DOWN** | L’erreur dans **Targets** et l’accès à l’exporteur depuis la machine ou le conteneur Prometheus. |
| La liste **Instance** est vide | La source et le job sélectionnés, puis le statut **UP** de la cible et la présence des métriques du bot. |
| Les courbes restent à zéro ou les classements sont vides | Attendez deux collectes. Envoyez ensuite un message ordinaire ou une commande publique dans un salon rejoint et attendez la collecte suivante. Un nouveau compteur a besoin d’un point de départ. |
| La collecte est disponible, mais IRC est déconnecté | Vérifiez la connexion IRC et les logs du bot. Son exporteur peut répondre même si le bot n’est plus sur IRC. |

Pour retirer le tableau, supprimez-le dans Grafana. Si vous aviez ajouté
un job Prometheus uniquement pour ce tableau, retirez-le, validez le fichier
et rechargez Prometheus. Aucune modification du bot ou de sa base n’est
nécessaire pour supprimer le tableau.

Références : [configuration Prometheus](https://prometheus.io/docs/prometheus/latest/configuration/configuration/),
[source Prometheus dans Grafana](https://grafana.com/docs/grafana/latest/datasources/prometheus/configure/),
[import dans Grafana](https://grafana.com/docs/grafana/latest/visualizations/dashboards/build-dashboards/import-dashboards/).
