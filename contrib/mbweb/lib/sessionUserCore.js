'use strict';

function publicSessionUser(user) {
  if (!user) return null;

  return {
    nickname: user.nickname,
    username: user.username || null,
    global_level: user.global_level,
    global_role: user.global_role,
    channels_count: user.channels_count || 0
  };
}

function roleNameFromLevel(level) {
  const n = Number(level);
  if (n === 0) return 'Owner';
  if (n === 1) return 'Master';
  if (n === 2) return 'Administrator';
  if (n === 3) return 'User';
  return 'Unknown';
}

function normalizeSessionUser(rawUser, profile, channels, levelCol) {
  const safeRaw = rawUser || {};
  const safeProfile = profile || {};
  const safeChannels = Array.isArray(channels) ? channels : [];
  const idUserLevel = safeProfile.id_user_level
    ?? safeRaw.id_user_level
    ?? (levelCol ? safeRaw[levelCol] : null)
    ?? null;

  const semanticLevel = typeof safeProfile.global_level === 'number'
    ? safeProfile.global_level
    : Number.isFinite(Number(idUserLevel))
      ? Math.max(0, Number(idUserLevel) - 1)
      : 999;

  return {
    id_user: safeRaw.id_user,
    nickname: safeProfile.nickname || safeRaw.nickname,
    username: safeProfile.username || safeRaw.username,
    id_user_level: idUserLevel,
    global_level: semanticLevel,
    global_role: safeProfile.global_role || roleNameFromLevel(semanticLevel),
    auth: safeProfile.auth ?? safeRaw.auth ?? null,
    tz: safeProfile.tz || null,
    birthday: safeProfile.birthday || null,
    fortniteid: safeProfile.fortniteid || null,
    last_login: safeProfile.last_login || null,
    channels_count: safeChannels.length,
    flags: {
      owner: semanticLevel <= 0,
      master: semanticLevel <= 1,
      administrator: semanticLevel <= 2,
      user: semanticLevel <= 3
    }
  };
}

module.exports = {
  normalizeSessionUser,
  publicSessionUser,
  roleNameFromLevel
};
