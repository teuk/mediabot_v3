-- MB842: data-only registration. No table/column/index/schema changes.
-- This standalone seed enables no channel. For an existing active pilot,
-- prefer tools/meta_ai_channels.pl --adopt-legacy --apply, which atomically
-- registers MetaAI and preserves only currently eligible legacy channels.
-- Running this seed first intentionally selects an empty opt-in policy.
INSERT INTO CHANSET_LIST(chanset)
SELECT 'MetaAI' WHERE NOT EXISTS(SELECT 1 FROM CHANSET_LIST WHERE chanset='MetaAI');
