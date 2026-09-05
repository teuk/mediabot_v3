'use strict';

const express = require('express');
const { config, safeBase } = require('../lib/config');
const { escapeHtml, renderPage } = require('../lib/render');
const { csrfField } = require('../lib/csrf');
const { requireFreshLogin } = require('../lib/sessionUser');
const { logAudit } = require('../lib/securityLog');
const { isOwner } = require('../lib/permissions');
const { ping } = require('../lib/db');
const { metricVal } = require('../lib/metrics');
const {
  getCachedMetrics,
  getCachedRadioStatus,
  clearIntegrationCache,
  getIntegrationCacheStats
} = require('../lib/integrationCache');

const router = express.Router();

function statusPill(ok, text) {
  return `<span class="mbw-status-pill ${ok ? 'ok' : 'bad'}">${escapeHtml(text)}</span>`;
}

router.get('/diagnostics', requireFreshLogin, async (req, res) => {
  if (!isOwner(req.session.user)) {
    return res.status(403).send(renderPage('Forbidden',
      `<section class="mbw-card"><p class="error">Owner level required.</p></section>`,
      req
    ));
  }

  const checks = [];

  try {
    const db = await ping();
    checks.push({
      name: 'MariaDB',
      ok: true,
      detail: `${db?.db || config.db.database}@${config.db.host}:${config.db.port}`
    });
  } catch (err) {
    checks.push({ name: 'MariaDB', ok: false, detail: 'unavailable' });
  }

  try {
    const metricsResult = await getCachedMetrics({ maxSamplesPerMetric: 20 });
    const metrics = metricsResult.value;
    if (metrics) {
      const partyline = metricVal(metrics, 'mediabot_partyline_sessions_current');
      checks.push({
        name: 'Prometheus metrics',
        ok: true,
        detail: partyline === null || partyline === undefined
          ? 'reachable, partyline metric not found'
          : `reachable, partyline sessions=${partyline}`
      });
    } else {
      checks.push({ name: 'Prometheus metrics', ok: false, detail: 'unreachable or invalid' });
    }
  } catch (err) {
    checks.push({ name: 'Prometheus metrics', ok: false, detail: 'unavailable' });
  }

  try {
    const radioResult = await getCachedRadioStatus();
    const radio = radioResult.value;
    checks.push({
      name: 'Icecast radio',
      ok: Boolean(radio.ok),
      detail: radio.ok
        ? `${radio.mounts.length} mount(s), listeners=${radio.mounts.reduce((s, m) => s + Number(m.listeners || 0), 0)}`
        : 'unavailable'
    });
  } catch (err) {
    checks.push({ name: 'Icecast radio', ok: false, detail: 'unavailable' });
  }

  const cacheRows = getIntegrationCacheStats().map(c => `
    <tr>
      <td><code>${escapeHtml(c.key)}</code></td>
      <td>${escapeHtml(String(Math.round(c.ageMs / 1000)))}s</td>
      <td>${escapeHtml(String(Math.round(c.expiresInMs / 1000)))}s</td>
      <td>${c.expired ? statusPill(false, 'expired') : statusPill(true, 'fresh')}</td>
    </tr>
  `).join('') || `<tr><td colspan="4" class="empty">No cache entries yet.</td></tr>`;

  const rows = checks.map(c => `
    <tr>
      <td><strong>${escapeHtml(c.name)}</strong></td>
      <td>${statusPill(c.ok, c.ok ? 'OK' : 'FAIL')}</td>
      <td>${escapeHtml(c.detail || '')}</td>
    </tr>
  `).join('');

  const body = `
<section class="mbw-hero">
  <div>
    <p class="mbw-kicker">Owner diagnostics</p>
    <h1>mbweb diagnostics</h1>
    <p>Quick health view for DB, metrics and radio integrations. No secrets are displayed.</p>
    <div class="mbw-actions">
      <a class="mbw-secondary" href="${safeBase('/api/status')}">API status</a>
      <a class="mbw-secondary" href="${safeBase('/api/metrics?max_samples=20')}">Metrics API</a>
    </div>
  </div>
</section>

<section class="mbw-card mbw-wide">
  <h2>Runtime checks</h2>
  <div class="mbw-table-wrap">
    <table class="mbw-data-table">
      <thead>
        <tr>
          <th>Component</th>
          <th>Status</th>
          <th>Detail</th>
        </tr>
      </thead>
      <tbody>${rows}</tbody>
    </table>
  </div>
</section>

<section class="mbw-card mbw-wide">
  <div class="mbw-section-head">
    <div>
      <h2>Integration cache</h2>
      <p>Short-lived cache for metrics and radio calls.</p>
    </div>
    <form method="post" action="${safeBase('/diagnostics/cache/clear')}" class="mbw-inline-form">
      ${csrfField(req)}
      <button class="mbw-secondary" type="submit">Clear cache</button>
    </form>
  </div>
  <div class="mbw-table-wrap">
    <table class="mbw-data-table">
      <thead>
        <tr>
          <th>Key</th>
          <th>Age</th>
          <th>Expires in</th>
          <th>Status</th>
        </tr>
      </thead>
      <tbody>${cacheRows}</tbody>
    </table>
  </div>
</section>
`;

  res.send(renderPage('Diagnostics', body, req));
});

router.post('/diagnostics/cache/clear', requireFreshLogin, async (req, res) => {
  if (!isOwner(req.session.user)) {
    return res.status(403).send(renderPage('Forbidden',
      `<section class="mbw-card"><p class="error">Owner level required.</p></section>`,
      req
    ));
  }

  const cleared = clearIntegrationCache();
  logAudit(console, 'cache.clear', { cleared });
  res.redirect(safeBase('/diagnostics'));
});


router.get('/api/cache/status', requireFreshLogin, async (req, res) => {
  if (!isOwner(req.session.user)) {
    return res.status(403).json({ ok: false, error: 'Forbidden' });
  }

  res.set('Cache-Control', 'no-store');

  res.json({
    ok: true,
    cache: getIntegrationCacheStats()
  });
});

router.post('/api/cache/clear', requireFreshLogin, async (req, res) => {
  if (!isOwner(req.session.user)) {
    return res.status(403).json({ ok: false, error: 'Forbidden' });
  }

  const cleared = clearIntegrationCache();
  logAudit(console, 'cache.clear', { cleared });

  res.set('Cache-Control', 'no-store');

  res.json({
    ok: true,
    cleared
  });
});


module.exports = router;
