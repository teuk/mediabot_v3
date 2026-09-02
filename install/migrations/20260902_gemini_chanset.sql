-- 20260902_gemini_chanset.sql
-- Data-only migration: register the opt-in +Gemini channel capability.
--
-- This migration deliberately enables no channel. The public !gemini command
-- fails closed until an operator explicitly applies +Gemini to a channel.

SET NAMES utf8mb4;

INSERT INTO CHANSET_LIST (chanset)
SELECT 'Gemini'
WHERE NOT EXISTS (
  SELECT 1 FROM CHANSET_LIST WHERE chanset = 'Gemini'
);

SELECT id_chanset_list, chanset
FROM CHANSET_LIST
WHERE chanset = 'Gemini';
