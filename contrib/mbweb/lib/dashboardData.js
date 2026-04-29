'use strict';

const { config } = require('./config');
const { ping } = require('./db');
const {
  getUserChannels,
  getCounts
} = require('./mediabotRepository');

// Short-lived cache for getUserChannels per user — avoids a redundant DB hit
// when the home page is loaded right after an authenticated page (which already
// called getUserChannels via refreshSessionUser).
// TTL: 30 seconds — low enough to stay fresh, high enough to absorb page loads.
const _channelsCache = new Map(); // id_user → { rows, expiresAt }
const _CHANNELS_TTL  = 30_000;

async function getCachedUserChannels(idUser) {
  const now    = Date.now();
  const cached = _channelsCache.get(idUser);
  if (cached && cached.expiresAt > now) return cached.rows;

  const rows = await getUserChannels(idUser);
  _channelsCache.set(idUser, { rows, expiresAt: now + _CHANNELS_TTL });

  // Evict expired entries lazily to avoid unbounded growth
  for (const [uid, entry] of _channelsCache) {
    if (entry.expiresAt <= now) _channelsCache.delete(uid);
  }

  return rows;
}

async function getDashboardData(req) {
  const data = {
    db: {
      ok: false,
      name: config.db.database,
      user: config.db.user,
      host: config.db.host,
      error: null
    },
    counts: {
      users: null,
      channels: null
    },
    me: req.session?.user || null,
    myChannels: [],
    generatedAt: new Date().toISOString()
  };

  try {
    const db = await ping();
    data.db.ok = true;
    data.db.name = db?.db || config.db.database;
  } catch (err) {
    data.db.error = err.message;
  }

  try {
    data.counts = await getCounts();
  } catch (err) {
    console.error('[mbweb][dashboard] getCounts failed', err.message);
  }

  if (req.session?.user?.id_user) {
    try {
      data.myChannels = await getCachedUserChannels(req.session.user.id_user);
    } catch (err) {
      console.error('[mbweb][dashboard] getUserChannels failed', err.message);
    }
  }

  return data;
}

module.exports = {
  getDashboardData
};
