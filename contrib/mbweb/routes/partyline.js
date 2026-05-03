'use strict';

const express = require('express');
const { safeBase }          = require('../lib/config');
const { escapeHtml, renderPage } = require('../lib/render');
const { isMaster }          = require('../lib/permissions');
const db                    = require('../lib/db');

const router = express.Router();

// ── /partyline  – Partyline status page (Master+) ────────────────────────────
router.get('/', async (req, res) => {
  const user = req.session?.user || null;

  if (!user) {
    return res.redirect(safeBase('/login'));
  }
  if (!isMaster(user)) {
    return res.status(403).send(renderPage('Forbidden',
      `<p class="error">Master level required.</p>`, req));
  }

  let sessions  = [];
  let bans      = [];
  let dbError   = null;

  try {
    // Active Partyline sessions from the USER table (auth=1 and online)
    // The bot writes auth=1 on login and 0 on logout / restart.
    const [sessRows] = await db.query(
      `SELECT u.nickname, ul.description AS level_desc,
              u.last_login
       FROM USER u
       JOIN USER_LEVEL ul ON ul.id_user_level = u.id_user_level
       WHERE u.auth = 1
       ORDER BY u.last_login DESC`
    );
    sessions = sessRows || [];

    // Recent ChannelBan activity (last 20 added bans)
    const [banRows] = await db.query(
      `SELECT cb.id_channel_ban, cb.mask, cb.ban_level,
              cb.reason, cb.created_by_nick, cb.created_at,
              cb.expires_at, cb.active, c.name AS channel_name
       FROM CHANNEL_BAN cb
       JOIN CHANNEL c ON c.id_channel = cb.id_channel
       ORDER BY cb.created_at DESC
       LIMIT 20`
    );
    bans = banRows || [];
  } catch (err) {
    dbError = err.message;
  }

  const fmtDate = (d) => d ? new Date(d).toISOString().replace('T', ' ').slice(0, 16) : '—';

  const sessRows = sessions.length
    ? sessions.map(s => `
        <tr>
          <td>${escapeHtml(s.nickname)}</td>
          <td>${escapeHtml(s.level_desc)}</td>
          <td>${fmtDate(s.last_login)}</td>
        </tr>`).join('')
    : `<tr><td colspan="3" class="empty">No authenticated users.</td></tr>`;

  const banRows = bans.length
    ? bans.map(b => {
        const active  = b.active ? '✓' : '✗';
        const expires = b.expires_at ? fmtDate(b.expires_at) : 'permanent';
        const reason  = b.reason || '';
        return `
        <tr class="${b.active ? '' : 'inactive'}">
          <td>${escapeHtml(b.channel_name)}</td>
          <td class="mono">${escapeHtml(b.mask)}</td>
          <td>${b.ban_level}</td>
          <td>${escapeHtml(b.created_by_nick || '?')}</td>
          <td>${fmtDate(b.created_at)}</td>
          <td>${expires}</td>
          <td>${active}</td>
          <td>${escapeHtml(reason)}</td>
        </tr>`;
      }).join('')
    : `<tr><td colspan="8" class="empty">No recent bans.</td></tr>`;

  const body = `
<h2>Partyline</h2>

${dbError ? `<p class="error">DB error: ${escapeHtml(dbError)}</p>` : ''}

<section>
  <h3>Authenticated Users (${sessions.length})</h3>
  <table>
    <thead>
      <tr>
        <th>Nickname</th>
        <th>Level</th>
        <th>Last login</th>
      </tr>
    </thead>
    <tbody>${sessRows}</tbody>
  </table>
</section>

<section>
  <h3>Recent Channel Bans (last 20)</h3>
  <table>
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
</section>

<style>
  tr.inactive { opacity: 0.5; }
  td.mono { font-family: monospace; font-size: 0.9em; }
  td.empty { text-align: center; color: #888; padding: 1rem; }
</style>`;

  res.send(renderPage('Partyline', body, req));
});

module.exports = router;
