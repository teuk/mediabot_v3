'use strict';

const { config } = require('./config');

const DEFAULT_RADIO_TIMEOUT_MS = 4000;
const DEFAULT_RADIO_MAX_BYTES = 1024 * 1024;

function intFromEnv(name, fallback, { min = 1, max = 10_000_000 } = {}) {
  const n = Number(process.env[name]);
  if (!Number.isFinite(n) || !Number.isInteger(n)) return fallback;
  return Math.min(Math.max(n, min), max);
}

function normalizeHttpBaseUrl(value) {
  const raw = String(value || '').trim().replace(/\/+$/, '');
  if (!raw) return null;

  try {
    const u = new URL(raw);
    if (u.protocol !== 'http:' && u.protocol !== 'https:') return null;
    return u.toString().replace(/\/+$/, '');
  } catch {
    return null;
  }
}

function normalizeMountPath(value, fallback = '/') {
  const raw = String(value || fallback || '').trim();
  if (!raw) return '/';

  const withoutQuery = raw.split(/[?#]/, 1)[0];
  const out = withoutQuery.startsWith('/') ? withoutQuery : '/' + withoutQuery;

  // Keep this as a path only; do not allow absolute URLs or control chars.
  if (/^\/\//.test(out) || /[\r\n\t]/.test(out)) return '/';

  return out.replace(/\/{2,}/g, '/');
}

async function fetchJson(url, timeoutMs = DEFAULT_RADIO_TIMEOUT_MS) {
  const timeout = intFromEnv(
    'MBWEB_RADIO_TIMEOUT_MS',
    timeoutMs,
    { min: 250, max: 30000 }
  );

  const maxBytes = intFromEnv(
    'MBWEB_RADIO_MAX_BYTES',
    DEFAULT_RADIO_MAX_BYTES,
    { min: 4096, max: 10 * 1024 * 1024 }
  );

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeout);

  try {
    const res = await fetch(url, {
      signal: controller.signal,
      headers: {
        'User-Agent': 'mbweb-mediabot-console/0.1',
        'Accept': 'application/json,text/plain,*/*;q=0.8'
      }
    });

    const text = await res.text();

    if (text.length > maxBytes) {
      return {
        ok: false,
        status: res.status,
        error: `Response too large: ${text.length} bytes`,
        bodyStart: text.slice(0, 200)
      };
    }

    if (!res.ok) {
      return {
        ok: false,
        status: res.status,
        error: `HTTP ${res.status}`,
        bodyStart: text.slice(0, 200)
      };
    }

    if (!text.trim()) {
      return {
        ok: false,
        status: res.status,
        error: 'Empty JSON response'
      };
    }

    try {
      return {
        ok: true,
        status: res.status,
        data: JSON.parse(text)
      };
    } catch (err) {
      return {
        ok: false,
        status: res.status,
        error: 'Invalid JSON: ' + err.message,
        bodyStart: text.slice(0, 200)
      };
    }
  } catch (err) {
    const cause = err?.cause
      ? [
          err.cause.code,
          err.cause.address,
          err.cause.port ? `port=${err.cause.port}` : null
        ].filter(Boolean).join(' ')
      : '';

    return {
      ok: false,
      status: null,
      error: err.name === 'AbortError'
        ? 'Timeout'
        : `${err.message}${cause ? ` (${cause})` : ''}`
    };
  } finally {
    clearTimeout(timer);
  }
}

function normalizeSources(source) {
  if (!source) return [];
  return Array.isArray(source) ? source : [source].filter(Boolean);
}

function findMount(sources, mountName) {
  const norm = s => String(s || '').replace(/\/+$/, '');
  const target = norm(mountName);

  return sources.find(src => src.listenurl && norm(src.listenurl).endsWith(target))
      || sources.find(src => norm(src.serverName) === target)
      || sources.find(src => norm(src.mount) === target)
      || sources.find(src => String(src.listenurl || '').includes(target))
      || null;
}

function publicListenUrl(mount) {
  const base = normalizeHttpBaseUrl(config.urls.radioPublicBase);
  if (!base) return null;

  const path = normalizeMountPath(mount || config.urls.radioPrimaryMount || '/');

  return base + path;
}

function extractMountFromListenUrl(listenurl, fallback = null) {
  const raw = String(listenurl || '').trim();
  if (!raw) return fallback;

  try {
    const u = new URL(raw);
    return normalizeMountPath(u.pathname || fallback || '/');
  } catch {
    if (raw.startsWith('/')) return normalizeMountPath(raw, fallback || '/');
    return fallback;
  }
}

async function getRadioStatus() {
  const url = config.urls.radioStatus;
  const primaryMount = normalizeMountPath(config.urls.radioPrimaryMount || '/radio160.mp3');

  const fetched = await fetchJson(url);

  const out = {
    ok: false,
    source: 'icecast',
    statusUrl: url,
    publicBaseUrl: normalizeHttpBaseUrl(config.urls.radioPublicBase),
    primaryMount,
    publicListenUrl: publicListenUrl(primaryMount),
    mounts: [],
    primary: null,
    rawError: null,
    generatedAt: new Date().toISOString()
  };

  if (!fetched.ok) {
    out.rawError = fetched.error || 'Unable to fetch radio status';
    out.httpStatus = fetched.status;
    return out;
  }

  const icestats = fetched.data?.icestats && typeof fetched.data.icestats === 'object'
    ? fetched.data.icestats
    : {};

  const sources = normalizeSources(icestats.source);

  out.ok = true;
  out.serverId = icestats.server_id || null;
  out.serverStart = icestats.server_start || null;
  out.admin = icestats.admin || null;
  out.host = icestats.host || null;
  out.location = icestats.location || null;

  out.mounts = sources
    .filter(src => src && typeof src === 'object')
    .map(src => {
      const listenurl = String(src.listenurl || '');
      const mount = extractMountFromListenUrl(
        listenurl,
        src.mount || src.server_name || primaryMount
      );

      return {
        mount,
        listenurl,
        publicListenUrl: publicListenUrl(mount || primaryMount),
        serverName: src.server_name || null,
        serverDescription: src.server_description || null,
        listeners: src.listeners ?? null,
        listenerPeak: src.listener_peak ?? null,
        bitrate: src.bitrate ?? null,
        genre: src.genre || null,
        contentType: src.content_type || null,
        title: src.title || src.yp_currently_playing || null,
        artist: src.artist || null,
        streamStart: src.stream_start || null
      };
    });

  out.primary = findMount(out.mounts, primaryMount) || out.mounts[0] || null;

  return out;
}

module.exports = {
  getRadioStatus,
  publicListenUrl,
  normalizeHttpBaseUrl,
  normalizeMountPath
};
