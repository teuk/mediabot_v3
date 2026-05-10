'use strict';

const express = require('express');

const { config } = require('../lib/config');
const {
  can,
  isOwner,
  isMaster,
  isAdministrator
} = require('../lib/permissions');
const { getDashboardData } = require('../lib/dashboardData');
const { requireFreshLogin } = require('../lib/sessionUser');

const router = express.Router();

// /health — no auth required (used by monitoring/systemd)
// returns no sensitive data (no session, no DB)
router.get('/health', (req, res) => {
  res.json({
    ok:        true,
    service:   'mbweb',
    timestamp: new Date().toISOString()
  });
});

// /api/status — Owner only
// getDashboardData exposes db.user, db.host, db.name → not public
router.get('/api/status', requireFreshLogin, async (req, res) => {
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

router.get('/api/dashboard', requireFreshLogin, async (req, res) => {
  try {
    const data = await getDashboardData(req);
    const user = req.session.user;

    const me = {
      nickname:       user.nickname,
      username:       user.username || null,
      global_level:   user.global_level,
      global_role:    user.global_role,
      channels_count: user.channels_count || 0
    };

    res.json({
      ok: true,
      me,
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
  } catch (err) {
    console.error('[mbweb][/api/dashboard] error:', err.message);
    res.status(500).json({ ok: false, error: 'Internal server error' });
  }
});

module.exports = router;