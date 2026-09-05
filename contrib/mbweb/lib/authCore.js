'use strict';

const crypto = require('crypto');

function timingSafeStringEqual(a, b) {
  const ba = Buffer.from(String(a));
  const bb = Buffer.from(String(b));
  const len = Math.max(ba.length, bb.length);
  const pa = Buffer.alloc(len);
  const pb = Buffer.alloc(len);
  ba.copy(pa);
  bb.copy(pb);
  return crypto.timingSafeEqual(pa, pb) && ba.length === bb.length;
}

async function verifyPassword(inputPassword, storedPassword, options = {}) {
  if (storedPassword === null || typeof storedPassword === 'undefined') {
    return { ok: false, method: 'missing' };
  }

  const stored = String(storedPassword);
  const input = String(inputPassword || '');

  if (options.allowPlaintext) {
    const looksLikePlaintext = (
      !/^\$2[aby]\$/.test(stored)
      && !/^\*[0-9A-F]{40}$/i.test(stored)
    );
    if (looksLikePlaintext) {
      return {
        ok: timingSafeStringEqual(stored, input),
        method: 'plaintext-exact'
      };
    }
  }

  if (/^\$2[aby]\$/.test(stored)) {
    if (typeof options.bcryptCompare !== 'function') {
      return { ok: false, method: 'bcrypt-unavailable' };
    }
    return {
      ok: Boolean(await options.bcryptCompare(input, stored)),
      method: 'bcrypt'
    };
  }

  if (/^\*[0-9A-F]{40}$/i.test(stored)) {
    if (typeof options.mysqlPassword !== 'function') {
      return { ok: false, method: 'mysql-password-unavailable' };
    }
    const mysqlHash = String(await options.mysqlPassword(input) || '');
    return {
      ok: timingSafeStringEqual(mysqlHash.toUpperCase(), stored.toUpperCase()),
      method: 'mysql-password'
    };
  }

  return { ok: false, method: 'no-matching-method' };
}

module.exports = {
  timingSafeStringEqual,
  verifyPassword
};
