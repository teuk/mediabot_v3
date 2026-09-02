-- 20260902_hailo_policy_chansets.sql
-- MB720-C: independent per-channel Hailo learn/respond controls.
--
-- Data only. Existing channels that already have +Hailo inherit both new
-- switches, preserving their pre-migration behaviour. Operators may then
-- disable learning or direct responses independently with ordinary chanset
-- commands. HailoChatter remains a separate existing opt-in.

SET NAMES utf8mb4;

INSERT INTO CHANSET_LIST (chanset)
SELECT 'HailoLearn'
WHERE NOT EXISTS (
  SELECT 1 FROM CHANSET_LIST WHERE chanset = 'HailoLearn'
);

INSERT INTO CHANSET_LIST (chanset)
SELECT 'HailoRespond'
WHERE NOT EXISTS (
  SELECT 1 FROM CHANSET_LIST WHERE chanset = 'HailoRespond'
);

INSERT INTO CHANNEL_SET (id_channel, id_chanset_list)
SELECT master_set.id_channel, target_list.id_chanset_list
FROM CHANNEL_SET AS master_set
JOIN CHANSET_LIST AS master_list
  ON master_list.id_chanset_list = master_set.id_chanset_list
 AND master_list.chanset = 'Hailo'
JOIN CHANSET_LIST AS target_list
  ON target_list.chanset = 'HailoLearn'
LEFT JOIN CHANNEL_SET AS existing_set
  ON existing_set.id_channel = master_set.id_channel
 AND existing_set.id_chanset_list = target_list.id_chanset_list
WHERE existing_set.id_channel_set IS NULL;

INSERT INTO CHANNEL_SET (id_channel, id_chanset_list)
SELECT master_set.id_channel, target_list.id_chanset_list
FROM CHANNEL_SET AS master_set
JOIN CHANSET_LIST AS master_list
  ON master_list.id_chanset_list = master_set.id_chanset_list
 AND master_list.chanset = 'Hailo'
JOIN CHANSET_LIST AS target_list
  ON target_list.chanset = 'HailoRespond'
LEFT JOIN CHANNEL_SET AS existing_set
  ON existing_set.id_channel = master_set.id_channel
 AND existing_set.id_chanset_list = target_list.id_chanset_list
WHERE existing_set.id_channel_set IS NULL;

SELECT id_chanset_list, chanset
FROM CHANSET_LIST
WHERE chanset IN ('HailoLearn', 'HailoRespond')
ORDER BY chanset;
