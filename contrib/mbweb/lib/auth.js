'use strict';

const bcrypt = require('bcryptjs');
const { config } = require('./config');
const { pool, qIdent, tableColumns } = require('./db');
const { verifyPassword } = require('./authCore');

function firstExisting(candidates, existing) {
  return candidates.find(c => existing.includes(c)) || null;
}

function logAuth(message, data = {}) {
  const event = String(message || 'event')
    .replace(/[^A-Za-z0-9 ._-]/g, '')
    .slice(0, 64);
  const flags = Object.fromEntries(
    Object.entries(data)
      .filter(([key, value]) => /(?:Provided|ok)$/.test(key) && typeof value === 'boolean')
  );
  console.log('[mbweb][auth]', event, JSON.stringify(flags));
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
  return verifyPassword(inputPassword, storedPassword, {
    allowPlaintext: config.auth.allowPlaintext,
    bcryptCompare: (input, stored) => bcrypt.compare(input, stored),
    mysqlPassword: async input => {
      const [rows] = await pool.execute('SELECT PASSWORD(?) AS hash', [input]);
      return rows && rows[0] ? String(rows[0].hash || '') : '';
    }
  });
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
      method: check.method
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
