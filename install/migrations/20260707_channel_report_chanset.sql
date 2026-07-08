-- 20260707_channel_report_chanset.sql
-- Data-only migration: adds a chanset to control automatic daily/weekly channel
-- reports on a per-channel basis. No schema change. [mb473]
--
-- Why:
--   The daily_channel_report and weekly_channel_report scheduled tasks post to
--   EVERY joined channel, with no per-channel opt-out. Quiet or service
--   channels have no way to silence them. The new chanset lets each channel
--   choose. To preserve current behaviour, the feature defaults to ENABLED in
--   code (chanset_enabled default => 1): existing channels keep receiving
--   reports until an admin explicitly runs `chanset #channel -ChannelReport`.
--
-- Usage:
--   mysql -u root -p --default-character-set=utf8mb4
--   SET NAMES utf8mb4;
--   USE <mediabot_database>;
--   SOURCE install/migrations/20260707_channel_report_chanset.sql;

SET NAMES utf8mb4;

INSERT INTO CHANSET_LIST (chanset)
SELECT 'ChannelReport'
WHERE NOT EXISTS (
  SELECT 1 FROM CHANSET_LIST WHERE chanset = 'ChannelReport'
);

SELECT id_chanset_list, chanset
FROM CHANSET_LIST
WHERE chanset = 'ChannelReport';
