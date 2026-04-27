'use strict';

const express = require('express');
const path = require('path');
const session = require('express-session');
const helmet = require('helmet');

const { config, safeBase } = require('./lib/config');
const { getRadioStatus } = require('./lib/radio');
const {
  getUserWithGlobalRole,
  getUserChannels,
  getAllChannels,
  getChannelById,
  userHasChannelAccess,
  getChannelUsers,
  getKnownChannelRelatedTables,
  getAllUsersWithRoles,
  getUserChannelCountMap,
  getUserHostmasks,
  getCommands,
  getCommandCategories,
  getQuotes,
  getQuoteChannels,
  getNetworks
} = require('./lib/mediabotRepository');
const {
  isOwner,
  isMaster,
  isAdministrator,
  can
} = require('./lib/permissions');
const { escapeHtml, renderPage } = require('./lib/render');
const { getDashboardData } = require('./lib/dashboardData');
const {
  requireLogin
} = require('./lib/sessionUser');
const {
  boolLabel
} = require('./lib/viewHelpers');
const apiRoutes = require('./routes/api');
const authRoutes = require('./routes/auth');

const app = express();

app.use(helmet({
  contentSecurityPolicy: {
    useDefaults: true,
    directives: {
      "default-src": ["'self'"],
      "style-src": ["'self'"],
      "script-src": ["'self'"],
      "img-src": ["'self'", "data:"],
      "connect-src": ["'self'"],
      "object-src": ["'none'"],
      "base-uri": ["'self'"],
      "frame-ancestors": ["'self'"]
    }
  },
  crossOriginEmbedderPolicy: false
}));


// ─── Prometheus metrics helper ─────────────────────────────────────────────
// Lightweight Prometheus text-format parser.
// Returns Map<metricName, { help, type, samples: [{labels, value}] }>
function parseMetrics(text) {
  const out = new Map();
  let currentHelp = null;
  let currentType = null;

  for (const rawLine of text.split('\n')) {
    const line = rawLine.trim();
    if (!line) continue;

    if (line.startsWith('# HELP ')) {
      const [, name, ...rest] = line.split(' ');
      currentHelp = { name, help: rest.join(' ') };
      continue;
    }

    if (line.startsWith('# TYPE ')) {
      const [, name, type] = line.split(' ');
      currentType = { name, type };
      continue;
    }

    if (line.startsWith('#')) continue;

    // Sample line: metric_name{label="val",...} value [timestamp]
    const braceOpen = line.indexOf('{');
    const braceClose = line.lastIndexOf('}');
    let metricName, labelsStr, rawValue;

    if (braceOpen !== -1 && braceClose !== -1) {
      metricName = line.slice(0, braceOpen);
      labelsStr  = line.slice(braceOpen + 1, braceClose);
      rawValue   = line.slice(braceClose + 1).trim().split(' ')[0];
    } else {
      const spaceIdx = line.indexOf(' ');
      metricName = line.slice(0, spaceIdx);
      labelsStr  = '';
      rawValue   = line.slice(spaceIdx + 1).trim().split(' ')[0];
    }

    const value = Number(rawValue);
    if (isNaN(value)) continue;

    // Parse labels into object
    const labels = {};
    if (labelsStr) {
      for (const pair of labelsStr.matchAll(/([\w]+)="([^"]*)"/g)) {
        labels[pair[1]] = pair[2];
      }
    }

    if (!out.has(metricName)) {
      out.set(metricName, {
        help:    currentHelp?.name === metricName ? currentHelp.help : '',
        type:    currentType?.name === metricName ? currentType.type : 'untyped',
        samples: []
      });
    }
    out.get(metricName).samples.push({ labels, value });
  }

  return out;
}

// Fetch + parse Prometheus metrics. Returns parsed Map or null on failure.
async function fetchMetrics() {
  const url = config.urls?.metrics;
  if (!url) return null;

  try {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 3000);

    const res = await fetch(url, { signal: controller.signal });
    clearTimeout(timer);

    if (!res.ok) return null;

    const text = await res.text();
    return parseMetrics(text);
  } catch (_) {
    return null;
  }
}

// Extract scalar value for a metric (first sample, no label filter)
function metricVal(parsed, name, labelFilter = null) {
  if (!parsed) return null;
  const entry = parsed.get(name);
  if (!entry || !entry.samples.length) return null;

  if (!labelFilter) return entry.samples[0].value;

  const sample = entry.samples.find(s =>
    Object.entries(labelFilter).every(([k, v]) => s.labels[k] === v)
  );
  return sample ? sample.value : null;
}

// Sum all samples of a metric (useful for counters with label splits)
function metricSum(parsed, name) {
  if (!parsed) return null;
  const entry = parsed.get(name);
  if (!entry || !entry.samples.length) return null;
  return entry.samples.reduce((s, r) => s + r.value, 0);
}

app.set('trust proxy', 'loopback');

app.use(express.urlencoded({ extended: false }));
app.use(express.json());

app.use(session({
  name: 'mbweb.sid',
  secret: config.sessionSecret,
  resave: false,
  saveUninitialized: false,
  cookie: {
    httpOnly: true,
    sameSite: 'lax',
    // B3 — mark cookie Secure when running behind HTTPS reverse proxy
    secure: process.env.NODE_ENV === 'production'
  }
}));

app.use(config.baseUrl + '/css', express.static(path.join(__dirname, 'public', 'css')));
app.use(config.baseUrl + '/public', express.static(path.join(__dirname, 'public')));

app.use(config.baseUrl, apiRoutes);
app.use(config.baseUrl, authRoutes);

