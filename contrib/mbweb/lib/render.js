'use strict';

const { safeBase } = require('./config');
const {
  isOwner,
  isMaster,
  isAdministrator
} = require('./permissions');

function escapeHtml(value) {
  return String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#039;');
}

function renderPage(title, body, req) {
  const user = req.session?.user || null;

  const loginUrl = safeBase('/login');
  const logoutUrl = safeBase('/logout');
  const homeUrl = safeBase('/');
  const cssUrl = safeBase('/css/mbweb.css');

  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>${escapeHtml(title)} - Mediabot v3</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <link rel="stylesheet" href="${cssUrl}">
</head>
<body>
  <header class="mbw-topbar">
    <a class="mbw-brand" href="${homeUrl}">
      <span class="mbw-brand-mark">MB</span>
      <span>
        <strong>Mediabot v3</strong>
        <small>web console</small>
      </span>
    </a>

    <nav class="mbw-nav">
      <div class="mbw-nav-links">
        <a class="mbw-nav-pill" href="${homeUrl}">Home</a>
        ${user ? `
  <a class="mbw-nav-pill" href="${safeBase('/profile')}">Profile</a>
  <a class="mbw-nav-pill" href="${safeBase('/channels')}">Channels</a>
  <a class="mbw-nav-pill" href="${safeBase('/radio')}">Radio</a>
  <a class="mbw-nav-pill" href="${safeBase('/quotes')}">Quotes</a>
  <a class="mbw-nav-pill" href="${safeBase('/commands')}">Commands</a>
  ${isMaster(user) ? `
    <a class="mbw-nav-pill elevated" href="${safeBase('/network')}">Network</a>
    <a class="mbw-nav-pill elevated" href="${safeBase('/users')}">Users</a>
    ${isMaster(user) ? `<a class="mbw-nav-pill elevated" href="${safeBase('/partyline')}">Partyline</a>` : ''}
    ${isOwner(user) ? `<a class="mbw-nav-pill elevated" href="${safeBase('/diagnostics')}">Diagnostics</a>` : ''}
  ` : ''}
` : ''}
      </div>

      <div class="mbw-nav-session">
        ${user ? `
          <span class="mbw-user-badge">
            <span class="mbw-user-dot"></span>
            <strong>${escapeHtml(user.nickname)}</strong>
          </span>
          <span class="mbw-role-badge ${isOwner(user) ? 'owner' : isMaster(user) ? 'master' : isAdministrator(user) ? 'admin' : 'user'}">${escapeHtml(user.global_role)}</span>
          <a class="mbw-logout-btn" href="${logoutUrl}">Logout</a>
        ` : `<a class="mbw-login-btn" href="${loginUrl}">Login</a>`}
      </div>
    </nav>
  </header>

  <main class="mbw-page">
    ${body}
  </main>
</body>
</html>`;
}

module.exports = {
  escapeHtml,
  renderPage
};
