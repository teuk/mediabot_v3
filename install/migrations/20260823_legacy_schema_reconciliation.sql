-- 20260823_legacy_schema_reconciliation.sql
-- mb695 — reconcile long-lived pre-3.3-era schemas with the current canonical
-- schema without discarding known USER.hostmasks_legacy compatibility data.
--
-- Safety model:
--   * fail closed on values that cannot be narrowed safely;
--   * preserve rows and USER.hostmasks_legacy;
--   * normalize legacy table charsets/collations to utf8mb4_unicode_ci;
--   * restore canonical column definitions, required indexes and FK rules;
--   * retain unrelated extra indexes (they may be local performance tuning);
--   * safe to replay: conditional conversions/index/FK work is skipped when
--     already canonical; metadata MODIFY statements are repeatable.

SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;
SET CHARACTER SET utf8mb4;

DROP PROCEDURE IF EXISTS `mb695_exec`;
DROP PROCEDURE IF EXISTS `mb695_assert_safe`;
DROP PROCEDURE IF EXISTS `mb695_convert_table`;
DROP PROCEDURE IF EXISTS `mb695_fix_single_index`;
DROP PROCEDURE IF EXISTS `mb695_drop_fk_if_exists`;
DROP PROCEDURE IF EXISTS `mb695_ensure_fk`;

DELIMITER //

CREATE PROCEDURE `mb695_exec`(IN p_sql LONGTEXT)
BEGIN
    SET @mb695_sql = p_sql;
    PREPARE mb695_stmt FROM @mb695_sql;
    EXECUTE mb695_stmt;
    DEALLOCATE PREPARE mb695_stmt;
END //

