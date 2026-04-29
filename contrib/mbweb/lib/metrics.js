'use strict';

const { config } = require('./config');

// Lightweight Prometheus text-format parser.
// Returns Map<metricName, { help, type, samples: [{labels, value}] }>
function parseMetrics(text) {
  const out = new Map();
  let currentHelp = null;
  let currentType = null;

  for (const rawLine of text.split('\n')) {
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
    let metricName, labelsStr, rawValue;

    if (braceOpen !== -1 && braceClose !== -1) {
      metricName = line.slice(0, braceOpen);
      labelsStr  = line.slice(braceOpen + 1, braceClose);
      rawValue   = line.slice(braceClose + 1).trim().split(' ')[0];
    } else {
      const spaceIdx = line.indexOf(' ');
      metricName = line.slice(0, spaceIdx);
      labelsStr  = '';
      rawValue   = line.slice(spaceIdx + 1).trim().split(' ')[0];
    }

    const value = Number(rawValue);
    if (isNaN(value)) continue;

    const labels = {};
    if (labelsStr) {
      for (const pair of labelsStr.matchAll(/([\w]+)="([^"]*)"/g)) {
        labels[pair[1]] = pair[2];
      }
    }

    if (!out.has(metricName)) {
      out.set(metricName, {
        help:    currentHelp?.name === metricName ? currentHelp.help : '',
        type:    currentType?.name === metricName ? currentType.type : 'untyped',
        samples: []
      });
    }
    out.get(metricName).samples.push({ labels, value });
  }

  return out;
}

// Fetch + parse Prometheus metrics. Returns parsed Map or null on failure.
async function fetchMetrics() {
  const url = config.urls?.metrics;
  if (!url) return null;

  try {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 3000);
    const res = await fetch(url, { signal: controller.signal });
    clearTimeout(timer);
    if (!res.ok) return null;
    return parseMetrics(await res.text());
  } catch (_) {
    return null;
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

module.exports = { parseMetrics, fetchMetrics, metricVal, metricSum };
