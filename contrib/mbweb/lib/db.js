'use strict';

const mysql = require('mysql2/promise');
const { config } = require('./config');

const pool = mysql.createPool(config.db);

function qIdent(identifier) {
  if (!/^[A-Za-z0-9_]+$/.test(identifier)) {
    throw new Error(`Unsafe SQL identifier: ${identifier}`);
  }
  return '`' + identifier + '`';
}

// Column schema cache — avoids a SHOW COLUMNS round-trip on every request.
// TTL: 60 s. Invalidated per table on explicit call to clearColumnCache().
const _columnCache = new Map(); // table → { cols: string[], expiresAt: number }
const COLUMN_CACHE_TTL_MS = 60_000;

async function tableColumns(table) {
  const now = Date.now();
  const cached = _columnCache.get(table);
  if (cached && cached.expiresAt > now) return cached.cols;

  const [rows] = await pool.query(`SHOW COLUMNS FROM ${qIdent(table)}`);
  const cols = rows.map(r => r.Field);
  _columnCache.set(table, { cols, expiresAt: now + COLUMN_CACHE_TTL_MS });
  return cols;
}

function clearColumnCache(table) {
  if (table) {
    _columnCache.delete(table);
  } else {
    _columnCache.clear();
  }
}

async function ping() {
  const [rows] = await pool.query('SELECT DATABASE() AS db');
  return rows[0] || null;
}

module.exports = {
  pool,
  qIdent,
  tableColumns,
  clearColumnCache,
  ping
};
