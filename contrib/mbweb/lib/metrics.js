'use strict';

const { config } = require('./config');

const DEFAULT_METRICS_TIMEOUT_MS = 3000;
const DEFAULT_METRICS_MAX_BYTES  = 1024 * 1024;
const DEFAULT_MAX_SAMPLES_PER_METRIC = 250;

function intFromEnv(name, fallback, { min = 1, max = 10_000_000 } = {}) {
  const n = Number(process.env[name]);
  if (!Number.isFinite(n) || !Number.isInteger(n)) return fallback;
  return Math.min(Math.max(n, min), max);
}

function parseLabels(labelsStr) {
  const labels = {};
  if (!labelsStr) return labels;

  // Prometheus label values may contain escaped quotes/backslashes.
  const re = /([A-Za-z_][A-Za-z0-9_]*)="((?:\\.|[^"\\])*)"/g;
  for (const pair of labelsStr.matchAll(re)) {
    labels[pair[1]] = pair[2]
      .replace(/\\"/g, '"')
      .replace(/\\\\/g, '\\')
      .replace(/\\n/g, '\n');
  }

  return labels;
}

// Lightweight Prometheus text-format parser.
// Returns Map<metricName, { help, type, samples: [{labels, value}] }>
function parseMetrics(text, options = {}) {
  const maxSamplesPerMetric = options.maxSamplesPerMetric ?? DEFAULT_MAX_SAMPLES_PER_METRIC;
  const out = new Map();
  let currentHelp = null;
  let currentType = null;

  for (const rawLine of String(text || '').split('\n')) {
    const line = rawLine.trim();
    if (!line) continue;

    if (line.startsWith('# HELP ')) {
      const [, name, ...rest] = line.split(' ');
      currentHelp = { name, help: rest.join(' ') };
      continue;
    }

    if (line.startsWith('# TYPE ')) {
      const [, name, type] = line.split(' ');
      currentType = { name, type };
      continue;
    }

    if (line.startsWith('#')) continue;

    const braceOpen  = line.indexOf('{');
    const braceClose = line.lastIndexOf('}');
    let metricName;
    let labelsStr;
    let rawValue;

    if (braceOpen !== -1 && braceClose !== -1 && braceClose > braceOpen) {
      metricName = line.slice(0, braceOpen);
      labelsStr  = line.slice(braceOpen + 1, braceClose);
      rawValue   = line.slice(braceClose + 1).trim().split(/\s+/)[0];
    } else {
      const spaceIdx = line.search(/\s/);
      if (spaceIdx <= 0) continue;

      metricName = line.slice(0, spaceIdx);
      labelsStr  = '';
      rawValue   = line.slice(spaceIdx + 1).trim().split(/\s+/)[0];
    }

    if (!/^[A-Za-z_:][A-Za-z0-9_:]*$/.test(metricName)) continue;

    const value = Number(rawValue);
    if (!Number.isFinite(value)) continue;

    if (!out.has(metricName)) {
      out.set(metricName, {
        help:    currentHelp?.name === metricName ? currentHelp.help : '',
        type:    currentType?.name === metricName ? currentType.type : 'untyped',
        samples: [],
        truncated: false
      });
    }

    const entry = out.get(metricName);
    if (entry.samples.length < maxSamplesPerMetric) {
      entry.samples.push({ labels: parseLabels(labelsStr), value });
    } else {
      entry.truncated = true;
    }
  }

  return out;
}

// Fetch + parse Prometheus metrics. Returns parsed Map or null on failure.
async function fetchMetrics(options = {}) {
  const url = config.urls?.metrics;
  if (!url) return null;

  const timeoutMs = options.timeoutMs
    ?? intFromEnv('MBWEB_METRICS_TIMEOUT_MS', DEFAULT_METRICS_TIMEOUT_MS, { min: 250, max: 30000 });

  const maxBytes = options.maxBytes
    ?? intFromEnv('MBWEB_METRICS_MAX_BYTES', DEFAULT_METRICS_MAX_BYTES, { min: 4096, max: 10 * 1024 * 1024 });

  const maxSamplesPerMetric = options.maxSamplesPerMetric
    ?? intFromEnv('MBWEB_METRICS_MAX_SAMPLES_PER_METRIC', DEFAULT_MAX_SAMPLES_PER_METRIC, { min: 1, max: 5000 });

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);

  try {
    const res = await fetch(url, {
      signal: controller.signal,
      headers: {
        'User-Agent': 'mbweb-mediabot-console/0.1',
        'Accept': 'text/plain,*/*;q=0.8'
      }
    });

    if (!res.ok) return null;

    const text = await res.text();
    if (text.length > maxBytes) {
      console.error(`[mbweb][metrics] response too large: ${text.length} bytes from ${url}`);
      return null;
    }

    return parseMetrics(text, { maxSamplesPerMetric });
  } catch (err) {
    const cause = err?.cause
      ? [
          err.cause.code,
          err.cause.address,
          err.cause.port ? `port=${err.cause.port}` : null
        ].filter(Boolean).join(' ')
      : '';

    console.error(
      `[mbweb][metrics] fetch failed url=${url}: ${err.message}${cause ? ` (${cause})` : ''}`
    );

    return null;
  } finally {
    clearTimeout(timer);
  }
}

// Extract scalar value for a metric (first sample, optional label filter)
function metricVal(parsed, name, labelFilter = null) {
  if (!parsed) return null;
  const entry = parsed.get(name);
  if (!entry || !entry.samples.length) return null;
  if (!labelFilter) return entry.samples[0].value;
  const sample = entry.samples.find(s =>
    Object.entries(labelFilter).every(([k, v]) => s.labels[k] === v)
  );
  return sample ? sample.value : null;
}

// Sum all samples of a metric (useful for counters with label splits)
function metricSum(parsed, name) {
  if (!parsed) return null;
  const entry = parsed.get(name);
  if (!entry || !entry.samples.length) return null;
  return entry.samples.reduce((s, r) => s + r.value, 0);
}

module.exports = {
  parseMetrics,
  fetchMetrics,
  metricVal,
  metricSum
};
