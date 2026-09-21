-- ===========================================================================
-- 20260921_quotes_anonymous_author.sql
-- MB755: represent an anonymous quote author with SQL NULL.
--
-- Historical code inserted id_user=0 for unauthenticated callers.  That value
-- cannot satisfy the canonical foreign key to USER.id_user.  This migration
-- makes the column nullable, repairs legacy zero/orphan sentinels, and changes
-- user deletion from quote deletion to attribution removal.
-- ===========================================================================

SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;
SET CHARACTER SET utf8mb4;

DROP PROCEDURE IF EXISTS `mb755_align_quote_author`;

DELIMITER //

CREATE PROCEDURE `mb755_align_quote_author`()
BEGIN
    DECLARE v_done INT DEFAULT 0;
    DECLARE v_table_count INT DEFAULT 0;
    DECLARE v_user_table_count INT DEFAULT 0;
    DECLARE v_column_count INT DEFAULT 0;
    DECLARE v_data_type VARCHAR(64) DEFAULT NULL;
    DECLARE v_column_type VARCHAR(255) DEFAULT NULL;
    DECLARE v_unexpected_fk INT DEFAULT 0;
    DECLARE v_fk_name VARCHAR(64) DEFAULT NULL;

    DECLARE fk_cursor CURSOR FOR
        SELECT DISTINCT `CONSTRAINT_NAME`
          FROM information_schema.KEY_COLUMN_USAGE
         WHERE `CONSTRAINT_SCHEMA` = DATABASE()
           AND `TABLE_NAME` = 'QUOTES'
           AND `COLUMN_NAME` = 'id_user'
           AND `REFERENCED_TABLE_NAME` IS NOT NULL;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;

    SELECT COUNT(*)
      INTO v_table_count
      FROM information_schema.TABLES
     WHERE `TABLE_SCHEMA` = DATABASE()
       AND `TABLE_NAME` = 'QUOTES'
       AND `TABLE_TYPE` = 'BASE TABLE';

    SELECT COUNT(*)
      INTO v_user_table_count
      FROM information_schema.TABLES
     WHERE `TABLE_SCHEMA` = DATABASE()
       AND `TABLE_NAME` = 'USER'
       AND `TABLE_TYPE` = 'BASE TABLE';

    IF v_table_count <> 1 OR v_user_table_count <> 1 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'mb755: expected QUOTES and USER base tables are required';
    END IF;

    SELECT COUNT(*), MAX(`DATA_TYPE`), MAX(`COLUMN_TYPE`)
      INTO v_column_count, v_data_type, v_column_type
      FROM information_schema.COLUMNS
     WHERE `TABLE_SCHEMA` = DATABASE()
       AND `TABLE_NAME` = 'QUOTES'
       AND `COLUMN_NAME` = 'id_user';

    IF v_column_count <> 1
       OR v_data_type NOT IN ('tinyint','smallint','mediumint','int','bigint') THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'mb755: unexpected QUOTES.id_user definition';
    END IF;

    IF v_column_type NOT LIKE '%unsigned%'
       AND EXISTS (SELECT 1 FROM `QUOTES` WHERE `id_user` < 0 LIMIT 1) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'mb755: negative QUOTES.id_user cannot be converted';
    END IF;

    SELECT COUNT(*)
      INTO v_unexpected_fk
      FROM (
        SELECT `CONSTRAINT_NAME`
          FROM information_schema.KEY_COLUMN_USAGE
         WHERE `CONSTRAINT_SCHEMA` = DATABASE()
           AND `TABLE_NAME` = 'QUOTES'
           AND `REFERENCED_TABLE_NAME` IS NOT NULL
           AND `CONSTRAINT_NAME` IN (
                SELECT `CONSTRAINT_NAME`
                  FROM information_schema.KEY_COLUMN_USAGE
                 WHERE `CONSTRAINT_SCHEMA` = DATABASE()
                   AND `TABLE_NAME` = 'QUOTES'
                   AND `COLUMN_NAME` = 'id_user'
                   AND `REFERENCED_TABLE_NAME` IS NOT NULL
           )
         GROUP BY `CONSTRAINT_NAME`
        HAVING COUNT(*) <> 1
            OR MAX(`COLUMN_NAME`) <> 'id_user'
            OR MAX(`REFERENCED_TABLE_NAME`) <> 'USER'
            OR MAX(`REFERENCED_COLUMN_NAME`) <> 'id_user'
      ) AS unexpected;

    IF v_unexpected_fk <> 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'mb755: unexpected foreign key uses QUOTES.id_user';
    END IF;

    OPEN fk_cursor;
    drop_loop: LOOP
        FETCH fk_cursor INTO v_fk_name;
        IF v_done = 1 THEN
            LEAVE drop_loop;
        END IF;
        SET @mb755_sql = CONCAT(
            'ALTER TABLE `QUOTES` DROP FOREIGN KEY `',
            REPLACE(v_fk_name, '`', '``'), '`'
        );
        PREPARE mb755_stmt FROM @mb755_sql;
        EXECUTE mb755_stmt;
        DEALLOCATE PREPARE mb755_stmt;
    END LOOP;
    CLOSE fk_cursor;

    ALTER TABLE `QUOTES`
        MODIFY COLUMN `id_user` BIGINT UNSIGNED NULL DEFAULT NULL;

    UPDATE `QUOTES` q
    LEFT JOIN `USER` u ON u.`id_user` = q.`id_user`
       SET q.`id_user` = NULL
     WHERE q.`id_user` IS NOT NULL
       AND (q.`id_user` = 0 OR u.`id_user` IS NULL);

    ALTER TABLE `QUOTES`
        ADD CONSTRAINT `fk_quotes_user`
        FOREIGN KEY (`id_user`) REFERENCES `USER` (`id_user`)
        ON DELETE SET NULL ON UPDATE CASCADE;

    IF NOT EXISTS (
        SELECT 1
          FROM information_schema.COLUMNS
         WHERE `TABLE_SCHEMA` = DATABASE()
           AND `TABLE_NAME` = 'QUOTES'
           AND `COLUMN_NAME` = 'id_user'
           AND `DATA_TYPE` = 'bigint'
           AND `COLUMN_TYPE` LIKE '%unsigned%'
           AND `IS_NULLABLE` = 'YES'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'mb755: QUOTES.id_user did not converge';
    END IF;

    IF NOT EXISTS (
        SELECT 1
          FROM information_schema.REFERENTIAL_CONSTRAINTS
         WHERE `CONSTRAINT_SCHEMA` = DATABASE()
           AND `TABLE_NAME` = 'QUOTES'
           AND `CONSTRAINT_NAME` = 'fk_quotes_user'
           AND `REFERENCED_TABLE_NAME` = 'USER'
           AND `DELETE_RULE` = 'SET NULL'
           AND `UPDATE_RULE` = 'CASCADE'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'mb755: canonical quote author foreign key is missing';
    END IF;
END //

DELIMITER ;

CALL `mb755_align_quote_author`();
DROP PROCEDURE `mb755_align_quote_author`;

SELECT `DATA_TYPE`, `COLUMN_TYPE`, `IS_NULLABLE`
FROM information_schema.COLUMNS
WHERE `TABLE_SCHEMA` = DATABASE()
  AND `TABLE_NAME` = 'QUOTES'
  AND `COLUMN_NAME` = 'id_user';

SELECT `CONSTRAINT_NAME`, `DELETE_RULE`, `UPDATE_RULE`
FROM information_schema.REFERENTIAL_CONSTRAINTS
WHERE `CONSTRAINT_SCHEMA` = DATABASE()
  AND `TABLE_NAME` = 'QUOTES'
  AND `CONSTRAINT_NAME` = 'fk_quotes_user';
