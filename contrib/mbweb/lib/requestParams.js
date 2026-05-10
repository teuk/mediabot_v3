'use strict';

function parsePositiveInt(value, fallback, { min = 1, max = 1000 } = {}) {
  const raw = Array.isArray(value) ? value[0] : value;
  const n = Number(raw);

  if (!Number.isFinite(n) || !Number.isInteger(n)) {
    return fallback;
  }

  return Math.min(Math.max(n, min), max);
}

function cleanSearch(value, { maxLength = 120 } = {}) {
  const raw = Array.isArray(value) ? value[0] : value;
  const out = String(raw || '').trim().replace(/\s+/g, ' ');

  if (!out) return null;

  return out.slice(0, maxLength);
}

module.exports = {
  parsePositiveInt,
  cleanSearch
};
