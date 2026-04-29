'use strict';

const express = require('express');
const path    = require('path');
const session = require('express-session');
const helmet  = require('helmet');

const { config, safeBase }  = require('./lib/config');
const { escapeHtml, renderPage } = require('./lib/render');

// ── Route files ───────────────────────────────────────────────────────────────
const apiRoutes      = require('./routes/api');
const authRoutes     = require('./routes/auth');
const homeRoutes     = require('./routes/home');
const profileRoutes  = require('./routes/profile');
const channelsRoutes = require('./routes/channels');
const radioRoutes    = require('./routes/radio');
const networkRoutes  = require('./routes/network');
const quotesRoutes   = require('./routes/quotes');
const commandsRoutes = require('./routes/commands');
const usersRoutes    = require('./routes/users');
const metricsRoutes  = require('./routes/metricsProxy');

const app = express();

app.use(helmet({
  contentSecurityPolicy: {
    useDefaults: true,
    directives: {
      'default-src': ["'self'"],
      'style-src':   ["'self'"],
      'script-src':  ["'self'"],
      'img-src':     ["'self'", 'data:'],
      'connect-src': ["'self'"],
      'object-src':  ["'none'"],
      'base-uri':    ["'self'"],
      'frame-ancestors': ["'self'"]
    }
  },
  crossOriginEmbedderPolicy: false
}));

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
    secure: process.env.NODE_ENV === 'production'
  }
}));

app.use(config.baseUrl + '/css',    express.static(path.join(__dirname, 'public', 'css')));
app.use(config.baseUrl + '/public', express.static(path.join(__dirname, 'public')));

// ── Mount routers ─────────────────────────────────────────────────────────────
app.use(config.baseUrl, apiRoutes);
app.use(config.baseUrl, authRoutes);
app.use(config.baseUrl, homeRoutes);
app.use(config.baseUrl, profileRoutes);
app.use(config.baseUrl, channelsRoutes);
app.use(config.baseUrl, radioRoutes);
app.use(config.baseUrl, networkRoutes);
app.use(config.baseUrl, quotesRoutes);
app.use(config.baseUrl, commandsRoutes);
app.use(config.baseUrl, usersRoutes);
app.use(config.baseUrl, metricsRoutes);

// ── 404 handler ───────────────────────────────────────────────────────────────
app.use((req, res) => {
  res.status(404).send(renderPage('404', `
<section class="mbw-card">
  <h1>404</h1>
  <p>Unknown route: ${escapeHtml(req.originalUrl)}</p>
</section>
`, req));
});

// ── Global error handler ──────────────────────────────────────────────────────
// Must be declared AFTER all routes. Express 5 forwards async rejections here.
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

  const wantsJson = req.path.startsWith(config.baseUrl + '/api/')
    || req.headers.accept?.includes('application/json');

  if (res.headersSent) return;

  if (wantsJson) {
    return res.status(status).json({ ok: false, error: message });
  }

  res.status(status).send(renderPage(
    status === 404 ? '404' : 'Error',
    `
<section class="mbw-card">
  <h1>${status === 404 ? '404 — Page not found' : 'Server error'}</h1>
  <p>${escapeHtml(message)}</p>
  ${!isProd && err.stack ? `<pre class="mbw-error-stack">${escapeHtml(err.stack)}</pre>` : ''}
  <a href="${safeBase('/')}" class="mbw-btn-secondary">← Home</a>
</section>
`,
    req
  ));
});

app.listen(config.port, config.host, () => {
  console.log(`[mbweb] listening on http://${config.host}:${config.port}${config.baseUrl || '/'}`);
  console.log(`[mbweb] db=${config.db.user}@${config.db.host}:${config.db.port}/${config.db.database}`);
  console.log('[mbweb] auth=' + JSON.stringify({
    table:          config.auth.table,
    loginColumns:   config.auth.loginColumns,
    passwordColumns: config.auth.passwordColumns,
    levelColumns:   config.auth.levelColumns,
    allowPlaintext: config.auth.allowPlaintext
  }));
});
