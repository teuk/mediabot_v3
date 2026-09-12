-- MB734: registration only; no channel activation or schema change.
SET NAMES utf8mb4;
INSERT INTO CHANSET_LIST (chanset)
SELECT 'Radio' WHERE NOT EXISTS (SELECT 1 FROM CHANSET_LIST WHERE chanset='Radio');
SELECT id_chanset_list, chanset FROM CHANSET_LIST WHERE chanset='Radio';