app.get(config.baseUrl + '/', async (req, res) => {
  const data = await getDashboardData(req);
  const user = req.session?.user || null;

  const channelPreviewRows = user && data.myChannels.length ? data.myChannels.slice(0, 8) : [];

  const guestBlock = `
<section class="mbw-card mbw-wide">
  <div class="mbw-section-head">
    <div>
      <h2>Espace utilisateur Mediabot</h2>
      <p>
        Connecte-toi avec ton compte Mediabot pour voir ton profil, tes canaux,
        tes droits, la radio et les outils adaptés à ton niveau.
      </p>
    </div>
    <a class="mbw-table-action" href="${safeBase('/login')}">Se connecter</a>
  </div>
</section>
`;

  const sessionBlock = user ? `
<section class="mbw-card mbw-wide">
  <div class="mbw-section-head">
    <div>
      <h2>Session Mediabot</h2>
      <p>Résumé du compte connecté et des droits globaux détectés.</p>
    </div>
    <span class="mbw-count-badge">${escapeHtml(user.global_role)}</span>
  </div>

  <div class="mbw-table-wrap compact">
    <table class="mbw-data-table mbw-home-session-table">
      <thead>
        <tr>
          <th>Nickname</th>
          <th>Username</th>
          <th>Rôle global</th>
          <th>Niveau</th>
          <th>Canaux visibles</th>
          <th>Timezone</th>
          <th>Last login</th>
        </tr>
      </thead>
      <tbody>
        <tr>
          <td class="mbw-user-main">
            <strong>${escapeHtml(user.nickname || 'unknown')}</strong>
            <small>id_user ${escapeHtml(user.id_user ?? 'n/a')}</small>
          </td>
          <td class="mbw-muted-cell">${escapeHtml(user.username || 'n/a')}</td>
          <td><span class="mbw-role-chip">${escapeHtml(user.global_role || 'n/a')}</span></td>
          <td class="mbw-number-cell">${escapeHtml(user.global_level ?? 'n/a')}</td>
          <td class="mbw-number-cell">${escapeHtml(user.channels_count ?? 'n/a')}</td>
          <td>${escapeHtml(user.tz || 'n/a')}</td>
          <td class="mbw-date-cell">${escapeHtml(user.last_login || 'n/a')}</td>
        </tr>
      </tbody>
    </table>
  </div>
</section>
` : guestBlock;

  const quickActions = user ? `
<section class="mbw-card mbw-wide">
  <div class="mbw-section-head">
    <div>
      <h2>Accès rapides</h2>
      <p>Les vues disponibles selon ton niveau Mediabot.</p>
    </div>
  </div>

  <div class="mbw-dashboard-grid">
    <a class="mbw-dashboard-tile" href="${safeBase('/profile')}">
      <strong>Profil</strong>
      <span>Identité, niveau global, hostmasks, timezone.</span>
    </a>

    <a class="mbw-dashboard-tile" href="${safeBase('/channels')}">
      <strong>Channels</strong>
      <span>Canaux visibles et droits associés.</span>
    </a>

    <a class="mbw-dashboard-tile" href="${safeBase('/radio')}">
      <strong>Radio</strong>
      <span>Icecast, mounts, auditeurs et titre courant.</span>
    </a>

    ${isMaster(user) ? `
      <a class="mbw-dashboard-tile elevated" href="${safeBase('/users')}">
        <strong>Users</strong>
        <span>Vue globale des utilisateurs Mediabot.</span>
      </a>
    ` : ''}

    <a class="mbw-dashboard-tile" href="${safeBase('/api/dashboard')}">
      <strong>API dashboard</strong>
      <span>État JSON de ton dashboard courant.</span>
    </a>

    ${isOwner(user) ? `
      <a class="mbw-dashboard-tile owner" href="${safeBase('/api/status')}">
        <strong>Status API</strong>
        <span>État brut de l’application mbweb.</span>
      </a>
    ` : ''}
  </div>
</section>
` : '';

  const channelPreview = user ? `
<section class="mbw-card mbw-wide">
  <div class="mbw-section-head">
    <div>
      <h2>Canaux accessibles</h2>
      <p>Aperçu compact des canaux visibles pour ton compte.</p>
    </div>
    <a class="mbw-table-action" href="${safeBase('/channels')}">Tout voir</a>
  </div>

  ${channelPreviewRows.length ? `
    <div class="mbw-table-wrap">
      <table class="mbw-data-table mbw-home-channels-table">
        <thead>
          <tr>
            <th>Canal</th>
            <th>Description / topic</th>
            <th>Auto join</th>
            <th>Mode</th>
            <th>Niveau canal</th>
            <th>Automode</th>
            <th>Détail</th>
          </tr>
        </thead>
        <tbody>
          ${channelPreviewRows.map(ch => {
            const autoJoin = Number(ch.auto_join || 0) === 1;
            const desc = ch.description || ch.topic || 'Aucune description.';
            return `
              <tr>
                <td class="mbw-channel-main">
                  <strong>${escapeHtml(ch.name || 'unknown')}</strong>
                  <small>id_channel ${escapeHtml(ch.id_channel ?? 'n/a')}</small>
                </td>
                <td class="mbw-channel-desc">${escapeHtml(desc)}</td>
                <td>
                  <span class="mbw-status-pill ${autoJoin ? 'ok' : 'bad'}">
                    ${autoJoin ? 'yes' : 'no'}
                  </span>
                </td>
                <td class="mbw-muted-cell">${escapeHtml(ch.chanmode || 'n/a')}</td>
                <td class="mbw-number-cell">${escapeHtml(ch.channel_level ?? 'n/a')}</td>
                <td class="mbw-muted-cell">${escapeHtml(ch.automode ?? 'n/a')}</td>
                <td><a class="mbw-table-action" href="${safeBase('/channels/' + ch.id_channel)}">ouvrir</a></td>
              </tr>
            `;
          }).join('')}
        </tbody>
      </table>
    </div>
  ` : `<p>Aucun canal accessible pour ce compte.</p>`}
</section>
` : '';

  // Format uptime seconds → human readable
  function fmtUptime(s) {
    if (s === null || s === undefined) return 'n/a';
    const secs  = Math.floor(s);
    const d = Math.floor(secs / 86400);
    const h = Math.floor((secs % 86400) / 3600);
    const m = Math.floor((secs % 3600) / 60);
    const parts = [];
    if (d) parts.push(`${d}j`);
    if (h) parts.push(`${h}h`);
    parts.push(`${m}mn`);
    return parts.join(' ');
  }

  const metricsBlock = data.metrics ? `
<section class="mbw-card mbw-wide">
  <div class="mbw-section-head">
    <div>
      <h2>Bot Mediabot — métriques live</h2>
      <p>Données Prometheus exposées sur <code>${escapeHtml(config.urls?.metrics || 'n/a')}</code></p>
    </div>
    <span class="mbw-count-badge ${data.metrics.ok ? 'ok' : 'bad'}">${data.metrics.ok ? 'online' : 'unreachable'}</span>
  </div>

  ${data.metrics.ok ? `
    <div class="mbw-metrics-grid">
      <div class="mbw-metric-tile ${Number(data.metrics.irc_connected) ? 'ok' : 'bad'}">
        <span>IRC</span>
        <strong>${Number(data.metrics.irc_connected) ? 'connecté' : 'déconnecté'}</strong>
      </div>
      <div class="mbw-metric-tile ${Number(data.metrics.db_connected) ? 'ok' : 'bad'}">
        <span>DB</span>
        <strong>${Number(data.metrics.db_connected) ? 'connectée' : 'erreur'}</strong>
      </div>
      <div class="mbw-metric-tile">
        <span>Uptime</span>
        <strong>${escapeHtml(fmtUptime(data.metrics.uptime_seconds))}</strong>
      </div>
      <div class="mbw-metric-tile">
        <span>Canaux gérés</span>
        <strong>${escapeHtml(data.metrics.channels_managed ?? 'n/a')}</strong>
      </div>
      <div class="mbw-metric-tile">
        <span>Users connus</span>
        <strong>${escapeHtml(data.metrics.users_known ?? 'n/a')}</strong>
      </div>
      <div class="mbw-metric-tile">
        <span>Messages reçus</span>
        <strong>${escapeHtml(data.metrics.privmsg_in ?? 'n/a')}</strong>
      </div>
      <div class="mbw-metric-tile">
        <span>Messages envoyés</span>
        <strong>${escapeHtml(data.metrics.privmsg_out ?? 'n/a')}</strong>
      </div>
      <div class="mbw-metric-tile">
        <span>Logins réussis</span>
        <strong>${escapeHtml(data.metrics.auth_success ?? 'n/a')}</strong>
      </div>
      <div class="mbw-metric-tile ${Number(data.metrics.auth_failure) > 0 ? 'warn' : ''}">
        <span>Logins échoués</span>
        <strong>${escapeHtml(data.metrics.auth_failure ?? 'n/a')}</strong>
      </div>
      <div class="mbw-metric-tile ${Number(data.metrics.restart_total) > 0 ? 'warn' : ''}">
        <span>Restarts IRC</span>
        <strong>${escapeHtml(data.metrics.restart_total ?? 'n/a')}</strong>
      </div>
      <div class="mbw-metric-tile ${Number(data.metrics.command_errors) > 0 ? 'bad' : ''}">
        <span>Erreurs commandes</span>
        <strong>${escapeHtml(data.metrics.command_errors ?? 'n/a')}</strong>
      </div>
    </div>
    <p class="mbw-muted-small">
      <a href="${safeBase('/api/metrics')}">Voir toutes les métriques →</a>
    </p>
  ` : `<p class="mbw-bad">Endpoint Prometheus inaccessible.</p>`}
</section>
` : '';

  const ownerSystemBlock = user && isOwner(user) ? `
<section class="mbw-card mbw-wide">
  <div class="mbw-section-head">
    <div>
      <h2>Vue Owner</h2>
      <p>Résumé global réservé Owner.</p>
    </div>
    <span class="mbw-count-badge">owner view</span>
  </div>

  <div class="mbw-table-wrap compact">
    <table class="mbw-data-table mbw-home-system-table">
      <thead>
        <tr>
          <th>Élément</th>
          <th>Valeur</th>
          <th>Détail</th>
          <th>Accès</th>
        </tr>
      </thead>
      <tbody>
        <tr>
          <td><strong>Users</strong></td>
          <td class="mbw-number-cell">${escapeHtml(data.counts.users ?? 'n/a')}</td>
          <td class="mbw-muted-cell">Comptes Mediabot dans USER.</td>
          <td><a class="mbw-table-action" href="${safeBase('/users')}">ouvrir</a></td>
        </tr>
        <tr>
          <td><strong>Channels</strong></td>
          <td class="mbw-number-cell">${escapeHtml(data.counts.channels ?? 'n/a')}</td>
          <td class="mbw-muted-cell">Canaux connus dans CHANNEL.</td>
          <td><a class="mbw-table-action" href="${safeBase('/channels')}">ouvrir</a></td>
        </tr>
        <tr>
          <td><strong>API status</strong></td>
          <td class="${data.db.ok ? 'mbw-ok' : 'mbw-bad'}">${data.db.ok ? 'ok' : 'error'}</td>
          <td class="mbw-muted-cell">${escapeHtml(data.db.user)}@${escapeHtml(data.db.host)} / ${escapeHtml(data.db.name)}</td>
          <td><a class="mbw-table-action" href="${safeBase('/api/status')}">ouvrir</a></td>
        </tr>
      </tbody>
    </table>
  </div>
</section>
` : '';

  const body = `
<section class="mbw-hero">
  <div>
    <p class="mbw-kicker">Console utilisateur</p>
    <h1>Mediabot v3</h1>
    <p>
      Espace personnel Mediabot : profil, canaux, droits, radio et vues
      adaptées au niveau global de l’utilisateur connecté.
    </p>
    <div class="mbw-actions">
      ${user ? `<a class="mbw-primary" href="${safeBase('/profile')}">Mon profil</a>` : `<a class="mbw-primary" href="${safeBase('/login')}">Se connecter</a>`}
      <a class="mbw-secondary" href="${safeBase('/health')}">Healthcheck</a>
    </div>
  </div>
</section>

<section class="mbw-grid">
  <article class="mbw-card">
    <h2>Base Mediabot</h2>
    <p class="${data.db.ok ? 'mbw-ok' : 'mbw-bad'}">${data.db.ok ? 'Connectée' : 'Erreur DB'}</p>
    <p>${escapeHtml(data.db.user)}@${escapeHtml(data.db.host)} / ${escapeHtml(data.db.name)}</p>
    ${data.db.error ? `<pre>${escapeHtml(data.db.error)}</pre>` : ''}
  </article>

  <article class="mbw-card">
    <h2>Utilisateurs</h2>
    <p class="mbw-big">${escapeHtml(data.counts.users ?? 'n/a')}</p>
    <p>Entrées dans la table USER.</p>
  </article>

  <article class="mbw-card">
    <h2>Canaux</h2>
    <p class="mbw-big">${escapeHtml(data.counts.channels ?? 'n/a')}</p>
    <p>Entrées dans la table CHANNEL.</p>
  </article>
</section>

${sessionBlock}
${quickActions}
${channelPreview}
${metricsBlock}
${ownerSystemBlock}
`;

  res.send(renderPage('Accueil', body, req));
});


