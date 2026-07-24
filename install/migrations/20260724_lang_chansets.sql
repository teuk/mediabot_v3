-- 20260724_lang_chansets.sql
-- Data-only migration: adds per-channel language chansets. No schema change.
-- [mb563]
--
-- Why:
--   Some commands answer in the language of main.LANG, which is global. A
--   bot living on both French and English channels needs per-channel
--   control. `chanset #channel +LangFR` forces French, `+LangES` Spanish;
--   with neither flag the global main.LANG keeps applying (so an unmigrated
--   or unflagged setup behaves exactly as before). FR wins if both are set:
--   pick one flag per channel. First consumer: the 8ball command.
--
-- Usage:
--   mysql -u root -p --default-character-set=utf8mb4
--   SET NAMES utf8mb4;
--   USE <mediabot_database>;
--   SOURCE install/migrations/20260724_lang_chansets.sql;

SET NAMES utf8mb4;

INSERT INTO CHANSET_LIST (chanset)
SELECT 'LangFR'
WHERE NOT EXISTS (
  SELECT 1 FROM CHANSET_LIST WHERE chanset = 'LangFR'
);

INSERT INTO CHANSET_LIST (chanset)
SELECT 'LangES'
WHERE NOT EXISTS (
  SELECT 1 FROM CHANSET_LIST WHERE chanset = 'LangES'
);

SELECT id_chanset_list, chanset
FROM CHANSET_LIST
WHERE chanset IN ('LangFR', 'LangES');
