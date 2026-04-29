'use strict';

const express = require('express');
const { config, safeBase } = require('../lib/config');
const { escapeHtml, renderPage } = require('../lib/render');
const { requireLogin } = require('../lib/sessionUser');
const { isOwner, isMaster, isAdministrator, can } = require('../lib/permissions');
const { boolLabel } = require('../lib/viewHelpers');
const {
  getAllChannels,
  getUserChannels,
  getChannelById,
  userHasChannelAccess,
  getChannelUsers,
  getKnownChannelRelatedTables
} = require('../lib/mediabotRepository');

const router = express.Router();

router.get('/api/channels', requireLogin, async (req, res) => {
  try {
    const user    = req.session.user;
    const page    = Math.max(1, Number(req.query.page) || 1);
    const perPage = Math.min(Number(req.query.per_page) || 50, 200);

    const result = isMaster(user)
      ? await getAllChannels({ page, perPage })
      : { rows: await getUserChannels(user.id_user), total: null };

    res.json({
      ok: true,
      scope:   isMaster(user) ? 'all' : 'mine',
      total:   result.total,
      page,
      perPage,
      pages:   result.total ? Math.ceil(result.total / perPage) : null,
      channels: result.rows
    });
  } catch (err) {
    console.error('[mbweb][/api/channels] error:', err.message);
    res.status(500).json({ ok: false, error: 'Internal server error' });
  }
});