app.get(config.baseUrl + '/api/me', requireLogin, async (req, res) => {
  // B2 — wrap in try/catch so DB errors return JSON, not HTML 500
  try {
    const profile = await getUserWithGlobalRole(req.session.user.id_user);
    const channels = await getUserChannels(req.session.user.id_user);
    const hostmasks = await getUserHostmasks(req.session.user.id_user);

    res.json({
      ok: true,
      me: req.session.user,
      profile,
      channels,
      hostmasks
    });
  } catch (err) {
    console.error('[mbweb][/api/me] error:', err.message);
    res.status(500).json({ ok: false, error: 'Internal server error' });
  }
});

app.get(config.baseUrl + '/api/channels', requireLogin, async (req, res) => {
  // B2 — try/catch for DB errors
  try {
    const user = req.session.user;
    const channels = isMaster(user)
      ? await getAllChannels()
      : await getUserChannels(user.id_user);

    res.json({
      ok: true,
      scope: isMaster(user) ? 'all' : 'mine',
      channels
    });
  } catch (err) {
    console.error('[mbweb][/api/channels] error:', err.message);
    res.status(500).json({ ok: false, error: 'Internal server error' });
  }
});

app.get(config.baseUrl + '/profile', requireLogin, async (req, res) => {
  // B2 — try/catch for DB errors
  let profile, hostmasks, channels;
  try {
    profile = await getUserWithGlobalRole(req.session.user.id_user);
    hostmasks = await getUserHostmasks(req.session.user.id_user);
    channels = await getUserChannels(req.session.user.id_user);
  } catch (err) {
    console.error('[mbweb][/profile] error:', err.message);
    return res.status(500).send(renderPage('Erreur', `
<section class="mbw-card">
  <h1>Erreur serveur</h1>
  <p>Impossible de charger le profil. Réessaie dans quelques instants.</p>
</section>
`, req));
  }

  const body = `
<section class="mbw-hero">
  <div>
    <p class="mbw-kicker">Espace personnel</p>
    <h1>${escapeHtml(req.session.user.nickname)}</h1>
    <p>
      Ton profil Mediabot, tes informations utiles et les accès détectés
      depuis la base du bot.
    </p>
    <div class="mbw-actions">
      <a class="mbw-primary" href="${safeBase('/channels')}">Voir mes canaux</a>
      <a class="mbw-secondary" href="${safeBase('/api/me')}">API me</a>
    </div>
  </div>
</section>

<section class="mbw-grid">
  <article class="mbw-card">
    <h2>Niveau global</h2>
    <p class="mbw-big">${escapeHtml(req.session.user.global_role)}</p>
    <p>niveau ${escapeHtml(req.session.user.global_level)}</p>
  </article>

  <article class="mbw-card">
    <h2>Canaux accessibles</h2>
    <p class="mbw-big">${escapeHtml(channels.length)}</p>
    <p>selon USER_CHANNEL.</p>
  </article>

  <article class="mbw-card">
    <h2>Auth IRC</h2>
    <p class="${Number(profile?.auth || 0) ? 'mbw-ok' : 'mbw-bad'}">${Number(profile?.auth || 0) ? 'authentifié' : 'non authentifié'}</p>
    <p>état courant côté table USER.</p>
  </article>
</section>

<section class="mbw-card mbw-wide">
  <h2>Détails du profil</h2>
  <div class="mbw-kv">
    <div><span>id_user</span><strong>${escapeHtml(profile?.id_user ?? req.session.user.id_user)}</strong></div>
    <div><span>nickname</span><strong>${escapeHtml(profile?.nickname ?? req.session.user.nickname)}</strong></div>
    <div><span>username</span><strong>${escapeHtml(profile?.username ?? '')}</strong></div>
    <div><span>timezone</span><strong>${escapeHtml(profile?.tz ?? 'n/a')}</strong></div>
    <div><span>birthday</span><strong>${escapeHtml(profile?.birthday ?? 'n/a')}</strong></div>
    <div><span>fortniteid</span><strong>${escapeHtml(profile?.fortniteid ?? 'n/a')}</strong></div>
    <div><span>last_login</span><strong>${escapeHtml(profile?.last_login ?? 'n/a')}</strong></div>
  </div>
</section>

<section class="mbw-card mbw-wide">
  <h2>Hostmasks</h2>
  ${hostmasks.length ? `
    <div class="mbw-list">
      ${hostmasks.map(h => `
        <div class="mbw-list-row">
          <strong>${escapeHtml(h.hostmask)}</strong>
          <span>${h.legacy ? 'legacy' : escapeHtml(h.created_at ?? '')}</span>
        </div>
      `).join('')}
    </div>
  ` : `<p>Aucune hostmask détectée.</p>`}
</section>
`;

  res.send(renderPage('Profil', body, req));
});

