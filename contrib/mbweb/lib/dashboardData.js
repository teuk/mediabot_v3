'use strict';

const { config } = require('./config');
const { ping } = require('./db');
const {
  getUserChannels,
  getCounts
} = require('./mediabotRepository');

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
      data.myChannels = await getUserChannels(req.session.user.id_user);
    } catch (err) {
      console.error('[mbweb][dashboard] getUserChannels failed', err.message);
    }
  }

  return data;
}

module.exports = {
  getDashboardData
};
