'use strict';

class ConfigError extends Error {
  constructor(message) {
    super(message);
    this.name = 'ConfigError';
  }
}

function normalizeBaseUrl(value) {
  const raw = String(value || '').trim();
  if (!raw || raw === '/') return '';

  if (/[\r\n\t?#]/.test(raw) || raw.startsWith('//')) {
    throw new ConfigError('MBWEB_BASE_URL must be a local URL path without query or fragment data.');
  }

  const prefixed = raw.startsWith('/') ? raw : `/${raw}`;
  const normalized = prefixed.replace(/\/{2,}/g, '/').replace(/\/+$/, '');

  if (normalized.split('/').some(part => part === '.' || part === '..')) {
    throw new ConfigError('MBWEB_BASE_URL must not contain dot path segments.');
  }

  return normalized;
}

function envInt(env, name, fallback, { min = 1, max = 65535 } = {}) {
  const raw = env[name];
  if (raw === undefined || raw === '') return fallback;

  if (!/^[0-9]+$/.test(String(raw))) {
    throw new ConfigError(`${name} must be an integer, got: ${raw}`);
  }

  const n = Number(raw);
  if (!Number.isSafeInteger(n) || n < min || n > max) {
    throw new ConfigError(`${name} must be between ${min} and ${max}, got: ${raw}`);
  }

  return n;
}

function csv(value) {
  return String(value || '')
    .split(',')
    .map(v => v.trim())
    .filter(Boolean);
}

function validateSessionSecret(secret) {
  const value = String(secret || '');
  if (!value || value === 'CHANGE_ME' || value.length < 32) {
    throw new ConfigError(
      'MBWEB_SESSION_SECRET is missing, default, or shorter than 32 characters.'
    );
  }
  return value;
}

function sessionStoreName(env, nodeEnv) {
  const raw = String(env.MBWEB_SESSION_STORE || '').trim().toLowerCase();
  const value = raw || (nodeEnv === 'production' ? '' : 'memory');

  if (nodeEnv === 'production' && value !== 'mysql') {
    throw new ConfigError(
      'Production requires MBWEB_SESSION_STORE=mysql; MemoryStore is forbidden.'
    );
  }
  if (!['memory', 'mysql'].includes(value)) {
    throw new ConfigError('MBWEB_SESSION_STORE must be either memory or mysql.');
  }
  return value;
}

function validateSqlIdentifier(value, name) {
  const identifier = String(value || '');
  if (!/^[A-Za-z0-9_]+$/.test(identifier)) {
    throw new ConfigError(`${name} must contain only ASCII letters, digits and underscores.`);
  }
  return identifier;
}

function buildConfig(env = process.env) {
  const nodeEnv = String(env.NODE_ENV || 'development').trim().toLowerCase();
  const host = env.MBWEB_HOST || '127.0.0.1';
  const store = sessionStoreName(env, nodeEnv);

  if (nodeEnv === 'production' && !['127.0.0.1', '::1'].includes(host)) {
    throw new ConfigError('Production MBWEB_HOST must be an explicit loopback address.');
  }

  return {
    nodeEnv,
    host,
    port: envInt(env, 'MBWEB_PORT', 4002, { min: 1, max: 65535 }),
    baseUrl: normalizeBaseUrl(env.MBWEB_BASE_URL || ''),

    db: {
      host: env.MBWEB_DB_HOST || 'localhost',
      port: envInt(env, 'MBWEB_DB_PORT', 3306, { min: 1, max: 65535 }),
      user: env.MBWEB_DB_USER || 'mediabotv3',
      password: env.MBWEB_DB_PASS || '',
      database: env.MBWEB_DB_NAME || 'mediabotv3',
      charset: 'utf8mb4',
      waitForConnections: true,
      connectionLimit: 5,
      queueLimit: 0
    },

    auth: {
      table: env.MBWEB_AUTH_TABLE || 'USER',
      loginColumns: csv(env.MBWEB_AUTH_LOGIN_COLUMNS || 'nickname,username'),
      passwordColumns: csv(env.MBWEB_AUTH_PASSWORD_COLUMNS || 'password'),
      levelColumns: csv(env.MBWEB_AUTH_LEVEL_COLUMNS || 'id_user_level'),
      allowPlaintext: String(env.MBWEB_ALLOW_PLAINTEXT_PASSWORDS || '0') === '1'
    },

    urls: {
      metrics: env.MBWEB_METRICS_URL || 'http://127.0.0.1:9108/metrics',
      radioStatus: env.MBWEB_RADIO_STATUS_URL || 'http://127.0.0.1:8000/status-json.xsl',
      radioPublicBase: env.MBWEB_RADIO_PUBLIC_BASE_URL || 'http://example.org:8000',
      radioPrimaryMount: env.MBWEB_RADIO_PRIMARY_MOUNT || '/radio160.mp3'
    },

    partyline: {
      host: env.MBWEB_PARTYLINE_HOST || '127.0.0.1',
      port: envInt(env, 'MBWEB_PARTYLINE_PORT', 23456, { min: 1, max: 65535 })
    },

    sessionSecret: validateSessionSecret(env.MBWEB_SESSION_SECRET || 'CHANGE_ME'),

    session: {
      store,
      table: validateSqlIdentifier(
        env.MBWEB_SESSION_TABLE || 'MBWEB_SESSION',
        'MBWEB_SESSION_TABLE'
      ),
      maxAgeMs: envInt(env, 'MBWEB_SESSION_MAX_AGE_MS', 8 * 60 * 60 * 1000, {
        min: 5 * 60 * 1000,
        max: 7 * 24 * 60 * 60 * 1000
      }),
      cleanupIntervalMs: envInt(
        env,
        'MBWEB_SESSION_CLEANUP_INTERVAL_MS',
        5 * 60 * 1000,
        { min: 30 * 1000, max: 60 * 60 * 1000 }
      )
    }
  };
}

function safeBasePath(baseUrl, pathname) {
  const path = String(pathname || '/');
  const normalized = path.startsWith('/') ? path : `/${path}`;
  return normalizeBaseUrl(baseUrl) + normalized;
}

module.exports = {
  ConfigError,
  buildConfig,
  csv,
  envInt,
  normalizeBaseUrl,
  safeBasePath,
  sessionStoreName,
  validateSqlIdentifier,
  validateSessionSecret
};