app.get(config.baseUrl + '/channels', requireLogin, async (req, res) => {
  const user = req.session.user;
  const channels = isMaster(user)
    ? await getAllChannels()
    : await getUserChannels(user.id_user);

  const activeCount = channels.filter(ch => Number(ch.auto_join || 0) === 1).length;

  const body = `
<section class="mbw-hero">
  <div>
    <p class="mbw-kicker">${isMaster(user) ? 'Vue globale' : 'Mes canaux'}</p>
    <h1>Channels</h1>
    <p>
      ${isMaster(user)
        ? 'Ton niveau permet de voir tous les canaux connus de Mediabot.'
        : 'Vue limitée aux canaux associés à ton compte Mediabot.'}
    </p>
    <div class="mbw-actions">
      <a class="mbw-primary" href="${safeBase('/profile')}">Mon profil</a>
      <a class="mbw-secondary" href="${safeBase('/api/channels')}">API channels</a>
    </div>
  </div>
</section>

<section class="mbw-grid">
  <article class="mbw-card">
    <h2>Total channels</h2>
    <p class="mbw-big">${escapeHtml(channels.length)}</p>
    <p>${isMaster(user) ? 'canaux globaux visibles' : 'canaux liés à ton compte'}.</p>
  </article>

  <article class="mbw-card">
    <h2>Auto join</h2>
    <p class="mbw-big">${escapeHtml(activeCount)}</p>
    <p>canaux avec auto_join actif.</p>
  </article>

  <article class="mbw-card">
    <h2>Scope</h2>
    <p class="mbw-big">${isMaster(user) ? 'global' : 'mine'}</p>
    <p>selon ton niveau Mediabot.</p>
  </article>
</section>

<section class="mbw-card mbw-wide">
  <div class="mbw-section-head">
    <div>
      <h2>${escapeHtml(channels.length)} canal(aux)</h2>
      <p>
        Tableau en lecture seule : configuration de base, auto-join,
        modes et droits de ton compte sur chaque canal.
      </p>
    </div>
    <span class="mbw-count-badge">${isMaster(user) ? 'global view' : 'filtered view'}</span>
  </div>

  ${channels.length ? `
    <div class="mbw-table-wrap">
      <table class="mbw-data-table mbw-channels-table">
        <thead>
          <tr>
            <th>Canal</th>
            <th>Description / topic</th>
            <th>Auto join</th>
            <th>Mode</th>
            <th>Niveau canal</th>
            <th>Automode</th>
            <th>Owner</th>
            <th>Détail</th>
          </tr>
        </thead>
        <tbody>
          ${channels.map(ch => {
            const autoJoin = Number(ch.auto_join || 0) === 1;
            const detailUrl = safeBase('/channels/' + ch.id_channel);
            const desc = ch.description || ch.topic || 'Aucune description.';

            return `
              <tr>
                <td class="mbw-channel-main">
                  <strong>${escapeHtml(ch.name || 'unknown')}</strong>
                  <small>id_channel ${escapeHtml(ch.id_channel ?? 'n/a')}</small>
                </td>
                <td class="mbw-channel-desc">${escapeHtml(desc)}</td>
                <td>
                  <span class="mbw-status-pill ${autoJoin ? 'ok' : 'bad'}">
                    ${autoJoin ? 'yes' : 'no'}
                  </span>
                </td>
                <td class="mbw-muted-cell">${escapeHtml(ch.chanmode || 'n/a')}</td>
                <td class="mbw-number-cell">${escapeHtml(ch.channel_level ?? 'n/a')}</td>
                <td class="mbw-muted-cell">${escapeHtml(ch.automode ?? 'n/a')}</td>
                <td class="mbw-number-cell">${escapeHtml(ch.channel_owner_id ?? 'n/a')}</td>
                <td>
                  <a class="mbw-table-action" href="${detailUrl}">ouvrir</a>
                </td>
              </tr>
            `;
          }).join('')}
        </tbody>
      </table>
    </div>
  ` : `<p>Aucun canal accessible pour ce compte.</p>`}
</section>
`;

  res.send(renderPage('Channels', body, req));
});


app.get(config.baseUrl + '/api/radio/status', requireLogin, async (req, res) => {
  try {
    const radio = await getRadioStatus();
    res.json({
      ok: true,
      radio
    });
  } catch (err) {
    console.error('[mbweb][radio] exception', err);
    res.status(500).json({
      ok: false,
      error: err.message
    });
  }
});

app.get(config.baseUrl + '/radio', requireLogin, async (req, res) => {
  let radio;

  try {
    radio = await getRadioStatus();
  } catch (err) {
    radio = {
      ok: false,
      rawError: err.message,
      mounts: [],
      primary: null
    };
  }

  const primary = radio.primary;
  const mounts = radio.mounts || [];
  const totalListeners = mounts.reduce((sum, m) => sum + Number(m.listeners || 0), 0);
  const activeMounts = mounts.length;

  const body = `
<section class="mbw-hero">
  <div>
    <p class="mbw-kicker">Radio</p>
    <h1>Radio status</h1>
    <p>
      État de la radio exposé depuis Icecast. Cette page est en lecture seule
      et utilise le flux de statut configuré pour Mediabot.
    </p>
    <div class="mbw-actions">
      <a class="mbw-primary" href="${escapeHtml(radio.publicListenUrl || '#')}">Écouter le mount principal</a>
      <a class="mbw-secondary" href="${safeBase('/api/radio/status')}">API radio</a>
    </div>
  </div>
</section>

<section class="mbw-grid">
  <article class="mbw-card">
    <h2>Icecast</h2>
    <p class="${radio.ok ? 'mbw-ok' : 'mbw-bad'}">${radio.ok ? 'online' : 'unavailable'}</p>
    <p>${escapeHtml(radio.statusUrl || '')}</p>
    ${radio.rawError ? `<pre>${escapeHtml(radio.rawError)}</pre>` : ''}
  </article>

  <article class="mbw-card">
    <h2>Mounts actifs</h2>
    <p class="mbw-big">${escapeHtml(activeMounts)}</p>
    <p>mounts retournés par Icecast.</p>
  </article>

  <article class="mbw-card">
    <h2>Auditeurs totaux</h2>
    <p class="mbw-big">${escapeHtml(totalListeners)}</p>
    <p>sur tous les mounts actifs.</p>
  </article>
</section>

<section class="mbw-card mbw-wide">
  <div class="mbw-section-head">
    <div>
      <h2>Lecture courante</h2>
      <p>Résumé du mount principal configuré pour Mediabot.</p>
    </div>
    <span class="mbw-count-badge">${escapeHtml(radio.primaryMount || 'n/a')}</span>
  </div>

  ${primary ? `
    <div class="mbw-table-wrap compact">
      <table class="mbw-data-table mbw-radio-current-table">
        <thead>
          <tr>
            <th>Mount</th>
            <th>Titre</th>
            <th>Artist</th>
            <th>Bitrate</th>
            <th>Listeners</th>
            <th>Peak</th>
            <th>Started</th>
            <th>Listen</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td class="mbw-radio-main">
              <strong>${escapeHtml(radio.primaryMount || primary.mount || 'n/a')}</strong>
              <small>primary mount</small>
            </td>
            <td class="mbw-radio-title">${escapeHtml(primary.title || 'n/a')}</td>
            <td class="mbw-muted-cell">${escapeHtml(primary.artist || 'n/a')}</td>
            <td class="mbw-number-cell">${escapeHtml(primary.bitrate ?? 'n/a')}</td>
            <td class="mbw-number-cell">${escapeHtml(primary.listeners ?? 'n/a')}</td>
            <td class="mbw-number-cell">${escapeHtml(primary.listenerPeak ?? 'n/a')}</td>
            <td class="mbw-date-cell">${escapeHtml(primary.streamStart || 'n/a')}</td>
            <td><a class="mbw-table-action" href="${escapeHtml(primary.publicListenUrl || radio.publicListenUrl || '#')}">ouvrir</a></td>
          </tr>
        </tbody>
      </table>
    </div>
  ` : `<p>Aucun mount principal actif détecté.</p>`}
</section>

<section class="mbw-card mbw-wide">
  <div class="mbw-section-head">
    <div>
      <h2>Mounts Icecast</h2>
      <p>Vue comparative des flux actuellement exposés par Icecast.</p>
    </div>
    <span class="mbw-count-badge">${escapeHtml(mounts.length)} mounts</span>
  </div>

  ${mounts.length ? `
    <div class="mbw-table-wrap">
      <table class="mbw-data-table mbw-radio-table">
        <thead>
          <tr>
            <th>Mount</th>
            <th>Titre</th>
            <th>Listeners</th>
            <th>Peak</th>
            <th>Bitrate</th>
            <th>Content</th>
            <th>Started</th>
            <th>Listen</th>
          </tr>
        </thead>
        <tbody>
          ${mounts.map(m => `
            <tr>
              <td class="mbw-radio-main">
                <strong>${escapeHtml(m.mount || 'unknown')}</strong>
                <small>${escapeHtml(m.serverName || '')}</small>
              </td>
              <td class="mbw-radio-title">${escapeHtml(m.title || m.serverDescription || 'n/a')}</td>
              <td class="mbw-number-cell">${escapeHtml(m.listeners ?? 'n/a')}</td>
              <td class="mbw-number-cell">${escapeHtml(m.listenerPeak ?? 'n/a')}</td>
              <td class="mbw-number-cell">${escapeHtml(m.bitrate ?? 'n/a')}</td>
              <td class="mbw-muted-cell">${escapeHtml(m.contentType || 'n/a')}</td>
              <td class="mbw-date-cell">${escapeHtml(m.streamStart || 'n/a')}</td>
              <td><a class="mbw-table-action" href="${escapeHtml(m.publicListenUrl || '#')}">ouvrir</a></td>
            </tr>
          `).join('')}
        </tbody>
      </table>
    </div>
  ` : `<p>Aucun mount actif retourné par Icecast.</p>`}
</section>
`;

  res.send(renderPage('Radio', body, req));
});



