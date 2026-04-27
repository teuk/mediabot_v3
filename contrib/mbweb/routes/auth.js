'use strict';

const express = require('express');

const { safeBase } = require('../lib/config');
const { authenticate, logAuth } = require('../lib/auth');
const { buildSessionUser } = require('../lib/sessionUser');
const { escapeHtml, renderPage } = require('../lib/render');

const router = express.Router();

// Simple in-process IP-based rate limiter for POST /login.
// Max 5 attempts per IP per 15-minute window.
const loginAttempts = new Map(); // ip -> { count, resetAt }
const LOGIN_MAX = 5;
const LOGIN_WINDOW_MS = 15 * 60 * 1000;

function loginRateLimiter(req, res, next) {
  const ip = req.ip || req.socket?.remoteAddress || 'unknown';
  const now = Date.now();

  let entry = loginAttempts.get(ip);

  if (!entry || entry.resetAt <= now) {
    entry = { count: 0, resetAt: now + LOGIN_WINDOW_MS };
    loginAttempts.set(ip, entry);
  }

  entry.count += 1;

  if (entry.count > LOGIN_MAX) {
    const retryAfterSec = Math.ceil((entry.resetAt - now) / 1000);
    const retryMin = Math.ceil(retryAfterSec / 60);

    console.warn(
      '[mbweb][rate-limit] login blocked for IP',
      ip,
      `(attempt ${entry.count}, retry in ${retryMin}mn)`
    );

    return res.status(429).send(renderPage('Trop de tentatives', `
<section class="mbw-card">
  <h1>Trop de tentatives</h1>
  <p>
    Trop de tentatives de connexion depuis cette adresse IP.
    Réessaie dans <strong>${retryMin} minute(s)</strong>.
  </p>
  <a href="${safeBase('/login')}" class="mbw-btn-secondary">← Retour</a>
</section>
`, req));
  }

  next();
}

setInterval(() => {
  const now = Date.now();
  for (const [ip, entry] of loginAttempts) {
    if (entry.resetAt <= now) loginAttempts.delete(ip);
  }
}, LOGIN_WINDOW_MS);

router.get('/login', (req, res) => {
  const error = req.query.error
    ? `<div class="mbw-alert">${escapeHtml(req.query.error)}</div>`
    : '';

  const body = `
<section class="mbw-login-panel">
  <h1>Connexion Mediabot</h1>
  <p>Utilise ton compte Mediabot IRC.</p>
  ${error}

  <form method="post" action="${safeBase('/login')}" class="mbw-form">
    <label>
      Nickname / username
      <input type="text" name="username" autocomplete="username" required autofocus>
    </label>

    <label>
      Mot de passe Mediabot
      <input type="password" name="password" autocomplete="current-password" required>
    </label>

    <button type="submit">Se connecter</button>
  </form>
</section>
`;

  res.send(renderPage('Login', body, req));
});

router.post('/login', loginRateLimiter, async (req, res) => {
  const login = String(req.body.username || req.body.login || req.body.nickname || '').trim();
  const password = String(req.body.password || '');

  logAuth('POST received', {
    url: req.originalUrl,
    ip: req.ip,
    bodyKeys: Object.keys(req.body || {}),
    login,
    passwordProvided: password.length > 0,
    passwordLen: password.length
  });

  if (!login || !password) {
    return res.redirect(safeBase('/login') + '?error=' + encodeURIComponent('Login ou mot de passe manquant.'));
  }

  try {
    const result = await authenticate(login, password);

    logAuth('auth result', {
      ok: result.ok,
      reason: result.reason || null,
      method: result.method || null,
      id_user: result.user?.id_user || null,
      nickname: result.user?.nickname || null
    });

    if (!result.ok) {
      const message =
        result.reason === 'user-not-found'
          ? 'Utilisateur inconnu.'
          : 'Mot de passe refusé.';

      return res.redirect(safeBase('/login') + '?error=' + encodeURIComponent(message));
    }

    const sessionUser = await buildSessionUser(result.user, result.levelCol);

    await new Promise((resolve, reject) => {
      req.session.regenerate(err => {
        if (err) return reject(err);
        req.session.user = sessionUser;
        req.session.save(err2 => err2 ? reject(err2) : resolve());
      });
    });

    loginAttempts.delete(req.ip || req.socket?.remoteAddress || 'unknown');

    logAuth('login success', {
      id_user: req.session.user.id_user,
      nickname: req.session.user.nickname,
      global_level: req.session.user.global_level,
      global_role: req.session.user.global_role,
      channels_count: req.session.user.channels_count
    });

    return res.redirect(safeBase('/'));
  } catch (err) {
    console.error('[mbweb][auth] exception', err);
    return res.redirect(safeBase('/login') + '?error=' + encodeURIComponent('Erreur authentification: ' + err.message));
  }
});

router.get('/logout', (req, res) => {
  req.session.destroy(err => {
    if (err) {
      console.error('[mbweb][logout] session destroy failed:', err.message);
    }
    res.redirect(safeBase('/'));
  });
});

module.exports = router;
