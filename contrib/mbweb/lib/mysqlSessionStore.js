'use strict';

const { qIdent } = require('./sql');
const { logError } = require('./securityLog');

const DEFAULT_MAX_DATA_BYTES = 64 * 1024;
const DEFAULT_CLEANUP_BATCH_SIZE = 1000;
const RETRYABLE_CODES = new Set([
  'ECONNRESET',
  'EPIPE',
  'ETIMEDOUT',
  'PROTOCOL_CONNECTION_LOST'
]);

function sessionId(value) {
  const sid = String(value || '');
  if (!/^[A-Za-z0-9_-]{16,128}$/.test(sid)) {
    const err = new Error('Invalid session identifier.');
    err.code = 'SESSION_ID_INVALID';
    throw err;
  }
  return sid;
}

function expiryMs(sess, now, defaultTtlMs) {
  const candidate = new Date(sess?.cookie?.expires || 0).getTime();
  const maximum = now + defaultTtlMs;
  if (Number.isFinite(candidate) && candidate > now) return Math.min(candidate, maximum);
  return maximum;
}

function serializeSession(sess, maxBytes = DEFAULT_MAX_DATA_BYTES) {
  const data = JSON.stringify(sess);
  if (!data || Buffer.byteLength(data, 'utf8') > maxBytes) {
    const err = new Error('Session payload exceeds the configured bound.');
    err.code = 'SESSION_DATA_INVALID';
    throw err;
  }
  return data;
}

function parseSession(data, maxBytes = DEFAULT_MAX_DATA_BYTES) {
  if (typeof data !== 'string' || Buffer.byteLength(data, 'utf8') > maxBytes) {
    const err = new Error('Stored session payload is invalid.');
    err.code = 'SESSION_DATA_INVALID';
    throw err;
  }
  const value = JSON.parse(data);
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    const err = new Error('Stored session payload is not an object.');
    err.code = 'SESSION_DATA_INVALID';
    throw err;
  }
  return value;
}

function createMySqlSessionStore(options = {}) {
  const Store = options.Store;
  const pool = options.pool;
  if (typeof Store !== 'function' || !pool || typeof pool.execute !== 'function') {
    throw new TypeError('express-session Store and a MariaDB pool are required.');
  }

  const table = qIdent(options.table || 'MBWEB_SESSION');
  const ttlMs = Number(options.ttlMs) || 8 * 60 * 60 * 1000;
  const cleanupIntervalMs = Number(options.cleanupIntervalMs) || 5 * 60 * 1000;
  const maxDataBytes = Number(options.maxDataBytes) || DEFAULT_MAX_DATA_BYTES;
  const cleanupBatchSize = Math.min(
    10_000,
    Math.max(1, Math.trunc(Number(options.cleanupBatchSize) || DEFAULT_CLEANUP_BATCH_SIZE))
  );
  const now = options.now || Date.now;
  const logger = options.logger || console;
  const setIntervalImpl = options.setIntervalImpl || setInterval;
  const clearIntervalImpl = options.clearIntervalImpl || clearInterval;

  return new class MySqlSessionStore extends Store {
    constructor() {
      super();
      this.closed = false;
      this.cleanupTimer = setIntervalImpl(() => {
        this.cleanup().catch(err => logError(logger, 'session.cleanup', err));
      }, cleanupIntervalMs);
      this.cleanupTimer.unref?.();
    }

    async execute(sql, params) {
      let attempt = 0;
      while (true) {
        try {
          return await pool.execute(sql, params);
        } catch (err) {
          if (attempt >= 1 || !RETRYABLE_CODES.has(String(err?.code || ''))) throw err;
          attempt += 1;
        }
      }
    }

    callback(operation, cb) {
      Promise.resolve().then(operation).then(
        value => cb?.(null, value),
        err => cb?.(err)
      );
    }

    get(sid, cb) {
      this.callback(async () => {
        const id = sessionId(sid);
        const [rows] = await this.execute(
          `SELECT session_data, expires_at FROM ${table} WHERE session_id = ? LIMIT 1`,
          [id]
        );
        if (!Array.isArray(rows)) {
          const err = new Error('Malformed session-store result.');
          err.code = 'SESSION_STORE_MALFORMED';
          throw err;
        }
        if (!rows.length) return null;
        const expires = new Date(rows[0].expires_at).getTime();
        if (!Number.isFinite(expires) || expires <= now()) {
          await this.execute(`DELETE FROM ${table} WHERE session_id = ?`, [id]);
          return null;
        }
        return parseSession(rows[0].session_data, maxDataBytes);
      }, cb);
    }

    set(sid, sess, cb) {
      this.callback(async () => {
        const id = sessionId(sid);
        const current = now();
        const expires = new Date(expiryMs(sess, current, ttlMs));
        const data = serializeSession(sess, maxDataBytes);
        await this.execute(
          `INSERT INTO ${table} (session_id, expires_at, session_data) VALUES (?, ?, ?)
           ON DUPLICATE KEY UPDATE expires_at = VALUES(expires_at), session_data = VALUES(session_data)`,
          [id, expires, data]
        );
      }, cb);
    }

    touch(sid, sess, cb) {
      this.callback(async () => {
        const id = sessionId(sid);
        const expires = new Date(expiryMs(sess, now(), ttlMs));
        await this.execute(
          `UPDATE ${table} SET expires_at = ? WHERE session_id = ?`,
          [expires, id]
        );
      }, cb);
    }

    destroy(sid, cb) {
      this.callback(async () => {
        await this.execute(`DELETE FROM ${table} WHERE session_id = ?`, [sessionId(sid)]);
      }, cb);
    }

    async cleanup() {
      if (this.closed) return 0;
      const [result] = await this.execute(
        `DELETE FROM ${table} WHERE expires_at <= CURRENT_TIMESTAMP(3) LIMIT ${cleanupBatchSize}`,
        []
      );
      return Number(result?.affectedRows) || 0;
    }

    async assertReady() {
      await this.execute(`SELECT session_id FROM ${table} LIMIT 0`, []);
      return true;
    }

    async end() {
      if (this.closed) return;
      this.closed = true;
      clearIntervalImpl(this.cleanupTimer);
    }
  }();
}

module.exports = {
  DEFAULT_CLEANUP_BATCH_SIZE,
  DEFAULT_MAX_DATA_BYTES,
  RETRYABLE_CODES,
  createMySqlSessionStore,
  expiryMs,
  parseSession,
  serializeSession,
  sessionId
};
