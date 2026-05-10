'use strict';

const express = require('express');
const { escapeHtml, renderPage } = require('../lib/render');
const { requireFreshLogin } = require('../lib/sessionUser');
const { isMaster } = require('../lib/permissions');
const { parsePositiveInt } = require('../lib/requestParams');
const { fetchMetrics, metricVal } = require('../lib/metrics');
const {
  getAuthenticatedDbUsers,
  getRecentChannelBans
} = require('../lib/mediabotRepository');

const router = express.Router();

function fmtDate(d) {
  return d ? new Date(d).toISOString().replace('T', ' ').slice(0, 16) : '—';
}

function fmtRuntimeCount(value) {
  if (value === null || value === undefined) return 'runtime unavailable';
  return `${Number(value) || 0} runtime`;
}

// ── /partyline – Partyline status page (Master+) ─────────────────────────────
// Important:
//   Real Partyline telnet/DCC sessions live in the Perl bot process memory.
//   USER.auth = 1 is not the same thing: it is the DB/IRC auth flag.
//   mbweb can only show the runtime Partyline count through Prometheus metrics,
//   unless the bot later exposes a dedicated Partyline status endpoint/table.
router.get('/partyline', requireFreshLogin, async (req, res) => {
  const user = req.session.user;

  if (!isMaster(user)) {
    return res.status(403).send(renderPage('Forbidden',
      `<section class="mbw-card"><p class="error">Master level required.</p></section>`,
      req
    ));
  }

  const banLimit = parsePositiveInt(req.query.limit, 20, { min: 1, max: 100 });

  let runtimeSessions = null;
  let runtimeMetricsStatus = 'Metrics endpoint unavailable';
  let dbUsers = [];
  let bans = [];
  let dbError = null;

  try {
    const metrics = await fetchMetrics({ maxSamplesPerMetric: 20 });
    if (metrics) {
      const val = metricVal(metrics, 'mediabot_partyline_sessions_current');
      if (val !== null && val !== undefined) {
        runtimeSessions = val;
        runtimeMetricsStatus = 'Runtime count from mediabot_partyline_sessions_current';
      } else {
        runtimeMetricsStatus = 'Metric mediabot_partyline_sessions_current not found';
      }
    }
  } catch (err) {
    console.error('[mbweb][partyline] metrics error:', err.message);
    runtimeMetricsStatus = 'Unable to read runtime Partyline metrics';
  }

  try {
    [dbUsers, bans] = await Promise.all([
      getAuthenticatedDbUsers(),
      getRecentChannelBans(banLimit)
    ]);
  } catch (err) {
    console.error('[mbweb][partyline] DB error:', err.message);
    dbError = 'Unable to load Partyline/DB data.';
  }

  const userRows = dbUsers.length
    ? dbUsers.map(s => `
        <tr>
          <td>${escapeHtml(s.nickname)}</td>
          <td>${escapeHtml(s.level_desc)}</td>
          <td>${fmtDate(s.last_login)}</td>
        </tr>`).join('')
    : `<tr><td colspan="3" class="empty">No DB-authenticated IRC users.</td></tr>`;

  const banRows = bans.length
    ? bans.map(b => {
        const active  = b.active ? '✓' : '✗';
        const expires = b.expires_at ? fmtDate(b.expires_at) : 'permanent';
        const reason  = b.reason || '';

        return `
        <tr class="${b.active ? '' : 'inactive'}">
          <td>${escapeHtml(b.channel_name)}</td>
          <td class="mono">${escapeHtml(b.mask)}</td>
          <td>${escapeHtml(String(b.ban_level ?? ''))}</td>
          <td>${escapeHtml(b.created_by_nick || '?')}</td>
          <td>${fmtDate(b.created_at)}</td>
          <td>${expires}</td>
          <td>${active}</td>
          <td>${escapeHtml(reason)}</td>
        </tr>`;
      }).join('')
    : `<tr><td colspan="8" class="empty">No recent bans.</td></tr>`;

  const body = `
<section class="mbw-hero">
  <div>
    <p class="mbw-kicker">Master view</p>
    <h1>Partyline</h1>
    <p>Runtime Partyline overview, IRC/DB authentication state, and recent ChannelBan activity.</p>
  </div>
  <span class="mbw-count-badge">${escapeHtml(fmtRuntimeCount(runtimeSessions))}</span>
</section>

<section class="mbw-card">
  <h2>Runtime Partyline Sessions</h2>
  <p>
    Current telnet/DCC Partyline sessions live inside the Perl bot process.
    mbweb cannot list nicknames from memory directly yet.
  </p>
  <p class="mbw-muted-cell">
    ${escapeHtml(runtimeMetricsStatus)}
  </p>
  <div class="mbw-metric-grid">
    <div class="mbw-metric-tile">
      <span>Runtime sessions</span>
      <strong>${runtimeSessions === null || runtimeSessions === undefined ? '—' : escapeHtml(String(runtimeSessions))}</strong>
    </div>
  </div>
</section>

${dbError ? `<section class="mbw-card"><p class="error">${escapeHtml(dbError)}</p></section>` : ''}

<section class="mbw-card mbw-wide">
  <h2>IRC / DB Authenticated Users (${dbUsers.length})</h2>
  <p class="mbw-muted-cell">
    This table is based on USER.auth = 1. It is not the live telnet Partyline session list.
  </p>
  <div class="mbw-table-wrap">
    <table class="mbw-data-table">
      <thead>
        <tr>
          <th>Nickname</th>
          <th>Level</th>
          <th>Last login</th>
        </tr>
      </thead>
      <tbody>${userRows}</tbody>
    </table>
  </div>
</section>

<section class="mbw-card mbw-wide">
  <div class="mbw-section-head">
    <div>
      <h2>Recent Channel Bans</h2>
      <p>Last ${escapeHtml(String(banLimit))} added bans.</p>
    </div>
  </div>
  <div class="mbw-table-wrap">
    <table class="mbw-data-table">
      <thead>
        <tr>
          <th>Channel</th>
          <th>Mask</th>
          <th>Level</th>
          <th>By</th>
          <th>Added</th>
          <th>Expires</th>
          <th>Active</th>
          <th>Reason</th>
        </tr>
      </thead>
      <tbody>${banRows}</tbody>
    </table>
  </div>
</section>

<style>
  tr.inactive { opacity: 0.5; }
  td.mono { font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace; font-size: 0.84em; }
  td.empty { text-align: center; color: #888; padding: 1rem; }
</style>`;

  res.send(renderPage('Partyline', body, req));
});

module.exports = router;
