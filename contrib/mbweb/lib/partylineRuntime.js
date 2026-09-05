'use strict';

const fs = require('fs/promises');

const DEFAULT_PATH = '/run/mediabot/partyline_sessions.json';
const DEFAULT_MAX_AGE_MS = 10 * 60 * 1000;
const DEFAULT_MAX_BYTES = 1024 * 1024;
const DEFAULT_MAX_SESSIONS = 100;

function runtimeStatusPath() {
  return process.env.MBWEB_PARTYLINE_STATUS_JSON || DEFAULT_PATH;
}

function safeString(value, max = 200) {
  return String(value || '').replace(/[\r\n\t]/g, ' ').slice(0, max);
}

async function readPartylineRuntime(options = {}) {
  const path = options.path || runtimeStatusPath();
  const maxAgeMs = Number(options.maxAgeMs) || DEFAULT_MAX_AGE_MS;
  const maxBytes = Math.max(1024, Number(options.maxBytes) || DEFAULT_MAX_BYTES);
  const maxSessions = Math.min(
    DEFAULT_MAX_SESSIONS,
    Math.max(1, Number(options.maxSessions) || DEFAULT_MAX_SESSIONS)
  );
  const fsImpl = options.fsImpl || fs;
  const now = typeof options.now === 'function' ? options.now : Date.now;

  try {
    const st = await fsImpl.stat(path);
    const ageMs = now() - st.mtimeMs;

    if (Number(st.size) > maxBytes) {
      throw Object.assign(new Error(`runtime status exceeds ${maxBytes} bytes`), {
        code: 'E2BIG'
      });
    }

    const raw = await fsImpl.readFile(path, 'utf8');
    if (Buffer.byteLength(raw, 'utf8') > maxBytes) {
      throw Object.assign(new Error(`runtime status exceeds ${maxBytes} bytes`), {
        code: 'E2BIG'
      });
    }
    const data = JSON.parse(raw);

    const sessions = Array.isArray(data.sessions)
      ? data.sessions.slice(0, maxSessions).map(s => ({
          fd: Number.isFinite(Number(s.fd)) ? Number(s.fd) : null,
          login: safeString(s.login, 80),
          level: Number.isFinite(Number(s.level)) ? Number(s.level) : null,
          level_desc: safeString(s.level_desc, 80),
          display: safeString(s.display, 180),
          peer_host: safeString(s.peer_host, 180),
          session_type: s.session_type === 'dcc' ? 'dcc' : 'telnet',
          console_level: Number.isFinite(Number(s.console_level)) ? Number(s.console_level) : null,
          connected_at: Number.isFinite(Number(s.connected_at)) ? Number(s.connected_at) : null,
          authenticated_at: Number.isFinite(Number(s.authenticated_at)) ? Number(s.authenticated_at) : null,
          age_seconds: Number.isFinite(Number(s.connected_at))
            ? Math.max(0, Math.round((now() / 1000) - Number(s.connected_at)))
            : (Number.isFinite(Number(s.age_seconds)) ? Number(s.age_seconds) : null)
        }))
      : [];

    return {
      ok: true,
      path,
      stale: ageMs > maxAgeMs,
      ageMs,
      generated_at: Number(data.generated_at) || null,
      count: sessions.length,
      sessions
    };
  } catch (err) {
    return {
      ok: false,
      path,
      stale: true,
      ageMs: null,
      error: err.code === 'ENOENT'
        ? 'runtime status file not found'
        : err.code === 'E2BIG'
          ? 'runtime status exceeds configured byte limit'
          : 'runtime status unavailable',
      count: 0,
      sessions: []
    };
  }
}

module.exports = {
  readPartylineRuntime,
  runtimeStatusPath
};
