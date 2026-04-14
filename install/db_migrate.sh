#!/bin/bash
# =============================================================================
#  db_migrate.sh — Mediabot v3 database migration
#  Migrates an existing mediabotv3 database to the new schema:
#    - USER_HOSTMASK table (hostmasks extracted from USER.hostmasks)
#    - MP3 table (new)
#    - BIGINT UNSIGNED on all primary/foreign keys
#    - USER.auth: int(11) → TINYINT(1)
#    - USER.*: latin1 → utf8mb4
#    - CHANNEL_LOG.publictext: varchar(400) → TEXT
#    - CHANNEL: + id_user, + notice columns
#    - WEBLOG: - password column
#    - 19 foreign keys added
#    - 12 indexes added
#
#  Usage:
#    sudo ./db_migrate.sh -c /path/to/mediabot.conf
#    sudo ./db_migrate.sh --dbhost localhost --dbport 3306 \
#                         --dbname mediabotv3 --dbuser root
#
#  The script is IDEMPOTENT — safe to run multiple times.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

log()   { echo -e "${GREEN}[$(date +'%d/%m/%Y %H:%M:%S')]${NC} $*"; }
warn()  { echo -e "${YELLOW}[$(date +'%d/%m/%Y %H:%M:%S')] ⚠️  $*${NC}"; }
error() { echo -e "${RED}[$(date +'%d/%m/%Y %H:%M:%S')] ❌ $*${NC}" >&2; exit 1; }
ok()    { echo -e "${GREEN}  ✅ $*${NC}"; }
skip()  { echo -e "${CYAN}  ⏭  $*${NC}"; }

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
CONF_FILE=""
DB_HOST="localhost"
DB_PORT="3306"
DB_NAME=""
DB_USER="root"
DB_PASS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--conf)    CONF_FILE="$2"; shift 2 ;;
        --dbhost)     DB_HOST="$2";   shift 2 ;;
        --dbport)     DB_PORT="$2";   shift 2 ;;
        --dbname)     DB_NAME="$2";   shift 2 ;;
        --dbuser)     DB_USER="$2";   shift 2 ;;
        --dbpass)     DB_PASS="$2";   shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Read config file if provided
# ---------------------------------------------------------------------------
if [[ -n "$CONF_FILE" ]]; then
    [[ -f "$CONF_FILE" ]] || error "Config file not found: $CONF_FILE"
    log "Reading config from $CONF_FILE"
    _get() { grep -E "^\s*$1\s*=" "$CONF_FILE" 2>/dev/null | tail -1 | sed 's/.*=\s*//' | tr -d '\r' || true; }
    [[ -z "$DB_NAME" ]] && DB_NAME=$(_get 'MAIN_PROG_DDBNAME')
    [[ -z "$DB_NAME" ]] && DB_NAME=$(_get 'MAIN_PROG_DBNAME')
    v=$(_get 'MAIN_PROG_DBHOST'); [[ -n "$v" ]] && DB_HOST="${v%%:*}"
    v=$(_get 'MAIN_PROG_DBPORT'); [[ -n "$v" ]] && DB_PORT="$v"
    v=$(_get 'MAIN_PROG_DBUSER'); [[ -n "$v" ]] && DB_USER="$v"
    v=$(_get 'MAIN_PROG_DBPASS'); [[ -n "$v" ]] && DB_PASS="$v"
fi

[[ -z "$DB_NAME" ]] && error "Database name not specified. Use -c mediabot.conf or --dbname."

log "Target: ${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}"

