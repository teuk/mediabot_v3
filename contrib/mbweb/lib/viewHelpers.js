'use strict';

function boolLabel(value) {
  if (value === null || typeof value === 'undefined') return 'n/a';
  return Number(value) ? 'yes' : 'no';
}

function yesNo(value) {
  return Number(value || 0) ? 'yes' : 'no';
}

function isEnabled(value) {
  return Number(value || 0) === 1;
}

module.exports = {
  boolLabel,
  yesNo,
  isEnabled
};
