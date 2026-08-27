-- 20260827_vdm_chanset.sql
-- Data-only migration: registers the opt-in +VDM channel capability.
-- [mb704]
--
-- This migration intentionally does NOT enable +VDM on any channel.
-- Manual !vdm and Spark-assisted VDM remain unavailable until later MB704
-- runtime rounds wire and authorize those paths explicitly.

SET NAMES utf8mb4;

INSERT INTO CHANSET_LIST (chanset)
SELECT 'VDM'
WHERE NOT EXISTS (
  SELECT 1 FROM CHANSET_LIST WHERE chanset = 'VDM'
);

SELECT id_chanset_list, chanset
FROM CHANSET_LIST
WHERE chanset = 'VDM';
