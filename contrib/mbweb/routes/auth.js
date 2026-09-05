'use strict';

const express = require('express');

const { config, safeBase } = require('../lib/config');
const { authenticate, logAuth } = require('../lib/auth');
const { buildSessionUser, requireLogin } = require('../lib/sessionUser');
const { escapeHtml, renderPage } = require('../lib/render');
const { csrfField } = require('../lib/csrf');
const { BoundedLoginThrottle } = require('../lib/loginThrottle');
const {
  destroyAuthenticatedSession,
  establishAuthenticatedSession
} = require('../lib/sessionLifecycle');
const { logAudit, logError } = require('../lib/securityLog');

const router = express.Router();

// Simple in-process IP-based rate limiter for POST /login.
// Max 5 attempts per source per 15-minute window, with a hard 2048-entry cap.
const loginThrottle = new BoundedLoginThrottle({
  maxAttempts: 5,
  windowMs: 15 * 60 * 1000,
  maxEntries: 2048
});

function loginSource(req) {
  return req.ip || req.socket?.remoteAddress || 'unknown';
}

function loginRateLimiter(req, res, next) {
  const result = loginThrottle.consume(loginSource(req));

  if (!result.allowed) {
    const retryMin = Math.ceil(result.retryAfterSec / 60);
    res.set('Retry-After', String(result.retryAfterSec));
    logAudit(console, 'login.blocked', {
      blocked: true,
      saturated: result.saturated,
      attempt: result.count || 0
    });

    return res.status(429).send(renderPage('Too many attempts', `
<section class="mbw-card">
  <h1>Too many attempts</h1>
  <p>
    Too many login attempts from this IP address.
    Please try again in <strong>${retryMin} minute(s)</strong>.
  </p>
  <a href="${safeBase('/login')}" class="mbw-btn-secondary">← Back</a>
</section>
`, req));
  }

  next();
}

// Housekeeping cannot grow beyond maxEntries and cannot hold process shutdown.
const loginPruneTimer = loginThrottle.startPruning();

router.get('/login', (req, res) => {
  const errors = {
    credentials: 'Invalid login or password.',
    missing: 'Login and password are required.',
    required: 'Login required.',
    internal: 'Internal error. Please try again in a few moments.'
  };
  const errorMessage = errors[String(req.query.error || '')] || '';
  const error = errorMessage
    ? `<div class="mbw-alert">${escapeHtml(errorMessage)}</div>`
    : '';

  const body = `
<section class="mbw-login-panel">
  <h1>Mediabot Login</h1>
  <p>Use your Mediabot IRC account.</p>
  ${error}

  <form method="post" action="${safeBase('/login')}" class="mbw-form">
    ${csrfField(req)}

    <label>
      Nickname / username
      <input type="text" name="username" autocomplete="username" required autofocus>
    </label>

    <label>
      Mediabot password
      <input type="password" name="password" autocomplete="current-password" required>
    </label>

    <button type="submit">Log in</button>
  </form>
</section>
`;

  res.send(renderPage('Login', body, req));
});

router.post('/login', loginRateLimiter, async (req, res) => {
  const login = String(req.body.username || req.body.login || req.body.nickname || '').trim();
  const password = String(req.body.password || '');

  logAuth('POST received', {
    loginProvided: Boolean(login),
    passwordProvided: password.length > 0
  });

  if (!login || !password) {
    return res.redirect(safeBase('/login') + '?error=missing');
  }

  try {
    const result = await authenticate(login, password);

    logAuth('auth result', {
      ok: result.ok,
      reason: result.reason || null,
      method: result.method || null
    });

    if (!result.ok) {
      return res.redirect(safeBase('/login') + '?error=credentials');
    }

    const sessionUser = await buildSessionUser(result.user, result.levelCol, { strict: true });
    await establishAuthenticatedSession(req, sessionUser);
    loginThrottle.reset(loginSource(req));

    logAuth('login success', {
      global_level: req.session.user.global_level,
      global_role: req.session.user.global_role,
      channels_count: req.session.user.channels_count
    });

    return res.redirect(safeBase('/'));
  } catch (err) {
    logError(console, 'auth', err);
    return res.redirect(safeBase('/login') + '?error=internal');
  }
});

router.post('/logout', requireLogin, async (req, res) => {
  try {
    await destroyAuthenticatedSession(req);
  } catch (err) {
    logError(console, 'logout', err);
  }
  res.clearCookie('mbweb.sid', {
    httpOnly: true,
    sameSite: 'lax',
    secure: config.nodeEnv === 'production',
    path: config.baseUrl || '/'
  });
  res.redirect(safeBase('/'));
});

module.exports = router;
