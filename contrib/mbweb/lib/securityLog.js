'use strict';

const SAFE_CODE = /^[A-Z][A-Z0-9_]{0,47}$/;
const SAFE_SCOPE = /^[a-z][a-z0-9_.-]{0,47}$/;

function errorDescriptor(err) {
  const code = SAFE_CODE.test(String(err?.code || ''))
    ? String(err.code)
    : 'INTERNAL_ERROR';
  const name = /^[A-Za-z][A-Za-z0-9]{0,31}$/.test(String(err?.name || ''))
    ? String(err.name)
    : 'Error';
  return { code, name };
}

function safeScope(scope) {
  const value = String(scope || 'runtime').toLowerCase();
  return SAFE_SCOPE.test(value) ? value : 'runtime';
}

function logError(logger, scope, err, details = {}) {
  const out = errorDescriptor(err);
  for (const [key, value] of Object.entries(details)) {
    if (!/^(?:method|status|attempt|retry|cleared|saturated)$/.test(key)) continue;
    if (typeof value === 'boolean' || Number.isFinite(value)
        || /^(?:GET|POST|PUT|PATCH|DELETE)$/.test(String(value))) {
      out[key] = value;
    }
  }
  (logger?.error || console.error)(
    `[mbweb][${safeScope(scope)}]`,
    JSON.stringify(out)
  );
}

function logAudit(logger, event, details = {}) {
  const out = {};
  for (const [key, value] of Object.entries(details)) {
    if (!/^(?:cleared|allowed|blocked|saturated|attempt)$/.test(key)) continue;
    if (typeof value === 'boolean' || Number.isFinite(value)) out[key] = value;
  }
  (logger?.log || console.log)(
    `[mbweb][audit][${safeScope(event)}]`,
    JSON.stringify(out)
  );
}

module.exports = {
  errorDescriptor,
  logAudit,
  logError,
  safeScope
};
