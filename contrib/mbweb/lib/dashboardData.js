'use strict';

const { config } = require('./config');
const { isOwner } = require('./permissions');
const { publicSessionUser } = require('./sessionUser');
const { logError } = require('./securityLog');
const { ping } = require('./db');
const {
  getUserChannels,
  getCounts
} = require('./mediabotRepository');

async function getDashboardData(req) {
  const owner = isOwner(req.session?.user);
  const data = {
    db: {
      ok: false,
      name: owner ? config.db.database : null,
      user: owner ? config.db.user : null,
      host: owner ? config.db.host : null,
      error: null
    },
    counts: {
      users: null,
      channels: null
    },
    me: publicSessionUser(req.session?.user),
    myChannels: [],
    generatedAt: new Date().toISOString()
  };

  try {
    const db = await ping();
    data.db.ok = true;
    if (owner) data.db.name = db?.db || config.db.database;
  } catch (err) {
    data.db.error = 'Database unavailable';
    logError(console, 'dashboard.database', err);
  }

  try {
    if (owner) data.counts = await getCounts();
  } catch (err) {
    logError(console, 'dashboard.counts', err);
  }

  if (req.session?.user?.id_user) {
    try {
      // Membership is authorization data: a process cache must not outlive a
      // revocation or turn a fresh database failure into stale channel rows.
      data.myChannels = await getUserChannels(req.session.user.id_user);
    } catch (err) {
      logError(console, 'dashboard.channels', err);
    }
  }

  return data;
}

module.exports = {
  getDashboardData
};
