'use strict';

const express = require('express');
const { config, safeBase } = require('../lib/config');
const { escapeHtml, renderPage } = require('../lib/render');
const { requireFreshLogin } = require('../lib/sessionUser');
const { isOwner, isMaster, isAdministrator, can } = require('../lib/permissions');
const { getCachedRadioStatus } = require('../lib/integrationCache');

const router = express.Router();

router.get('/api/radio/status', requireFreshLogin, async (req, res) => {
  try {
    const radioResult = await getCachedRadioStatus({ force: req.query.refresh === '1' });
    const radio = radioResult.value;
    res.set('X-MBWeb-Cache', radioResult.cached ? 'HIT' : 'MISS');
    res.json({
      ok: true,
      radio
    });
  } catch (err) {
    console.error('[mbweb][radio] exception', err.message);
    res.status(500).json({
      ok: false,
      error: 'Internal server error'
    });
  }
});

router.get('/radio', requireFreshLogin, async (req, res) => {
  let radio;

  try {
    const radioResult = await getCachedRadioStatus({ force: req.query.refresh === '1' });
    radio = radioResult.value;
  } catch (err) {
    radio = {
      ok: false,
      rawError: err.message,
      mounts: [],
      primary: null
    };
  }

  const primary = radio.primary;
  const mounts = radio.mounts || [];
  const totalListeners = mounts.reduce((sum, m) => sum + Number(m.listeners || 0), 0);
  const activeMounts = mounts.length;

  const body = `
<section class="mbw-hero">
  <div>
    <p class="mbw-kicker">Radio</p>
    <h1>Radio status</h1>
    <p>
      Radio status exposed from Icecast. This page is read-only
      and uses the status stream configured for Mediabot.
    </p>
    <div class="mbw-actions">
      <a class="mbw-primary" href="${escapeHtml(radio.publicListenUrl || '#')}">Listen to main mount</a>
      <a class="mbw-secondary" href="${safeBase('/api/radio/status')}">API radio</a>
    </div>
  </div>
</section>

<section class="mbw-grid">
  <article class="mbw-card">
    <h2>Icecast</h2>
    <p class="${radio.ok ? 'mbw-ok' : 'mbw-bad'}">${radio.ok ? 'online' : 'unavailable'}</p>
    <p>${escapeHtml(radio.statusUrl || '')}</p>
    ${radio.rawError ? `<pre>${escapeHtml(radio.rawError)}</pre>` : ''}
  </article>

  <article class="mbw-card">
    <h2>Active mounts</h2>
    <p class="mbw-big">${escapeHtml(activeMounts)}</p>
    <p>mounts returned by Icecast.</p>
  </article>

  <article class="mbw-card">
    <h2>Total listeners</h2>
    <p class="mbw-big">${escapeHtml(totalListeners)}</p>
    <p>across all active mounts.</p>
  </article>
</section>

<section class="mbw-card mbw-wide">
  <div class="mbw-section-head">
    <div>
      <h2>Now playing</h2>
      <p>Summary of the primary mount configured for Mediabot.</p>
    </div>
    <span class="mbw-count-badge">${escapeHtml(radio.primaryMount || 'n/a')}</span>
  </div>

  ${primary ? `
    <div class="mbw-table-wrap compact">
      <table class="mbw-data-table mbw-radio-current-table">
        <thead>
          <tr>
            <th>Mount</th>
            <th>Title</th>
            <th>Artist</th>
            <th>Bitrate</th>
            <th>Listeners</th>
            <th>Peak</th>
            <th>Started</th>
            <th>Listen</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td class="mbw-radio-main">
              <strong>${escapeHtml(radio.primaryMount || primary.mount || 'n/a')}</strong>
              <small>primary mount</small>
            </td>
            <td class="mbw-radio-title">${escapeHtml(primary.title || 'n/a')}</td>
            <td class="mbw-muted-cell">${escapeHtml(primary.artist || 'n/a')}</td>
            <td class="mbw-number-cell">${escapeHtml(primary.bitrate ?? 'n/a')}</td>
            <td class="mbw-number-cell">${escapeHtml(primary.listeners ?? 'n/a')}</td>
            <td class="mbw-number-cell">${escapeHtml(primary.listenerPeak ?? 'n/a')}</td>
            <td class="mbw-date-cell">${escapeHtml(primary.streamStart || 'n/a')}</td>
            <td><a class="mbw-table-action" href="${escapeHtml(primary.publicListenUrl || radio.publicListenUrl || '#')}">open</a></td>
          </tr>
        </tbody>
      </table>
    </div>
  ` : `<p>No active primary mount detected.</p>`}
</section>

<section class="mbw-card mbw-wide">
  <div class="mbw-section-head">
    <div>
      <h2>Mounts Icecast</h2>
      <p>Comparative view of streams currently exposed by Icecast.</p>
    </div>
    <span class="mbw-count-badge">${escapeHtml(mounts.length)} mounts</span>
  </div>

  ${mounts.length ? `
    <div class="mbw-table-wrap">
      <table class="mbw-data-table mbw-radio-table">
        <thead>
          <tr>
            <th>Mount</th>
            <th>Title</th>
            <th>Listeners</th>
            <th>Peak</th>
            <th>Bitrate</th>
            <th>Content</th>
            <th>Started</th>
            <th>Listen</th>
          </tr>
        </thead>
        <tbody>
          ${mounts.map(m => `
            <tr>
              <td class="mbw-radio-main">
                <strong>${escapeHtml(m.mount || 'unknown')}</strong>
                <small>${escapeHtml(m.serverName || '')}</small>
              </td>
              <td class="mbw-radio-title">${escapeHtml(m.title || m.serverDescription || 'n/a')}</td>
              <td class="mbw-number-cell">${escapeHtml(m.listeners ?? 'n/a')}</td>
              <td class="mbw-number-cell">${escapeHtml(m.listenerPeak ?? 'n/a')}</td>
              <td class="mbw-number-cell">${escapeHtml(m.bitrate ?? 'n/a')}</td>
              <td class="mbw-muted-cell">${escapeHtml(m.contentType || 'n/a')}</td>
              <td class="mbw-date-cell">${escapeHtml(m.streamStart || 'n/a')}</td>
              <td><a class="mbw-table-action" href="${escapeHtml(m.publicListenUrl || '#')}">open</a></td>
            </tr>
          `).join('')}
        </tbody>
      </table>
    </div>
  ` : `<p>No active mount returned by Icecast.</p>`}
</section>
`;

  res.send(renderPage('Radio', body, req));
});



// ─── Network topology ──────────────────────────────────────────────────────


module.exports = router;
