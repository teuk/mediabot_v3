-- ===========================================================================
-- 20260903_fullop_chanset.sql
-- Data-only migration: register the opt-in +Fullop channel policy.
--
-- No channel is enabled by this migration.  Activation remains an explicit
-- `chanset #channel +Fullop` operator decision after the bot has IRC op rights.

SET NAMES utf8mb4;

INSERT INTO CHANSET_LIST (chanset)
SELECT 'Fullop'
WHERE NOT EXISTS (
  SELECT 1 FROM CHANSET_LIST WHERE chanset = 'Fullop'
);

SELECT id_chanset_list, chanset
FROM CHANSET_LIST
WHERE chanset = 'Fullop';
