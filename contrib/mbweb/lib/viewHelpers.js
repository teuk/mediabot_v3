'use strict';

function boolLabel(value) {
  if (value === null || typeof value === 'undefined') return 'n/a';
  return Number(value) ? 'yes' : 'no';
}

function fmtUptime(s) {
  if (s === null || s === undefined) return 'n/a';
  const secs = Math.floor(s);
  const d = Math.floor(secs / 86400);
  const h = Math.floor((secs % 86400) / 3600);
  const m = Math.floor((secs % 3600) / 60);
  const parts = [];
  if (d) parts.push(`${d}j`);
  if (h) parts.push(`${h}h`);
  parts.push(`${m}mn`);
  return parts.join(' ');
}

module.exports = { boolLabel, fmtUptime };