# Apple Music → Spotify / YouTube

`+AppleMusicFallback` ajoute des liens directs vers le morceau correspondant
sur Spotify et YouTube lorsqu'un lien de morceau Apple Music est collé.
Le titre AppleMusic habituel arrive en premier. Chaque service ajoute ensuite
au plus une ligne courte, avec son badge habituel, l'artiste, le titre et le lien.

Exemple (les badges conservent leurs couleurs IRC) :

```text
(Listener) [AppleMusic] Nuit étoilée - by Björk 星 - 3m 33s
(Listener) [Spotify] Björk 星 — Nuit étoilée · https://open.spotify.com/track/…
(Listener) [YouTube] Björk 星 — Nuit étoilée · https://www.youtube.com/watch?v=…
```

L'ordre des deux liens dépend du service qui répond en premier. Le fond fixe
reste limité aux badges historiques ; le texte et les URL utilisent le thème
du client, avec RESET avant le texte et en fin de ligne. Les lignes tiennent
dans 400 octets UTF-8, sans couper un caractère ni l'URL. `+NoColors`, les mots
interdits et l'anti-flood continuent de passer par la sortie IRC commune.
Une sortie refusée par l'anti-flood n'est pas remise dans une file retardée.

## Activation

Depuis un compte authentifié Administrator ou autorisé au niveau 450 du salon :

```text
!chanset #salon +AppleMusic
!chanset #salon +AppleMusicFallback
```

L'activation de `AppleMusic` reste nécessaire pour traiter le lien d'origine.
Les sorties additionnelles sont autorisées par `AppleMusicFallback` lui-même :
il n'est pas nécessaire d'activer les traitements autonomes de liens Spotify
ou YouTube. Les réponses du bot ne sont pas réinjectées dans le routeur d'URL.

Le nouveau chanset est **désactivé par défaut**, y compris si son entrée n'existe
pas encore dans `CHANSET_LIST`. La première commande explicite et autorisée
`+AppleMusicFallback` inscrit cette seule entrée dans le catalogue existant,
puis active le seul salon demandé. Ni l'installation des fichiers ni la lecture
d'un lien n'inscrivent ce chanset. Les sorties gardent leur journalisation
habituelle. Aucun schéma, migration ou champ n'est ajouté.

Désactivation immédiate des nouvelles recherches et des réponses en attente :

```text
!chanset #salon -AppleMusicFallback
```

Une désactivation suivie d'une réactivation ne ressuscite pas les anciennes
réponses. Le transport IRC, la génération du salon lorsqu'elle est disponible,
la politique actuelle et l'époque d'activation sont revérifiés avant l'envoi.
Ces protections concernent les deux nouvelles sorties ; le traitement historique
et l'annonce AppleMusic sont conservés.

## Services et rapprochement

La configuration existante fournit :

| Entrée | Usage |
|---|---|
| `[tavily] API_KEY` | Une recherche web `basic` par plateforme, limitée à son domaine officiel |
| `[main] YOUTUBE_APIKEY` | Métadonnées `videos` des candidats YouTube, sans appel `search.list` |

Les recherches peuvent consommer des crédits Tavily et du quota YouTube.
Aucune nouvelle clé Spotify n'est nécessaire : les métadonnées publiques
Spotify sont récupérées par le collecteur déjà présent. L'absence d'une clé
est signalée lors de l'activation et par l'outil de contrôle. Sans Tavily,
aucune recherche n'est lancée ; sans clé YouTube, Spotify reste utilisable.
La configuration privée n'est jamais réécrite ni affichée.

Le rapprochement part uniquement d'un **identifiant exact de morceau** reconnu
par le lookup iTunes : URL `/song/…/ID`, ou URL d'album contenant `?i=TRACK_ID`.
Un album entier, une playlist, une page HTML de secours ou un titre sans artiste
ou durée n'autorise pas de rapprochement deviné.

* Spotify : titre et artiste concordants après normalisation Unicode/casse/
  ponctuation, durée à trois secondes près, URL directe de piste vérifiée.
  Deux candidats au maximum sont inspectés.