# ---------------------------------------------------------------------------
# MySQL command helper
# ---------------------------------------------------------------------------
MY_ARGS=(-h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER")
[[ -n "$DB_PASS" ]] && MY_ARGS+=(-p"$DB_PASS")

mysql_cmd() {
    mysql "${MY_ARGS[@]}" "$DB_NAME" -e "$1" 2>&1 || true
}
mysql_q() {
    mysql "${MY_ARGS[@]}" "$DB_NAME" -sNe "$1" 2>/dev/null || echo ""
}
col_exists() {
    local tbl="$1" col="$2"
    [[ -n "$(mysql_q "SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='$tbl' AND COLUMN_NAME='$col';")" ]]
}
table_exists() {
    [[ -n "$(mysql_q "SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='$1';")" ]]
}
fk_exists() {
    [[ -n "$(mysql_q "SELECT 1 FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS WHERE TABLE_SCHEMA=DATABASE() AND CONSTRAINT_NAME='$1' AND CONSTRAINT_TYPE='FOREIGN KEY';")" ]]
}
index_exists() {
    [[ -n "$(mysql_q "SELECT 1 FROM INFORMATION_SCHEMA.STATISTICS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='$1' AND INDEX_NAME='$2';")" ]]
}

# ---------------------------------------------------------------------------
# Test connection
# ---------------------------------------------------------------------------
log "Testing database connection..."
mysql_cmd "SELECT 1" > /dev/null || error "Cannot connect to ${DB_NAME}. Check credentials."
ok "Connected to ${DB_NAME}"

# ---------------------------------------------------------------------------
# Backup
# ---------------------------------------------------------------------------
BACKUP_FILE="/tmp/mediabot_pre_migrate_$(date +%Y%m%d_%H%M%S).sql"
log "Creating backup: $BACKUP_FILE"
DUMP_ARGS=("${MY_ARGS[@]}" "$DB_NAME")
mysqldump "${DUMP_ARGS[@]}" -r "$BACKUP_FILE" && ok "Backup saved: $BACKUP_FILE" || warn "Backup failed — continuing anyway"

# ---------------------------------------------------------------------------
mysql_cmd "SET FOREIGN_KEY_CHECKS = 0;"

# ===========================================================================
# P1 — Create USER_HOSTMASK and migrate hostmasks from USER
# ===========================================================================
log "P1 — USER_HOSTMASK table"

if ! table_exists USER_HOSTMASK; then
    mysql_cmd "
    CREATE TABLE \`USER_HOSTMASK\` (
        \`id_user_hostmask\` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
        \`id_user\`          BIGINT UNSIGNED NOT NULL,
        \`hostmask\`         VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL,
        \`created_at\`       DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (\`id_user_hostmask\`),
        KEY \`idx_user_hostmask_id_user\`  (\`id_user\`),
        KEY \`idx_user_hostmask_hostmask\` (\`hostmask\`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;"
    ok "USER_HOSTMASK created"

    # Migrate existing hostmasks (comma-separated) from USER.hostmasks
    if col_exists USER hostmasks; then
        log "  Migrating hostmasks from USER.hostmasks..."
        mysql_cmd "
        INSERT INTO USER_HOSTMASK (id_user, hostmask, created_at)
        SELECT u.id_user,
               TRIM(SUBSTRING_INDEX(SUBSTRING_INDEX(u.hostmasks, ',', n.n), ',', -1)) AS hostmask,
               NOW()
        FROM USER u
        CROSS JOIN (
            SELECT 1 n UNION SELECT 2 UNION SELECT 3
            UNION SELECT 4 UNION SELECT 5
        ) n
        WHERE n.n <= 1 + (LENGTH(u.hostmasks) - LENGTH(REPLACE(u.hostmasks, ',', '')))
          AND TRIM(SUBSTRING_INDEX(SUBSTRING_INDEX(u.hostmasks, ',', n.n), ',', -1)) != ''
          AND u.hostmasks != '';"
        ok "Hostmasks migrated"

        # Rename (keep as legacy, safe to DROP later)
        mysql_cmd "ALTER TABLE \`USER\` CHANGE \`hostmasks\` \`hostmasks_legacy\`
            VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT ''
            COMMENT 'Migrated to USER_HOSTMASK — safe to DROP after validation';" 2>/dev/null || true
        ok "USER.hostmasks renamed to hostmasks_legacy"
    fi
else
    skip "USER_HOSTMASK already exists"
fi

# ===========================================================================
# P2 — Create MP3 table
# ===========================================================================
log "P2 — MP3 table"
if ! table_exists MP3; then
    mysql_cmd "
    CREATE TABLE \`MP3\` (
        \`id_mp3\`     BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
        \`id_user\`    BIGINT UNSIGNED NOT NULL,
        \`id_youtube\` VARCHAR(255) NOT NULL,
        \`folder\`     VARCHAR(255) NOT NULL,
        \`filename\`   VARCHAR(255) NOT NULL,
        \`artist\`     VARCHAR(255) NOT NULL,
        \`title\`      VARCHAR(255) NOT NULL,
        PRIMARY KEY (\`id_mp3\`),
        KEY \`idx_mp3_id_user\` (\`id_user\`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;"
    ok "MP3 created"
else
    skip "MP3 already exists"
fi

# ===========================================================================
# P3 — WEBLOG: drop password column
# ===========================================================================
log "P3 — WEBLOG.password"
if col_exists WEBLOG password; then
    mysql_cmd "ALTER TABLE \`WEBLOG\` DROP COLUMN \`password\`;"
    ok "WEBLOG.password dropped"
else
    skip "WEBLOG.password already removed"
fi

# ===========================================================================
# P4 — CHANNEL_LOG.publictext: varchar(400) → TEXT
# ===========================================================================
log "P4 — CHANNEL_LOG.publictext → TEXT"
TYPE=$(mysql_q "SELECT DATA_TYPE FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='CHANNEL_LOG' AND COLUMN_NAME='publictext';")
if [[ "$TYPE" != "text" ]]; then
    mysql_cmd "ALTER TABLE \`CHANNEL_LOG\` MODIFY \`publictext\` TEXT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL;"
    ok "CHANNEL_LOG.publictext → TEXT"
else
    skip "CHANNEL_LOG.publictext already TEXT"
fi

# ===========================================================================
# P5 — USER: utf8mb4 + auth TINYINT(1)
# ===========================================================================
log "P5 — USER encoding + auth type"
mysql_cmd "
ALTER TABLE \`USER\`
    MODIFY \`nickname\`  VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '',
    MODIFY \`password\`  VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
    MODIFY \`username\`  VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
    MODIFY \`info1\`     VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
    MODIFY \`info2\`     VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
    MODIFY \`auth\`      TINYINT(1) NOT NULL DEFAULT 0;"
ok "USER: utf8mb4 + auth TINYINT(1)"

# ===========================================================================
# P6 — Add CHANNEL.id_user and CHANNEL.notice if missing
# ===========================================================================
log "P6 — CHANNEL new columns"
if ! col_exists CHANNEL id_user; then
    mysql_cmd "ALTER TABLE \`CHANNEL\` ADD COLUMN \`id_user\` BIGINT UNSIGNED DEFAULT NULL;"
    ok "CHANNEL.id_user added"
else
    skip "CHANNEL.id_user already exists"
fi
if ! col_exists CHANNEL notice; then
    mysql_cmd "ALTER TABLE \`CHANNEL\` ADD COLUMN \`notice\` VARCHAR(255) DEFAULT NULL;"
    ok "CHANNEL.notice added"
else
    skip "CHANNEL.notice already exists"
fi

# Fix CHANNEL.topic (NOT NULL → nullable)
mysql_cmd "ALTER TABLE \`CHANNEL\` MODIFY \`topic\` VARCHAR(400) DEFAULT NULL;" 2>/dev/null || true

# ===========================================================================
# P7 — USER_CHANNEL: utf8mb4
# ===========================================================================
log "P7 — USER_CHANNEL encoding"
mysql_cmd "
ALTER TABLE \`USER_CHANNEL\`
    MODIFY \`greet\`    VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
    MODIFY \`automode\` VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT 'NONE';"
ok "USER_CHANNEL: utf8mb4"

# ===========================================================================
# P8 — BIGINT UNSIGNED on all PKs/FKs
# ===========================================================================
log "P8 — BIGINT UNSIGNED migration"

declare -A MODS
MODS["ACTIONS_LOG"]="MODIFY \`id_actions_log\` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, MODIFY \`id_user\` BIGINT UNSIGNED DEFAULT NULL, MODIFY \`id_channel\` BIGINT UNSIGNED DEFAULT NULL"
MODS["BADWORDS"]="MODIFY \`id_badwords\` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, MODIFY \`id_channel\` BIGINT UNSIGNED NOT NULL DEFAULT 0"
MODS["CHANNEL"]="MODIFY \`id_channel\` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT"
MODS["CHANNEL_FLOOD"]="MODIFY \`id_channel_flood\` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, MODIFY \`id_channel\` BIGINT UNSIGNED NOT NULL"
MODS["CHANNEL_LOG"]="MODIFY \`id_channel_log\` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, MODIFY \`id_channel\` BIGINT UNSIGNED DEFAULT NULL"
MODS["CHANNEL_PURGED"]="MODIFY \`id_channel_purged\` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, MODIFY \`id_channel\` BIGINT UNSIGNED NOT NULL"
MODS["CHANNEL_SET"]="MODIFY \`id_channel_set\` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, MODIFY \`id_channel\` BIGINT UNSIGNED NOT NULL, MODIFY \`id_chanset_list\` BIGINT UNSIGNED NOT NULL"
MODS["CHANSET_LIST"]="MODIFY \`id_chanset_list\` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT"
MODS["CONSOLE"]="MODIFY \`id_console\` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, MODIFY \`id_parent\` BIGINT UNSIGNED DEFAULT NULL"
MODS["HAILO_CHANNEL"]="MODIFY \`id_hailo_channel\` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, MODIFY \`id_channel\` BIGINT UNSIGNED NOT NULL"
MODS["HAILO_EXCLUSION_NICK"]="MODIFY \`id_hailo_exclusion_nick\` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT"
MODS["IGNORES"]="MODIFY \`id_ignores\` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, MODIFY \`id_channel\` BIGINT UNSIGNED NOT NULL DEFAULT 0"
MODS["NETWORK"]="MODIFY \`id_network\` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT"
MODS["PUBLIC_COMMANDS"]="MODIFY \`id_public_commands\` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, MODIFY \`id_user\` BIGINT UNSIGNED DEFAULT NULL, MODIFY \`id_public_commands_category\` BIGINT UNSIGNED NOT NULL, MODIFY \`hits\` BIGINT UNSIGNED NOT NULL DEFAULT 0, ADD COLUMN \`active\` TINYINT(1) NOT NULL DEFAULT 1"
MODS["PUBLIC_COMMANDS_CATEGORY"]="MODIFY \`id_public_commands_category\` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT"
MODS["QUOTES"]="MODIFY \`id_quotes\` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, MODIFY \`id_channel\` BIGINT UNSIGNED NOT NULL, MODIFY \`id_user\` BIGINT UNSIGNED NOT NULL"
MODS["RESPONDERS"]="MODIFY \`id_responders\` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, MODIFY \`id_channel\` BIGINT UNSIGNED NOT NULL DEFAULT 0, MODIFY \`chance\` BIGINT UNSIGNED NOT NULL DEFAULT 95, MODIFY \`hits\` BIGINT UNSIGNED NOT NULL DEFAULT 0"
MODS["SERVERS"]="MODIFY \`id_server\` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, MODIFY \`id_network\` BIGINT UNSIGNED NOT NULL"
MODS["TIMERS"]="MODIFY \`id_timers\` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT"
MODS["TIMEZONE"]="MODIFY \`id_timezone\` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT"
MODS["USER"]="MODIFY \`id_user\` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, MODIFY \`id_user_level\` BIGINT UNSIGNED NOT NULL"
MODS["USER_CHANNEL"]="MODIFY \`id_user_channel\` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, MODIFY \`id_user\` BIGINT UNSIGNED NOT NULL, MODIFY \`id_channel\` BIGINT UNSIGNED NOT NULL, MODIFY \`level\` BIGINT UNSIGNED NOT NULL DEFAULT 0"
MODS["USER_LEVEL"]="MODIFY \`id_user_level\` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT"
MODS["WEBLOG"]="MODIFY \`id_weblog\` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT"
MODS["YOMOMMA"]="MODIFY \`id_yomomma\` BIGINT UNSIGNED NOT NULL"
MODS["MP3"]="MODIFY \`id_mp3\` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, MODIFY \`id_user\` BIGINT UNSIGNED NOT NULL"
MODS["USER_HOSTMASK"]="MODIFY \`id_user_hostmask\` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, MODIFY \`id_user\` BIGINT UNSIGNED NOT NULL"

# YOMOMMA : add PK if missing, then MODIFY
if table_exists "YOMOMMA"; then
    HAS_PK=$(mysql_q "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='YOMOMMA' AND CONSTRAINT_TYPE='PRIMARY KEY';")
    if [[ "$HAS_PK" -eq 0 ]]; then
        mysql_cmd "ALTER TABLE \`YOMOMMA\` ADD PRIMARY KEY (\`id_yomomma\`);"
        ok "YOMOMMA: PRIMARY KEY added"
    fi
    mysql_cmd "ALTER TABLE \`YOMOMMA\` MODIFY \`id_yomomma\` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT;"
    ok "YOMOMMA: BIGINT UNSIGNED"
fi

for TBL in "${!MODS[@]}"; do
    if table_exists "$TBL"; then
        mysql_cmd "ALTER TABLE \`${TBL}\` ${MODS[$TBL]};" 2>/dev/null && ok "$TBL: BIGINT UNSIGNED" || warn "$TBL: skipped (check manually)"
    fi
done

# ===========================================================================
# P9 — Indexes
# ===========================================================================
log "P9 — Indexes"

add_index() {
    local tbl="$1" idx_name="$2" cols="$3"
    if ! index_exists "$tbl" "$idx_name"; then
        mysql_cmd "ALTER TABLE \`$tbl\` ADD INDEX \`$idx_name\` ($cols);"
        ok "Index $idx_name on $tbl"
    else
        skip "Index $idx_name already exists"
    fi
}

add_index ACTIONS_LOG      idx_actions_log_user      '`id_user`'
add_index ACTIONS_LOG      idx_actions_log_channel   '`id_channel`'
add_index ACTIONS_LOG      idx_actions_log_ts        '`ts`'
add_index BADWORDS         idx_badwords_channel      '`id_channel`'
add_index CHANNEL          idx_channel_id_user       '`id_user`'
add_index CHANNEL_FLOOD    idx_channel_flood_channel '`id_channel`'
add_index CHANNEL_LOG      idx_channel_log_channel   '`id_channel`'
add_index CHANNEL_SET      idx_channel_set_channel   '`id_channel`'
add_index CHANNEL_SET      idx_channel_set_chanset   '`id_chanset_list`'
add_index IGNORES          idx_ignores_channel       '`id_channel`'
add_index MP3              idx_mp3_user              '`id_user`'
add_index SERVERS          idx_servers_network       '`id_network`'

# ===========================================================================
# P9b — Purge orphaned rows before adding foreign keys
# ===========================================================================
log "P9b — Purging orphaned rows (id_channel references)"

for TBL in ACTIONS_LOG CHANNEL_LOG CHANNEL_FLOOD CHANNEL_SET BADWORDS IGNORES QUOTES RESPONDERS; do
    if table_exists "$TBL"; then
        COL="id_channel"
        # Check if column exists in this table
        if col_exists "$TBL" "$COL"; then
            ORPHANS=$(mysql_q "SELECT COUNT(*) FROM \`$TBL\` WHERE \`$COL\` IS NOT NULL AND \`$COL\` NOT IN (SELECT id_channel FROM CHANNEL) AND \`$COL\` != 0;")
            if [[ "$ORPHANS" -gt 0 ]]; then
                warn "$TBL: $ORPHANS orphaned rows with invalid id_channel — setting to NULL or 0"
                # Tables with NOT NULL id_channel get 0 (global scope), others get NULL
                NULL_OK=$(mysql_q "SELECT IS_NULLABLE FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='$TBL' AND COLUMN_NAME='id_channel';")
                if [[ "$NULL_OK" == "YES" ]]; then
                    mysql_cmd "UPDATE \`$TBL\` SET \`id_channel\` = NULL WHERE \`id_channel\` IS NOT NULL AND \`id_channel\` NOT IN (SELECT id_channel FROM CHANNEL);"
                else
                    mysql_cmd "UPDATE \`$TBL\` SET \`id_channel\` = 0 WHERE \`id_channel\` NOT IN (SELECT id_channel FROM CHANNEL) AND \`id_channel\` != 0;"
                fi
                ok "$TBL: orphans cleaned"
            else
                skip "$TBL: no orphaned rows"
            fi
        fi
    fi
done

# Tables where id_channel=0 means "global/no channel" but FK requires real id
# CHANNEL_FLOOD and CHANNEL_SET with id_channel=0 are orphaned — delete them
for TBL in CHANNEL_FLOOD CHANNEL_SET; do
    if table_exists "$TBL"; then
        ZERO=$(mysql_q "SELECT COUNT(*) FROM \`$TBL\` WHERE \`id_channel\` = 0;")
        if [[ "$ZERO" -gt 0 ]]; then
            warn "$TBL: $ZERO rows with id_channel=0 (no real channel) — deleting"
            mysql_cmd "DELETE FROM \`$TBL\` WHERE \`id_channel\` = 0;"
            ok "$TBL: rows with id_channel=0 removed"
        fi
    fi
done

# IGNORES with id_channel=0 are global ignores — keep them (FK allows 0 via default)
# Instead skip FK for IGNORES id_channel since 0 = global scope

# ===========================================================================
# P10 — Foreign keys
# ===========================================================================
log "P10 — Foreign keys"

add_fk() {
    local fk_name="$1" tbl="$2" col="$3" ref_tbl="$4" ref_col="$5" on_del="${6:-CASCADE}" on_upd="${7:-CASCADE}"
    if ! fk_exists "$fk_name"; then
        mysql_cmd "ALTER TABLE \`$tbl\` ADD CONSTRAINT \`$fk_name\`
            FOREIGN KEY (\`$col\`) REFERENCES \`$ref_tbl\` (\`$ref_col\`)
            ON DELETE $on_del ON UPDATE $on_upd;" 2>/dev/null \
            && ok "FK $fk_name" || warn "FK $fk_name failed (check data integrity)"
    else
        skip "FK $fk_name already exists"
    fi
}

add_fk fk_user_level          USER              id_user_level               USER_LEVEL  id_user_level  RESTRICT    CASCADE
add_fk fk_user_hostmask_user   USER_HOSTMASK    id_user                     USER        id_user        CASCADE     CASCADE
add_fk fk_user_channel_user    USER_CHANNEL     id_user                     USER        id_user        CASCADE     CASCADE
add_fk fk_user_channel_channel USER_CHANNEL     id_channel                  CHANNEL     id_channel     CASCADE     CASCADE
add_fk fk_channel_user         CHANNEL          id_user                     USER        id_user        "SET NULL"  CASCADE
add_fk fk_actions_log_user     ACTIONS_LOG      id_user                     USER        id_user        "SET NULL"  CASCADE
add_fk fk_actions_log_channel  ACTIONS_LOG      id_channel                  CHANNEL     id_channel     "SET NULL"  CASCADE
add_fk fk_channel_log_channel  CHANNEL_LOG      id_channel                  CHANNEL     id_channel     "SET NULL"  CASCADE
add_fk fk_channel_flood_chan    CHANNEL_FLOOD    id_channel                  CHANNEL     id_channel     CASCADE     CASCADE
add_fk fk_channel_set_channel  CHANNEL_SET      id_channel                  CHANNEL     id_channel     CASCADE     CASCADE
add_fk fk_channel_set_chanset  CHANNEL_SET      id_chanset_list             CHANSET_LIST id_chanset_list CASCADE   CASCADE
add_fk fk_badwords_channel     BADWORDS         id_channel                  CHANNEL     id_channel     CASCADE     CASCADE
# fk_ignores_channel skipped: id_channel=0 means global scope (no real channel ref)
add_fk fk_quotes_channel       QUOTES           id_channel                  CHANNEL     id_channel     CASCADE     CASCADE
add_fk fk_quotes_user          QUOTES           id_user                     USER        id_user        CASCADE     CASCADE
add_fk fk_pc_user              PUBLIC_COMMANDS  id_user                     USER        id_user        "SET NULL"  CASCADE
add_fk fk_pc_category          PUBLIC_COMMANDS  id_public_commands_category PUBLIC_COMMANDS_CATEGORY id_public_commands_category RESTRICT CASCADE
add_fk fk_servers_network      SERVERS          id_network                  NETWORK     id_network     CASCADE     CASCADE
add_fk fk_mp3_user             MP3              id_user                     USER        id_user        CASCADE     CASCADE

mysql_cmd "SET FOREIGN_KEY_CHECKS = 1;"

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  Migration complete — ${DB_NAME}${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo "  Backup saved at: $BACKUP_FILE"
echo ""
echo "  Next steps:"
echo "  1. Verify data: SELECT COUNT(*) FROM USER_HOSTMASK;"
echo "  2. Test the bot: ./start"
echo "  3. Once validated, drop the legacy column:"
echo "     ALTER TABLE \`USER\` DROP COLUMN \`hostmasks_legacy\`;"
echo ""