// ─── Network topology ──────────────────────────────────────────────────────

app.get(config.baseUrl + '/api/network', requireLogin, async (req, res) => {
  if (!isMaster(req.session.user)) {
    return res.status(403).json({ ok: false, error: 'Forbidden' });
  }

  try {
    const networks = await getNetworks();
    res.json({ ok: true, total: networks.length, networks });
  } catch (err) {
    console.error('[mbweb][/api/network] error:', err.message);
    res.status(500).json({ ok: false, error: 'Internal server error' });
  }
});

app.get(config.baseUrl + '/network', requireLogin, async (req, res) => {
  if (!isMaster(req.session.user)) {
    return res.status(403).send(renderPage('Accès refusé', `
<section class="mbw-card">
  <h1>Accès refusé</h1>
  <p>Cette page est réservée aux Owner et Master Mediabot.</p>
  <a href="${safeBase('/')}">← Retour à l'accueil</a>
</section>
`, req));
  }

  let networks;

  try {
    networks = await getNetworks();
  } catch (err) {
    console.error('[mbweb][/network] error:', err.message);
    return res.status(500).send(renderPage('Erreur', `
<section class="mbw-card">
  <h1>Erreur serveur</h1>
  <p>Impossible de charger la topologie réseau.</p>
</section>
`, req));
  }

  const totalServers = networks.reduce((s, n) => s + n.servers.length, 0);

  const networkCards = networks.length ? networks.map(net => `
    <article class="mbw-network-card">
      <header class="mbw-network-header">
        <div>
          <h3>${escapeHtml(net.network_name || 'unnamed')}</h3>
          <span class="mbw-count-badge">${escapeHtml(net.servers.length)} serveur(s)</span>
        </div>
        <span class="mbw-muted-cell">id_network ${escapeHtml(net.id_network ?? 'n/a')}</span>
      </header>

      ${net.servers.length ? `
        <div class="mbw-server-list">
          ${net.servers.map(s => `
            <div class="mbw-server-row">
              <span class="mbw-server-host">${escapeHtml(s.hostname || s.raw || 'n/a')}</span>
              ${s.port ? `<span class="mbw-server-port">:${escapeHtml(s.port)}</span>` : ''}
              <span class="mbw-server-id">id_server ${escapeHtml(s.id_server ?? 'n/a')}</span>
            </div>
          `).join('')}
        </div>
      ` : `<p class="mbw-muted-cell">Aucun serveur défini pour ce réseau.</p>`}
    </article>
  `).join('') : `<p>Aucun réseau IRC configuré dans la base Mediabot.</p>`;

  const body = `
<section class="mbw-hero">
  <div>
    <p class="mbw-kicker">Infrastructure</p>
    <h1>Topologie réseau IRC</h1>
    <p>
      Réseaux et serveurs IRC configurés dans la base Mediabot.
      Lecture seule — modification via le script <code>conf_servers.pl</code>.
    </p>
    <div class="mbw-actions">
      <a class="mbw-primary" href="${safeBase('/api/network')}">API JSON</a>
      <a class="mbw-secondary" href="${safeBase('/')}">Accueil</a>
    </div>
  </div>
</section>

<section class="mbw-grid">
  <article class="mbw-card">
    <h2>Réseaux</h2>
    <p class="mbw-big">${escapeHtml(networks.length)}</p>
    <p>entrées dans NETWORK.</p>
  </article>

  <article class="mbw-card">
    <h2>Serveurs</h2>
    <p class="mbw-big">${escapeHtml(totalServers)}</p>
    <p>entrées dans SERVERS.</p>
  </article>

  <article class="mbw-card">
    <h2>Moy. serveurs</h2>
    <p class="mbw-big">${escapeHtml(networks.length ? (totalServers / networks.length).toFixed(1) : 'n/a')}</p>
    <p>par réseau configuré.</p>
  </article>
</section>

<section class="mbw-card mbw-wide">
  <div class="mbw-section-head">
    <div>
      <h2>Réseaux IRC configurés</h2>
      <p>
        Chaque réseau liste ses serveurs de connexion.
        Mediabot choisit un serveur au hasard parmi ceux disponibles.
      </p>
    </div>
    <span class="mbw-count-badge">${escapeHtml(networks.length)} réseaux</span>
  </div>

  <div class="mbw-network-grid">
    ${networkCards}
  </div>
</section>
`;

  res.send(renderPage('Network', body, req));
});

// ─── Metrics proxy (Owner only) ────────────────────────────────────────────

app.get(config.baseUrl + '/api/metrics', requireLogin, async (req, res) => {
  if (!isOwner(req.session.user)) {
    return res.status(403).json({ ok: false, error: 'Forbidden' });
  }

  try {
    const parsed = await fetchMetrics();
    if (!parsed) {
      return res.status(503).json({ ok: false, error: 'Metrics endpoint unreachable' });
    }

    const out = {};
    for (const [name, entry] of parsed) {
      out[name] = {
        help: entry.help,
        type: entry.type,
        samples: entry.samples
      };
    }

    res.json({ ok: true, metricsUrl: config.urls?.metrics, metrics: out });
  } catch (err) {
    console.error('[mbweb][/api/metrics] error:', err.message);
    res.status(500).json({ ok: false, error: 'Internal server error' });
  }
});

// ─── Quotes explorer ───────────────────────────────────────────────────────

app.get(config.baseUrl + '/api/quotes', requireLogin, async (req, res) => {
  try {
    const channel = req.query.channel || null;
    const search  = req.query.q       || null;
    const page    = Math.max(1, Number(req.query.page) || 1);
    const perPage = Math.min(Number(req.query.per_page) || 50, 200);

    const [result, channels] = await Promise.all([
      getQuotes({ channel, search, page, perPage }),
      getQuoteChannels()
    ]);

    res.json({
      ok: true,
      total: result.total,
      page,
      perPage,
      pages: Math.ceil(result.total / perPage),
      quotes: result.rows,
      channels
    });
  } catch (err) {
    console.error('[mbweb][/api/quotes] error:', err.message);
    res.status(500).json({ ok: false, error: 'Internal server error' });
  }
});

