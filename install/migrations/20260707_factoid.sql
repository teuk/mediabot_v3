-- 20260707_factoid.sql
-- Structure migration: shared per-channel key/value facts. [mb476]
--
-- Adds the FACTOID table backing !learn / !whatis / !forget / !factoids.
-- Idempotent: CREATE TABLE IF NOT EXISTS. Foreign keys are declared inline so
-- a fresh CREATE gets them; on a pre-existing table the CREATE is skipped.
--
-- Usage:
--   mysql -u root -p --default-character-set=utf8mb4
--   SET NAMES utf8mb4;
--   USE <mediabot_database>;
--   SOURCE install/migrations/20260707_factoid.sql;
--
-- Validation:
--   perl tools/check_schema_drift.pl --conf=mediabot.conf --strict

SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `FACTOID` (
  `id_factoid`      BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `id_channel`      BIGINT UNSIGNED NOT NULL,
  `keyword`         VARCHAR(64)  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL,
  `value`           VARCHAR(400) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL,
  `created_by`      BIGINT UNSIGNED DEFAULT NULL,
  `created_by_nick` VARCHAR(64)  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `created_at`      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at`      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  `hits`            BIGINT UNSIGNED NOT NULL DEFAULT 0,
  PRIMARY KEY (`id_factoid`),
  UNIQUE KEY `uniq_factoid_channel_keyword` (`id_channel`, `keyword`),
  KEY `idx_factoid_created_by` (`created_by`),
  CONSTRAINT `fk_factoid_channel`    FOREIGN KEY (`id_channel`) REFERENCES `CHANNEL` (`id_channel`) ON DELETE CASCADE  ON UPDATE CASCADE,
  CONSTRAINT `fk_factoid_created_by` FOREIGN KEY (`created_by`) REFERENCES `USER`    (`id_user`)    ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Shared per-channel key/value facts (mb476: !learn / !whatis / !forget)';

SELECT 'FACTOID ready' AS result;
