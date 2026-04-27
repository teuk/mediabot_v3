'use strict';

require('dotenv').config();

function normalizeBaseUrl(value) {
  if (!value || value === '/') return '';
  let out = String(value).trim();
  if (!out.startsWith('/')) out = '/' + out;
  return out.replace(/\/+$/, '');
}

function csv(value) {
  return String(value || '')
    .split(',')
    .map(v => v.trim())
    .filter(Boolean);
}

const config = {
  host: process.env.MBWEB_HOST || '127.0.0.1',
  port: parseInt(process.env.MBWEB_PORT || '4002', 10),
  baseUrl: normalizeBaseUrl(process.env.MBWEB_BASE_URL || ''),

  db: {
    host: process.env.MBWEB_DB_HOST || 'localhost',
    port: parseInt(process.env.MBWEB_DB_PORT || '3306', 10),
    user: process.env.MBWEB_DB_USER || 'mediabotv3',
    password: process.env.MBWEB_DB_PASS || '',
    database: process.env.MBWEB_DB_NAME || 'mediabotv3',
    charset: 'utf8mb4',
    waitForConnections: true,
    connectionLimit: 5,
    queueLimit: 0
  },

  auth: {
    table: process.env.MBWEB_AUTH_TABLE || 'USER',
    loginColumns: csv(process.env.MBWEB_AUTH_LOGIN_COLUMNS || 'nickname,username'),
    passwordColumns: csv(process.env.MBWEB_AUTH_PASSWORD_COLUMNS || 'password'),
    levelColumns: csv(process.env.MBWEB_AUTH_LEVEL_COLUMNS || 'id_user_level'),
    allowPlaintext: String(process.env.MBWEB_ALLOW_PLAINTEXT_PASSWORDS || '0') === '1'
  },

  urls: {
    metrics: process.env.MBWEB_METRICS_URL || 'http://127.0.0.1:9108/metrics',
    radioStatus: process.env.MBWEB_RADIO_STATUS_URL || 'http://127.0.0.1:8000/status-json.xsl',
    radioPublicBase: process.env.MBWEB_RADIO_PUBLIC_BASE_URL || 'http://teuk.org:8000',
    radioPrimaryMount: process.env.MBWEB_RADIO_PRIMARY_MOUNT || '/radio160.mp3'
  },

  partyline: {
    host: process.env.MBWEB_PARTYLINE_HOST || '127.0.0.1',
    port: parseInt(process.env.MBWEB_PARTYLINE_PORT || '23456', 10)
  },

  sessionSecret: process.env.MBWEB_SESSION_SECRET || 'CHANGE_ME'
};

function safeBase(pathname) {
  if (!pathname.startsWith('/')) pathname = '/' + pathname;
  return config.baseUrl + pathname;
}

// B1 — fail-fast: refuse to start with a weak or default session secret
if (!config.sessionSecret || config.sessionSecret === 'CHANGE_ME' || config.sessionSecret.length < 32) {
  console.error('[mbweb][config] FATAL: MBWEB_SESSION_SECRET is missing, default, or shorter than 32 characters.');
  console.error('[mbweb][config] Set a strong secret in your .env file and restart.');
  process.exit(1);
}

module.exports = {
  config,
  normalizeBaseUrl,
  csv,
  safeBase
};
