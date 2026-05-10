'use strict';

const { RuntimeCache } = require('./runtimeCache');
const { fetchMetrics } = require('./metrics');
const { getRadioStatus } = require('./radio');

const cache = new RuntimeCache();

function envInt(name, fallback, { min = 1, max = 600_000 } = {}) {
  const n = Number(process.env[name]);
  if (!Number.isFinite(n) || !Number.isInteger(n)) return fallback;
  return Math.min(Math.max(n, min), max);
}

function metricsTtlMs() {
  return envInt('MBWEB_METRICS_CACHE_TTL_MS', 5000, { min: 500, max: 120_000 });
}

function radioTtlMs() {
  return envInt('MBWEB_RADIO_CACHE_TTL_MS', 5000, { min: 500, max: 120_000 });
}

async function getCachedMetrics(options = {}) {
  const maxSamples = Number(options.maxSamplesPerMetric) || 250;
  const key = `metrics:${maxSamples}`;

  return cache.getOrSet(
    key,
    options.ttlMs || metricsTtlMs(),
    () => fetchMetrics({ maxSamplesPerMetric: maxSamples }),
    { force: Boolean(options.force) }
  );
}

async function getCachedRadioStatus(options = {}) {
  return cache.getOrSet(
    'radio:status',
    options.ttlMs || radioTtlMs(),
    () => getRadioStatus(),
    { force: Boolean(options.force) }
  );
}

function clearIntegrationCache(prefix = null) {
  return cache.clear(prefix);
}

function getIntegrationCacheStats() {
  return cache.stats();
}

module.exports = {
  getCachedMetrics,
  getCachedRadioStatus,
  clearIntegrationCache,
  getIntegrationCacheStats
};