CREATE PROCEDURE `mb695_assert_safe`()
BEGIN
    IF EXISTS (SELECT 1 FROM `ACTIONS_QUEUE` WHERE `id_actions_queue` < 0 LIMIT 1) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='mb695: ACTIONS_QUEUE has negative ids';
    END IF;
    IF EXISTS (
        SELECT 1 FROM `ACTIONS_QUEUE`
        GROUP BY `id_actions_queue` HAVING COUNT(*) > 1 LIMIT 1
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='mb695: ACTIONS_QUEUE has duplicate ids';
    END IF;
    IF EXISTS (
        SELECT 1
          FROM information_schema.STATISTICS
         WHERE `TABLE_SCHEMA`=DATABASE()
           AND `TABLE_NAME`='ACTIONS_QUEUE'
           AND `INDEX_NAME`='PRIMARY'
           AND NOT (`SEQ_IN_INDEX`=1 AND `COLUMN_NAME`='id_actions_queue')
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='mb695: ACTIONS_QUEUE has an unexpected primary key';
    END IF;
    IF EXISTS (SELECT 1 FROM `BOT_ALIAS` WHERE `id_alias` < 0 OR `created_at` IS NULL LIMIT 1) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='mb695: BOT_ALIAS cannot be normalized safely';
    END IF;
    IF EXISTS (
        SELECT 1 FROM `KARMA`
        WHERE `id_karma` < 0 OR `id_channel` < 0 OR `score` IS NULL LIMIT 1
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='mb695: KARMA cannot be normalized safely';
    END IF;
    IF EXISTS (
        SELECT 1 FROM `REMINDERS`
        WHERE `id_reminder` < 0 OR `id_channel` < 0 OR `created_at` IS NULL
           OR `delivered` IS NULL OR `delivered` < 0 OR `delivered` > 255
        LIMIT 1
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='mb695: REMINDERS cannot be normalized safely';
    END IF;
    IF EXISTS (
        SELECT 1 FROM `TIMERS`
        WHERE `duration` < -2147483648 OR `duration` > 2147483647 LIMIT 1
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='mb695: TIMERS.duration is outside signed INT range';
    END IF;
    IF EXISTS (
        SELECT 1 FROM `NETWORK`
        GROUP BY LEFT(`network_name`,191) HAVING COUNT(*) > 1 LIMIT 1
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='mb695: NETWORK has 191-char unique-prefix collisions';
    END IF;
    IF EXISTS (
        SELECT 1 FROM `PUBLIC_COMMANDS`
        GROUP BY LEFT(`command`,191) HAVING COUNT(*) > 1 LIMIT 1
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='mb695: PUBLIC_COMMANDS has 191-char unique-prefix collisions';
    END IF;
    IF EXISTS (
        SELECT 1 FROM `TIMERS`
        GROUP BY LEFT(`name`,191) HAVING COUNT(*) > 1 LIMIT 1
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='mb695: TIMERS has 191-char unique-prefix collisions';
    END IF;
    IF EXISTS (
        SELECT 1 FROM `USER`
        WHERE CAST(`creation_date` AS CHAR)='0000-00-00 00:00:00'
           OR (`last_login` IS NOT NULL AND CAST(`last_login` AS CHAR)='0000-00-00 00:00:00')
        LIMIT 1
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='mb695: USER contains zero dates';
    END IF;

    IF EXISTS (
        SELECT 1 FROM `CHANNEL` c LEFT JOIN `USER` u ON u.`id_user`=c.`id_user`
        WHERE c.`id_user` IS NOT NULL AND u.`id_user` IS NULL LIMIT 1
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='mb695: CHANNEL has orphan id_user values';
    END IF;
    IF EXISTS (
        SELECT 1 FROM `FACTOID` f LEFT JOIN `CHANNEL` c ON c.`id_channel`=f.`id_channel`
        WHERE c.`id_channel` IS NULL LIMIT 1
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='mb695: FACTOID has orphan id_channel values';
    END IF;
    IF EXISTS (
        SELECT 1 FROM `FACTOID` f LEFT JOIN `USER` u ON u.`id_user`=f.`created_by`
        WHERE f.`created_by` IS NOT NULL AND u.`id_user` IS NULL LIMIT 1
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='mb695: FACTOID has orphan created_by values';
    END IF;
    IF EXISTS (
        SELECT 1 FROM `KARMA` k LEFT JOIN `CHANNEL` c ON c.`id_channel`=k.`id_channel`
        WHERE c.`id_channel` IS NULL LIMIT 1
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='mb695: KARMA has orphan id_channel values';
    END IF;
    IF EXISTS (
        SELECT 1 FROM `PUBLIC_COMMANDS` p LEFT JOIN `USER` u ON u.`id_user`=p.`id_user`
        WHERE p.`id_user` IS NOT NULL AND u.`id_user` IS NULL LIMIT 1
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='mb695: PUBLIC_COMMANDS has orphan id_user values';
    END IF;
    IF EXISTS (
        SELECT 1 FROM `PUBLIC_COMMANDS` p
        LEFT JOIN `PUBLIC_COMMANDS_CATEGORY` c
          ON c.`id_public_commands_category`=p.`id_public_commands_category`
        WHERE p.`id_public_commands_category` IS NOT NULL
          AND c.`id_public_commands_category` IS NULL LIMIT 1
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='mb695: PUBLIC_COMMANDS has orphan category values';
    END IF;
    IF EXISTS (
        SELECT 1 FROM `REMINDERS` r LEFT JOIN `CHANNEL` c ON c.`id_channel`=r.`id_channel`
        WHERE c.`id_channel` IS NULL LIMIT 1
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='mb695: REMINDERS has orphan id_channel values';
    END IF;
    IF EXISTS (
        SELECT 1 FROM `TRIVIA_SCORES` t LEFT JOIN `CHANNEL` c ON c.`id_channel`=t.`id_channel`
        WHERE c.`id_channel` IS NULL LIMIT 1
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='mb695: TRIVIA_SCORES has orphan id_channel values';
    END IF;
END //

CREATE PROCEDURE `mb695_convert_table`(IN p_table VARCHAR(64))
BEGIN
    DECLARE v_table_collation VARCHAR(64) DEFAULT NULL;
    DECLARE v_bad_columns INT DEFAULT 0;

    IF p_table NOT REGEXP '^[A-Z0-9_]+$' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='mb695: unsafe table identifier';
    END IF;

    SELECT `TABLE_COLLATION`
      INTO v_table_collation
      FROM information_schema.TABLES
     WHERE `TABLE_SCHEMA`=DATABASE()
       AND `TABLE_NAME`=p_table
       AND `TABLE_TYPE`='BASE TABLE'
     LIMIT 1;

    IF v_table_collation IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='mb695: expected table missing';
    END IF;

    SELECT COUNT(*)
      INTO v_bad_columns
      FROM information_schema.COLUMNS
     WHERE `TABLE_SCHEMA`=DATABASE()
       AND `TABLE_NAME`=p_table
       AND `CHARACTER_SET_NAME` IS NOT NULL
       AND (`CHARACTER_SET_NAME` <> 'utf8mb4' OR `COLLATION_NAME` <> 'utf8mb4_unicode_ci');

    IF v_table_collation <> 'utf8mb4_unicode_ci' OR v_bad_columns > 0 THEN
        CALL `mb695_exec`(
            CONCAT('ALTER TABLE `', p_table,
                   '` CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci')
        );
    END IF;
END //

CREATE PROCEDURE `mb695_fix_single_index`(
    IN p_table VARCHAR(64),
    IN p_index VARCHAR(64),
    IN p_column VARCHAR(64),
    IN p_prefix INT,
    IN p_unique TINYINT
)
BEGIN
    DECLARE v_exists INT DEFAULT 0;
    DECLARE v_ok INT DEFAULT 0;

    IF p_table NOT REGEXP '^[A-Z0-9_]+$'
       OR p_index NOT REGEXP '^[A-Za-z0-9_]+$'
       OR p_column NOT REGEXP '^[A-Za-z0-9_]+$' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='mb695: unsafe index identifier';
    END IF;

    SELECT COUNT(*) INTO v_exists
      FROM information_schema.STATISTICS
     WHERE `TABLE_SCHEMA`=DATABASE()
       AND `TABLE_NAME`=p_table
       AND `INDEX_NAME`=p_index;

    SELECT COUNT(*) INTO v_ok
      FROM information_schema.STATISTICS
     WHERE `TABLE_SCHEMA`=DATABASE()
       AND `TABLE_NAME`=p_table
       AND `INDEX_NAME`=p_index
       AND `SEQ_IN_INDEX`=1
       AND `COLUMN_NAME`=p_column
       AND COALESCE(`SUB_PART`,0)=p_prefix
       AND `NON_UNIQUE`=IF(p_unique=1,0,1)
       AND NOT EXISTS (
           SELECT 1 FROM information_schema.STATISTICS s2
            WHERE s2.`TABLE_SCHEMA`=DATABASE()
              AND s2.`TABLE_NAME`=p_table
              AND s2.`INDEX_NAME`=p_index
              AND s2.`SEQ_IN_INDEX`>1
       );

    IF v_ok = 0 THEN
        IF v_exists > 0 THEN
            CALL `mb695_exec`(CONCAT('ALTER TABLE `',p_table,'` DROP INDEX `',p_index,'`'));
        END IF;
        CALL `mb695_exec`(
            CONCAT('ALTER TABLE `',p_table,'` ADD ',
                   IF(p_unique=1,'UNIQUE ',''),'INDEX `',p_index,'` (`',p_column,'`(',p_prefix,'))')
        );
    END IF;
END //

CREATE PROCEDURE `mb695_drop_fk_if_exists`(IN p_table VARCHAR(64), IN p_fk VARCHAR(64))
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.TABLE_CONSTRAINTS
         WHERE `CONSTRAINT_SCHEMA`=DATABASE()
           AND `TABLE_NAME`=p_table
           AND `CONSTRAINT_NAME`=p_fk
           AND `CONSTRAINT_TYPE`='FOREIGN KEY'
    ) THEN
        CALL `mb695_exec`(CONCAT('ALTER TABLE `',p_table,'` DROP FOREIGN KEY `',p_fk,'`'));
    END IF;
END //

CREATE PROCEDURE `mb695_ensure_fk`(
    IN p_table VARCHAR(64),
    IN p_fk VARCHAR(64),
    IN p_column VARCHAR(64),
    IN p_ref_table VARCHAR(64),
    IN p_ref_column VARCHAR(64),
    IN p_delete_rule VARCHAR(16),
    IN p_update_rule VARCHAR(16)
)
BEGIN
    DECLARE v_ok INT DEFAULT 0;

    IF p_table NOT REGEXP '^[A-Z0-9_]+$'
       OR p_fk NOT REGEXP '^[A-Za-z0-9_]+$'
       OR p_column NOT REGEXP '^[A-Za-z0-9_]+$'
       OR p_ref_table NOT REGEXP '^[A-Z0-9_]+$'
       OR p_ref_column NOT REGEXP '^[A-Za-z0-9_]+$'
       OR p_delete_rule NOT IN ('CASCADE','SET NULL','RESTRICT','NO ACTION')
       OR p_update_rule NOT IN ('CASCADE','SET NULL','RESTRICT','NO ACTION') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='mb695: unsafe foreign-key definition';
    END IF;

    SELECT COUNT(*) INTO v_ok
      FROM information_schema.KEY_COLUMN_USAGE k
      JOIN information_schema.REFERENTIAL_CONSTRAINTS r
        ON r.`CONSTRAINT_SCHEMA`=k.`CONSTRAINT_SCHEMA`
       AND r.`TABLE_NAME`=k.`TABLE_NAME`
       AND r.`CONSTRAINT_NAME`=k.`CONSTRAINT_NAME`
     WHERE k.`CONSTRAINT_SCHEMA`=DATABASE()
       AND k.`TABLE_NAME`=p_table
       AND k.`CONSTRAINT_NAME`=p_fk
       AND k.`ORDINAL_POSITION`=1
       AND k.`COLUMN_NAME`=p_column
       AND k.`REFERENCED_TABLE_NAME`=p_ref_table
       AND k.`REFERENCED_COLUMN_NAME`=p_ref_column
       AND r.`DELETE_RULE`=p_delete_rule
       AND r.`UPDATE_RULE`=p_update_rule
       AND NOT EXISTS (
           SELECT 1
             FROM information_schema.KEY_COLUMN_USAGE k2
            WHERE k2.`CONSTRAINT_SCHEMA`=DATABASE()
              AND k2.`TABLE_NAME`=p_table
              AND k2.`CONSTRAINT_NAME`=p_fk
              AND k2.`ORDINAL_POSITION`>1
       );

    IF v_ok = 0 THEN
        CALL `mb695_drop_fk_if_exists`(p_table,p_fk);
        CALL `mb695_exec`(
            CONCAT('ALTER TABLE `',p_table,'` ADD CONSTRAINT `',p_fk,
                   '` FOREIGN KEY (`',p_column,'`) REFERENCES `',p_ref_table,
                   '` (`',p_ref_column,'`) ON DELETE ',p_delete_rule,
                   ' ON UPDATE ',p_update_rule)
        );
    END IF;
END //

DELIMITER ;

CALL `mb695_assert_safe`();

-- ---------------------------------------------------------------------------
-- Normalize legacy table defaults and inherited textual columns.
-- RSS/achievement/newer tables are intentionally not touched because they are
-- already canonical and some contain deliberate ASCII columns.
-- ---------------------------------------------------------------------------
CALL `mb695_convert_table`('ACTIONS_LOG');
CALL `mb695_convert_table`('ACTIONS_QUEUE');
CALL `mb695_convert_table`('BADWORDS');
CALL `mb695_convert_table`('BOT_ALIAS');
CALL `mb695_convert_table`('CHANNEL_FLOOD');
CALL `mb695_convert_table`('CHANNEL_PURGED');
CALL `mb695_convert_table`('CHANNEL_SET');
CALL `mb695_convert_table`('CHANSET_LIST');
CALL `mb695_convert_table`('CONSOLE');
CALL `mb695_convert_table`('HAILO_CHANNEL');
CALL `mb695_convert_table`('HAILO_EXCLUSION_NICK');
CALL `mb695_convert_table`('IGNORES');
CALL `mb695_convert_table`('KARMA');
CALL `mb695_convert_table`('MP3');
CALL `mb695_convert_table`('NETWORK');
CALL `mb695_convert_table`('PUBLIC_COMMANDS');
CALL `mb695_convert_table`('PUBLIC_COMMANDS_CATEGORY');
CALL `mb695_convert_table`('QUOTES');
CALL `mb695_convert_table`('REMINDERS');
CALL `mb695_convert_table`('SERVERS');
CALL `mb695_convert_table`('TIMERS');
CALL `mb695_convert_table`('TIMEZONE');
CALL `mb695_convert_table`('USER');
CALL `mb695_convert_table`('USER_CHANNEL');
CALL `mb695_convert_table`('USER_LEVEL');
CALL `mb695_convert_table`('WEBLOG');
CALL `mb695_convert_table`('YOMOMMA');

-- ---------------------------------------------------------------------------
-- Canonical column definitions that are not fixed by charset conversion.
-- ---------------------------------------------------------------------------
SET @mb695_has_actions_pk := (
    SELECT COUNT(*) FROM information_schema.TABLE_CONSTRAINTS
     WHERE `CONSTRAINT_SCHEMA`=DATABASE()
       AND `TABLE_NAME`='ACTIONS_QUEUE'
       AND `CONSTRAINT_NAME`='PRIMARY'
       AND `CONSTRAINT_TYPE`='PRIMARY KEY'
);
SET @mb695_sql := IF(
    @mb695_has_actions_pk = 0,
    'ALTER TABLE `ACTIONS_QUEUE` MODIFY COLUMN `id_actions_queue` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, ADD PRIMARY KEY (`id_actions_queue`)',
    'ALTER TABLE `ACTIONS_QUEUE` MODIFY COLUMN `id_actions_queue` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT'
);
CALL `mb695_exec`(@mb695_sql);

ALTER TABLE `BOT_ALIAS`
    MODIFY COLUMN `id_alias` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    MODIFY COLUMN `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP;

ALTER TABLE `CHANNEL`
    MODIFY COLUMN `auto_join` TINYINT(1) NOT NULL DEFAULT 0;

ALTER TABLE `CHANNEL_PURGED`
    MODIFY COLUMN `auto_join` TINYINT(1) NOT NULL DEFAULT 0;

ALTER TABLE `KARMA`
    MODIFY COLUMN `id_karma` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    MODIFY COLUMN `id_channel` BIGINT UNSIGNED NOT NULL,
    MODIFY COLUMN `score` INT NOT NULL DEFAULT 0;

ALTER TABLE `REMINDERS`
    MODIFY COLUMN `id_reminder` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    MODIFY COLUMN `id_channel` BIGINT UNSIGNED NOT NULL,
    MODIFY COLUMN `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    MODIFY COLUMN `delivered` TINYINT UNSIGNED NOT NULL DEFAULT 0;

ALTER TABLE `TIMERS`
    MODIFY COLUMN `duration` INT NOT NULL;

ALTER TABLE `TRIVIA_SCORES`
    MODIFY COLUMN `last_correct` DATETIME NOT NULL
        DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP;

ALTER TABLE `USER`
    MODIFY COLUMN `creation_date` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    MODIFY COLUMN `last_login` DATETIME DEFAULT NULL;

-- ---------------------------------------------------------------------------
-- Required canonical prefix indexes. Unrelated extra indexes are preserved.
-- ---------------------------------------------------------------------------
CALL `mb695_fix_single_index`('CHANNEL_LOG','userhost','userhost',191,0);
-- Keep one canonical durable index effect as explicit SQL so Mediabot Doctor
-- can observe this reconciliation migration without executing stored routines.
-- The preflight collision guard above makes the rebuild safe.
ALTER TABLE `NETWORK` DROP INDEX IF EXISTS `network_name`;
ALTER TABLE `NETWORK`
    ADD UNIQUE INDEX `network_name` (`network_name`(191));
CALL `mb695_fix_single_index`('PUBLIC_COMMANDS','command','command',191,1);
CALL `mb695_fix_single_index`('TIMERS','name','name',191,1);

-- ---------------------------------------------------------------------------
-- Replace known historical FK names and the one historical rule drift.
-- ---------------------------------------------------------------------------
CALL `mb695_drop_fk_if_exists`('CHANNEL','fk_channel_owner');
CALL `mb695_drop_fk_if_exists`('PUBLIC_COMMANDS','fk_public_commands_category');
CALL `mb695_drop_fk_if_exists`('PUBLIC_COMMANDS','fk_public_commands_user');

CALL `mb695_ensure_fk`('CHANNEL','fk_channel_user','id_user','USER','id_user','SET NULL','CASCADE');
CALL `mb695_ensure_fk`('FACTOID','fk_factoid_channel','id_channel','CHANNEL','id_channel','CASCADE','CASCADE');
CALL `mb695_ensure_fk`('FACTOID','fk_factoid_created_by','created_by','USER','id_user','SET NULL','CASCADE');
CALL `mb695_ensure_fk`('KARMA','fk_karma_channel','id_channel','CHANNEL','id_channel','CASCADE','CASCADE');
CALL `mb695_ensure_fk`('PUBLIC_COMMANDS','fk_pc_user','id_user','USER','id_user','SET NULL','CASCADE');
CALL `mb695_ensure_fk`('PUBLIC_COMMANDS','fk_pc_category','id_public_commands_category','PUBLIC_COMMANDS_CATEGORY','id_public_commands_category','RESTRICT','CASCADE');
CALL `mb695_ensure_fk`('REMINDERS','fk_reminders_channel','id_channel','CHANNEL','id_channel','CASCADE','CASCADE');
CALL `mb695_ensure_fk`('TRIVIA_SCORES','fk_trivia_scores_channel','id_channel','CHANNEL','id_channel','CASCADE','CASCADE');

-- USER.hostmasks_legacy is intentionally preserved. R2 proved that at least one
-- long-lived user still has legacy hostmask data without a USER_HOSTMASK row.
-- Removing or rewriting that compatibility data belongs to a separately proven
-- data migration, not to structural reconciliation.

DROP PROCEDURE IF EXISTS `mb695_ensure_fk`;
DROP PROCEDURE IF EXISTS `mb695_drop_fk_if_exists`;
DROP PROCEDURE IF EXISTS `mb695_fix_single_index`;
DROP PROCEDURE IF EXISTS `mb695_convert_table`;
DROP PROCEDURE IF EXISTS `mb695_assert_safe`;
DROP PROCEDURE IF EXISTS `mb695_exec`;

SELECT 'MB695 legacy schema reconciliation complete' AS result;