router.get('/channels', requireLogin, async (req, res) => {
  const user = req.session.user;
  const PER_PAGE = 50;
  const page     = isMaster(user) ? Math.max(1, Number(req.query.page) || 1) : 1;

  function pageUrl(p) {
    return safeBase('/channels') + '?page=' + p;
  }

  function paginationBar(current, total) {
    if (total <= 1) return '';
    return `
<div class="mbw-pagination">
  ${current > 1
    ? `<a class="mbw-page-btn" href="${escapeHtml(pageUrl(current - 1))}">‹ Previous</a>`
    : '<span class="mbw-page-btn disabled">‹ Previous</span>'}
  <span class="mbw-page-info">Page ${escapeHtml(current)} / ${escapeHtml(total)}</span>
  ${current < total
    ? `<a class="mbw-page-btn" href="${escapeHtml(pageUrl(current + 1))}">Next ›</a>`
    : '<span class="mbw-page-btn disabled">Next ›</span>'}
</div>`;
  }

  let channels, totalChannels, totalPages;

  try {
    if (isMaster(user)) {
      const result = await getAllChannels({ page, perPage: PER_PAGE });
      channels      = result.rows;
      totalChannels = result.total;
      totalPages    = Math.ceil(totalChannels / PER_PAGE);
    } else {
      channels      = await getUserChannels(user.id_user);
      totalChannels = channels.length;
      totalPages    = 1;
    }
  } catch (err) {
    console.error('[mbweb][/channels] error:', err.message);
    return res.status(500).send(renderPage('Error', `
<section class="mbw-card">
  <h1>Server error</h1>
  <p>Unable to load channels. Please try again in a few moments.</p>
</section>
`, req));
  }

  const activeCount = channels.filter(ch => Number(ch.auto_join || 0) === 1).length;

  const body = `
<section class="mbw-hero">
  <div>
    <p class="mbw-kicker">${isMaster(user) ? 'Global view' : 'My channels'}</p>
    <h1>Channels</h1>
    <p>
      ${isMaster(user)
        ? 'Your level grants access to all channels known to Mediabot.'
        : 'Limited to channels linked to your Mediabot account.'}
    </p>
    <div class="mbw-actions">
      <a class="mbw-primary" href="${safeBase('/profile')}">My profile</a>
      <a class="mbw-secondary" href="${safeBase('/api/channels')}">API channels</a>
    </div>
  </div>
</section>

<section class="mbw-grid">
  <article class="mbw-card">
    <h2>Total channels</h2>
    <p class="mbw-big">${escapeHtml(totalChannels)}</p>
    <p>${isMaster(user) ? 'all channels visible' : 'channels linked to your account'}.</p>
  </article>

  <article class="mbw-card">
    <h2>Auto join</h2>
    <p class="mbw-big">${escapeHtml(activeCount)}</p>
    <p>channels with auto_join enabled.</p>
  </article>

  <article class="mbw-card">
    <h2>Scope</h2>
    <p class="mbw-big">${isMaster(user) ? 'global' : 'mine'}</p>
    <p>based on your Mediabot level.</p>
  </article>
</section>

<section class="mbw-card mbw-wide">
  <div class="mbw-section-head">
    <div>
      <h2>${escapeHtml(totalChannels)} channel(s)</h2>
      <p>
        Read-only table: basic configuration, auto-join,
        modes and your account permissions per channel.
      </p>
    </div>
    <span class="mbw-count-badge">${isMaster(user) ? 'global view' : 'filtered view'}</span>
  </div>

  ${paginationBar(page, totalPages)}

  <div>
  </div>

  ${channels.length ? `
    <div class="mbw-table-wrap">
      <table class="mbw-data-table mbw-channels-table">
        <thead>
          <tr>
            <th>Channel</th>
            <th>Description / topic</th>
            <th>Auto join</th>
            <th>Mode</th>
            <th>Chan. level</th>
            <th>Automode</th>
            <th>Owner</th>
            <th>Detail</th>
          </tr>
        </thead>
        <tbody>
          ${channels.map(ch => {
            const autoJoin = Number(ch.auto_join || 0) === 1;
            const detailUrl = safeBase('/channels/' + ch.id_channel);
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
                <td class="mbw-number-cell">${escapeHtml(ch.channel_owner_id ?? 'n/a')}</td>
                <td>
                  <a class="mbw-table-action" href="${detailUrl}">open</a>
                </td>
              </tr>
            `;
          }).join('')}
        </tbody>
      </table>
    </div>
  ` : `<p>No accessible channel for this account.</p>`}
</section>
`;

  res.send(renderPage('Channels', body, req));
});


router.get('/api/channels/:id', requireLogin, async (req, res) => {
  const idChannel = Number(req.params.id);

  if (!Number.isInteger(idChannel) || idChannel <= 0) {
    return res.status(400).json({ ok: false, error: 'Invalid channel id' });
  }

  try {
    const allowed = await userHasChannelAccess(req.session.user.id_user, idChannel);
    if (!allowed) {
      return res.status(403).json({ ok: false, error: 'Forbidden' });
    }

    const channel = await getChannelById(idChannel);
    if (!channel) {
      return res.status(404).json({ ok: false, error: 'Channel not found' });
    }

    const users = await getChannelUsers(idChannel);
    const relatedTables = await getKnownChannelRelatedTables();

    res.json({ ok: true, channel, users, relatedTables });
  } catch (err) {
    console.error('[mbweb][/api/channels/:id] error:', err.message);
    res.status(500).json({ ok: false, error: 'Internal server error' });
  }
});

router.get('/channels/:id', requireLogin, async (req, res) => {
  const idChannel = Number(req.params.id);

  if (!Number.isInteger(idChannel) || idChannel <= 0) {
    return res.status(400).send(renderPage('Invalid channel', `
<section class="mbw-card">
  <h1>Invalid channel</h1>
  <p>The requested channel ID is not valid.</p>
  <a href="${safeBase('/channels')}">← Back to channels</a>
</section>
`, req));
  }

  let channel, users, relatedTables, allowed;

  try {
    allowed = await userHasChannelAccess(req.session.user.id_user, idChannel);
  } catch (err) {
    console.error('[mbweb][/channels/:id] access check error:', err.message);
    return res.status(500).send(renderPage('Error', `
<section class="mbw-card">
  <h1>Server error</h1>
  <p>Unable to verify access rights.</p>
</section>
`, req));
  }

  if (!allowed) {
    return res.status(403).send(renderPage('Access denied', `
<section class="mbw-card">
  <h1>Access denied</h1>
  <p>Your Mediabot account does not have sufficient permissions to view this channel.</p>
  <a href="${safeBase('/channels')}">← Back to channels</a>
</section>
`, req));
  }

  try {
    [channel, users, relatedTables] = await Promise.all([
      getChannelById(idChannel),
      getChannelUsers(idChannel),
      getKnownChannelRelatedTables()
    ]);
  } catch (err) {
    console.error('[mbweb][/channels/:id] data fetch error:', err.message);
    return res.status(500).send(renderPage('Error', `
<section class="mbw-card">
  <h1>Server error</h1>
  <p>Unable to load channel data.</p>
</section>
`, req));
  }

  if (!channel) {
    return res.status(404).send(renderPage('Channel not found', `
<section class="mbw-card">
  <h1>Channel not found</h1>
  <p>No Mediabot channel matches this identifier.</p>
  <a href="${safeBase('/channels')}">← Back to channels</a>
</section>
`, req));
  }

  const chansetSection = relatedTables.length ? `
<section class="mbw-card mbw-wide">
  <h2>Linked tables detected</h2>
  <p>Chansets, responders, quotes and logs will be wired in a future version.</p>
  <div class="mbw-taglist">
    ${relatedTables.map(t => `<span>${escapeHtml(t)}</span>`).join('')}
  </div>
</section>
` : '';

  const body = `
<section class="mbw-hero">
  <div>
    <p class="mbw-kicker">IRC channel</p>
    <h1>${escapeHtml(channel.name || 'unknown')}</h1>
    <p>
      Detailed channel view from the Mediabot database:
      configuration, associated users and per-channel levels.
    </p>
    <div class="mbw-actions">
      <a class="mbw-primary" href="${safeBase('/channels')}">← Back to channels</a>
      <a class="mbw-secondary" href="${safeBase('/api/channels/' + idChannel)}">API JSON</a>
    </div>
  </div>
</section>

<section class="mbw-grid">
  <article class="mbw-card">
    <h2>Channel</h2>
    <p class="mbw-big">${escapeHtml(channel.name || 'n/a')}</p>
    <p>id_channel: ${escapeHtml(channel.id_channel ?? 'n/a')}</p>
  </article>

  <article class="mbw-card">
    <h2>Linked users</h2>
    <p class="mbw-big">${escapeHtml(users.length)}</p>
    <p>from USER_CHANNEL.</p>
  </article>

  <article class="mbw-card">
    <h2>Auto join</h2>
    <p class="${Number(channel.auto_join || 0) ? 'mbw-ok' : 'mbw-bad'}">
      ${Number(channel.auto_join || 0) ? 'enabled' : 'disabled'}
    </p>
    <p>mode: ${escapeHtml(channel.chanmode || 'n/a')}</p>
  </article>
</section>

<section class="mbw-card mbw-wide">
  <h2>Configuration</h2>
  <div class="mbw-kv">
    <div><span>id_channel</span><strong>${escapeHtml(channel.id_channel ?? 'n/a')}</strong></div>
    <div><span>name</span><strong>${escapeHtml(channel.name ?? 'n/a')}</strong></div>
    <div><span>description</span><strong>${escapeHtml(channel.description ?? 'n/a')}</strong></div>
    <div><span>topic</span><strong>${escapeHtml(channel.topic ?? 'n/a')}</strong></div>
    <div><span>chanmode</span><strong>${escapeHtml(channel.chanmode ?? 'n/a')}</strong></div>
    <div><span>owner id_user</span><strong>${escapeHtml(channel.channel_owner_id ?? 'n/a')}</strong></div>
    <div><span>tmdb_lang</span><strong>${escapeHtml(channel.tmdb_lang ?? 'n/a')}</strong></div>
    <div><span>urltitle</span><strong>${escapeHtml(channel.urltitle ?? 'n/a')}</strong></div>
    <div><span>auto_join</span><strong>${escapeHtml(boolLabel(channel.auto_join))}</strong></div>
  </div>
</section>

<section class="mbw-card mbw-wide">
  <h2>Channel users</h2>
  ${users.length ? `
    <div class="mbw-table-wrap">
      <table class="mbw-data-table mbw-channels-table">
        <thead>
          <tr>
            <th>Nickname</th>
            <th>Global role</th>
            <th>Chan. level</th>
            <th>Automode</th>
            <th>Greet</th>
          </tr>
        </thead>
        <tbody>
          ${users.map(u => `
            <tr>
              <td class="mbw-user-main">
                <strong>${escapeHtml(u.nickname || 'unknown')}</strong>
                <small>${escapeHtml(u.username || '')}</small>
              </td>
              <td><span class="mbw-role-chip">${escapeHtml(u.global_role || String(u.global_level ?? 'n/a'))}</span></td>
              <td>${escapeHtml(u.channel_level ?? 'n/a')}</td>
              <td>${escapeHtml(u.automode ?? 'n/a')}</td>
              <td class="mbw-muted-cell">${escapeHtml(u.greet ?? '')}</td>
            </tr>
          `).join('')}
        </tbody>
      </table>
    </div>
  ` : `<p>No user linked to this channel in USER_CHANNEL.</p>`}
</section>

${chansetSection}
`;

  res.send(renderPage(`Channel — ${channel.name || idChannel}`, body, req));
});


module.exports = router;
