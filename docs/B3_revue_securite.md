# Procédure B3 — Revue de sécurité finale (RC 3.3)

Direction 3.3, Phase B, jalon **B3**. Objectif : garantir, avant de créer le tag
RC, qu'aucun invariant de sécurité du bot n'a régressé.

## L'outil : `tools/security_audit.pl`

Audit en LECTURE de source (n'exécute rien, ne contacte rien). Chaque contrôle
cible un invariant réel déjà tenu par le code ; si un refactor le casse, l'audit
sort en **NO-GO (exit 1)**, ce qui bloque la RC.

Les 7 axes correspondent à la liste B3 de la direction :

1. **Secrets jamais loggés** — aucun `log()` n'interpole une clé API/DBPASS en
   clair ; les tokens DCC passent par le masqueur `_dcc_token_hint`.
2. **TLS des API authentifiées** — `_make_http` laisse `verify_SSL`
   configurable (défaut 0 pour la compat OVH/Kimsufi), MAIS tout appel vers une
   API authentifiée (OpenAI, Claude, TMDB) force `verify_SSL => 1`.
3. **Commandes externes sans shell** — yt-dlp lancé via `exec @cmd` (forme
   LIST), requête utilisateur précédée de `'--'` (mb417-B1, anti-injection
   d'options) ; aucun `system`/`exec` string interpolé ni backticks.
4. **Sanitisation CR/LF/NUL** — neutralisation des séquences de contrôle avant
   écriture sur le fil IRC.
5. **Verrou de process** — `flock(LOCK_EX|LOCK_NB)` sur le PID file (refuse une
   seconde instance).
6. **Limites HTTP** — cap de taille (`max_size`) dans les fetchers YouTube et
   URL.
7. **Throttle d'authentification** — garde anti-brute-force sur les DEUX
   chemins de login (IRC et Partyline).

## Usage

```bash
cd ~/mediabot_v3
perl tools/security_audit.pl
echo "exit=$?"   # 0 = GO, 1 = NO-GO
```

Options : `--root DIR` (auditer un autre arbre), `--warn-only` (rétrograder les
défauts en avertissements, pour explorer sans bloquer), `--quiet`.

## Matrice de détection (validée hors-ligne)

En fabriquant des arbres volontairement cassés, chaque régression est bien
attrapée :

| Invariant cassé | Verdict |
|---|---|
| Arbre sain | GO (exit 0) |
| Clé API loggée en clair | NO-GO (exit 1) |
| flock non exclusif (double instance) | NO-GO (exit 1) |
| Throttle login retiré | NO-GO (exit 1) |
| `verify_SSL=0` sur API authentifiée | NO-GO (exit 1) |
| Guard `--` yt-dlp retiré | NO-GO (exit 1) |

## Place dans la RC

À lancer dans le cadre du jalon B3, avant de créer le tag. Un NO-GO est un
critère No-Go de la direction (« régression auth/Partyline », « secrets
loggés »). Le test offline `t/cases/682_mb471_security_audit.t` garde en plus
l'invariant « l'arbre réel reste GO » à chaque exécution de la suite.

## Note

L'audit vérifie des invariants ciblés, pas une couverture exhaustive de toute
surface d'attaque. Il complète — sans les remplacer — la revue manuelle des
points B3 (permissions fichiers, arguments yt-dlp au cas par cas, limites de
lignes/rate limits applicatives) que Christophe mène sur l'instance réelle.
