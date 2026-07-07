#!/usr/bin/env bash
# =============================================================================
#  t/live/a2_matrix.sh — Orchestrateur de la matrice live « A2 » (direction 3.3)
# =============================================================================
#  Enchaîne, contre une instance JETABLE du bot (jamais la prod), les trois
#  volets de la matrice A2 de la direction 3.3 :
#
#    1. Cas fonctionnels live (t/test_live.pl, closures t/live/*.t) :
#         core smoke, auth, dispatch, channel/user, quotes, external, db,
#         ignores, jeux, ET les nouveaux domaines A2 :
#           16 karma · 17 trivia · 18 notes · 19 reminders ·
#           20 radio · 21 ai · 22 url parsers
#       Le partyline restart (13) couvre les DEUX coupures + reconnexion.
#       Le die_last (99) tue le bot proprement en fin de parcours.
#
#    2. Cycle de vie (t/live/lifecycle_check.sh) :
#         arrêt propre SIGTERM · PID supprimé · double instance refusée ·
#         redémarrage opérationnel, le tout sur DEUX cycles.
#
#  Ce script NE crée PAS la base ni la conf : il délègue au runner Perl, qui
#  provisionne `mediabot_test`. Le lifecycle réutilise cette base.
#
#  Rien ici ne touche VERSION, commit.sh, ni la configuration privée : c'est un
#  outil de VALIDATION avant RC, pas une étape de publication.
#
#  Usage (sur teuk.org, environnement Perl réel + Crypt::Bcrypt) :
#    t/live/a2_matrix.sh --server 127.0.0.1 --port 6667 \
#                        --channel '#mbtest' --dbuser mediabot_test
#
#  Options (transmises telles quelles au runner et au lifecycle) :
#    --server <host>     Serveur IRC de test        (défaut: 127.0.0.1)
#    --port <port>       Port IRC                    (défaut: 6667)
#    --channel <chan>    Canal de test              (défaut: #mbtest)
#    --dbuser <user>     Utilisateur MariaDB        (défaut: mediabot_test)
#    --dbpass <pass>     Mot de passe MariaDB        (optionnel)
#    --verbose           Sortie détaillée du runner
#    --skip-lifecycle    Ne lancer que les cas fonctionnels
#    --skip-functional   Ne lancer que le cycle de vie
#    --keep-db           Conserver la base après les cas fonctionnels
# =============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

SERVER="127.0.0.1"
PORT="6667"
CHANNEL="#mbtest"
DBUSER="mediabot_test"
DBPASS=""
VERBOSE=""
SKIP_LIFECYCLE=0
SKIP_FUNCTIONAL=0
KEEP_DB=0

while [ $# -gt 0 ]; do
    case "$1" in
        --server)         SERVER="$2";  shift 2 ;;
        --port)           PORT="$2";    shift 2 ;;
        --channel)        CHANNEL="$2"; shift 2 ;;
        --dbuser)         DBUSER="$2";  shift 2 ;;
        --dbpass)         DBPASS="$2";  shift 2 ;;
        --verbose|-v)     VERBOSE="--verbose"; shift ;;
        --skip-lifecycle) SKIP_LIFECYCLE=1; shift ;;
        --skip-functional)SKIP_FUNCTIONAL=1; shift ;;
        --keep-db)        KEEP_DB=1; shift ;;
        -h|--help)
            sed -n '2,50p' "$0"; exit 0 ;;
        *)
            echo "Option inconnue: $1" >&2; exit 2 ;;
    esac
done

ts() { date +'%d/%m/%Y %H:%M:%S'; }
say() { printf '[%s] %s\n' "$(ts)" "$*"; }
hr()  { printf '=%.0s' {1..78}; printf '\n'; }

RC_FUNCTIONAL=0
RC_LIFECYCLE=0

cd "$PROJECT_ROOT" || { echo "Projet introuvable: $PROJECT_ROOT" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Volet 1 — cas fonctionnels live
# ---------------------------------------------------------------------------
if [ "$SKIP_FUNCTIONAL" -eq 0 ]; then
    hr
    say "VOLET 1/2 — Cas fonctionnels live (t/test_live.pl)"
    hr

    KEEP_FLAG=""
    [ "$KEEP_DB" -eq 1 ] && KEEP_FLAG="--keep-db"

    DBPASS_FLAG=""
    [ -n "$DBPASS" ] && DBPASS_FLAG="--dbpass $DBPASS"

    # shellcheck disable=SC2086
    perl t/test_live.pl \
        --server "$SERVER" --port "$PORT" \
        --channel "$CHANNEL" --dbuser "$DBUSER" \
        $DBPASS_FLAG $VERBOSE $KEEP_FLAG
    RC_FUNCTIONAL=$?

    if [ "$RC_FUNCTIONAL" -eq 0 ]; then
        say "Volet fonctionnel : OK"
    else
        say "Volet fonctionnel : ÉCHEC (rc=$RC_FUNCTIONAL)"
    fi
fi

# ---------------------------------------------------------------------------
# Volet 2 — cycle de vie
# ---------------------------------------------------------------------------
if [ "$SKIP_LIFECYCLE" -eq 0 ]; then
    hr
    say "VOLET 2/2 — Cycle de vie (SIGTERM / PID / double instance / restart x2)"
    hr

    if [ ! -x "$SCRIPT_DIR/lifecycle_check.sh" ]; then
        say "lifecycle_check.sh introuvable ou non exécutable — volet ignoré"
        RC_LIFECYCLE=127
    else
        DBPASS_FLAG=""
        [ -n "$DBPASS" ] && DBPASS_FLAG="--dbpass $DBPASS"
        # shellcheck disable=SC2086
        "$SCRIPT_DIR/lifecycle_check.sh" \
            --server "$SERVER" --port "$PORT" \
            --dbuser "$DBUSER" $DBPASS_FLAG
        RC_LIFECYCLE=$?

        if [ "$RC_LIFECYCLE" -eq 0 ]; then
            say "Volet cycle de vie : OK"
        else
            say "Volet cycle de vie : ÉCHEC (rc=$RC_LIFECYCLE)"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Synthèse
# ---------------------------------------------------------------------------
hr
say "SYNTHÈSE MATRICE A2"
[ "$SKIP_FUNCTIONAL" -eq 0 ] && say "  fonctionnel : $([ $RC_FUNCTIONAL -eq 0 ] && echo OK || echo ÉCHEC)"
[ "$SKIP_LIFECYCLE"  -eq 0 ] && say "  cycle de vie : $([ $RC_LIFECYCLE -eq 0 ] && echo OK || echo ÉCHEC)"
hr

if [ "$RC_FUNCTIONAL" -ne 0 ] || [ "$RC_LIFECYCLE" -ne 0 ]; then
    exit 1
fi
say "Matrice A2 : toutes les validations sont vertes."
exit 0
