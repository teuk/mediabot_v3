'use strict';

const express = require('express');
const { config, safeBase } = require('../lib/config');
const { escapeHtml, renderPage } = require('../lib/render');
const { requireLogin } = require('../lib/sessionUser');
const { isOwner, isMaster, isAdministrator, can } = require('../lib/permissions');
const { getAllUsersWithRoles, getUserChannelCountMap } = require('../lib/mediabotRepository');

const router = express.Router();

router.get('/api/users', requireLogin, async (req, res) => {
  if (!isMaster(req.session.user)) {
    return res.status(403).json({ ok: false, error: 'Forbidden' });
  }

  const page    = Math.max(1, Number(req.query.page) || 1);
  const perPage = Math.min(Number(req.query.per_page) || 50, 200);
  const search  = req.query.q?.trim() || null;

  try {
    const [result, channelCounts] = await Promise.all([
      getAllUsersWithRoles({ page, perPage, search }),
      getUserChannelCountMap()
    ]);

    res.json({
      ok: true,
      scope: 'global',
      search,
      total: result.total,
      page,
      perPage,
      pages: Math.ceil(result.total / perPage),
      users: result.rows.map(u => ({
        ...u,
        channels_count: channelCounts[u.id_user] || 0
      }))
    });
  } catch (err) {
    console.error('[mbweb][/api/users] error:', err.message);
    res.status(500).json({ ok: false, error: 'Internal server error' });
  }
});

router.get('/users', requireLogin, async (req, res) => {
  if (!isMaster(req.session.user)) {
    return res.status(403).send(renderPage('Access denied', `
<section class="mbw-card">
  <h1>Access denied</h1>
  <p>This page is restricted to Owner and Master.</p>
  <a href="${safeBase('/')}">← Back to home</a>
</section>
`, req));
  }

  const PER_PAGE = 50;
  const page     = Math.max(1, Number(req.query.page) || 1);
  const search   = req.query.q?.trim() || null;

  function pageUrl(p) {
    const params = new URLSearchParams();
    if (search) params.set('q', search);
    params.set('page', p);
    return safeBase('/users') + '?' + params.toString();
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

  let result, channelCounts;

  try {
    [result, channelCounts] = await Promise.all([
      getAllUsersWithRoles({ page, perPage: PER_PAGE, search }),
      getUserChannelCountMap()
    ]);
  } catch (err) {
    console.error('[mbweb][/users] error:', err.message);
    return res.status(500).send(renderPage('Error', `
<section class="mbw-card">
  <h1>Server error</h1>
  <p>Unable to load user list.</p>
</section>
`, req));
  }

  // Role stats for summary bar
  const users = result.rows;
  const total  = result.total;
  const totalPages = Math.ceil(total / PER_PAGE);


  const filterBar = `
<section class="mbw-card mbw-wide">
  <form method="get" action="${safeBase('/users')}" class="mbw-filter-bar">
    <input
      type="search"
      name="q"
      placeholder="Search by nickname or username…"
      value="${escapeHtml(search || '')}"
      class="mbw-search-input"
    >
    <button type="submit" class="mbw-btn-primary">Filter</button>
    ${search ? `<a href="${safeBase('/users')}" class="mbw-btn-secondary">Reset</a>` : ''}
  </form>
</section>
`;

  const roleStats = users.reduce((acc, u) => {
    const role = u.global_role || `level ${u.global_level ?? u.id_user_level ?? 'n/a'}`;
    acc[role] = (acc[role] || 0) + 1;
    return acc;
  }, {});

  const authCount   = users.filter(u => Number(u.auth || 0) === 1).length;
  const masterCount = users.filter(u => Number(u.global_level ?? 999) <= 1).length;

  const body = `
<section class="mbw-hero">
  <div>
    <p class="mbw-kicker">Read-only administration</p>
    <h1>Users</h1>
    <p>
      Global overview of Mediabot accounts, their levels, and status
      IRC authentication status and channel memberships.
    </p>
    <div class="mbw-actions">
      <a class="mbw-primary" href="${safeBase('/api/users')}">API JSON</a>
      <a class="mbw-secondary" href="${safeBase('/profile')}">My profile</a>
    </div>
  </div>
</section>

<section class="mbw-grid">
  <article class="mbw-card">
    <h2>Total</h2>
    <p class="mbw-big">${escapeHtml(users.length)}</p>
    <p>accounts in USER.</p>
  </article>

  <article class="mbw-card">
    <h2>Owner / Master</h2>
    <p class="mbw-big">${escapeHtml(masterCount)}</p>
    <p>elevated global levels.</p>
  </article>

  <article class="mbw-card">
    <h2>Auth active</h2>
    <p class="mbw-big">${escapeHtml(authCount)}</p>
    <p>USER.auth = 1.</p>
  </article>
</section>

<section class="mbw-card mbw-wide">
  <div class="mbw-section-head">
    <div>
      <h2>Role breakdown</h2>
      <p>Overview of Mediabot global levels.</p>
    </div>
  </div>
  <div class="mbw-role-grid">
    ${Object.entries(roleStats).map(([role, n]) => `
      <div class="mbw-role-pill">
        <span>${escapeHtml(role)}</span>
        <strong>${escapeHtml(n)}</strong>
      </div>
    `).join('')}
  </div>
</section>

${filterBar}

<section class="mbw-card mbw-wide">
  <div class="mbw-section-head">
    <div>
      <h2>Mediabot users</h2>
      <p>Read-only table — accounts, levels, IRC auth, channels and last login.</p>
    </div>
    <span class="mbw-count-badge">${escapeHtml(total)} user(s)${search ? ' matching' : ''}</span>
  </div>

  ${paginationBar(page, totalPages)}

  ${users.length ? `
    <div class="mbw-table-wrap">
      <table class="mbw-data-table mbw-users-table">
        <thead>
          <tr>
            <th>Nickname</th>
            <th>Username</th>
            <th>Role</th>
            <th>Auth</th>
            <th>Channels</th>
            <th>Timezone</th>
            <th>Last login</th>
          </tr>
        </thead>
        <tbody>
          ${users.map(u => {
            const role        = u.global_role || String(u.global_level ?? u.id_user_level ?? 'n/a');
            const authOk      = Number(u.auth || 0) === 1;
            const channelCount = channelCounts[u.id_user] || 0;

            return `
              <tr>
                <td class="mbw-user-main">
                  <strong>${escapeHtml(u.nickname || 'unknown')}</strong>
                  <small>id_user ${escapeHtml(u.id_user ?? 'n/a')}</small>
                </td>
                <td class="mbw-muted-cell">${escapeHtml(u.username || 'n/a')}</td>
                <td><span class="mbw-role-chip">${escapeHtml(role)}</span></td>
                <td>
                  <span class="mbw-status-pill ${authOk ? 'ok' : 'bad'}">
                    ${authOk ? 'yes' : 'no'}
                  </span>
                </td>
                <td class="mbw-number-cell">${escapeHtml(channelCount)}</td>
                <td class="mbw-muted-cell">${escapeHtml(u.tz || 'n/a')}</td>
                <td class="mbw-date-cell">${escapeHtml(u.last_login || 'n/a')}</td>
              </tr>
            `;
          }).join('')}
        </tbody>
      </table>
    </div>
  ` : `<p>No user found.</p>`}
  ${paginationBar(page, totalPages)}
</section>
`;

  res.send(renderPage('Users', body, req));
});

// ─── Channel detail ────────────────────────────────────────────────────────


module.exports = router;
