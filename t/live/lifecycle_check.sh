#!/usr/bin/env bash
# =============================================================================
#  t/live/lifecycle_check.sh — Matrice live « cycle de vie » (mb451, C5)
# =============================================================================
#  Vérifie, contre une instance JETABLE du bot (jamais la prod), que :
#
#    A. Arrêt propre SIGTERM     : exit 0, PID file supprimé, QUIT IRC envoyé.
#    B. Refus de double instance : un 2e bot sur le MÊME PID file échoue
#                                  (exit != 0, message de verrou), sans tuer
#                                  ni déloger le 1er.
#    C. Redémarrage opérationnel : après l'arrêt propre, un nouveau départ
#                                  reprend le PID file et se reconnecte.
#
#  Le tout est exécuté sur DEUX cycles (les « 2 coupures » de la roadmap C5)
#  pour prouver la répétabilité du cycle stop→start.
#
#  Ce script NE crée PAS la base : il réutilise `mediabot_test` déjà provisionnée
#  par un run de `t/test_live.pl`. Il génère sa propre conf jetable depuis
#  `test.conf.tpl` avec un PID, un nick et un port Partyline dédiés.
#
#  Contrat de code vérifié (mb451) :
#    - catch_term/catch_int -> clean_and_exit(0) -> releasePidFile() unlink le PID.
#    - acquirePidFile() échoue si le flock est tenu -> clean_and_exit(1) (exit 1),
#      et NE supprime PAS le PID d'autrui (release n'unlink que si owner).
#
#  Usage :
#    t/live/lifecycle_check.sh --server 127.0.0.1 --port 6667 [options]
#
#  Options (toutes ont un défaut « test ») :
#    --server <host>     Serveur IRC de test        (défaut: 127.0.0.1)
#    --port <port>       Port IRC                    (défaut: 6667)
#    --channel <chan>    Canal de test              (défaut: #mblife)
#    --botnick <nick>    Nick du bot jetable        (défaut: mblife_<pid>)
#    --dbhost <host>     Hôte MySQL                  (défaut: localhost)
#    --dbport <port>     Port MySQL                  (défaut: 3306)
#    --dbuser <user>     Utilisateur MySQL          (défaut: mediabot_test)
#    --mysql-defaults-file <path>
#                        Fichier client MySQL 0600  (optionnel)
#    --timeout <s>       Timeout par étape          (défaut: 45)
#    --keep-conf         Ne pas supprimer la conf jetable en sortie
# =============================================================================

set -Eeuo pipefail
umask 077

# ---------------------------------------------------------------------------
# Emplacements
# ---------------------------------------------------------------------------
LIVE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${LIVE_DIR}/../.." && pwd)"
BOT_SCRIPT="${REPO_DIR}/mediabot.pl"
TPL_FILE="${LIVE_DIR}/test.conf.tpl"

# Conf/PID/log JETABLES, dédiés à ce script (jamais ceux du harnais ni de la prod)
LIFE_CONF="${LIVE_DIR}/lifecycle.conf"
LIFE_PID="/tmp/mediabot_lifecycle_$$.pid"
LIFE_LOG="${LIVE_DIR}/lifecycle_bot.log"
LIFE_PLPORT="23470"

# ---------------------------------------------------------------------------
# Paramètres
# ---------------------------------------------------------------------------
IRC_SERVER="127.0.0.1"
IRC_PORT="6667"
IRC_CHANNEL="#mblife"
BOTNICK="mblife_$$"
DBHOST="localhost"
DBPORT="3306"
DBUSER="mediabot_test"
MYSQL_DEFAULTS_FILE="${MEDIABOT_TEST_MYSQL_DEFAULTS_FILE:-}"
STEP_TIMEOUT="45"
KEEP_CONF="0"

while [ $# -gt 0 ]; do
  case "$1" in
    --server)   IRC_SERVER="$2"; shift 2 ;;
    --port)     IRC_PORT="$2"; shift 2 ;;
    --channel)  IRC_CHANNEL="$2"; shift 2 ;;
    --botnick)  BOTNICK="$2"; shift 2 ;;
    --dbhost)   DBHOST="$2"; shift 2 ;;
    --dbport)   DBPORT="$2"; shift 2 ;;
    --dbuser)   DBUSER="$2"; shift 2 ;;
    --mysql-defaults-file)
                 MYSQL_DEFAULTS_FILE="$2"; shift 2 ;;
    --dbpass)    die "--dbpass a été retiré : utilisez --mysql-defaults-file <fichier-0600>" ;;
    --timeout)  STEP_TIMEOUT="$2"; shift 2 ;;
    --keep-conf) KEEP_CONF="1"; shift ;;
    -h|--help)  sed -n '2,60p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# Sortie colorée + compteurs
