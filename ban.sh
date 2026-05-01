cd /home/mediabot/mediabot_v3 || exit 1

SQL_FILE="/home/mediabot/mediabot_v3/install/migrations/20260502_channel_ban.sql"
DB_NAME="mediabotv3"

echo "===== CHECK MIGRATION FILE ====="
ls -lh "$SQL_FILE"
stat -c 'owner=%U group=%G mode=%a file=%n' "$SQL_FILE"
wc -l "$SQL_FILE"

echo
echo "===== SQL QUICK CHECK ====="
grep -nE 'CREATE TABLE|CHANNEL_BAN|FOREIGN KEY|idx_channel_ban|DEFAULT CHARSET|SET NAMES' "$SQL_FILE"

echo
echo "===== IMPORT VIA MYSQL CLIENT / SOURCE / UTF8MB4 ====="
mysql \
  --default-character-set=utf8mb4 \
  -u root \
  "$DB_NAME" \
  --show-warnings \
  --execute="
SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;
SET CHARACTER SET utf8mb4;
SOURCE ${SQL_FILE};
"

echo
echo "===== CHECK TABLE EXISTS ====="
mysql \
  --default-character-set=utf8mb4 \
  -u root \
  "$DB_NAME" \
  --table \
  --execute="
SHOW TABLES LIKE 'CHANNEL_BAN';
"

echo
echo "===== SHOW CREATE TABLE ====="
mysql \
  --default-character-set=utf8mb4 \
  -u root \
  "$DB_NAME" \
  --execute="
SHOW CREATE TABLE CHANNEL_BAN\G
"

echo
echo "===== CHECK INDEXES ====="
mysql \
  --default-character-set=utf8mb4 \
  -u root \
  "$DB_NAME" \
  --table \
  --execute="
SHOW INDEX FROM CHANNEL_BAN;
"

echo
echo "===== CHECK FOREIGN KEYS ====="
mysql \
  --default-character-set=utf8mb4 \
  -u root \
  "$DB_NAME" \
  --table \
  --execute="
SELECT
  CONSTRAINT_NAME,
  TABLE_NAME,
  COLUMN_NAME,
  REFERENCED_TABLE_NAME,
  REFERENCED_COLUMN_NAME
FROM information_schema.KEY_COLUMN_USAGE
WHERE TABLE_SCHEMA = DATABASE()
  AND TABLE_NAME = 'CHANNEL_BAN'
  AND REFERENCED_TABLE_NAME IS NOT NULL
ORDER BY CONSTRAINT_NAME, ORDINAL_POSITION;
"

echo
echo "===== CHECK EMPTY TABLE ====="
mysql \
  --default-character-set=utf8mb4 \
  -u root \
  "$DB_NAME" \
  --table \
  --execute="
SELECT COUNT(*) AS channel_ban_rows FROM CHANNEL_BAN;
"

echo
echo "===== DONE ====="
