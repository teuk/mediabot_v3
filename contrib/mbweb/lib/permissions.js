'use strict';

function globalLevel(user) {
  if (!user) return 999;
  if (typeof user.global_level === 'number') return user.global_level;
  if (typeof user.level === 'number') return user.level;
  if (typeof user.id_user_level === 'number') {
    // USER_LEVEL ids are usually 1..4, while semantic levels are 0..3.
    return Math.max(0, user.id_user_level - 1);
  }
  return 999;
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
  if (!user) return false;

  switch (action) {
    case 'view:dashboard':
    case 'view:profile':
    case 'edit:profile':
    case 'view:radio':
      return isUser(user);

    case 'view:system':
    case 'view:all_users':
    case 'use:partyline':
      return isOwner(user);

    case 'view:all_channels':
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
