'use strict';

const express = require('express');
const { config, safeBase } = require('../lib/config');
const { escapeHtml, renderPage } = require('../lib/render');
const { requireLogin } = require('../lib/sessionUser');
const { isOwner, isMaster, isAdministrator, can } = require('../lib/permissions');
const { fetchMetrics } = require('../lib/metrics');

const router = express.Router();

router.get('/api/metrics', requireLogin, async (req, res) => {
  if (!isOwner(req.session.user)) {
    return res.status(403).json({ ok: false, error: 'Forbidden' });
  }

  try {
    const parsed = await fetchMetrics();
    if (!parsed) {
      return res.status(503).json({ ok: false, error: 'Metrics endpoint unreachable' });
    }

    const out = {};
    for (const [name, entry] of parsed) {
      out[name] = {
        help: entry.help,
        type: entry.type,
        samples: entry.samples
      };
    }

    res.json({ ok: true, metricsUrl: config.urls?.metrics, metrics: out });
  } catch (err) {
    console.error('[mbweb][/api/metrics] error:', err.message);
    res.status(500).json({ ok: false, error: 'Internal server error' });
  }
});

// ─── Quotes explorer ───────────────────────────────────────────────────────


module.exports = router;