* YouTube : identifiants de vidéos directs, métadonnées du service et durée à
  trois secondes près. Le titre contient l'artiste, ou appartient à son canal
  portant son nom, `Topic` ou `VEVO`. Le suffixe explicite `(Official Audio)` ou
  `(Audio)` est accepté ; les mots de version comme `live`, `cover` ou `remix`
  restent significatifs. Un résultat `Topic` est préféré s'il est disponible.
* Une réponse absente, malformée, ambiguë ou trop différente n'ajoute aucun lien
  pour ce service. L'autre service et l'annonce AppleMusic restent indépendants.

Il s'agit d'une concordance de métadonnées, **pas d'une analyse acoustique ni
d'une preuve d'identité ISRC**. Un catalogue peut publier plusieurs masters sous
les mêmes titre/artiste/durée. À l'inverse, un morceau valide avec une écriture
ou une durée différente peut être écarté. Une indisponibilité ou un quota refusé
ne prouve pas qu'un morceau n'existe pas sur la plateforme.

## Limites et fonctionnement

Les HTTP s'exécutent dans des processus `AsyncWorker`, jamais dans la boucle
IRC pour les nouvelles recherches. Sans boucle compatible, ces ajouts restent
inactifs. Les recherches utilisent HTTPS avec vérification TLS, réponses
bornées à 512 Kio et aucun suivi de redirection authentifiée. Les résultats du
worker sont limités à 4 Kio ; le parent accepte seulement une URL canonique.

| Limite par instance | Valeur |
|---|---:|
| Recherches simultanées | 4 |
| Nouveaux workers par minute | 12, deux pour un nouveau morceau complet |
| Cache de résultats | 128 entrées plateforme/morceau |
| Succès en cache | 1 heure |
| Absence/échec en cache | 2 minutes |
| Doublon d'un morceau dans un même salon | 30 secondes |
| Destinataires d'une recherche partagée | 16 |
| Clés récentes conservées | 256, expiration 30 secondes |
| Délai worker Spotify / YouTube | 35 / 20 secondes |

Les recherches d'un même morceau sont partagées entre salons ; chaque
destinataire conserve ses propres vérifications d'activation et de transport.
Les clés de cache contiennent notamment le storefront, l'identifiant Apple,
l'artiste, le titre et la durée. Une limite atteinte omet l'ajout plutôt que
de bloquer IRC. Le cache Apple historique antérieur à l'activation est rafraîchi
si ses métadonnées exactes de morceau manquent.

## Contrôle sans envoi sur IRC

Par défaut, vérifier uniquement la présence des entrées de configuration :

```bash
perl tools/applemusic_fallback_check.pl --conf mediabot.conf
```

Pour tester les services depuis la machine du bot, en consommant leurs quotas :

```bash
perl tools/applemusic_fallback_check.pl --conf mediabot.conf --live \
  --url 'https://music.apple.com/fr/album/test/100?i=123'
```

Remplacer l'URL d'exemple par un vrai lien de morceau. Le fichier de configuration
doit être lisible en mode `0600`. Le contrôle n'ouvre aucune connexion à la base,
ne change aucun chanset et n'envoie rien sur IRC. Il affiche uniquement les
présences de clés, les métadonnées du morceau et les URL validées. Aucun détail
d'erreur HTTP contenant une clé n'est imprimé. Sortie 0 si tous les contrôles
sélectionnés réussissent, 1 si une clé ou une correspondance manque, 2 pour des
arguments invalides ; les erreurs de précondition interrompent aussi le contrôle.

Références de conception : [Tavily Search](https://docs.tavily.com/documentation/api-reference/endpoint/search),
[Spotify oEmbed](https://developer.spotify.com/documentation/embeds/reference/oembed),
[YouTube videos.list](https://developers.google.com/youtube/v3/docs/videos/list).
L'ancien service public Odesli n'est pas utilisé :
[son API publique a été retirée le 31 juillet 2026](https://linktr.ee/help/en/articles/15201827-sunsetting-the-songlink-odesli-public-api).
