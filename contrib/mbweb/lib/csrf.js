'use strict';

const crypto = require('crypto');

const TOKEN_BYTES = 32;
const TOKEN_PATTERN = /^[a-f0-9]{64}$/;
const SAFE_METHODS = new Set(['GET', 'HEAD', 'OPTIONS']);

function validToken(value) {
  return typeof value === 'string' && TOKEN_PATTERN.test(value);
}

function tokensEqual(candidate, expected) {
  if (!validToken(candidate) || !validToken(expected)) return false;
  return crypto.timingSafeEqual(
    Buffer.from(candidate, 'ascii'),
    Buffer.from(expected, 'ascii')
  );
}

function ensureCsrfToken(session, randomBytes = crypto.randomBytes) {
  if (!session || typeof session !== 'object') {
    throw new TypeError('A session is required for CSRF protection.');
  }
  if (!validToken(session._csrf)) {
    session._csrf = randomBytes(TOKEN_BYTES).toString('hex');
  }
  return session._csrf;
}

function requestToken(req) {
  const header = req?.get?.('x-csrf-token') ?? req?.headers?.['x-csrf-token'];
  const body = req?.body?._csrf;
  if (header && body && header !== body) return null;
  return header || body || null;
}

function csrfDecision(req) {
  const method = String(req?.method || 'GET').toUpperCase();
  if (SAFE_METHODS.has(method)) return { allowed: true, method, safe: true };

  const expected = req?.session?._csrf;
  const supplied = requestToken(req);
  return {
    allowed: tokensEqual(supplied, expected),
    method,
    safe: false
  };
}

function createCsrfProtection(options = {}) {
  const logger = options.logger || console;

  return function csrfProtection(req, res, next) {
    res.locals = res.locals || {};

    const decision = csrfDecision(req);
    if (decision.safe) {
      if (validToken(req.session?._csrf)) {
        req.csrfToken = req.session._csrf;
        res.locals.csrfToken = req.csrfToken;
      }
      return next();
    }
    if (decision.allowed) {
      req.csrfToken = req.session._csrf;
      res.locals.csrfToken = req.csrfToken;
      return next();
    }

    logger.warn('[mbweb][csrf] request rejected', decision.method);
    res.set?.('Cache-Control', 'no-store');
    if (String(req.path || '').includes('/api/')) {
      return res.status(403).json({ ok: false, error: 'Invalid or expired form token' });
    }
    return res.status(403).send('Invalid or expired form token.');
  };
}

function csrfField(req) {
  if (!req?.session) return '';
  const token = validToken(req.csrfToken)
    ? req.csrfToken
    : ensureCsrfToken(req.session);
  req.csrfToken = token;
  return `<input type="hidden" name="_csrf" value="${token}">`;
}

module.exports = {
  SAFE_METHODS,
  TOKEN_BYTES,
  createCsrfProtection,
  csrfDecision,
  csrfField,
  ensureCsrfToken,
  requestToken,
  tokensEqual,
  validToken
};
