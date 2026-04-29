'use strict';

const express = require('express');
const { config, safeBase } = require('../lib/config');
const { escapeHtml, renderPage } = require('../lib/render');
const { requireLogin } = require('../lib/sessionUser');
const { isOwner, isMaster, isAdministrator, can } = require('../lib/permissions');
const { getQuotes, getQuoteChannels } = require('../lib/mediabotRepository');

const router = express.Router();

router.get('/api/quotes', requireLogin, async (req, res) => {
  try {
    const channel = req.query.channel || null;
    const search  = req.query.q       || null;
    const page    = Math.max(1, Number(req.query.page) || 1);
    const perPage = Math.min(Number(req.query.per_page) || 50, 200);

    const [result, channels] = await Promise.all([
      getQuotes({ channel, search, page, perPage }),
      getQuoteChannels()
    ]);

    res.json({
      ok: true,
      total: result.total,
      page,
      perPage,
      pages: Math.ceil(result.total / perPage),
      quotes: result.rows,
      channels
    });
  } catch (err) {
    console.error('[mbweb][/api/quotes] error:', err.message);
    res.status(500).json({ ok: false, error: 'Internal server error' });
  }
});

router.get('/quotes', requireLogin, async (req, res) => {
  const channel = req.query.channel || null;
  const search  = req.query.q       || null;
  const page    = Math.max(1, Number(req.query.page) || 1);
  const perPage = 50;

  let result, channels;

  try {
    [result, channels] = await Promise.all([
      getQuotes({ channel, search, page, perPage }),
      getQuoteChannels()
    ]);
  } catch (err) {
    console.error('[mbweb][/quotes] error:', err.message);
    return res.status(500).send(renderPage('Error', `
<section class="mbw-card">
  <h1>Server error</h1>
  <p>Unable to load quotes.</p>
</section>
`, req));
  }

  const totalPages = Math.ceil(result.total / perPage);

  // Pagination helper
  function pageUrl(p) {
    const params = new URLSearchParams();
    if (channel) params.set('channel', channel);
    if (search)  params.set('q', search);
    params.set('page', p);
    return safeBase('/quotes') + '?' + params.toString();
  }

  const paginationBar = totalPages > 1 ? `
<div class="mbw-pagination">
  ${page > 1         ? `<a class="mbw-page-btn" href="${escapeHtml(pageUrl(page - 1))}">‹ Previous</a>` : '<span class="mbw-page-btn disabled">‹ Previous</span>'}
  <span class="mbw-page-info">Page ${escapeHtml(page)} / ${escapeHtml(totalPages)}</span>
  ${page < totalPages ? `<a class="mbw-page-btn" href="${escapeHtml(pageUrl(page + 1))}">Next ›</a>` : '<span class="mbw-page-btn disabled">Next ›</span>'}
</div>
` : '';

  const filterBar = `
<section class="mbw-card mbw-wide">
  <form method="get" action="${safeBase('/quotes')}" class="mbw-filter-bar">
    <input
      type="search"
      name="q"
      placeholder="Search in text…"
      value="${escapeHtml(search || '')}"
      class="mbw-search-input"
    >
    <select name="channel" class="mbw-select">
      <option value="">All channels</option>
      ${channels.map(ch => `
        <option value="${escapeHtml(ch.name)}"
          ${channel === ch.name ? 'selected' : ''}>
          ${escapeHtml(ch.name)} (${escapeHtml(ch.n)})
        </option>
      `).join('')}
    </select>
    <button type="submit" class="mbw-btn-primary">Filter</button>
    ${search || channel ? `<a href="${safeBase('/quotes')}" class="mbw-btn-secondary">Reset</a>` : ''}
  </form>
</section>
`;

  const body = `
<section class="mbw-hero">
  <div>
    <p class="mbw-kicker">Bot Mediabot</p>
    <h1>Quotes</h1>
    <p>
      Explorer for quotes recorded per IRC channel.
      Add and remove via IRC commands <code>!q add</code> / <code>!q del</code>.
    </p>
    <div class="mbw-actions">
      <a class="mbw-primary" href="${safeBase('/api/quotes')}">API JSON</a>
      <a class="mbw-secondary" href="${safeBase('/')}">Home</a>
    </div>
  </div>
</section>

<section class="mbw-grid">
  <article class="mbw-card">
    <h2>Total</h2>
    <p class="mbw-big">${escapeHtml(result.total)}</p>
    <p>quotes in the database.</p>
  </article>

  <article class="mbw-card">
    <h2>Channels</h2>
    <p class="mbw-big">${escapeHtml(channels.length)}</p>
    <p>channels with at least one quote.</p>
  </article>

  <article class="mbw-card">
    <h2>Page</h2>
    <p class="mbw-big">${escapeHtml(page)} / ${escapeHtml(totalPages || 1)}</p>
    <p>${escapeHtml(perPage)} quotes per page.</p>
  </article>
</section>

${filterBar}

<section class="mbw-card mbw-wide">
  <div class="mbw-section-head">
    <div>
      <h2>${search || channel ? 'Filtered results' : 'Latest quotes'}</h2>
      <p>${escapeHtml(result.rows.length)} quote(s) shown out of ${escapeHtml(result.total)} total.</p>
    </div>
    <span class="mbw-count-badge">${escapeHtml(result.total)} total</span>
  </div>

  ${paginationBar}

  ${result.rows.length ? `
    <div class="mbw-quotes-list">
      ${result.rows.map(q => `
        <div class="mbw-quote-card">
          <div class="mbw-quote-body">${escapeHtml(q.quotetext || '')}</div>
          <div class="mbw-quote-meta">
            <span class="mbw-quote-id">#${escapeHtml(q.id_quotes ?? '')}</span>
            ${q.channel_name ? `<span class="mbw-quote-channel">${escapeHtml(q.channel_name)}</span>` : ''}
            ${q.author_nick  ? `<span class="mbw-quote-author">by ${escapeHtml(q.author_nick)}</span>` : ''}
            ${q.ts           ? `<span class="mbw-quote-date">${escapeHtml(String(q.ts).slice(0, 19).replace('T', ' '))}</span>` : ''}
          </div>
        </div>
      `).join('')}
    </div>
  ` : `<p>No quote${search || channel ? ' matching the filter' : ''}.</p>`}

  ${paginationBar}
</section>
`;

  res.send(renderPage('Quotes', body, req));
});

// ─── Commands explorer ─────────────────────────────────────────────────────


module.exports = router;
