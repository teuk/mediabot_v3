'use strict';

const express = require('express');
const { config } = require('../lib/config');
const { requireFreshLogin } = require('../lib/sessionUser');
const { isOwner } = require('../lib/permissions');
const { fetchMetrics } = require('../lib/metrics');
const { parsePositiveInt, cleanSearch } = require('../lib/requestParams');

const router = express.Router();

function parseMetricNames(raw) {
  const cleaned = cleanSearch(raw, { maxLength: 1000 });
  if (!cleaned) return null;

  const names = cleaned
    .split(',')
    .map(s => s.trim())
    .filter(Boolean)
    .filter(s => /^[A-Za-z_:][A-Za-z0-9_:]*$/.test(s))
    .slice(0, 50);

  return names.length ? new Set(names) : null;
}

router.get('/api/metrics', requireFreshLogin, async (req, res) => {
  if (!isOwner(req.session.user)) {
    return res.status(403).json({ ok: false, error: 'Forbidden' });
  }

  res.set('Cache-Control', 'no-store');

  const maxSamples = parsePositiveInt(
    req.query.max_samples,
    250,
    { min: 1, max: 5000 }
  );

  const wantedNames = parseMetricNames(req.query.names);

  try {
    const parsed = await fetchMetrics({ maxSamplesPerMetric: maxSamples });
    if (!parsed) {
      return res.status(503).json({ ok: false, error: 'Metrics endpoint unreachable' });
    }

    const out = {};
    let metricCount = 0;
    let sampleCount = 0;
    let truncatedMetricCount = 0;

    for (const [name, entry] of parsed) {
      if (wantedNames && !wantedNames.has(name)) continue;

      metricCount += 1;
      sampleCount += entry.samples.length;
      if (entry.truncated) truncatedMetricCount += 1;

      out[name] = {
        help: entry.help,
        type: entry.type,
        samples: entry.samples,
        truncated: Boolean(entry.truncated)
      };
    }

    res.json({
      ok: true,
      metricsUrl: config.urls?.metrics,
      metricCount,
      sampleCount,
      maxSamplesPerMetric: maxSamples,
      truncatedMetricCount,
      filtered: Boolean(wantedNames),
      metrics: out
    });
  } catch (err) {
    console.error('[mbweb][/api/metrics] error:', err.message);
    res.status(500).json({ ok: false, error: 'Internal server error' });
  }
});

module.exports = router;