app.get(config.baseUrl + '/quotes', requireLogin, async (req, res) => {
  const channel = req.query.channel || null;
  const search  = req.query.q       || null;
  const page    = Math.max(1, Number(req.query.page) || 1);
  const perPage = 50;

  let result, channels;

  try {
    [result, channels] = await Promise.all([
      getQuotes({ channel, search, page, perPage }),
      getQuoteChannels()
    ]);
  } catch (err) {
    console.error('[mbweb][/quotes] error:', err.message);
    return res.status(500).send(renderPage('Erreur', `
<section class="mbw-card">
  <h1>Erreur serveur</h1>
  <p>Impossible de charger les quotes.</p>
</section>
`, req));
  }

  const totalPages = Math.ceil(result.total / perPage);

  // Pagination helper
  function pageUrl(p) {
    const params = new URLSearchParams();
    if (channel) params.set('channel', channel);
    if (search)  params.set('q', search);
    params.set('page', p);
    return safeBase('/quotes') + '?' + params.toString();
  }

  const paginationBar = totalPages > 1 ? `
<div class="mbw-pagination">
  ${page > 1         ? `<a class="mbw-page-btn" href="${escapeHtml(pageUrl(page - 1))}">‹ Précédent</a>` : '<span class="mbw-page-btn disabled">‹ Précédent</span>'}
  <span class="mbw-page-info">Page ${escapeHtml(page)} / ${escapeHtml(totalPages)}</span>
  ${page < totalPages ? `<a class="mbw-page-btn" href="${escapeHtml(pageUrl(page + 1))}">Suivant ›</a>` : '<span class="mbw-page-btn disabled">Suivant ›</span>'}
</div>
` : '';

  const filterBar = `
<section class="mbw-card mbw-wide">
  <form method="get" action="${safeBase('/quotes')}" class="mbw-filter-bar">
    <input
      type="search"
      name="q"
      placeholder="Rechercher dans le texte…"
      value="${escapeHtml(search || '')}"
      class="mbw-search-input"
    >
    <select name="channel" class="mbw-select">
      <option value="">Tous les canaux</option>
      ${channels.map(ch => `
        <option value="${escapeHtml(ch.name)}"
          ${channel === ch.name ? 'selected' : ''}>
          ${escapeHtml(ch.name)} (${escapeHtml(ch.n)})
        </option>
      `).join('')}
    </select>
    <button type="submit" class="mbw-btn-primary">Filtrer</button>
    ${search || channel ? `<a href="${safeBase('/quotes')}" class="mbw-btn-secondary">Réinitialiser</a>` : ''}
  </form>
</section>
`;

  const body = `
<section class="mbw-hero">
  <div>
    <p class="mbw-kicker">Bot Mediabot</p>
    <h1>Quotes</h1>
    <p>
      Explorateur des citations enregistrées par canal IRC.
      Ajout et suppression via les commandes IRC <code>!q add</code> / <code>!q del</code>.
    </p>
    <div class="mbw-actions">
      <a class="mbw-primary" href="${safeBase('/api/quotes')}">API JSON</a>
      <a class="mbw-secondary" href="${safeBase('/')}">Accueil</a>
    </div>
  </div>
</section>

<section class="mbw-grid">
  <article class="mbw-card">
    <h2>Total</h2>
    <p class="mbw-big">${escapeHtml(result.total)}</p>
    <p>quotes dans la base.</p>
  </article>

  <article class="mbw-card">
    <h2>Canaux</h2>
    <p class="mbw-big">${escapeHtml(channels.length)}</p>
    <p>canaux avec au moins une quote.</p>
  </article>

  <article class="mbw-card">
    <h2>Page</h2>
    <p class="mbw-big">${escapeHtml(page)} / ${escapeHtml(totalPages || 1)}</p>
    <p>${escapeHtml(perPage)} quotes par page.</p>
  </article>
</section>

${filterBar}

<section class="mbw-card mbw-wide">
  <div class="mbw-section-head">
    <div>
      <h2>${search || channel ? 'Résultats filtrés' : 'Dernières quotes'}</h2>
      <p>${escapeHtml(result.rows.length)} quote(s) affichée(s) sur ${escapeHtml(result.total)} au total.</p>
    </div>
    <span class="mbw-count-badge">${escapeHtml(result.total)} total</span>
  </div>

  ${paginationBar}

  ${result.rows.length ? `
    <div class="mbw-quotes-list">
      ${result.rows.map(q => `
        <div class="mbw-quote-card">
          <div class="mbw-quote-body">${escapeHtml(q.quotetext || '')}</div>
          <div class="mbw-quote-meta">
            <span class="mbw-quote-id">#${escapeHtml(q.id_quotes ?? '')}</span>
            ${q.channel_name ? `<span class="mbw-quote-channel">${escapeHtml(q.channel_name)}</span>` : ''}
            ${q.author_nick  ? `<span class="mbw-quote-author">par ${escapeHtml(q.author_nick)}</span>` : ''}
            ${q.ts           ? `<span class="mbw-quote-date">${escapeHtml(String(q.ts).slice(0, 19).replace('T', ' '))}</span>` : ''}
          </div>
        </div>
      `).join('')}
    </div>
  ` : `<p>Aucune quote${search || channel ? ' correspondant aux critères' : ''}.</p>`}

  ${paginationBar}
</section>
`;

  res.send(renderPage('Quotes', body, req));
});

// ─── Commands explorer ─────────────────────────────────────────────────────

app.get(config.baseUrl + '/api/commands', requireLogin, async (req, res) => {
  try {
    const category = req.query.category || null;
    const search   = req.query.q        || null;
    const limit    = Math.min(Number(req.query.limit) || 200, 500);

    const [commands, categories] = await Promise.all([
      getCommands({ category, search, limit }),
      getCommandCategories()
    ]);

    res.json({ ok: true, total: commands.length, commands, categories });
  } catch (err) {
    console.error('[mbweb][/api/commands] error:', err.message);
    res.status(500).json({ ok: false, error: 'Internal server error' });
  }
});

app.get(config.baseUrl + '/commands', requireLogin, async (req, res) => {
  const category = req.query.category || null;
  const search   = req.query.q        || null;

  let commands, categories;

  try {
    [commands, categories] = await Promise.all([
      getCommands({ category, search }),
      getCommandCategories()
    ]);
  } catch (err) {
    console.error('[mbweb][/commands] error:', err.message);
    return res.status(500).send(renderPage('Erreur', `
<section class="mbw-card">
  <h1>Erreur serveur</h1>
  <p>Impossible de charger les commandes.</p>
</section>
`, req));
  }

  const activeCount   = commands.filter(c => Number(c.active || 0) === 1).length;
  const totalHits     = commands.reduce((s, c) => s + Number(c.hits || 0), 0);

  // Search/filter bar
  const filterBar = `
<section class="mbw-card mbw-wide">
  <form method="get" action="${safeBase('/commands')}" class="mbw-filter-bar">
    <input
      type="search"
      name="q"
      placeholder="Rechercher une commande…"
      value="${escapeHtml(search || '')}"
      class="mbw-search-input"
    >
    <select name="category" class="mbw-select">
      <option value="">Toutes les catégories</option>
      ${categories.map(cat => `
        <option value="${escapeHtml(cat.category)}"
          ${category === cat.category ? 'selected' : ''}>
          ${escapeHtml(cat.category)} (${escapeHtml(cat.n)})
        </option>
      `).join('')}
    </select>
    <button type="submit" class="mbw-btn-primary">Filtrer</button>
    ${search || category ? `<a href="${safeBase('/commands')}" class="mbw-btn-secondary">Réinitialiser</a>` : ''}
  </form>
</section>
`;

  const body = `
<section class="mbw-hero">
  <div>
    <p class="mbw-kicker">Bot Mediabot</p>
    <h1>Commandes personnalisées</h1>
    <p>
      Explorateur des commandes IRC définies dans la base Mediabot.
      Lecture seule — modification via la commande IRC <code>!addcmd</code>.
    </p>
    <div class="mbw-actions">
      <a class="mbw-primary" href="${safeBase('/api/commands')}">API JSON</a>
      <a class="mbw-secondary" href="${safeBase('/')}">Accueil</a>
    </div>
  </div>
</section>

<section class="mbw-grid">
  <article class="mbw-card">
    <h2>Total</h2>
    <p class="mbw-big">${escapeHtml(commands.length)}</p>
    <p>commandes dans PUBLIC_COMMANDS.</p>
  </article>

  <article class="mbw-card">
    <h2>Actives</h2>
    <p class="mbw-big">${escapeHtml(activeCount)}</p>
    <p>état active = 1.</p>
  </article>

  <article class="mbw-card">
    <h2>Hits totaux</h2>
    <p class="mbw-big">${escapeHtml(totalHits)}</p>
    <p>nombre d'utilisations cumulées.</p>
  </article>
</section>

${filterBar}

<section class="mbw-card mbw-wide">
  <div class="mbw-section-head">
    <div>
      <h2>${search || category ? 'Résultats filtrés' : 'Toutes les commandes'}</h2>
      <p>Triées par nombre de hits décroissant.</p>
    </div>
    <span class="mbw-count-badge">${escapeHtml(commands.length)} commandes</span>
  </div>

  ${commands.length ? `
    <div class="mbw-table-wrap">
      <table class="mbw-data-table mbw-commands-table">
        <thead>
          <tr>
            <th>Commande</th>
            <th>Action</th>
            <th>Catégorie</th>
            <th>Auteur</th>
            <th>Hits</th>
            <th>Statut</th>
            <th>Créée le</th>
          </tr>
        </thead>
        <tbody>
          ${commands.map(cmd => {
            const isActive = Number(cmd.active || 0) === 1;
            return `
              <tr>
                <td><strong>!${escapeHtml(cmd.command || '')}</strong></td>
                <td class="mbw-muted-cell mbw-cmd-action">${escapeHtml(cmd.action || 'n/a')}</td>
                <td><span class="mbw-role-chip">${escapeHtml(cmd.category || 'n/a')}</span></td>
                <td class="mbw-muted-cell">${escapeHtml(cmd.author_nick || String(cmd.id_user ?? 'n/a'))}</td>
                <td class="mbw-number-cell">${escapeHtml(cmd.hits ?? 0)}</td>
                <td>
                  <span class="mbw-status-pill ${isActive ? 'ok' : 'bad'}">
                    ${isActive ? 'active' : 'hold'}
                  </span>
                </td>
                <td class="mbw-date-cell">${escapeHtml(cmd.creation_date || 'n/a')}</td>
              </tr>
            `;
          }).join('')}
        </tbody>
      </table>
    </div>
  ` : `<p>Aucune commande${search || category ? ' correspondant aux critères' : ' dans la base'}.</p>`}
</section>
`;

  res.send(renderPage('Commandes', body, req));
});

