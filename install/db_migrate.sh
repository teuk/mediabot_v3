#!/bin/bash
set -e

cd "$(dirname "$0")"
DEPLOY_DIR="$(pwd)"
TARGET_DIR="${DEPLOY_DIR}/mediabot_v3"

CURRENT_HOST=$(hostname -f 2>/dev/null || hostname)
CURRENT_USER=$(id -un)

# +-------------------------------------------------------------------------+
# | [1] Numéro de version suivant                                           |
# +-------------------------------------------------------------------------+
LAST_VER=$(ls -d mediabot_v3.* 2>/dev/null | sed 's/.*\.//' | sort -n | tail -1 || true)
NEXT_VER=$(( ${LAST_VER:-0} + 1 ))

# +-------------------------------------------------------------------------+
# | [2] Trouver l'instance à arrêter                                        |
# |                                                                         |
# | Stratégie : pour chaque process perl qui charge mediabot.pl,            |
# |   1. extraire la valeur de --conf= (relative ou absolue)                |
# |   2. résoudre son chemin absolu en se plaçant dans le cwd du process    |
# |      (via /proc/<pid>/cwd)                                              |
# |   3. comparer le répertoire parent du conf résolu avec TARGET_DIR       |
# +-------------------------------------------------------------------------+
BOT_PID=""

for PID in $(pgrep -f "mediabot\.pl" 2>/dev/null || true); do
    # Ligne de commande complète du process
    CMDLINE=$(tr '\0' ' ' < /proc/${PID}/cmdline 2>/dev/null || true)
    [ -z "$CMDLINE" ] && continue

    # Extraire la valeur de --conf=
    CONF_ARG=$(echo "$CMDLINE" | grep -oP '(?<=--conf=)\S+' || true)
    [ -z "$CONF_ARG" ] && continue

    # Résoudre le chemin absolu : si relatif, le préfixer avec le cwd du process
    if [[ "$CONF_ARG" = /* ]]; then
        CONF_ABS="$CONF_ARG"
    else
        PROC_CWD=$(readlink -f /proc/${PID}/cwd 2>/dev/null || true)
        [ -z "$PROC_CWD" ] && continue
        CONF_ABS="${PROC_CWD}/${CONF_ARG}"
    fi

    # Résoudre les liens symboliques éventuels
    CONF_REAL=$(readlink -f "$CONF_ABS" 2>/dev/null || echo "$CONF_ABS")

    # Répertoire parent du conf
    CONF_DIR=$(dirname "$CONF_REAL")

    # Comparer avec TARGET_DIR (résolu lui aussi)
    TARGET_REAL=$(readlink -f "$TARGET_DIR" 2>/dev/null || echo "$TARGET_DIR")

    if [ "$CONF_DIR" = "$TARGET_REAL" ]; then
        BOT_PID="$PID"
        echo "🔎 Found matching instance: PID=${PID} conf=${CONF_REAL}"
        break
    fi
done

if [ -n "$BOT_PID" ]; then
    echo "🛑 Sending SIGTERM to PID ${BOT_PID} ..."
    kill -15 "$BOT_PID"

    WAIT=0
    while kill -0 "$BOT_PID" 2>/dev/null; do
        sleep 1
        WAIT=$((WAIT + 1))
        if [ "$WAIT" -ge 30 ]; then
            echo "⚠️  Still alive after 30s — sending SIGKILL ..."
            kill -9 "$BOT_PID" 2>/dev/null || true
            break
        fi
    done
    echo "✅ Bot stopped."
else
    echo "ℹ️  No running mediabot instance found for ${TARGET_DIR}."
fi

# +-------------------------------------------------------------------------+
# | [3] Archiver le répertoire courant                                      |
# +-------------------------------------------------------------------------+
if [ -d "mediabot_v3" ]; then
    echo "📦 Archiving mediabot_v3 → mediabot_v3.${NEXT_VER} ..."
    mv -v mediabot_v3 "mediabot_v3.${NEXT_VER}"
else
    echo "ℹ️  No mediabot_v3 directory to archive."
fi

BACKUP_DIR="${DEPLOY_DIR}/mediabot_v3.${NEXT_VER}"

# +-------------------------------------------------------------------------+
# | [4] Clone depuis GitHub                                                 |
# +-------------------------------------------------------------------------+
echo "🌐 Cloning latest version from GitHub ..."
git clone https://github.com/teuk/mediabot_v3

# +-------------------------------------------------------------------------+
# | [5] Restaurer conf + brain Hailo                                        |
# +-------------------------------------------------------------------------+
echo "⚙️  Restoring config and Hailo brain ..."

if [ -f "${BACKUP_DIR}/mediabot.conf" ]; then
    cp -pfv "${BACKUP_DIR}/mediabot.conf" ./mediabot_v3/
else
    echo "⚠️  Warning: mediabot.conf not found in ${BACKUP_DIR}."
fi

LATEST_BRAIN=$(ls -t mediabot_v3.*/*.brn 2>/dev/null | head -1 || true)
if [ -n "$LATEST_BRAIN" ]; then
    cp -pfv "$LATEST_BRAIN" ./mediabot_v3/
else
    echo "⚠️  Warning: no .brn brain file found in previous versions."
fi

# +-------------------------------------------------------------------------+
# | [6] Validation syntaxe Perl                                             |
# +-------------------------------------------------------------------------+
echo "🔍 Checking Perl syntax ..."
( cd ./mediabot_v3 && perl -c mediabot.pl )

echo ""
echo "✅ Deploy complete. Run: cd mediabot_v3 && ./start"
