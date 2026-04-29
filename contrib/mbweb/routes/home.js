'use strict';

const express = require('express');
const { config, safeBase } = require('../lib/config');
const { escapeHtml, renderPage } = require('../lib/render');
const { requireLogin } = require('../lib/sessionUser');
const { isOwner, isMaster, isAdministrator, can } = require('../lib/permissions');
const { boolLabel, fmtUptime } = require('../lib/viewHelpers');
const { fetchMetrics, metricVal } = require('../lib/metrics');
const { getDashboardData } = require('../lib/dashboardData');

const router = express.Router();

router.get('/', async (req, res) => {
  const [data, parsedMetrics] = await Promise.all([
    getDashboardData(req),
    fetchMetrics()
  ]);

  data.metrics = parsedMetrics
    ? {
        ok:                       true,
        irc_connected:            metricVal(parsedMetrics, 'mediabot_irc_connected'),
        db_connected:             metricVal(parsedMetrics, 'mediabot_db_connected'),
        up:                       metricVal(parsedMetrics, 'mediabot_up'),
        uptime_seconds:           metricVal(parsedMetrics, 'mediabot_uptime_seconds'),
        channels_managed:         metricVal(parsedMetrics, 'mediabot_channels_managed'),
        current_channels:         metricVal(parsedMetrics, 'mediabot_current_channels'),
        privmsg_in:               metricVal(parsedMetrics, 'mediabot_privmsg_in_total'),
        privmsg_out:              metricVal(parsedMetrics, 'mediabot_privmsg_out_total'),
        notice_out:               metricVal(parsedMetrics, 'mediabot_notice_out_total'),
        irc_login_total:          metricVal(parsedMetrics, 'mediabot_irc_login_total'),
        partyline_sessions:       metricVal(parsedMetrics, 'mediabot_partyline_sessions_current'),
        timers:                   metricVal(parsedMetrics, 'mediabot_timers_current')
      }
    : { ok: false };
  const user = req.session?.user || null;

  const channelPreviewRows = user && data.myChannels.length ? data.myChannels.slice(0, 8) : [];

  const guestBlock = `
<section class="mbw-card mbw-wide">
  <div class="mbw-section-head">
    <div>
      <h2>Mediabot user space</h2>
      <p>
        Log in with your Mediabot account to view your profile, channels,
        your permissions, radio, and tools tailored to your level.
      </p>
    </div>
    <a class="mbw-table-action" href="${safeBase('/login')}">Log in</a>
  </div>
</section>
`;

  const sessionBlock = user ? `
<section class="mbw-card mbw-wide">
  <div class="mbw-section-head">
    <div>
      <h2>Mediabot session</h2>
      <p>Summary of the connected account and detected global permissions.</p>
    </div>
    <span class="mbw-count-badge">${escapeHtml(user.global_role)}</span>
  </div>

  <div class="mbw-table-wrap compact">
    <table class="mbw-data-table mbw-home-session-table">
      <thead>
        <tr>
          <th>Nickname</th>
          <th>Username</th>
          <th>Global role</th>
          <th>Level</th>
          <th>Visible channels</th>
          <th>Timezone</th>
          <th>Last login</th>
        </tr>
      </thead>
      <tbody>
        <tr>
          <td class="mbw-user-main">
            <strong>${escapeHtml(user.nickname || 'unknown')}</strong>
            <small>id_user ${escapeHtml(user.id_user ?? 'n/a')}</small>
          </td>
          <td class="mbw-muted-cell">${escapeHtml(user.username || 'n/a')}</td>
          <td><span class="mbw-role-chip">${escapeHtml(user.global_role || 'n/a')}</span></td>
          <td class="mbw-number-cell">${escapeHtml(user.global_level ?? 'n/a')}</td>
          <td class="mbw-number-cell">${escapeHtml(user.channels_count ?? 'n/a')}</td>
          <td>${escapeHtml(user.tz || 'n/a')}</td>
          <td class="mbw-date-cell">${escapeHtml(user.last_login || 'n/a')}</td>
        </tr>
      </tbody>
    </table>
  </div>
</section>
` : guestBlock;

  const quickActions = user ? `
<section class="mbw-card mbw-wide">
  <div class="mbw-section-head">
    <div>
      <h2>Quick access</h2>
      <p>Views available based on your Mediabot level.</p>
    </div>
  </div>

  <div class="mbw-dashboard-grid">
    <a class="mbw-dashboard-tile" href="${safeBase('/profile')}">
      <strong>Profile</strong>
      <span>Identity, global level, hostmasks, timezone.</span>
    </a>

    <a class="mbw-dashboard-tile" href="${safeBase('/channels')}">
      <strong>Channels</strong>
      <span>Visible channels and associated permissions.</span>
    </a>

    <a class="mbw-dashboard-tile" href="${safeBase('/radio')}">
      <strong>Radio</strong>
      <span>Icecast, mounts, listeners and current track.</span>
    </a>

    ${isMaster(user) ? `
      <a class="mbw-dashboard-tile elevated" href="${safeBase('/users')}">
        <strong>Users</strong>
        <span>Global overview of Mediabot users.</span>
      </a>
    ` : ''}

    <a class="mbw-dashboard-tile" href="${safeBase('/api/dashboard')}">
      <strong>API dashboard</strong>
      <span>JSON state of your current dashboard.</span>
    </a>

    ${isOwner(user) ? `
      <a class="mbw-dashboard-tile owner" href="${safeBase('/api/status')}">
        <strong>Status API</strong>
        <span>Raw mbweb application state.</span>
      </a>
    ` : ''}
  </div>
</section>
` : '';

  const channelPreview = user ? `
<section class="mbw-card mbw-wide">
  <div class="mbw-section-head">
    <div>
      <h2>Accessible channels</h2>
      <p>Compact overview of channels visible to your account.</p>
    </div>
    <a class="mbw-table-action" href="${safeBase('/channels')}">View all</a>
  </div>

  ${channelPreviewRows.length ? `
    <div class="mbw-table-wrap">
      <table class="mbw-data-table mbw-home-channels-table">
        <thead>
          <tr>
            <th>Channel</th>
            <th>Description / topic</th>
            <th>Auto join</th>
            <th>Mode</th>
            <th>Chan. level</th>
            <th>Automode</th>
            <th>Detail</th>
          </tr>
        </thead>
        <tbody>
          ${channelPreviewRows.map(ch => {
            const autoJoin = Number(ch.auto_join || 0) === 1;
            const desc = ch.description || ch.topic || 'No description.';
            return `
              <tr>
                <td class="mbw-channel-main">
                  <strong>${escapeHtml(ch.name || 'unknown')}</strong>
                  <small>id_channel ${escapeHtml(ch.id_channel ?? 'n/a')}</small>
                </td>
                <td class="mbw-channel-desc">${escapeHtml(desc)}</td>
                <td>
                  <span class="mbw-status-pill ${autoJoin ? 'ok' : 'bad'}">
                    ${autoJoin ? 'yes' : 'no'}
                  </span>
                </td>
                <td class="mbw-muted-cell">${escapeHtml(ch.chanmode || 'n/a')}</td>
                <td class="mbw-number-cell">${escapeHtml(ch.channel_level ?? 'n/a')}</td>
                <td class="mbw-muted-cell">${escapeHtml(ch.automode ?? 'n/a')}</td>
                <td><a class="mbw-table-action" href="${safeBase('/channels/' + ch.id_channel)}">open</a></td>
              </tr>
            `;
          }).join('')}
        </tbody>
      </table>
    </div>
  ` : `<p>No accessible channel for this account.</p>`}
</section>
` : '';


  const metricsBlock = data.metrics ? `
<section class="mbw-card mbw-wide">
  <div class="mbw-section-head">
    <div>
      <h2>Bot Mediabot — live metrics</h2>
      <p>Prometheus endpoint: <code>${escapeHtml(config.urls?.metrics || 'n/a')}</code></p>
    </div>
    <span class="mbw-count-badge ${data.metrics.ok ? 'ok' : 'bad'}">${data.metrics.ok ? 'online' : 'unreachable'}</span>
  </div>

  ${data.metrics.ok ? `
    <div class="mbw-metrics-grid">
      <div class="mbw-metric-tile ${Number(data.metrics.irc_connected) ? 'ok' : 'bad'}">
        <span>IRC</span>
        <strong>${Number(data.metrics.irc_connected) ? 'connected' : 'disconnected'}</strong>
      </div>
      <div class="mbw-metric-tile ${Number(data.metrics.db_connected) ? 'ok' : 'bad'}">
        <span>DB</span>
        <strong>${Number(data.metrics.db_connected) ? 'connected' : 'error'}</strong>
      </div>
      <div class="mbw-metric-tile">
        <span>Uptime</span>
        <strong>${escapeHtml(fmtUptime(data.metrics.uptime_seconds))}</strong>
      </div>
      <div class="mbw-metric-tile">
        <span>Managed channels</span>
        <strong>${escapeHtml(data.metrics.channels_managed ?? 'n/a')}</strong>
      </div>
      <div class="mbw-metric-tile">
        <span>Joined channels</span>
        <strong>${escapeHtml(data.metrics.current_channels ?? 'n/a')}</strong>
      </div>
      <div class="mbw-metric-tile">
        <span>Messages in</span>
        <strong>${escapeHtml(data.metrics.privmsg_in ?? 'n/a')}</strong>
      </div>
      <div class="mbw-metric-tile">
        <span>Messages out</span>
        <strong>${escapeHtml(data.metrics.privmsg_out ?? 'n/a')}</strong>
      </div>
      <div class="mbw-metric-tile">
        <span>Notices out</span>
        <strong>${escapeHtml(data.metrics.notice_out ?? 'n/a')}</strong>
      </div>
      <div class="mbw-metric-tile">
        <span>IRC logins</span>
        <strong>${escapeHtml(data.metrics.irc_login_total ?? 'n/a')}</strong>
      </div>
      <div class="mbw-metric-tile ${Number(data.metrics.partyline_sessions) > 0 ? 'ok' : ''}">
        <span>Partyline</span>
        <strong>${escapeHtml(data.metrics.partyline_sessions ?? 'n/a')} session(s)</strong>
      </div>
      <div class="mbw-metric-tile">
        <span>Active timers</span>
        <strong>${escapeHtml(data.metrics.timers ?? 'n/a')}</strong>
      </div>
    </div>
    <p class="mbw-muted-small">
      <a href="${safeBase('/api/metrics')}">View all metrics →</a>
    </p>
  ` : `<p class="mbw-bad">Prometheus endpoint unreachable.</p>`}
</section>
` : '';

  const ownerSystemBlock = user && isOwner(user) ? `
<section class="mbw-card mbw-wide">
  <div class="mbw-section-head">
    <div>
      <h2>Owner view</h2>
      <p>Global summary restricted to Owner.</p>
    </div>
    <span class="mbw-count-badge">owner view</span>
  </div>

  <div class="mbw-table-wrap compact">
    <table class="mbw-data-table mbw-home-system-table">
      <thead>
        <tr>
          <th>Item</th>
          <th>Value</th>
          <th>Detail</th>
          <th>Access</th>
        </tr>
      </thead>
      <tbody>
        <tr>
          <td><strong>Users</strong></td>
          <td class="mbw-number-cell">${escapeHtml(data.counts.users ?? 'n/a')}</td>
          <td class="mbw-muted-cell">Mediabot accounts in USER.</td>
          <td><a class="mbw-table-action" href="${safeBase('/users')}">open</a></td>
        </tr>
        <tr>
          <td><strong>Channels</strong></td>
          <td class="mbw-number-cell">${escapeHtml(data.counts.channels ?? 'n/a')}</td>
          <td class="mbw-muted-cell">Known channels in CHANNEL.</td>
          <td><a class="mbw-table-action" href="${safeBase('/channels')}">open</a></td>
        </tr>
        <tr>
          <td><strong>API status</strong></td>
          <td class="${data.db.ok ? 'mbw-ok' : 'mbw-bad'}">${data.db.ok ? 'ok' : 'error'}</td>
          <td class="mbw-muted-cell">${escapeHtml(data.db.user)}@${escapeHtml(data.db.host)} / ${escapeHtml(data.db.name)}</td>
          <td><a class="mbw-table-action" href="${safeBase('/api/status')}">open</a></td>
        </tr>
      </tbody>
    </table>
  </div>
</section>
` : '';

  const body = `
<section class="mbw-hero">
  <div>
    <p class="mbw-kicker">User console</p>
    <h1>Mediabot v3</h1>
    <p>
      Your Mediabot console: profile, channels, permissions, radio
      and views tailored to your global level.
    </p>
    <div class="mbw-actions">
      ${user ? `<a class="mbw-primary" href="${safeBase('/profile')}">My profile</a>` : `<a class="mbw-primary" href="${safeBase('/login')}">Log in</a>`}
      <a class="mbw-secondary" href="${safeBase('/health')}">Healthcheck</a>
    </div>
  </div>
</section>

<section class="mbw-grid">
  <article class="mbw-card">
    <h2>Base Mediabot</h2>
    <p class="${data.db.ok ? 'mbw-ok' : 'mbw-bad'}">${data.db.ok ? 'Connected' : 'DB error'}</p>
    <p>${escapeHtml(data.db.user)}@${escapeHtml(data.db.host)} / ${escapeHtml(data.db.name)}</p>
    ${data.db.error ? `<pre>${escapeHtml(data.db.error)}</pre>` : ''}
  </article>

  <article class="mbw-card">
    <h2>Users</h2>
    <p class="mbw-big">${escapeHtml(data.counts.users ?? 'n/a')}</p>
    <p>Entries in USER table.</p>
  </article>

  <article class="mbw-card">
    <h2>Channels</h2>
    <p class="mbw-big">${escapeHtml(data.counts.channels ?? 'n/a')}</p>
    <p>Entries in CHANNEL table.</p>
  </article>
</section>

${sessionBlock}
${quickActions}
${channelPreview}
${metricsBlock}
${ownerSystemBlock}
`;

  res.send(renderPage('Home', body, req));
});



module.exports = router;
