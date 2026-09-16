-- ===========================================================================
-- 20260916_channel_timezone.sql
-- Add an explicit IANA civil-time policy to every IRC channel.
--
-- Existing rows deliberately start at UTC. Set the intended IANA timezone
-- through `!chanset #channel timezone Area/City` after deploying the code;
-- that command also invalidates legacy hour-band achievement state.
-- ===========================================================================

SET NAMES utf8mb4;

ALTER TABLE `CHANNEL`
  ADD COLUMN IF NOT EXISTS `timezone`
    VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin
    NOT NULL DEFAULT 'UTC'
    AFTER `tmdb_lang`;

SELECT id_channel, name, timezone
FROM CHANNEL
ORDER BY id_channel;
