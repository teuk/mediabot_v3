'use strict';

const { config } = require('./config');

async function fetchJson(url, timeoutMs = 4000) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);

  try {
    const res = await fetch(url, {
      signal: controller.signal,
      headers: {
        'User-Agent': 'mbweb-mediabot-console/0.1'
      }
    });

    const text = await res.text();

    if (!res.ok) {
      return {
        ok: false,
        status: res.status,
        error: `HTTP ${res.status}`,
        bodyStart: text.slice(0, 200)
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
    return {
      ok: false,
      status: null,
      error: err.name === 'AbortError' ? 'Timeout' : err.message
    };
  } finally {
    clearTimeout(timer);
  }
}

function normalizeSources(source) {
  if (!source) return [];
  return Array.isArray(source) ? source : [source];
}

function findMount(sources, mountName) {
  // B7 — normalise both sides to avoid trailing-slash mismatches
  const norm = s => String(s || '').replace(/\/+$/, '');
  const target = norm(mountName);
  return sources.find(src => src.listenurl && norm(src.listenurl).endsWith(target))
      || sources.find(src => norm(src.server_name) === target)
      || sources.find(src => norm(src.mount) === target)
      || sources.find(src => String(src.listenurl || '').includes(target))
      || null;
}

function publicListenUrl(mount) {
  const base = String(config.urls.radioPublicBase || '').replace(/\/+$/, '');
  const m = String(mount || config.urls.radioPrimaryMount || '').startsWith('/')
    ? String(mount || config.urls.radioPrimaryMount)
    : '/' + String(mount || config.urls.radioPrimaryMount);

  return base + m;
}

async function getRadioStatus() {
  const url = config.urls.radioStatus;
  const primaryMount = config.urls.radioPrimaryMount;

  const fetched = await fetchJson(url);

  const out = {
    ok: false,
    source: 'icecast',
    statusUrl: url,
    publicBaseUrl: config.urls.radioPublicBase,
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

  const icestats = fetched.data?.icestats || {};
  const sources = normalizeSources(icestats.source);

  out.ok = true;
  out.serverId = icestats.server_id || null;
  out.serverStart = icestats.server_start || null;
  out.admin = icestats.admin || null;
  out.host = icestats.host || null;
  out.location = icestats.location || null;

  out.mounts = sources.map(src => {
    const listenurl = src.listenurl || '';
    const mount = listenurl.includes('/')
      ? '/' + listenurl.split('/').slice(3).join('/')
      : (src.mount || src.server_name || null);

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
  publicListenUrl
};
