'use strict';

const express = require('express');
const { escapeHtml, renderPage } = require('../lib/render');
const { requireFreshLogin } = require('../lib/sessionUser');
const { isMaster } = require('../lib/permissions');
const { parsePositiveInt } = require('../lib/requestParams');
const { metricVal } = require('../lib/metrics');
const { getCachedMetrics } = require('../lib/integrationCache');
const { readPartylineRuntime } = require('../lib/partylineRuntime');
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

function runtimeBadgeCount(runtimeFile, runtimeSessions) {
  if (runtimeFile && runtimeFile.ok) {
    return `${Number(runtimeFile.count) || 0} runtime`;
  }

  return fmtRuntimeCount(runtimeSessions);
}

function runtimeFreshLabel(runtimeFile) {
  if (!runtimeFile || !runtimeFile.ok) return ' — unavailable';
  return runtimeFile.stale ? ' — stale snapshot' : ' — fresh';
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
  let runtimeFile = await readPartylineRuntime();
  let dbUsers = [];
  let bans = [];
  let dbError = null;

  try {
    const metricsResult = await getCachedMetrics({ maxSamplesPerMetric: 20, force: req.query.refresh === '1' });
    const metrics = metricsResult.value;
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
  <span class="mbw-count-badge">${escapeHtml(runtimeBadgeCount(runtimeFile, runtimeSessions))}</span>
</section>

<section class="mbw-card mbw-wide">
  <h2>Runtime Partyline Sessions</h2>
  <p class="mbw-muted-cell">
    Source: ${escapeHtml(runtimeFile.path)}
    ${runtimeFreshLabel(runtimeFile)}
    ${runtimeFile.ageMs !== null && runtimeFile.ageMs !== undefined ? ` — Snapshot age: ${escapeHtml(String(Math.round(runtimeFile.ageMs / 1000)))}s` : ''}
  </p>

  <div class="mbw-metric-grid">
    <div class="mbw-metric-tile">
      <span>Runtime sessions</span>
      <strong>${runtimeFile.ok ? escapeHtml(String(runtimeFile.count)) : '—'}</strong>
    </div>
    <div class="mbw-metric-tile">
      <span>Metrics fallback</span>
      <strong>${runtimeSessions === null || runtimeSessions === undefined ? '—' : escapeHtml(String(runtimeSessions))}</strong>
    </div>
  </div>

  ${runtimeFile.ok && runtimeFile.sessions.length ? `
  <div class="mbw-table-wrap">
    <table class="mbw-data-table">
      <thead>
        <tr>
          <th>Login</th>
          <th>Level</th>
          <th>Type</th>
          <th>Console</th>
          <th>Host</th>
          <th>Age</th>
        </tr>
      </thead>
      <tbody>
        ${runtimeFile.sessions.map(s => `
          <tr>
            <td>${escapeHtml(s.login || '?')}</td>
            <td>${escapeHtml(s.level_desc || String(s.level ?? '?'))}</td>
            <td>${escapeHtml(s.session_type)}</td>
            <td>${s.console_level === null ? 'off' : escapeHtml(String(s.console_level))}</td>
            <td class="mono">${escapeHtml(s.peer_host || '')}</td>
            <td>${s.age_seconds === null ? '—' : escapeHtml(String(Math.max(0, Math.round(s.age_seconds)))) + 's'}</td>
          </tr>
        `).join('')}
      </tbody>
    </table>
  </div>` : `
    <p class="mbw-muted-cell">
      ${runtimeFile.ok ? 'No live authenticated Partyline sessions found in runtime JSON.' : escapeHtml(runtimeFile.error || 'Runtime file unavailable.')}
    </p>
  `}
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
