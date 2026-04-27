'use strict';

const crypto = require('crypto'); // built-in, no install needed
const bcrypt = require('bcryptjs');
const { config } = require('./config');
const { pool, qIdent, tableColumns } = require('./db');

// Constant-time string comparison to prevent timing attacks.
// Pads both sides to the same length before calling timingSafeEqual
// so length differences don't leak information either.
function timingSafeStringEqual(a, b) {
  const ba = Buffer.from(String(a));
  const bb = Buffer.from(String(b));
  // Always allocate and compare buffers of the same length
  const len  = Math.max(ba.length, bb.length);
  const pa   = Buffer.alloc(len);
  const pb   = Buffer.alloc(len);
  ba.copy(pa);
  bb.copy(pb);
  // timingSafeEqual throws if lengths differ — they won't, we just allocated them equal
  return crypto.timingSafeEqual(pa, pb) && ba.length === bb.length;
}

function firstExisting(candidates, existing) {
  return candidates.find(c => existing.includes(c)) || null;
}

function logAuth(message, data = {}) {
  console.log('[mbweb][auth]', message, JSON.stringify(data));
}

async function findUser(login) {
  const columns = await tableColumns(config.auth.table);

  const usableLoginCols = config.auth.loginColumns.filter(c => columns.includes(c));
  const passwordCol = firstExisting(config.auth.passwordColumns, columns);
  const levelCol = firstExisting(config.auth.levelColumns, columns);

  logAuth('column detection', {
    table: config.auth.table,
    usableLoginCols,
    passwordCol,
    levelCol
  });

  if (!usableLoginCols.length) {
    throw new Error(`No login column found. Tried: ${config.auth.loginColumns.join(', ')}`);
  }

  if (!passwordCol) {
    throw new Error(`No password column found. Tried: ${config.auth.passwordColumns.join(', ')}`);
  }

  const selectCols = [
    'id_user',
    ...usableLoginCols,
    passwordCol,
    levelCol,
    'auth',
    'last_login',
    'creation_date'
  ].filter(Boolean);

  const uniqueSelectCols = [...new Set(selectCols)].filter(c => columns.includes(c));
  const where = usableLoginCols.map(c => `${qIdent(c)} = ?`).join(' OR ');
  const sql = `
    SELECT ${uniqueSelectCols.map(qIdent).join(', ')}
    FROM ${qIdent(config.auth.table)}
    WHERE ${where}
    LIMIT 1
  `;

  const params = usableLoginCols.map(() => login);
  const [rows] = await pool.execute(sql, params);

  return {
    user: rows[0] || null,
    passwordCol,
    levelCol,
    usableLoginCols
  };
}

async function passwordMatches(inputPassword, storedPassword) {
  if (storedPassword === null || typeof storedPassword === 'undefined') {
    return { ok: false, method: 'missing' };
  }

  const stored = String(storedPassword);
  const input = String(inputPassword || '');

  if (config.auth.allowPlaintext) {
    // B1 — use constant-time comparison to prevent timing attacks on plaintext passwords.
    // Only return here if the stored value looks like actual plaintext (not a hash).
    // Hashed passwords (bcrypt $2a$… or MySQL *XXXX…) fall through to their own branch.
    const looksLikePlaintext = (
      !/^\$2[aby]\$/.test(stored) &&        // not bcrypt
      !/^\*[0-9A-F]{40}$/i.test(stored)     // not MySQL PASSWORD()
    );
    if (looksLikePlaintext) {
      return {
        ok: timingSafeStringEqual(stored, input),
        method: 'plaintext-exact'
      };
    }
  }

  // B5 — removed: plaintext-trimmed was accepting passwords with stray
  // whitespace, producing false positives (e.g. "secret " matching "secret").

  if (/^\$2[aby]\$/.test(stored)) {
    const ok = await bcrypt.compare(input, stored);
    return { ok, method: 'bcrypt' };
  }

  if (/^\*[0-9A-F]{40}$/i.test(stored)) {
    const [rows] = await pool.execute('SELECT PASSWORD(?) AS hash', [input]);
    const mysqlHash = rows && rows[0] ? String(rows[0].hash || '') : '';
    // B1 — constant-time comparison for MySQL PASSWORD() hash
    return {
      ok: timingSafeStringEqual(mysqlHash.toUpperCase(), stored.toUpperCase()),
      method: 'mysql-password'
    };
  }

  return { ok: false, method: 'no-matching-method' };
}

async function authenticate(login, password) {
  const result = await findUser(login);
  const user = result.user;

  if (!user) {
    return { ok: false, reason: 'user-not-found' };
  }

  const check = await passwordMatches(password, user[result.passwordCol]);

  if (!check.ok) {
    return {
      ok: false,
      reason: 'password-refused',
      method: check.method,
      user
    };
  }

  return {
    ok: true,
    method: check.method,
    user,
    passwordCol: result.passwordCol,
    levelCol: result.levelCol
  };
}

module.exports = {
  authenticate,
  findUser,
  passwordMatches,
  logAuth
};
