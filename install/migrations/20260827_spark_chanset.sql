-- 20260827_spark_chanset.sql
-- Data-only migration: registers the opt-in +Spark channel capability.
-- [mb703]
--
-- This migration intentionally does NOT enable +Spark on any channel.
-- Existing channels remain opted out because no CHANNEL_SET row is created.
-- Runtime scheduling and IRC emission are delivered in later MB703 rounds.

SET NAMES utf8mb4;

INSERT INTO CHANSET_LIST (chanset)
SELECT 'Spark'
WHERE NOT EXISTS (
  SELECT 1 FROM CHANSET_LIST WHERE chanset = 'Spark'
);

SELECT id_chanset_list, chanset
FROM CHANSET_LIST
WHERE chanset = 'Spark';
