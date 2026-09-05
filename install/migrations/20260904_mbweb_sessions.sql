-- ==========================================================================
-- 20260904_mbweb_sessions.sql
-- Dedicated persistent session storage for the optional mbweb console.
--
-- This migration creates no account and grants no privilege. Operators must
-- grant the mbweb identity only SELECT on its documented read surface and
-- SELECT/INSERT/UPDATE/DELETE on this table.

SET NAMES utf8mb4;

CREATE TABLE IF NOT EXISTS `MBWEB_SESSION` (
  `session_id`   VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  `expires_at`   DATETIME(3) NOT NULL,
  `session_data` MEDIUMTEXT CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL,
  `updated_at`   DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3)
                 ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (`session_id`),
  KEY `idx_mbweb_session_expires_at` (`expires_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

SELECT COUNT(*) AS mbweb_session_table_present
FROM information_schema.tables
WHERE table_schema = DATABASE()
  AND table_name = 'MBWEB_SESSION';
