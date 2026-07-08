-- 20260707_didyoumean_chanset.sql
-- Data-only migration: adds a chanset to control the "did you mean?" command
-- suggestion on a per-channel basis. No schema change. [mb475]
--
-- Why:
--   On an unknown public command, the bot can suggest the closest known
--   command ("Unknown command '!raodm'. Did you mean !random?"). Some channels
--   may prefer the bot to stay silent. The chanset lets each channel choose.
--   Defaults to ENABLED in code (chanset_enabled default => 1): behaviour is
--   on by default; `chanset #channel -DidYouMean` silences it.
--
-- Usage:
--   mysql -u root -p --default-character-set=utf8mb4
--   SET NAMES utf8mb4;
--   USE <mediabot_database>;
--   SOURCE install/migrations/20260707_didyoumean_chanset.sql;

SET NAMES utf8mb4;

INSERT INTO CHANSET_LIST (chanset)
SELECT 'DidYouMean'
WHERE NOT EXISTS (
  SELECT 1 FROM CHANSET_LIST WHERE chanset = 'DidYouMean'
);

SELECT id_chanset_list, chanset
FROM CHANSET_LIST
WHERE chanset = 'DidYouMean';
