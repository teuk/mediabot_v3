-- 20260905_quotes_512_contract.sql
-- Align QUOTES.quotetext with Mediabot::Quotes, which accepts at most 512
-- characters. The spell widens old 255/360-character columns without touching
-- quote rows and refuses any unexpected shape instead of narrowing it.

SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;
SET CHARACTER SET utf8mb4;

DROP PROCEDURE IF EXISTS `mb719_align_quotes_512`;

DELIMITER //

CREATE PROCEDURE `mb719_align_quotes_512`()
BEGIN
    DECLARE v_table_count INT DEFAULT 0;
    DECLARE v_column_count INT DEFAULT 0;
    DECLARE v_data_type VARCHAR(64) DEFAULT NULL;
    DECLARE v_capacity BIGINT DEFAULT NULL;
    DECLARE v_nullable VARCHAR(3) DEFAULT NULL;

    SELECT COUNT(*)
      INTO v_table_count
      FROM information_schema.TABLES
     WHERE `TABLE_SCHEMA` = DATABASE()
       AND `TABLE_NAME` = 'QUOTES'
       AND `TABLE_TYPE` = 'BASE TABLE';

    IF v_table_count <> 1 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'mb719: expected QUOTES base table is missing';
    END IF;

    SELECT COUNT(*), MAX(`DATA_TYPE`), MAX(`CHARACTER_MAXIMUM_LENGTH`),
           MAX(`IS_NULLABLE`)
      INTO v_column_count, v_data_type, v_capacity, v_nullable
      FROM information_schema.COLUMNS
     WHERE `TABLE_SCHEMA` = DATABASE()
       AND `TABLE_NAME` = 'QUOTES'
       AND `COLUMN_NAME` = 'quotetext';

    IF v_column_count <> 1 OR v_data_type <> 'varchar' OR v_capacity IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'mb719: unexpected QUOTES.quotetext definition';
    END IF;

    IF v_capacity > 512 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'mb719: refusing to narrow QUOTES.quotetext';
    END IF;

    IF EXISTS (SELECT 1 FROM `QUOTES` WHERE `quotetext` IS NULL LIMIT 1) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'mb719: QUOTES.quotetext contains NULL values';
    END IF;

    IF EXISTS (SELECT 1 FROM `QUOTES` WHERE CHAR_LENGTH(`quotetext`) > 512 LIMIT 1) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'mb719: quote text exceeds the 512-character contract';
    END IF;

    IF v_capacity <> 512 OR v_nullable <> 'NO' THEN
        ALTER TABLE `QUOTES`
            MODIFY COLUMN `quotetext` VARCHAR(512) NOT NULL;
    END IF;

    IF NOT EXISTS (
        SELECT 1
          FROM information_schema.COLUMNS
         WHERE `TABLE_SCHEMA` = DATABASE()
           AND `TABLE_NAME` = 'QUOTES'
           AND `COLUMN_NAME` = 'quotetext'
           AND `DATA_TYPE` = 'varchar'
           AND `CHARACTER_MAXIMUM_LENGTH` = 512
           AND `IS_NULLABLE` = 'NO'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'mb719: QUOTES.quotetext did not converge';
    END IF;
END //

DELIMITER ;

CALL `mb719_align_quotes_512`();
DROP PROCEDURE `mb719_align_quotes_512`;

SELECT `DATA_TYPE`, `CHARACTER_MAXIMUM_LENGTH`, `IS_NULLABLE`
FROM information_schema.COLUMNS
WHERE `TABLE_SCHEMA` = DATABASE()
  AND `TABLE_NAME` = 'QUOTES'
  AND `COLUMN_NAME` = 'quotetext';
