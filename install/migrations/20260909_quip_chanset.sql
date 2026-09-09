-- MB732: register the optional Quip capability by name.
-- Existing channel choices remain unchanged; this creates no CHANNEL_SET row.
SET NAMES utf8mb4;

INSERT INTO CHANSET_LIST (chanset)
SELECT 'Quip'
WHERE NOT EXISTS (
  SELECT 1 FROM CHANSET_LIST WHERE chanset = 'Quip'
);

SELECT id_chanset_list, chanset
FROM CHANSET_LIST
WHERE chanset = 'Quip';
