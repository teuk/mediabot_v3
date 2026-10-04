'use strict';

// Only the four known Mediabot roles grant access. Null, booleans and
// out-of-range values must never be coerced to Owner.
function roleNumber(value, min, max) {
  if (typeof value !== 'number' && typeof value !== 'string') return 999;
  if (typeof value === 'string' && !/^[0-4]$/.test(value)) return 999;
  const n = Number(value);
  return Number.isInteger(n) && n >= min && n <= max ? n : 999;
}

function globalLevel(user) {
  if (!user) return 999;
  if (user.global_level !== null && user.global_level !== undefined) {
    return roleNumber(user.global_level, 0, 3);
  }
  if (user.level !== null && user.level !== undefined) {
    return roleNumber(user.level, 0, 3);
  }
  const id = roleNumber(user.id_user_level, 1, 4);
  return id === 999 ? 999 : id - 1;
}

function isOwner(user) {
  return globalLevel(user) <= 0;
}

function isMaster(user) {
  return globalLevel(user) <= 1;
}

function isAdministrator(user) {
  return globalLevel(user) <= 2;
}

function isUser(user) {
  return globalLevel(user) <= 3;
}

function can(user, action, context = {}) {
  if (!isUser(user)) return false;

  switch (action) {
    case 'view:dashboard':
    case 'view:profile':
    case 'edit:profile':
    case 'view:radio':
      return isUser(user);

    case 'view:system':
    case 'use:partyline':
      return isOwner(user);

    case 'view:all_channels':
    case 'view:all_users':
    case 'view:partyline':
      return isMaster(user);

    case 'view:channel':
      if (isMaster(user)) return true;
      return Boolean(context.channel && context.channel.userHasAccess);

    case 'view:channel_logs':
    case 'edit:channel':
      if (isMaster(user)) return true;
      return Boolean(context.channel && context.channel.userHasAdminAccess);

    default:
      return false;
  }
}

module.exports = {
  globalLevel,
  isOwner,
  isMaster,
  isAdministrator,
  isUser,
  can
};
