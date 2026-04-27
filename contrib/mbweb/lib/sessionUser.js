'use strict';

const {
  getUserWithGlobalRole,
  getUserChannels
} = require('./mediabotRepository');
const { safeBase } = require('./config');

function roleNameFromLevel(level) {
  const n = Number(level);
  if (n === 0) return 'Owner';
  if (n === 1) return 'Master';
  if (n === 2) return 'Administrator';
  if (n === 3) return 'User';
  return 'Unknown';
}

function requireLogin(req, res, next) {
  if (!req.session?.user) {
    return res.redirect(safeBase('/login') + '?error=' + encodeURIComponent('Connexion requise.'));
  }
  next();
}

async function buildSessionUser(rawUser, levelCol) {
  let profile = null;
  let channels = [];

  try {
    profile = await getUserWithGlobalRole(rawUser.id_user);
  } catch (err) {
    console.error('[mbweb][session] failed to load global role', err.message);
  }

  try {
    channels = await getUserChannels(rawUser.id_user);
  } catch (err) {
    console.error('[mbweb][session] failed to load user channels', err.message);
  }

  const idUserLevel = profile?.id_user_level ?? rawUser.id_user_level ?? rawUser[levelCol] ?? null;

  const semanticLevel =
    typeof profile?.global_level === 'number'
      ? profile.global_level
      : Number.isFinite(Number(idUserLevel))
        ? Math.max(0, Number(idUserLevel) - 1)
        : 999;

  return {
    id_user: rawUser.id_user,
    nickname: profile?.nickname || rawUser.nickname,
    username: profile?.username || rawUser.username,
    id_user_level: idUserLevel,
    global_level: semanticLevel,
    global_role: profile?.global_role || roleNameFromLevel(semanticLevel),
    auth: profile?.auth ?? rawUser.auth ?? null,
    tz: profile?.tz || null,
    birthday: profile?.birthday || null,
    fortniteid: profile?.fortniteid || null,
    last_login: profile?.last_login || null,
    channels_count: channels.length,
    flags: {
      owner: semanticLevel <= 0,
      master: semanticLevel <= 1,
      administrator: semanticLevel <= 2,
      user: semanticLevel <= 3
    }
  };
}

module.exports = {
  roleNameFromLevel,
  requireLogin,
  buildSessionUser
};
