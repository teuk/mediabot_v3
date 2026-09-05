'use strict';

const express = require('express');
const http = require('http');
const path = require('path');
const session = require('express-session');
const helmet = require('helmet');

const { config, safeBase } = require('./lib/config');
const { pool } = require('./lib/db');
const { escapeHtml, renderPage } = require('./lib/render');
const { createHttpBoundaries } = require('./lib/httpBoundary');
const { installGracefulShutdown, listenHttpServer } = require('./lib/serverLifecycle');
const { createCsrfProtection } = require('./lib/csrf');
const { createMySqlSessionStore } = require('./lib/mysqlSessionStore');
const { sessionOptions } = require('./lib/sessionPolicy');
const { logError } = require('./lib/securityLog');

// ── Route files ───────────────────────────────────────────────────────────────
const apiRoutes = require('./routes/api');
const authRoutes = require('./routes/auth');
const homeRoutes = require('./routes/home');
const profileRoutes = require('./routes/profile');
const channelsRoutes = require('./routes/channels');
const radioRoutes = require('./routes/radio');
const networkRoutes = require('./routes/network');
const quotesRoutes = require('./routes/quotes');
const commandsRoutes = require('./routes/commands');
const usersRoutes = require('./routes/users');
const metricsRoutes = require('./routes/metricsProxy');
const partylineRoutes = require('./routes/partyline');
const diagnosticsRoutes = require('./routes/diagnostics');

function createApp(options = {}) {
  const runtimeConfig = options.config || config;
  const sessionImpl = options.sessionImpl || session;
  const poolImpl = options.pool || pool;
  const app = express();

  app.use(helmet({
    contentSecurityPolicy: {
      useDefaults: true,
      directives: {
        'default-src': ["'self'"],
        'style-src': ["'self'"],
        'script-src': ["'self'"],
        'img-src': ["'self'", 'data:'],
        'connect-src': ["'self'"],
        'object-src': ["'none'"],
        'base-uri': ["'self'"],
        'frame-ancestors': ["'self'"]
      }
    },
    crossOriginEmbedderPolicy: false
  }));

  app.set('trust proxy', 'loopback');

  app.use(express.urlencoded({ extended: false, limit: '32kb', parameterLimit: 64 }));
  app.use(express.json({ limit: '32kb' }));

  const sessionStore = runtimeConfig.session.store === 'mysql'
    ? createMySqlSessionStore({
        Store: sessionImpl.Store,
        pool: poolImpl,
        table: runtimeConfig.session.table,
        ttlMs: runtimeConfig.session.maxAgeMs,
        cleanupIntervalMs: runtimeConfig.session.cleanupIntervalMs
      })
    : null;

  app.locals.mbwebSessionStore = sessionStore;
  app.use(sessionImpl(sessionOptions(runtimeConfig, sessionStore)));
  app.use(createCsrfProtection());

  app.use(runtimeConfig.baseUrl + '/css', express.static(path.join(__dirname, 'public', 'css')));
  app.use(runtimeConfig.baseUrl + '/public', express.static(path.join(__dirname, 'public')));

  // ── Mount routers ───────────────────────────────────────────────────────────
  app.use(runtimeConfig.baseUrl, apiRoutes);
  app.use(runtimeConfig.baseUrl, authRoutes);
  app.use(runtimeConfig.baseUrl, homeRoutes);
  app.use(runtimeConfig.baseUrl, profileRoutes);
  app.use(runtimeConfig.baseUrl, channelsRoutes);
  app.use(runtimeConfig.baseUrl, radioRoutes);
  app.use(runtimeConfig.baseUrl, networkRoutes);
  app.use(runtimeConfig.baseUrl, quotesRoutes);
  app.use(runtimeConfig.baseUrl, commandsRoutes);
  app.use(runtimeConfig.baseUrl, usersRoutes);
  app.use(runtimeConfig.baseUrl, metricsRoutes);
  app.use(runtimeConfig.baseUrl, partylineRoutes);
  app.use(runtimeConfig.baseUrl, diagnosticsRoutes);

  const boundaries = createHttpBoundaries({
    baseUrl: runtimeConfig.baseUrl,
    escapeHtml,
    renderPage,
    safeBase
  });

  // Express 5 forwards asynchronous route failures to the final error boundary.
  app.use(boundaries.notFound);
  app.use(boundaries.error);

  return app;
}

async function startApplication(options = {}) {
  const runtimeConfig = options.config || config;
  const poolImpl = options.pool || pool;
  const app = options.app || createApp({
    config: runtimeConfig,
    pool: poolImpl,
    sessionImpl: options.sessionImpl
  });
  const server = options.server || http.createServer(app);
  const logger = options.logger || console;
  const sessionStore = app.locals?.mbwebSessionStore || null;

  try {
    if (sessionStore?.assertReady) await sessionStore.assertReady();
    await listenHttpServer(server, {
      port: runtimeConfig.port,
      host: runtimeConfig.host
    });
  } catch (err) {
    for (const closeable of [sessionStore, poolImpl]) {
      if (!closeable || typeof closeable.end !== 'function') continue;
      try {
        await closeable.end();
      } catch (closeErr) {
        logError(logger, 'startup.resource', closeErr);
      }
    }
    throw err;
  }

  logger.log(
    `[mbweb] listening on http://${runtimeConfig.host}:${runtimeConfig.port}`
    + `${runtimeConfig.baseUrl || '/'}`
  );
  logger.log(`[mbweb] session store=${runtimeConfig.session.store}`);
  logger.log('[mbweb] database and authentication adapters configured');

  const shutdown = installGracefulShutdown({
    server,
    closeables: [sessionStore, poolImpl].filter(Boolean),
    logger,
    timeoutMs: 5000
  });

  return { app, server, shutdown };
}

if (require.main === module) {
  startApplication().catch(err => {
    logError(console, 'startup', err);
    process.exitCode = 1;
  });
}

module.exports = {
  createApp,
  startApplication
};
