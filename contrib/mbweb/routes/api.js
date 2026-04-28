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

// /health — pas d'auth requise (utilisé par monitoring/systemd)
// mais ne retourne AUCUNE donnée sensible (pas de session, pas de DB)
router.get('/health', (req, res) => {
  res.json({
    ok:        true,
    service:   'mbweb',
    timestamp: new Date().toISOString()
  });
});

// /api/status — réservé Owner
// getDashboardData expose db.user, db.host, db.name → pas public
router.get('/api/status', requireLogin, async (req, res) => {
  if (!isOwner(req.session.user)) {
    return res.status(403).json({ ok: false, error: 'Forbidden' });
  }

  try {
    const data = await getDashboardData(req);
    res.json({
      ok:      true,
      service: 'mbweb',
      permissions: {
        viewDashboard:   can(req.session.user, 'view:dashboard'),
        viewRadio:       can(req.session.user, 'view:radio'),
        viewSystem:      can(req.session.user, 'view:system'),
        viewAllChannels: can(req.session.user, 'view:all_channels')
      },
      ...data
    });
  } catch (err) {
    console.error('[mbweb][/api/status] error:', err.message);
    res.status(500).json({ ok: false, error: 'Internal server error' });
  }
});

router.get('/api/dashboard', requireLogin, async (req, res) => {
  const data = await getDashboardData(req);
  const user = req.session.user;

  res.json({
    ok: true,
    me: user,
    role: {
      global_level:  user.global_level,
      global_role:   user.global_role,
      owner:         isOwner(user),
      master:        isMaster(user),
      administrator: isAdministrator(user)
    },
    visibleBlocks: {
      profile:     can(user, 'view:profile'),
      radio:       can(user, 'view:radio'),
      users:       isMaster(user),
      allChannels: isMaster(user),
      system:      isOwner(user)
    },
    dashboard: data
  });
});

module.exports = router;