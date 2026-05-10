'use strict';

function parsePositiveInt(value, fallback, { min = 1, max = 1000 } = {}) {
  const raw = Array.isArray(value) ? value[0] : value;
  const n = Number(raw);

  if (!Number.isFinite(n) || !Number.isInteger(n)) {
    return fallback;
  }

  return Math.min(Math.max(n, min), max);
}


function parseRouteId(value) {
  const raw = Array.isArray(value) ? value[0] : value;
  const str = String(raw || '').trim();

  if (!/^[1-9][0-9]{0,9}$/.test(str)) {
    return null;
  }

  const n = Number(str);
  return Number.isSafeInteger(n) ? n : null;
}

function cleanSearch(value, { maxLength = 120 } = {}) {
  const raw = Array.isArray(value) ? value[0] : value;
  const out = String(raw || '').trim().replace(/\s+/g, ' ');

  if (!out) return null;

  return out.slice(0, maxLength);
}

module.exports = {
  parseRouteId,
  parsePositiveInt,
  cleanSearch
};