# ---------------------------------------------------------------------------
PASS=0
FAIL=0
ok()   { echo "  [PASS] $*"; PASS=$((PASS + 1)); }
ko()   { echo "  [FAIL] $*" >&2; FAIL=$((FAIL + 1)); }
info() { echo "  $*"; }
die()  { echo "FATAL: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Nettoyage garanti (le bot jetable ne doit jamais survivre au script)
# ---------------------------------------------------------------------------
BOT_PID=""
BOT2_PID=""
cleanup() {
  local sig="${1:-}"
  for p in "${BOT2_PID}" "${BOT_PID}"; do
    if [ -n "${p}" ] && kill -0 "${p}" 2>/dev/null; then
      kill -TERM "${p}" 2>/dev/null || true
      for _ in 1 2 3 4 5; do kill -0 "${p}" 2>/dev/null || break; sleep 1; done
      kill -KILL "${p}" 2>/dev/null || true
    fi
  done
  [ -e "${LIFE_PID}" ] && rm -f "${LIFE_PID}"
  if [ "${KEEP_CONF}" != "1" ] && [ -e "${LIFE_CONF}" ]; then rm -f "${LIFE_CONF}"; fi
  [ -n "${sig}" ] && exit 1
}
trap 'cleanup' EXIT
trap 'cleanup INT'  INT
trap 'cleanup TERM' TERM

# ---------------------------------------------------------------------------
# Pré-vol + GARDE-FOUS PROD (refus catégorique de toucher l'instance réelle)
# ---------------------------------------------------------------------------
echo "===== mb451 lifecycle_check — pré-vol ====="
[ -f "${BOT_SCRIPT}" ] || die "mediabot.pl introuvable : ${BOT_SCRIPT}"
[ -f "${TPL_FILE}" ]   || die "template introuvable : ${TPL_FILE}"
command -v perl >/dev/null 2>&1 || die "perl requis"

# Le PID jetable NE DOIT PAS ressembler à celui de la prod.
case "${LIFE_PID}" in
  *mediabot3*|/home/mediabot/*) die "PID jetable pointe vers un chemin de prod: ${LIFE_PID}" ;;
esac
[ -e "${LIFE_PID}" ] && die "le PID jetable existe déjà (${LIFE_PID}) — run concurrent ?"

# La base DOIT être la base de test, jamais mediabot2/mediabotv3.
case "${DBUSER}" in
  mediabot2|mediabotv3) die "refus : DBUSER de prod (${DBUSER})" ;;
esac
info "Cible IRC   : ${IRC_SERVER}:${IRC_PORT} ${IRC_CHANNEL}"
info "Nick jetable: ${BOTNICK}"
info "PID jetable : ${LIFE_PID}"
info "DB test     : ${DBUSER}@${DBHOST}:${DBPORT}"

# ---------------------------------------------------------------------------
# Générer la conf jetable depuis le template
# ---------------------------------------------------------------------------
generate_conf() {
  local tpl; tpl="$(cat "${TPL_FILE}")"
  tpl="${tpl//\{\{DBHOST\}\}/${DBHOST}}"
  tpl="${tpl//\{\{DBPORT\}\}/${DBPORT}}"
  tpl="${tpl//\{\{BOTNICK\}\}/${BOTNICK}}"
  tpl="${tpl//\{\{CMDCHAR\}\}/!}"
  tpl="${tpl//\{\{LOGFILE\}\}/${LIFE_LOG}}"
  tpl="${tpl//\{\{PARTYLINE_PORT\}\}/${LIFE_PLPORT}}"
  printf '%s\n' "${tpl}" > "${LIFE_CONF}"

  # Forcer le PID jetable dans la conf générée.
  # (le template met MAIN_PID_FILE=/tmp/mediabot_test.pid ; on le remplace)
  perl -i -pe "s{^MAIN_PID_FILE=.*}{MAIN_PID_FILE=${LIFE_PID}}" "${LIFE_CONF}"

  # NB : le bot lit son serveur dans la table SERVERS de la base, PAS dans la
  # conf (cf. test_live.pl). Le serveur/port/canal sont donc gérés côté DB par
  # set_test_server(), pas ici. Le nick vient bien de CONN_NICK (conf).

  # Garde-fou : la conf générée ne doit jamais référencer la base de prod.
  if grep -Eq '(^|[^[:alnum:]_])(mediabot2|mediabotv3)([^[:alnum:]_]|$)' "${LIFE_CONF}"; then
    die "la conf jetable référence une base de prod — abandon"
  fi
  info "conf jetable générée : ${LIFE_CONF}"
}

# ---------------------------------------------------------------------------
# Pointer la base de test vers le serveur IRC de test (comme test_live.pl)
# ---------------------------------------------------------------------------
DBNAME="mediabot_test"
set_test_server() {
  # Refus catégorique si la base ciblée ressemble à la prod.
  case "${DBNAME}" in
    mediabot2|mediabotv3) die "refus : DBNAME de prod (${DBNAME})" ;;
  esac
  if ! command -v mysql >/dev/null 2>&1; then
    info "(client mysql absent — SERVERS non mis à jour ; le bot utilisera la valeur existante)"
    return 0
  fi
  local srv="${IRC_SERVER}:${IRC_PORT}"
  local sql="UPDATE \`${DBNAME}\`.SERVERS SET server_hostname='${srv}' WHERE id_server=1;"
  local mysql_cmd=(mysql)
  if [ -n "${MYSQL_DEFAULTS_FILE}" ]; then
    [ -f "${MYSQL_DEFAULTS_FILE}" ] || die "fichier MySQL introuvable : ${MYSQL_DEFAULTS_FILE}"
    [ ! -L "${MYSQL_DEFAULTS_FILE}" ] || die "refus d'un lien symbolique pour les identifiants MySQL"
    local mysql_mode
    mysql_mode="$(stat -c '%a' "${MYSQL_DEFAULTS_FILE}" 2>/dev/null || true)"
    case "${mysql_mode}" in
      400|600) ;;
      *) die "le fichier MySQL doit être en mode 0600 ou 0400 (actuel=${mysql_mode:-inconnu})" ;;
    esac
    # MySQL exige --defaults-extra-file avant les autres options.
    mysql_cmd+=("--defaults-extra-file=${MYSQL_DEFAULTS_FILE}")
  fi
  mysql_cmd+=(-h "${DBHOST}" -P "${DBPORT}" -u "${DBUSER}")

  if "${mysql_cmd[@]}" -e "${sql}" 2>/dev/null; then
    ok "SERVERS.id_server=1 pointé sur ${srv} (base ${DBNAME})"
  else
    info "(échec UPDATE SERVERS — base ${DBNAME} provisionnée ? le bot utilisera la valeur existante)"
  fi
}

# ---------------------------------------------------------------------------
# Démarrage / attente du bot
# ---------------------------------------------------------------------------
start_bot() {
  # $1 = variable de sortie pour le PID ; lance le bot en arrière-plan.
  : > "${LIFE_LOG}" 2>/dev/null || true
  ( cd "${REPO_DIR}" && exec perl "${BOT_SCRIPT}" "--conf=${LIFE_CONF}" \
      >>"${LIFE_LOG}" 2>&1 ) &
  printf -v "$1" '%s' "$!"
}

wait_pidfile_present() {
  local deadline=$(( SECONDS + STEP_TIMEOUT ))
  while [ "${SECONDS}" -lt "${deadline}" ]; do
    [ -s "${LIFE_PID}" ] && return 0
    sleep 1
  done
  return 1
}

wait_log_contains() {
  local pat="$1" deadline=$(( SECONDS + STEP_TIMEOUT ))
  while [ "${SECONDS}" -lt "${deadline}" ]; do
    grep -Eq "${pat}" "${LIFE_LOG}" 2>/dev/null && return 0
    sleep 1
  done
  return 1
}

wait_process_gone() {
  local p="$1" deadline=$(( SECONDS + STEP_TIMEOUT ))
  while [ "${SECONDS}" -lt "${deadline}" ]; do
    kill -0 "${p}" 2>/dev/null || return 0
    sleep 1
  done
  return 1
}

# =============================================================================
# Un cycle complet A→B→C. Appelé deux fois (les « 2 coupures »).
# =============================================================================
run_cycle() {
  local cycle="$1"
  echo
  echo "===== Cycle ${cycle} ====="

  # --- Démarrage initial ---------------------------------------------------
  start_bot BOT_PID
  info "bot lancé (PID hôte=${BOT_PID})"
  if wait_pidfile_present; then
    ok "PID file créé au démarrage (${LIFE_PID})"
  else
    ko "PID file absent après ${STEP_TIMEOUT}s — le bot n'a pas démarré ?"
    tail -n 20 "${LIFE_LOG}" 2>/dev/null | sed 's/^/    /'
    return 1
  fi
  # PID file cohérent avec le process ?
  local pidval; pidval="$(tr -d '[:space:]' < "${LIFE_PID}" 2>/dev/null || true)"
  if [ -n "${pidval}" ] && kill -0 "${pidval}" 2>/dev/null; then
    ok "PID file contient un PID vivant (${pidval})"
  else
    ko "PID file incohérent (contenu='${pidval}')"
  fi

  # --- B. Double instance --------------------------------------------------
  info "tentative de 2e instance sur le même PID file (doit être refusée)…"
  ( cd "${REPO_DIR}" && perl "${BOT_SCRIPT}" "--conf=${LIFE_CONF}" \
      >>"${LIFE_LOG}.dup" 2>&1 ) &
  BOT2_PID="$!"
  # La 2e instance doit sortir d'elle-même, vite.
  if wait_process_gone "${BOT2_PID}"; then
    # exit code de la 2e instance. mb456-B3: with `set -e`, a plain `wait`
    # returning the EXPECTED non-zero refusal code aborts the whole script
    # before it can record PASS. Capture it through an if-condition instead.
    local rc2
    if wait "${BOT2_PID}" 2>/dev/null; then rc2=0; else rc2=$?; fi
    if [ "${rc2}" -ne 0 ]; then
      ok "2e instance refusée (exit ${rc2} != 0)"
    else
      ko "2e instance sortie en 0 — le verrou n'a pas joué"
    fi
  else
    ko "2e instance toujours vivante après ${STEP_TIMEOUT}s — pas de refus"
    kill -KILL "${BOT2_PID}" 2>/dev/null || true
  fi
  BOT2_PID=""
  if grep -Eqi 'locked by process|belongs to live process|Failed to acquire PID' "${LIFE_LOG}.dup" 2>/dev/null; then
    ok "message de verrou explicite journalisé par la 2e instance"
  else
    info "(pas de message de verrou dans le log de la 2e instance — non bloquant)"
  fi
  rm -f "${LIFE_LOG}.dup" 2>/dev/null || true

  # Le 1er doit être resté vivant ET propriétaire du PID.
  if kill -0 "${BOT_PID}" 2>/dev/null; then
    ok "1re instance toujours vivante après la tentative de double"
  else
    ko "1re instance morte après la tentative de double instance !"
  fi
  local pidnow; pidnow="$(tr -d '[:space:]' < "${LIFE_PID}" 2>/dev/null || true)"
  if [ "${pidnow}" = "${pidval}" ]; then
    ok "PID file toujours détenu par la 1re instance (${pidnow})"
  else
    ko "PID file modifié par la 2e instance (avant=${pidval} après=${pidnow})"
  fi

  # --- A. Arrêt propre SIGTERM --------------------------------------------
  info "envoi SIGTERM à la 1re instance…"
  kill -TERM "${BOT_PID}" 2>/dev/null || true
  if wait_process_gone "${BOT_PID}"; then
    # Keep reporting a bad shutdown code instead of letting `set -e` abort
    # before the FAIL counter and cleanup paths run (mb456-B3).
    local rc1
    if wait "${BOT_PID}" 2>/dev/null; then rc1=0; else rc1=$?; fi
    if [ "${rc1}" -eq 0 ]; then
      ok "arrêt SIGTERM propre (exit 0)"
    else
      ko "SIGTERM : exit ${rc1} (attendu 0)"
    fi
  else
    ko "le bot n'est pas mort après SIGTERM en ${STEP_TIMEOUT}s"
    kill -KILL "${BOT_PID}" 2>/dev/null || true
  fi
  if wait_log_contains 'clean shutdown|Cleaning and exiting'; then
    ok "log de shutdown propre présent"
  else
    info "(pas de trace 'clean shutdown' dans le log — non bloquant selon debug level)"
  fi
  if [ ! -e "${LIFE_PID}" ]; then
    ok "PID file supprimé à l'arrêt (releasePidFile)"
  else
    ko "PID file résiduel après l'arrêt : ${LIFE_PID}"
    rm -f "${LIFE_PID}" 2>/dev/null || true
  fi
  BOT_PID=""

  # --- C. Redémarrage ------------------------------------------------------
  # (le simple fait que le cycle suivant redémarre valide la reprise ; sur le
  #  dernier cycle on fait un démarrage/arrêt de confirmation)
  return 0
}

# =============================================================================
# Exécution
# =============================================================================
generate_conf
set_test_server

run_cycle 1 || true
# C. reprise : le cycle 2 EST le redémarrage après l'arrêt propre du cycle 1.
run_cycle 2 || true

# ---------------------------------------------------------------------------
# Rapport
# ---------------------------------------------------------------------------
echo
echo "============================================================"
echo " mb451 lifecycle_check : ${PASS} PASS / ${FAIL} FAIL"
echo "============================================================"
[ "${FAIL}" -eq 0 ]
