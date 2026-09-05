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

async function requireFreshLogin(req, res, next) {
  if (!req.session?.user) {
    return res.redirect(safeBase('/login') + '?error=' + encodeURIComponent('Login required.'));
  }

  try {
    await refreshSessionUser(req, { force: true, strict: true });
    return next();
  } catch (err) {
    logError(console, 'session.refresh', err);
    res.set('Cache-Control', 'no-store');
    return res.status(503).send('Authorization could not be refreshed.');
  }
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
  buildSessionUser,
  refreshSessionUser
};
