'use strict';

const express = require('express');
const { config, safeBase } = require('../lib/config');
const { escapeHtml, renderPage } = require('../lib/render');
const { requireLogin } = require('../lib/sessionUser');
const { isOwner, isMaster, isAdministrator, can } = require('../lib/permissions');
const { getUserWithGlobalRole, getUserChannels, getUserHostmasks } = require('../lib/mediabotRepository');

const router = express.Router();

router.get('/api/me', requireLogin, async (req, res) => {
  // B2 — wrap in try/catch so DB errors return JSON, not HTML 500
  try {
    const profile = await getUserWithGlobalRole(req.session.user.id_user);
    const channels = await getUserChannels(req.session.user.id_user);
    const hostmasks = await getUserHostmasks(req.session.user.id_user);

    res.json({
      ok: true,
      me: req.session.user,
      profile,
      channels,
      hostmasks
    });
  } catch (err) {
    console.error('[mbweb][/api/me] error:', err.message);
    res.status(500).json({ ok: false, error: 'Internal server error' });
  }
});


router.get('/profile', requireLogin, async (req, res) => {
  // B2 — try/catch for DB errors
  let profile, hostmasks, channels;
  try {
    profile = await getUserWithGlobalRole(req.session.user.id_user);
    hostmasks = await getUserHostmasks(req.session.user.id_user);
    channels = await getUserChannels(req.session.user.id_user);
  } catch (err) {
    console.error('[mbweb][/profile] error:', err.message);
    return res.status(500).send(renderPage('Error', `
<section class="mbw-card">
  <h1>Server error</h1>
  <p>Unable to load profile. Please try again in a few moments.</p>
</section>
`, req));
  }

  const body = `
<section class="mbw-hero">
  <div>
    <p class="mbw-kicker">Personal space</p>
    <h1>${escapeHtml(req.session.user.nickname)}</h1>
    <p>
      Your Mediabot profile, useful information and detected access
      from the bot database.
    </p>
    <div class="mbw-actions">
      <a class="mbw-primary" href="${safeBase('/channels')}">View my channels</a>
      <a class="mbw-secondary" href="${safeBase('/api/me')}">API me</a>
    </div>
  </div>
</section>

<section class="mbw-grid">
  <article class="mbw-card">
    <h2>Global level</h2>
    <p class="mbw-big">${escapeHtml(req.session.user.global_role)}</p>
    <p>level ${escapeHtml(req.session.user.global_level)}</p>
  </article>

  <article class="mbw-card">
    <h2>Accessible channels</h2>
    <p class="mbw-big">${escapeHtml(channels.length)}</p>
    <p>from USER_CHANNEL.</p>
  </article>

  <article class="mbw-card">
    <h2>Auth IRC</h2>
    <p class="${Number(profile?.auth || 0) ? 'mbw-ok' : 'mbw-bad'}">${Number(profile?.auth || 0) ? 'authenticated' : 'not authenticated'}</p>
    <p>current state from USER table.</p>
  </article>
</section>

<section class="mbw-card mbw-wide">
  <h2>Profile details</h2>
  <div class="mbw-kv">
    <div><span>id_user</span><strong>${escapeHtml(profile?.id_user ?? req.session.user.id_user)}</strong></div>
    <div><span>nickname</span><strong>${escapeHtml(profile?.nickname ?? req.session.user.nickname)}</strong></div>
    <div><span>username</span><strong>${escapeHtml(profile?.username ?? '')}</strong></div>
    <div><span>timezone</span><strong>${escapeHtml(profile?.tz ?? 'n/a')}</strong></div>
    <div><span>birthday</span><strong>${escapeHtml(profile?.birthday ?? 'n/a')}</strong></div>
    <div><span>fortniteid</span><strong>${escapeHtml(profile?.fortniteid ?? 'n/a')}</strong></div>
    <div><span>last_login</span><strong>${escapeHtml(profile?.last_login ?? 'n/a')}</strong></div>
  </div>
</section>

<section class="mbw-card mbw-wide">
  <h2>Hostmasks</h2>
  ${hostmasks.length ? `
    <div class="mbw-list">
      ${hostmasks.map(h => `
        <div class="mbw-list-row">
          <strong>${escapeHtml(h.hostmask)}</strong>
          <span>${h.legacy ? 'legacy' : escapeHtml(h.created_at ?? '')}</span>
        </div>
      `).join('')}
    </div>
  ` : `<p>No hostmask detected.</p>`}
</section>
`;

  res.send(renderPage('Profile', body, req));
});


module.exports = router;
