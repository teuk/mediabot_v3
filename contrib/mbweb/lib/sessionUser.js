'use strict';

const {
  getUserWithGlobalRole,
  getUserChannels
} = require('./mediabotRepository');
const { safeBase } = require('./config');
const {
  normalizeSessionUser,
  publicSessionUser,
  roleNameFromLevel
} = require('./sessionUserCore');
const { logError } = require('./securityLog');
const { destroyAuthenticatedSession } = require('./sessionLifecycle');

// Refresh interval: rebuild session user from DB if level may have changed.
// Runs at most once every 2 minutes per session to avoid per-request DB hits.
const SESSION_REFRESH_INTERVAL_MS = 2 * 60 * 1000;

async function refreshSessionUser(req, options = {}) {
  const user = req.session?.user;
  if (!user) return false;

  const now = Date.now();
  const lastRefresh = req.session._userRefreshedAt || 0;
  if (!options.force && (now - lastRefresh) < SESSION_REFRESH_INTERVAL_MS) return false;

  try {
    const refreshed = await buildSessionUser(
      { id_user: user.id_user, ...user },
      null,
      { strict: Boolean(options.strict) }
    );
    req.session.user = refreshed;
    req.session._userRefreshedAt = now;
    await new Promise((resolve, reject) => {
      req.session.save(err => err ? reject(err) : resolve());
    });
    return true;
  } catch (err) {
    logError(console, 'session.refresh', err);
    if (err.code === 'MBWEB_AUTH_REVOKED') {
      // Revoke before touching the store, even if destruction subsequently fails.
      req.session.user = null;
      req.session._userRefreshedAt = 0;
      try { await destroyAuthenticatedSession(req); }
      catch (destroyErr) { logError(console, 'session.revoke', destroyErr); }
    }
    if (options.strict) throw err;
    return false;
  }
}

function requireLogin(req, res, next) {
  if (!req.session?.user) {
    return res.redirect(safeBase('/login') + '?error=' + encodeURIComponent('Login required.'));
  }
  // Fire-and-forget refresh — does not block the request
  refreshSessionUser(req).catch(() => {});
  next();
}

function rejectLogin(req, res) {
  res.set('Cache-Control', 'no-store');
  if (req.path?.startsWith('/api/')) {
    return res.status(401).json({ ok: false, error: 'Login required.' });
  }
  return res.redirect(safeBase('/login') + '?error=' + encodeURIComponent('Login required.'));
}

async function requireFreshLogin(req, res, next) {
  if (!req.session?.user) return rejectLogin(req, res);

  try {
    await refreshSessionUser(req, { force: true, strict: true });
    res.set('Cache-Control', 'no-store');
    return next();
  } catch (err) {
    if (err.code === 'MBWEB_AUTH_REVOKED') return rejectLogin(req, res);
    res.set('Cache-Control', 'no-store');
    if (req.path?.startsWith('/api/')) {
      return res.status(503).json({ ok: false, error: 'Authorization could not be refreshed.' });
    }
    return res.status(503).send('Authorization could not be refreshed.');
  }
}

function refreshOptionalLogin(req, res, next) {
  if (!req.session?.user) return next();
  return requireFreshLogin(req, res, next);
}

async function buildSessionUser(rawUser, levelCol, options = {}) {
  let profile = null;
  let channels = [];

  try {
    profile = await getUserWithGlobalRole(rawUser.id_user);
  } catch (err) {
    logError(console, 'session.role', err);
    if (options.strict) throw err;
  }

  if (!profile || normalizeSessionUser(rawUser, profile, [], levelCol).global_level === 999) {
    throw Object.assign(new Error('Current account authorization is unavailable.'), {
      code: 'MBWEB_AUTH_REVOKED'
    });
  }

  try {
    channels = await getUserChannels(rawUser.id_user);
  } catch (err) {
    logError(console, 'session.channels', err);
    if (options.strict) throw err;
  }

  return normalizeSessionUser(rawUser, profile, channels, levelCol);
}

module.exports = {
  publicSessionUser,
  roleNameFromLevel,
  normalizeSessionUser,
  requireLogin,
  requireFreshLogin,
  refreshOptionalLogin,
  buildSessionUser,
  refreshSessionUser
};
