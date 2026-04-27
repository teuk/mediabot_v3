'use strict';

const express = require('express');

const { config } = require('../lib/config');
const { can } = require('../lib/permissions');
const {
  isOwner,
  isMaster,
  isAdministrator
} = require('../lib/permissions');
const { getDashboardData } = require('../lib/dashboardData');
const { requireLogin } = require('../lib/sessionUser');

const router = express.Router();

router.get('/health', async (req, res) => {
  res.json({
    ok: true,
    service: 'mbweb',
    baseUrl: config.baseUrl || '/',
    db: `${config.db.user}@${config.db.host}:${config.db.port}/${config.db.database}`,
    user: req.session?.user || null,
    timestamp: new Date().toISOString()
  });
});

router.get('/api/status', async (req, res) => {
  const data = await getDashboardData(req);

  res.json({
    ok: true,
    service: 'mbweb',
    permissions: req.session?.user ? {
      viewDashboard: can(req.session.user, 'view:dashboard'),
      viewRadio: can(req.session.user, 'view:radio'),
      viewSystem: can(req.session.user, 'view:system'),
      viewAllChannels: can(req.session.user, 'view:all_channels')
    } : null,
    ...data
  });
});

router.get('/api/dashboard', requireLogin, async (req, res) => {
  const data = await getDashboardData(req);
  const user = req.session.user;

  res.json({
    ok: true,
    me: user,
    role: {
      global_level: user.global_level,
      global_role: user.global_role,
      owner: isOwner(user),
      master: isMaster(user),
      administrator: isAdministrator(user)
    },
    visibleBlocks: {
      profile: can(user, 'view:profile'),
      radio: can(user, 'view:radio'),
      users: isMaster(user),
      allChannels: isMaster(user),
      system: isOwner(user)
    },
    dashboard: data
  });
});

module.exports = router;
