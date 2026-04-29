'use strict';

const express = require('express');
const { config, safeBase } = require('../lib/config');
const { escapeHtml, renderPage } = require('../lib/render');
const { requireLogin } = require('../lib/sessionUser');
const { isOwner, isMaster, isAdministrator, can } = require('../lib/permissions');
const { getNetworks } = require('../lib/mediabotRepository');

const router = express.Router();

router.get('/api/network', requireLogin, async (req, res) => {
  if (!isMaster(req.session.user)) {
    return res.status(403).json({ ok: false, error: 'Forbidden' });
  }

  try {
    const networks = await getNetworks();
    res.json({ ok: true, total: networks.length, networks });
  } catch (err) {
    console.error('[mbweb][/api/network] error:', err.message);
    res.status(500).json({ ok: false, error: 'Internal server error' });
  }
});

router.get('/network', requireLogin, async (req, res) => {
  if (!isMaster(req.session.user)) {
    return res.status(403).send(renderPage('Access denied', `
<section class="mbw-card">
  <h1>Access denied</h1>
  <p>This page is restricted to Owner and Master.</p>
  <a href="${safeBase('/')}">← Back to home</a>
</section>
`, req));
  }

  let networks;

  try {
    networks = await getNetworks();
  } catch (err) {
    console.error('[mbweb][/network] error:', err.message);
    return res.status(500).send(renderPage('Error', `
<section class="mbw-card">
  <h1>Server error</h1>
  <p>Unable to load network topology.</p>
</section>
`, req));
  }

  const totalServers = networks.reduce((s, n) => s + n.servers.length, 0);

  const networkCards = networks.length ? networks.map(net => `
    <article class="mbw-network-card">
      <header class="mbw-network-header">
        <div>
          <h3>${escapeHtml(net.network_name || 'unnamed')}</h3>
          <span class="mbw-count-badge">${escapeHtml(net.servers.length)} server(s)</span>
        </div>
        <span class="mbw-muted-cell">id_network ${escapeHtml(net.id_network ?? 'n/a')}</span>
      </header>

      ${net.servers.length ? `
        <div class="mbw-server-list">
          ${net.servers.map(s => `
            <div class="mbw-server-row">
              <span class="mbw-server-host">${escapeHtml(s.hostname || s.raw || 'n/a')}</span>
              ${s.port ? `<span class="mbw-server-port">:${escapeHtml(s.port)}</span>` : ''}
              <span class="mbw-server-id">id_server ${escapeHtml(s.id_server ?? 'n/a')}</span>
            </div>
          `).join('')}
        </div>
      ` : `<p class="mbw-muted-cell">No server defined for this network.</p>`}
    </article>
  `).join('') : `<p>No IRC network configured in the Mediabot database.</p>`;

  const body = `
<section class="mbw-hero">
  <div>
    <p class="mbw-kicker">Infrastructure</p>
    <h1>IRC Network Topology</h1>
    <p>
      IRC networks and servers configured in the Mediabot database.
      Read-only — edit via the <code>conf_servers.pl</code> script.
    </p>
    <div class="mbw-actions">
      <a class="mbw-primary" href="${safeBase('/api/network')}">API JSON</a>
      <a class="mbw-secondary" href="${safeBase('/')}">Home</a>
    </div>
  </div>
</section>

<section class="mbw-grid">
  <article class="mbw-card">
    <h2>Networks</h2>
    <p class="mbw-big">${escapeHtml(networks.length)}</p>
    <p>entries in NETWORK.</p>
  </article>

  <article class="mbw-card">
    <h2>Servers</h2>
    <p class="mbw-big">${escapeHtml(totalServers)}</p>
    <p>entries in SERVERS.</p>
  </article>

  <article class="mbw-card">
    <h2>Avg. servers</h2>
    <p class="mbw-big">${escapeHtml(networks.length ? (totalServers / networks.length).toFixed(1) : 'n/a')}</p>
    <p>per configured network.</p>
  </article>
</section>

<section class="mbw-card mbw-wide">
  <div class="mbw-section-head">
    <div>
      <h2>Configured IRC networks</h2>
      <p>
        Each network lists its connection servers.
        Mediabot picks a server at random from the available list.
      </p>
    </div>
    <span class="mbw-count-badge">${escapeHtml(networks.length)} networks</span>
  </div>

  <div class="mbw-network-grid">
    ${networkCards}
  </div>
</section>
`;

  res.send(renderPage('Network', body, req));
});

// ─── Metrics proxy (Owner only) ────────────────────────────────────────────


module.exports = router;