// ─── Users list (Master+) ──────────────────────────────────────────────────

app.get(config.baseUrl + '/api/users', requireLogin, async (req, res) => {
  if (!isMaster(req.session.user)) {
    return res.status(403).json({ ok: false, error: 'Forbidden' });
  }

  try {
    const [users, channelCounts] = await Promise.all([
      getAllUsersWithRoles(),
      getUserChannelCountMap()
    ]);

    res.json({
      ok: true,
      scope: 'global',
      total: users.length,
      users: users.map(u => ({
        ...u,
        channels_count: channelCounts[u.id_user] || 0
      }))
    });
  } catch (err) {
    console.error('[mbweb][/api/users] error:', err.message);
    res.status(500).json({ ok: false, error: 'Internal server error' });
  }
});

app.get(config.baseUrl + '/users', requireLogin, async (req, res) => {
  if (!isMaster(req.session.user)) {
    return res.status(403).send(renderPage('Accès refusé', `
<section class="mbw-card">
  <h1>Accès refusé</h1>
  <p>Cette page est réservée aux Owner et Master Mediabot.</p>
  <a href="${safeBase('/')}">← Retour à l'accueil</a>
</section>
`, req));
  }

  let users, channelCounts;

  try {
    [users, channelCounts] = await Promise.all([
      getAllUsersWithRoles(),
      getUserChannelCountMap()
    ]);
  } catch (err) {
    console.error('[mbweb][/users] error:', err.message);
    return res.status(500).send(renderPage('Erreur', `
<section class="mbw-card">
  <h1>Erreur serveur</h1>
  <p>Impossible de charger la liste des utilisateurs.</p>
</section>
`, req));
  }

  // Role stats for summary bar
  const roleStats = users.reduce((acc, u) => {
    const role = u.global_role || `level ${u.global_level ?? u.id_user_level ?? 'n/a'}`;
    acc[role] = (acc[role] || 0) + 1;
    return acc;
  }, {});

  const authCount  = users.filter(u => Number(u.auth || 0) === 1).length;
  const masterCount = users.filter(u => Number(u.global_level ?? 999) <= 1).length;

  const body = `
<section class="mbw-hero">
  <div>
    <p class="mbw-kicker">Administration lecture seule</p>
    <h1>Utilisateurs</h1>
    <p>
      Vue globale des comptes Mediabot, de leurs niveaux, de leur état
      d'authentification IRC et de leurs rattachements aux canaux.
    </p>
    <div class="mbw-actions">
      <a class="mbw-primary" href="${safeBase('/api/users')}">API JSON</a>
      <a class="mbw-secondary" href="${safeBase('/profile')}">Mon profil</a>
    </div>
  </div>
</section>

<section class="mbw-grid">
  <article class="mbw-card">
    <h2>Total</h2>
    <p class="mbw-big">${escapeHtml(users.length)}</p>
    <p>comptes dans USER.</p>
  </article>

  <article class="mbw-card">
    <h2>Owner / Master</h2>
    <p class="mbw-big">${escapeHtml(masterCount)}</p>
    <p>niveaux globaux élevés.</p>
  </article>

  <article class="mbw-card">
    <h2>Auth active</h2>
    <p class="mbw-big">${escapeHtml(authCount)}</p>
    <p>champ USER.auth = 1.</p>
  </article>
</section>

<section class="mbw-card mbw-wide">
  <div class="mbw-section-head">
    <div>
      <h2>Répartition par rôle</h2>
      <p>Vue synthétique des niveaux globaux Mediabot.</p>
    </div>
  </div>
  <div class="mbw-role-grid">
    ${Object.entries(roleStats).map(([role, n]) => `
      <div class="mbw-role-pill">
        <span>${escapeHtml(role)}</span>
        <strong>${escapeHtml(n)}</strong>
      </div>
    `).join('')}
  </div>
</section>

<section class="mbw-card mbw-wide">
  <div class="mbw-section-head">
    <div>
      <h2>Utilisateurs Mediabot</h2>
      <p>Tableau en lecture seule — comptes, niveaux, auth IRC, canaux et dernier login.</p>
    </div>
    <span class="mbw-count-badge">${escapeHtml(users.length)} users</span>
  </div>

  ${users.length ? `
    <div class="mbw-table-wrap">
      <table class="mbw-data-table mbw-users-table">
        <thead>
          <tr>
            <th>Nickname</th>
            <th>Username</th>
            <th>Rôle</th>
            <th>Auth</th>
            <th>Canaux</th>
            <th>Timezone</th>
            <th>Last login</th>
          </tr>
        </thead>
        <tbody>
          ${users.map(u => {
            const role        = u.global_role || String(u.global_level ?? u.id_user_level ?? 'n/a');
            const authOk      = Number(u.auth || 0) === 1;
            const channelCount = channelCounts[u.id_user] || 0;

            return `
              <tr>
                <td class="mbw-user-main">
                  <strong>${escapeHtml(u.nickname || 'unknown')}</strong>
                  <small>id_user ${escapeHtml(u.id_user ?? 'n/a')}</small>
                </td>
                <td class="mbw-muted-cell">${escapeHtml(u.username || 'n/a')}</td>
                <td><span class="mbw-role-chip">${escapeHtml(role)}</span></td>
                <td>
                  <span class="mbw-status-pill ${authOk ? 'ok' : 'bad'}">
                    ${authOk ? 'yes' : 'no'}
                  </span>
                </td>
                <td class="mbw-number-cell">${escapeHtml(channelCount)}</td>
                <td class="mbw-muted-cell">${escapeHtml(u.tz || 'n/a')}</td>
                <td class="mbw-date-cell">${escapeHtml(u.last_login || 'n/a')}</td>
              </tr>
            `;
          }).join('')}
        </tbody>
      </table>
    </div>
  ` : `<p>Aucun utilisateur trouvé.</p>`}
</section>
`;

  res.send(renderPage('Users', body, req));
});

// ─── Channel detail ────────────────────────────────────────────────────────

app.get(config.baseUrl + '/api/channels/:id', requireLogin, async (req, res) => {
  const idChannel = Number(req.params.id);

  if (!Number.isInteger(idChannel) || idChannel <= 0) {
    return res.status(400).json({ ok: false, error: 'Invalid channel id' });
  }

  try {
    const allowed = await userHasChannelAccess(req.session.user.id_user, idChannel);
    if (!allowed) {
      return res.status(403).json({ ok: false, error: 'Forbidden' });
    }

    const channel = await getChannelById(idChannel);
    if (!channel) {
      return res.status(404).json({ ok: false, error: 'Channel not found' });
    }

    const users = await getChannelUsers(idChannel);
    const relatedTables = await getKnownChannelRelatedTables();

    res.json({ ok: true, channel, users, relatedTables });
  } catch (err) {
    console.error('[mbweb][/api/channels/:id] error:', err.message);
    res.status(500).json({ ok: false, error: 'Internal server error' });
  }
});

