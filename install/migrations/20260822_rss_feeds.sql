-- 20260822_rss_feeds.sql
-- mb692 — native per-channel RSS feed persistence and durable item dedup.
--
-- This round creates storage only. Polling and IRC command registration come
-- later.
--
-- Validation:
--   perl tools/check_schema_drift.pl --conf=mediabot.conf --strict --types --indexes

SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `RSS_FEED` (
  `id_rss_feed`       BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `id_channel`        BIGINT UNSIGNED NOT NULL,
  `label`             VARCHAR(80) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL,
  `url`               VARCHAR(2048) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL,
  `url_hash`          CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  `enabled`           TINYINT(1) NOT NULL DEFAULT 1,
  `poll_interval`     INT UNSIGNED NOT NULL DEFAULT 1800,
  `announce_limit`    TINYINT UNSIGNED NOT NULL DEFAULT 5,
  `etag`              VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `last_modified`     VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `last_poll_at`      DATETIME DEFAULT NULL,
  `last_success_at`   DATETIME DEFAULT NULL,
  `last_error_at`     DATETIME DEFAULT NULL,
  `last_error`        VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `created_by`        BIGINT UNSIGNED DEFAULT NULL,
  `created_by_nick`   VARCHAR(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `created_at`        DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at`        DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id_rss_feed`),
  UNIQUE KEY `uq_rss_feed_channel_label` (`id_channel`, `label`),
  UNIQUE KEY `uq_rss_feed_channel_url_hash` (`id_channel`, `url_hash`),
  KEY `idx_rss_feed_enabled_poll` (`enabled`, `last_poll_at`),
  KEY `idx_rss_feed_created_by` (`created_by`),
  CONSTRAINT `fk_rss_feed_channel`
    FOREIGN KEY (`id_channel`) REFERENCES `CHANNEL` (`id_channel`)
    ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT `fk_rss_feed_created_by`
    FOREIGN KEY (`created_by`) REFERENCES `USER` (`id_user`)
    ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Per-channel native RSS/Atom subscriptions (mb692)';

CREATE TABLE IF NOT EXISTS `RSS_ITEM` (
  `id_rss_item`       BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `id_rss_feed`       BIGINT UNSIGNED NOT NULL,
  `item_key`          CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  `title`             VARCHAR(600) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL,
  `url`               VARCHAR(2048) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `published_raw`     VARCHAR(160) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `seen_at`           DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `announced_at`      DATETIME DEFAULT NULL,
  PRIMARY KEY (`id_rss_item`),
  UNIQUE KEY `uq_rss_item_feed_key` (`id_rss_feed`, `item_key`),
  KEY `idx_rss_item_feed_seen` (`id_rss_feed`, `seen_at`),
  KEY `idx_rss_item_feed_announced` (`id_rss_feed`, `announced_at`),
  CONSTRAINT `fk_rss_item_feed`
    FOREIGN KEY (`id_rss_feed`) REFERENCES `RSS_FEED` (`id_rss_feed`)
    ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Durable RSS item baseline/dedup state (mb692)';

SELECT 'RSS_FEED / RSS_ITEM ready' AS result;
