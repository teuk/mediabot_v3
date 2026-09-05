# Audit de sécurité transversal — B3 et MB724

Le contrôle historique B3 de la RC 3.3 reste le socle. MB724 l'étend à toute
la surface acceptée pour 3.5 : bot IRC, Partyline/DCC, scripts, workers,
fournisseurs IA, Hailo, métriques, updater, systemd et mbweb.

## Outil

`tools/security_audit.pl` lit uniquement l'arbre source. Il n'exécute aucune
fonction applicative, ne contacte aucun service et ne lit aucune configuration
privée. Chaque défaut produit **NO-GO (exit 1)**. `--warn-only` est réservé à
l'exploration et n'est jamais une preuve d'acceptation.

Les 37 invariants sont regroupés en 16 axes :

1. secrets absents des logs et tokens DCC masqués ;
2. TLS vérifié par défaut et unique exception Icecast explicitement bornée ;
3. commandes externes sans shell implicite et arguments yt-dlp protégés ;
4. neutralisation CR/LF/NUL avant émission IRC ;
5. verrou exclusif non bloquant d'instance ;
6. taille des téléchargements HTTP bornée ;
7. throttles de connexion IRC et Partyline ;
8. workers et ScriptRunner bornés en temps, entrées, sorties et terminaison ;
9. transport IA limité à HTTPS, TLS vérifié, timeout et réponse de 1 Mio ;
10. cerveaux Hailo isolés par réseau/canal, fallback local et late gate ;
11. métriques agrégées sur loopback, sans prompt, contexte, brouillon ni réponse ;
12. commandes Partyline, updater et délégation Fullop fail-closed ;
13. identités systemd et chemins inscriptibles minimaux ;
14. rollback IRC/mbweb et exclusion du matériel privé des archives publiques ;
15. sessions MySQL, CSRF, corps HTTP, listener et upstreams mbweb bornés ;
16. diagnostic DB forcé en lecture seule contre types, index et référence SQL.

## Usage source

```bash
cd /home/mediabot/mediabot_v3
perl tools/security_audit.pl
echo "SECURITY_AUDIT_RC=$?"
```

Options : `--root DIR`, `--quiet` et `--warn-only`.

## Exercice opérationnel MB724

Le résultat source ne suffit pas à fermer MB724. Le déploiement supporté
prouve également, en lecture seule :

- les unités IRC et mbweb actives sous l'identité attendue ;
- mbweb local et HTTPS sain, sans dépendance de vie du bot IRC ;
- l'endpoint métriques limité à l'adresse configurée ;
- le diagnostic Doctor exécuté avec session DB read-only et son verdict borné ;
- le manifeste source exact et le checkpoint MB723-D R9 ;
- une preuve récente de déploiement, rollback et redéploiement mbweb ;
- l'absence de changement de PID/état des services, de grants et de fichiers
  privés pendant l'exercice.

Le rapport opérationnel contient uniquement des digests, états systemd,
compteurs et verdicts. Il ne copie ni secret, ni conversation, ni cookie, ni
contenu de sauvegarde root.

MB724 n'absorbe pas MB719 : un écart de schéma déjà connu reste un résultat
MB719 et n'est ni corrigé ni requalifié ici. MB724 exige que Doctor ait imposé
la session read-only et enregistre seulement le nombre de constats par niveau.

## Limite de preuve

Cet audit est un contrat de non-régression ciblé, pas un scanner universel.
MB719 reste l'autorité de mutation/restauration du schéma de production ;
MB726 reste l'autorité de reproduction des archives de release ; MB725 garde
les répétitions d'installation et de mise à niveau. La full suite reste réservée
au commit final imminent et au candidat de release, conformément à la roadmap.