app.get(config.baseUrl + '/channels/:id', requireLogin, async (req, res) => {
  const idChannel = Number(req.params.id);

  if (!Number.isInteger(idChannel) || idChannel <= 0) {
    return res.status(400).send(renderPage('Canal invalide', `
<section class="mbw-card">
  <h1>Canal invalide</h1>
  <p>L'identifiant de canal demandé n'est pas valide.</p>
  <a href="${safeBase('/channels')}">← Retour aux canaux</a>
</section>
`, req));
  }

  let channel, users, relatedTables, allowed;

  try {
    allowed = await userHasChannelAccess(req.session.user.id_user, idChannel);
  } catch (err) {
    console.error('[mbweb][/channels/:id] access check error:', err.message);
    return res.status(500).send(renderPage('Erreur', `
<section class="mbw-card">
  <h1>Erreur serveur</h1>
  <p>Impossible de vérifier les droits d'accès.</p>
</section>
`, req));
  }

  if (!allowed) {
    return res.status(403).send(renderPage('Accès refusé', `
<section class="mbw-card">
  <h1>Accès refusé</h1>
  <p>Ton compte Mediabot ne possède pas les droits suffisants pour voir ce canal.</p>
  <a href="${safeBase('/channels')}">← Retour aux canaux</a>
</section>
`, req));
  }

  try {
    [channel, users, relatedTables] = await Promise.all([
      getChannelById(idChannel),
      getChannelUsers(idChannel),
      getKnownChannelRelatedTables()
    ]);
  } catch (err) {
    console.error('[mbweb][/channels/:id] data fetch error:', err.message);
    return res.status(500).send(renderPage('Erreur', `
<section class="mbw-card">
  <h1>Erreur serveur</h1>
  <p>Impossible de charger les données du canal.</p>
</section>
`, req));
  }

  if (!channel) {
    return res.status(404).send(renderPage('Canal introuvable', `
<section class="mbw-card">
  <h1>Canal introuvable</h1>
  <p>Aucun canal Mediabot ne correspond à cet identifiant.</p>
  <a href="${safeBase('/channels')}">← Retour aux canaux</a>
</section>
`, req));
  }

  const chansetSection = relatedTables.length ? `
<section class="mbw-card mbw-wide">
  <h2>Tables liées détectées</h2>
  <p>Chansets, responders, quotes et logs seront branchés dans une prochaine version.</p>
  <div class="mbw-taglist">
    ${relatedTables.map(t => `<span>${escapeHtml(t)}</span>`).join('')}
  </div>
</section>
` : '';

  const body = `
<section class="mbw-hero">
  <div>
    <p class="mbw-kicker">Canal IRC</p>
    <h1>${escapeHtml(channel.name || 'unknown')}</h1>
    <p>
      Vue détaillée du canal depuis la base Mediabot :
      configuration, utilisateurs associés et niveaux par canal.
    </p>
    <div class="mbw-actions">
      <a class="mbw-primary" href="${safeBase('/channels')}">← Retour channels</a>
      <a class="mbw-secondary" href="${safeBase('/api/channels/' + idChannel)}">API JSON</a>
    </div>
  </div>
</section>

<section class="mbw-grid">
  <article class="mbw-card">
    <h2>Canal</h2>
    <p class="mbw-big">${escapeHtml(channel.name || 'n/a')}</p>
    <p>id_channel: ${escapeHtml(channel.id_channel ?? 'n/a')}</p>
  </article>

  <article class="mbw-card">
    <h2>Utilisateurs liés</h2>
    <p class="mbw-big">${escapeHtml(users.length)}</p>
    <p>depuis USER_CHANNEL.</p>
  </article>

  <article class="mbw-card">
    <h2>Auto join</h2>
    <p class="${Number(channel.auto_join || 0) ? 'mbw-ok' : 'mbw-bad'}">
      ${Number(channel.auto_join || 0) ? 'enabled' : 'disabled'}
    </p>
    <p>mode: ${escapeHtml(channel.chanmode || 'n/a')}</p>
  </article>
</section>

<section class="mbw-card mbw-wide">
  <h2>Configuration</h2>
  <div class="mbw-kv">
    <div><span>id_channel</span><strong>${escapeHtml(channel.id_channel ?? 'n/a')}</strong></div>
    <div><span>name</span><strong>${escapeHtml(channel.name ?? 'n/a')}</strong></div>
    <div><span>description</span><strong>${escapeHtml(channel.description ?? 'n/a')}</strong></div>
    <div><span>topic</span><strong>${escapeHtml(channel.topic ?? 'n/a')}</strong></div>
    <div><span>chanmode</span><strong>${escapeHtml(channel.chanmode ?? 'n/a')}</strong></div>
    <div><span>owner id_user</span><strong>${escapeHtml(channel.channel_owner_id ?? 'n/a')}</strong></div>
    <div><span>tmdb_lang</span><strong>${escapeHtml(channel.tmdb_lang ?? 'n/a')}</strong></div>
    <div><span>urltitle</span><strong>${escapeHtml(channel.urltitle ?? 'n/a')}</strong></div>
    <div><span>auto_join</span><strong>${escapeHtml(boolLabel(channel.auto_join))}</strong></div>
  </div>
</section>

<section class="mbw-card mbw-wide">
  <h2>Utilisateurs du canal</h2>
  ${users.length ? `
    <div class="mbw-table-wrap">
      <table class="mbw-data-table mbw-channels-table">
        <thead>
          <tr>
            <th>Nickname</th>
            <th>Rôle global</th>
            <th>Niveau canal</th>
            <th>Automode</th>
            <th>Greet</th>
          </tr>
        </thead>
        <tbody>
          ${users.map(u => `
            <tr>
              <td class="mbw-user-main">
                <strong>${escapeHtml(u.nickname || 'unknown')}</strong>
                <small>${escapeHtml(u.username || '')}</small>
              </td>
              <td><span class="mbw-role-chip">${escapeHtml(u.global_role || String(u.global_level ?? 'n/a'))}</span></td>
              <td>${escapeHtml(u.channel_level ?? 'n/a')}</td>
              <td>${escapeHtml(u.automode ?? 'n/a')}</td>
              <td class="mbw-muted-cell">${escapeHtml(u.greet ?? '')}</td>
            </tr>
          `).join('')}
        </tbody>
      </table>
    </div>
  ` : `<p>Aucun utilisateur lié à ce canal dans USER_CHANNEL.</p>`}
</section>

${chansetSection}
`;

  res.send(renderPage(`Channel — ${channel.name || idChannel}`, body, req));
});

app.use((req, res) => {
  res.status(404).send(renderPage('404', `
<section class="mbw-card">
  <h1>404</h1>
  <p>Route inconnue: ${escapeHtml(req.originalUrl)}</p>
</section>
`, req));
});

// ─── Global error handler (E1) ────────────────────────────────────────────
// Catches any error thrown or passed to next(err) in async route handlers.
// Express 5 automatically forwards async rejections here.
// Must be declared AFTER all routes and BEFORE app.listen().
// eslint-disable-next-line no-unused-vars
app.use((err, req, res, next) => {
  const status  = err.status || err.statusCode || 500;
  const isProd  = process.env.NODE_ENV === 'production';
  const message = isProd ? 'Internal server error' : (err.message || 'Unknown error');

  console.error('[mbweb][error]',
    req.method, req.originalUrl,
    '→', status,
    '|', err.message,
    isProd ? '' : ('\n' + (err.stack || ''))
  );

  // Respond with JSON for API routes, HTML for page routes
  const wantsJson = req.path.startsWith(config.baseUrl + '/api/')
    || req.headers.accept?.includes('application/json');

  if (res.headersSent) return;

  if (wantsJson) {
    return res.status(status).json({ ok: false, error: message });
  }

  res.status(status).send(renderPage(
    status === 404 ? '404' : 'Erreur',
    `
<section class="mbw-card">
  <h1>${status === 404 ? '404 — Page introuvable' : 'Erreur serveur'}</h1>
  <p>${escapeHtml(message)}</p>
  ${!isProd && err.stack ? `<pre class="mbw-error-stack">${escapeHtml(err.stack)}</pre>` : ''}
  <a href="${safeBase('/')}" class="mbw-btn-secondary">← Accueil</a>
</section>
`,
    req
  ));
});

app.listen(config.port, config.host, () => {
  console.log(`[mbweb] listening on http://${config.host}:${config.port}${config.baseUrl || '/'}`);
  console.log(`[mbweb] db=${config.db.user}@${config.db.host}:${config.db.port}/${config.db.database}`);
  console.log('[mbweb] auth=' + JSON.stringify({
    table: config.auth.table,
    loginColumns: config.auth.loginColumns,
    passwordColumns: config.auth.passwordColumns,
    levelColumns: config.auth.levelColumns,
    allowPlaintext: config.auth.allowPlaintext
  }));
});