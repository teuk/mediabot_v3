# MB1076 — Éviter le retour des logs dans leurs propres callbacks console

Base : snap_mediabot_v3_teuk_20261102_165107.zip.
VERSION : 3.8dev-20261102_141856. Les 389 chemins précédemment qualifiés
correspondent à MB1075 final ; tous les correctifs antérieurs sont conservés.

## Défaut

Log::log écrivait dans stdout et le fichier, puis appelait les hooks console.
Si un hook, un transport instrumenté ou son gestionnaire d'exception appelait
à nouveau le même logger, le nouvel événement repartait dans les mêmes hooks.
Un callback qui journalise chaque envoi pouvait ainsi produire une récursion
non bornée et une cascade de messages au lieu de terminer l'envoi initial.

## Correction

Un état local à l'appel et à l'instance protège uniquement la redistribution
aux hooks. Les messages imbriqués suivent les mêmes filtres de niveau et sont
écrits normalement dans stdout et le fichier. Ils ne sont pas réinjectés dans
les consoles pendant leur propre redistribution. La portée dynamique restaure
l'état à la fin, y compris quand un callback lève une exception.

Il n'y a ni file supplémentaire, ni tâche différée, ni attente ou verrou. Les
records ordinaires suivants retrouvent la redistribution normale. Un autre
logger conserve ses propres hooks. Les erreurs de callbacks restent contenues
comme avant ; les autres hooks reçoivent l'événement initial. Niveaux, API de
retrait, dates, formats, Unicode, rotation et reopen sont inchangés.
Le mode shell conserve ses propres filtres console et broadcast existants.

## Tests natifs

Le cas 1254 existant garde les scénarios réels de rotation/reopen, fichier
actif conservé sur erreur, diagnostics bornés, filtrage, Unicode et reprise.
Les trois assertions par tentative d'échec de rotation sont regroupées en
une (deux tentatives, quatre assertions de moins). Les deux vérifications
console/warning d'un record filtré sont regroupées (une de moins).
Toutes les conditions sont conservées, sans comparer le texte du code.

Trois nouvelles assertions utilisent le vrai Log, ses hooks et un vrai fichier :
- deux hooks qui journalisent chacun leur propre envoi, avec contrôle du
  contenu UTF-8 exact et unique dans stdout/fichier et dans chaque hook ;
- deux loggers dont les callbacks s'appellent mutuellement, avec conservation
  de la redistribution propre au second logger et arrêt du cycle au retour ;
- callback qui journalise puis lève un objet, gestionnaire __DIE__ qui journalise,
  autre hook toujours actif, retrait du hook fautif, filtrage et envoi suivant.

Le compteur de sécurité des callbacks de test borne seulement l'ancienne
implémentation pendant la contre-épreuve ; il ne simule pas la garde ajoutée.
25 assertions au lieu de 27 : deux de moins, aucun nouveau cas ni délai.
QUALIFICATION.md du paquet donne les mesures locales et leurs limites.

## Exploitation

Aucun schéma, donnée persistante, dépendance ou configuration à modifier.
VERSION, README racine, commit.sh privé, runner/ETA, radio, YouTube, minuteurs
MB1075 et correctifs antérieurs sont conservés.

Le paquet contrôle les contenus exacts avant/après et les anciens changements
qualifiés en attente. Full visible --progress/ETA sans redirection, audits,
inventaire et whitespace avant staging/restart. Ensuite dev seul, nouveau PID
stable dix secondes, commit.sh natif interactif --skip-preflight, VERSION
3.8dev automatique. Un PID stable ne prouve pas la reconnexion IRC.
