-- 20260828_spark_action_chanset.sql
-- Data-only migration: registers the opt-in +SparkAction capability.
-- [mb709]
--
-- This migration intentionally does NOT enable +SparkAction on any channel.
-- Active micro-events require both +Spark and +SparkAction and are wired only
-- in later MB709 runtime rounds.

SET NAMES utf8mb4;

INSERT INTO CHANSET_LIST (chanset)
SELECT 'SparkAction'
WHERE NOT EXISTS (
  SELECT 1 FROM CHANSET_LIST WHERE chanset = 'SparkAction'
);

SELECT id_chanset_list, chanset
FROM CHANSET_LIST
WHERE chanset = 'SparkAction';
