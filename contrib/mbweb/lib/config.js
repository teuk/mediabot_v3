'use strict';

require('dotenv').config();

const {
  ConfigError,
  buildConfig,
  csv,
  normalizeBaseUrl,
  safeBasePath,
  validateSessionSecret
} = require('./configCore');

const config = buildConfig(process.env);

function safeBase(pathname) {
  return safeBasePath(config.baseUrl, pathname);
}

module.exports = {
  ConfigError,
  buildConfig,
  config,
  normalizeBaseUrl,
  csv,
  safeBase,
  safeBasePath,
  validateSessionSecret
};
