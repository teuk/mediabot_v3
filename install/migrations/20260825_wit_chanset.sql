-- 20260825_wit_chanset.sql
-- Data-only migration: registers the opt-in +Wit channel capability.
-- [mb700]
--
-- This migration intentionally does NOT enable +Wit on any channel.
-- Existing channels remain opted out because no CHANNEL_SET row is created.
-- Runtime wiring is delivered in later MB700 rounds.

SET NAMES utf8mb4;

INSERT INTO CHANSET_LIST (chanset)
SELECT 'Wit'
WHERE NOT EXISTS (
  SELECT 1 FROM CHANSET_LIST WHERE chanset = 'Wit'
);

SELECT id_chanset_list, chanset
FROM CHANSET_LIST
WHERE chanset = 'Wit';
