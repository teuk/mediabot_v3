-- 20260710_quotes_hits.sql
-- Adds a `hits` recall counter to QUOTES, powering the !topquote hall of fame
-- (mb501). Idempotent: only adds the column if it isn't there yet. No data loss.
--
-- Usage:
--   mysql -u root -p --default-character-set=utf8mb4
--   SET NAMES utf8mb4;
--   USE <mediabot_database>;
--   SOURCE install/migrations/20260710_quotes_hits.sql;

SET NAMES utf8mb4;

SET @col_exists := (
  SELECT COUNT(*)
  FROM information_schema.COLUMNS
  WHERE TABLE_SCHEMA = DATABASE()
    AND TABLE_NAME   = 'QUOTES'
    AND COLUMN_NAME  = 'hits'
);

SET @ddl := IF(@col_exists = 0,
  'ALTER TABLE `QUOTES` ADD COLUMN `hits` BIGINT UNSIGNED NOT NULL DEFAULT 0 AFTER `quotetext`',
  'SELECT "QUOTES.hits already present" AS note'
);

PREPARE stmt FROM @ddl;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

-- Optional index to make the hall of fame ordering cheap on large channels.
SET @idx_exists := (
  SELECT COUNT(*)
  FROM information_schema.STATISTICS
  WHERE TABLE_SCHEMA = DATABASE()
    AND TABLE_NAME   = 'QUOTES'
    AND INDEX_NAME   = 'idx_quotes_channel_hits'
);

SET @ddl2 := IF(@idx_exists = 0,
  'ALTER TABLE `QUOTES` ADD INDEX `idx_quotes_channel_hits` (`id_channel`, `hits`)',
  'SELECT "idx_quotes_channel_hits already present" AS note'
);

PREPARE stmt2 FROM @ddl2;
EXECUTE stmt2;
DEALLOCATE PREPARE stmt2;
