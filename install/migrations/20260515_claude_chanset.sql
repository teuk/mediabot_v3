-- =============================================================================
-- mediabot_v3 migration — Claude chanset
-- Date: 2026-05-15
--
-- Adds the Claude chanset used by the ai / Claude command gate.
-- Safe for existing databases.
-- =============================================================================

SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;

INSERT INTO `CHANSET_LIST` (`chanset`)
SELECT 'Claude'
WHERE NOT EXISTS (
  SELECT 1
  FROM `CHANSET_LIST`
  WHERE `chanset` = 'Claude'
);
