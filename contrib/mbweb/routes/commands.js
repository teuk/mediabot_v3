'use strict';

const express = require('express');
const { config, safeBase } = require('../lib/config');
const { escapeHtml, renderPage } = require('../lib/render');
const { requireLogin } = require('../lib/sessionUser');
const { isOwner, isMaster, isAdministrator, can } = require('../lib/permissions');
const { getCommands, getCommandCategories } = require('../lib/mediabotRepository');

const router = express.Router();

router.get('/api/commands', requireLogin, async (req, res) => {
  try {
    const category = req.query.category || null;
    const search   = req.query.q        || null;
    const limit    = Math.min(Number(req.query.limit) || 200, 500);

    const [commands, categories] = await Promise.all([
      getCommands({ category, search, limit }),
      getCommandCategories()
    ]);

    res.json({ ok: true, total: commands.length, commands, categories });
  } catch (err) {
    console.error('[mbweb][/api/commands] error:', err.message);
    res.status(500).json({ ok: false, error: 'Internal server error' });
  }
});

router.get('/commands', requireLogin, async (req, res) => {
  const category = req.query.category || null;
  const search   = req.query.q        || null;

  let commands, categories;

  try {
    [commands, categories] = await Promise.all([
      getCommands({ category, search }),
      getCommandCategories()
    ]);
  } catch (err) {
    console.error('[mbweb][/commands] error:', err.message);
    return res.status(500).send(renderPage('Error', `
<section class="mbw-card">
  <h1>Server error</h1>
  <p>Unable to load commands.</p>
</section>
`, req));
  }

  const activeCount   = commands.filter(c => Number(c.active || 0) === 1).length;
  const totalHits     = commands.reduce((s, c) => s + Number(c.hits || 0), 0);

  // Search/filter bar
  const filterBar = `
<section class="mbw-card mbw-wide">
  <form method="get" action="${safeBase('/commands')}" class="mbw-filter-bar">
    <input
      type="search"
      name="q"
      placeholder="Search a command…"
      value="${escapeHtml(search || '')}"
      class="mbw-search-input"
    >
    <select name="category" class="mbw-select">
      <option value="">All categories</option>
      ${categories.map(cat => `
        <option value="${escapeHtml(cat.category)}"
          ${category === cat.category ? 'selected' : ''}>
          ${escapeHtml(cat.category)} (${escapeHtml(cat.n)})
        </option>
      `).join('')}
    </select>
    <button type="submit" class="mbw-btn-primary">Filter</button>
    ${search || category ? `<a href="${safeBase('/commands')}" class="mbw-btn-secondary">Reset</a>` : ''}
  </form>
</section>
`;

  const body = `
<section class="mbw-hero">
  <div>
    <p class="mbw-kicker">Bot Mediabot</p>
    <h1>Custom commands</h1>
    <p>
      Explorer for IRC commands defined in the Mediabot database.
      Read-only — edit via the IRC command <code>!addcmd</code>.
    </p>
    <div class="mbw-actions">
      <a class="mbw-primary" href="${safeBase('/api/commands')}">API JSON</a>
      <a class="mbw-secondary" href="${safeBase('/')}">Home</a>
    </div>
  </div>
</section>

<section class="mbw-grid">
  <article class="mbw-card">
    <h2>Total</h2>
    <p class="mbw-big">${escapeHtml(commands.length)}</p>
    <p>commands in PUBLIC_COMMANDS.</p>
  </article>

  <article class="mbw-card">
    <h2>Active</h2>
    <p class="mbw-big">${escapeHtml(activeCount)}</p>
    <p>active state = 1.</p>
  </article>

  <article class="mbw-card">
    <h2>Total hits</h2>
    <p class="mbw-big">${escapeHtml(totalHits)}</p>
    <p>cumulative usage count.</p>
  </article>
</section>

${filterBar}

<section class="mbw-card mbw-wide">
  <div class="mbw-section-head">
    <div>
      <h2>${search || category ? 'Filtered results' : 'All commands'}</h2>
      <p>Sorted by hit count descending.</p>
    </div>
    <span class="mbw-count-badge">${escapeHtml(commands.length)} commands</span>
  </div>

  ${commands.length ? `
    <div class="mbw-table-wrap">
      <table class="mbw-data-table mbw-commands-table">
        <thead>
          <tr>
            <th>Command</th>
            <th>Action</th>
            <th>Category</th>
            <th>Author</th>
            <th>Hits</th>
            <th>Status</th>
            <th>Created</th>
          </tr>
        </thead>
        <tbody>
          ${commands.map(cmd => {
            const isActive = Number(cmd.active || 0) === 1;
            return `
              <tr>
                <td><strong>!${escapeHtml(cmd.command || '')}</strong></td>
                <td class="mbw-muted-cell mbw-cmd-action">${escapeHtml(cmd.action || 'n/a')}</td>
                <td><span class="mbw-role-chip">${escapeHtml(cmd.category || 'n/a')}</span></td>
                <td class="mbw-muted-cell">${escapeHtml(cmd.author_nick || String(cmd.id_user ?? 'n/a'))}</td>
                <td class="mbw-number-cell">${escapeHtml(cmd.hits ?? 0)}</td>
                <td>
                  <span class="mbw-status-pill ${isActive ? 'ok' : 'bad'}">
                    ${isActive ? 'active' : 'hold'}
                  </span>
                </td>
                <td class="mbw-date-cell">${escapeHtml(cmd.creation_date || 'n/a')}</td>
              </tr>
            `;
          }).join('')}
        </tbody>
      </table>
    </div>
  ` : `<p>No command${search || category ? ' matching the filter' : ' in the database'}.</p>`}
</section>
`;

  res.send(renderPage('Commands', body, req));
});

// ─── Users list (Master+) ──────────────────────────────────────────────────


module.exports = router;
