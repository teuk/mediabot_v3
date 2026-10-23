'use strict';

const fs = require('node:fs/promises');
const { constants } = require('node:fs');
const path = require('node:path');
const { escapeHtml } = require('./html');

const FLAGS = Object.freeze(('UrlTitle Youtube YoutubeSearch AppleMusic AppleMusicFallback Reddit '
  + 'Hailo HailoLearn HailoRespond HailoChatter Spark SparkAction Claude Gemini MetaAI '
  + 'VDM RandomQuote Games AchievementAnnounce Radio AntiFlood NoColors').split(' '));
const MAX_BYTES = 65536;
const MAX_AGE_SECONDS = 120;

function integer(value, max = 9999999999) {
  if (!Number.isSafeInteger(value) || value < 0 || value > max) throw new Error('Invalid observation');
  return value;
}
function choice(value, values) {
  if (!values.includes(value)) throw new Error('Invalid observation');
  return value;
}
function object(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Invalid observation');
  return value;
}
function pacing(value, kind) {
  const raw = object(value);
  const out = {
    runtime: choice(raw.runtime, ['present', 'absent']),
    state: choice(raw.state, ['fresh', 'absent', 'busy', 'invalid', 'unavailable', 'unknown'])
  };
  if (!['fresh', 'absent'].includes(out.state)) return out;
  out.source = choice(raw.source, ['channel', 'default']);
  if (raw.file_modified_at !== undefined) out.file_modified_at = integer(raw.file_modified_at);
  if (kind === 'rss') {
    out.gap = integer(raw.gap, 10080); out.daily = integer(raw.daily, 24);
    out.used = integer(raw.used, 300); out.wait = integer(raw.wait);
  } else {
    out.interval = integer(raw.interval, 604800);
    if (out.interval < 900) throw new Error('Invalid observation');
    out.custom = integer(raw.custom, 1); out.scheduled = integer(raw.scheduled, 1);
    if (out.scheduled) {
      out.next_at = integer(raw.next_at); out.wait = integer(raw.wait); out.pending = integer(raw.pending, 1);
    }
  }
  return out;
}
function pluginRows(raw) {
  if (raw === null || raw === undefined) return { state: 'unknown', packages: [] };
  object(raw);
  const state = choice(raw.state, ['observed', 'partial']);
  if (!Array.isArray(raw.packages) || raw.packages.length > 64) throw new Error('Invalid observation');
  const packages = [];
  for (const value of raw.packages) {
    const p = object(value);
    if (p.state === 'unavailable') continue; // No reliable evidence of channel scope.
    choice(p.state, ['observed']);
    integer(p.configured, 1); integer(p.retained_failures, 64);
    if (!p.configured && !p.retained_failures) continue;
    if (typeof p.name !== 'string' || !/^[a-z0-9][a-z0-9_.-]{0,63}$/.test(p.name)) throw new Error('Invalid observation');
    packages.push({
      name: p.name,
      lifecycle: choice(p.lifecycle, ['enabled', 'disabled']),
      policy: choice(p.policy, ['off', 'observe', 'on']),
      decision: choice(p.decision, ['blocked', 'shadow', 'active']),
      missing_capabilities: integer(p.missing_capabilities, 64),
      quarantined_resources: integer(p.quarantined_resources, 64),
      retained_failures: p.retained_failures,
      last_failure_at: p.last_failure_at === null ? null : integer(p.last_failure_at)
    });
  }
  return { state, coverage_incomplete: integer(raw.omitted) > 0 || state === 'partial', packages };
}
function projectReport(raw, id, name) {
  object(raw);
  if (raw.version !== 3 || raw.channel_id !== id || raw.channel !== name) throw new Error('Identity mismatch');
  const flags = {};
  for (const key of FLAGS) flags[key] = choice(object(raw.flags)[key], ['on', 'off', 'missing', 'unknown']);
  const rss = object(raw.rss_failures);
  const rssFailures = { state: choice(rss.state, ['observed', 'unavailable', 'unknown']) };
  if (rssFailures.state === 'observed') {
    rssFailures.retained_feeds = integer(rss.retained_feeds);
    if (rss.latest_db_time !== null && (typeof rss.latest_db_time !== 'string'
        || !/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/.test(rss.latest_db_time))) throw new Error('Invalid time');
    rssFailures.latest_db_time = rss.latest_db_time;
  }
  const activity = object(raw.activity);
  // Global scheduler details, loaded plugin inventory, notes and raw error
  // records never cross this per-channel web boundary, even for a Master.
  return {
    version: 3, channel_id: id, channel: name, observed_at: integer(raw.observed_at),
    database: choice(raw.database, ['fresh']),
    channel_joined: choice(raw.channel_joined, ['yes', 'no', 'unknown']), flags,
    rss: pacing(activity.rss, 'rss'), randomquote: pacing(activity.randomquote, 'randomquote'),
    rss_failures: rssFailures, plugins: pluginRows(raw.plugins)
  };
}
async function readChannelDiagnostics(options = {}) {
  const { id, name } = options;
  const directory = options.directory ?? process.env.MBWEB_CHANNEL_DIAGNOSTICS_DIR;
  if (!directory) return { state: 'unavailable', reason: 'not_configured' };
  let handle;
  try {
    integer(id); if (!id || typeof name !== 'string' || !path.isAbsolute(directory)
        || path.normalize(directory) !== directory) throw new Error('Invalid identity');
    let current = path.parse(directory).root;
    for (const part of directory.slice(current.length).split(path.sep).filter(Boolean)) {
      current = path.join(current, part);
      if ((await fs.lstat(current)).isSymbolicLink()) throw new Error('Unsafe path');
    }
    handle = await fs.open(path.join(directory, `${id}.json`), constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    const stat = await handle.stat();
    if (!stat.isFile() || stat.size > MAX_BYTES) throw new Error('Invalid file');
    const buffer = Buffer.alloc(MAX_BYTES + 1); let size = 0;
    while (size <= MAX_BYTES) {
      const { bytesRead } = await handle.read(buffer, size, buffer.length - size, null);
      if (!bytesRead) break;
      size += bytesRead;
    }
    if (size > MAX_BYTES) throw new Error('Invalid file');
    const raw = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(buffer.subarray(0, size)));
    const report = projectReport(raw, id, name);
    const now = options.now ? options.now() : Date.now();
    const ageSeconds = now / 1000 - report.observed_at;
    if (ageSeconds < -5) throw new Error('Future observation');
    if (ageSeconds > MAX_AGE_SECONDS) return { state: 'stale', observed_at: report.observed_at };
    return { state: 'fresh', age_seconds: Math.max(0, Math.floor(ageSeconds)), report };
  } catch (err) {
    return { state: 'unavailable', reason: err.code === 'ENOENT' ? 'not_published' : 'invalid_or_unreadable' };
  } finally { if (handle) await handle.close().catch(() => {}); }
}
function timestamp(value) { return value === null || value === undefined ? 'unknown' : new Date(value * 1000).toISOString(); }
function renderChannelDiagnostics(result) {
  const e = escapeHtml;
  if (result.state !== 'fresh') return `<section class="mbw-card"><h2>Runtime observation unavailable</h2><p>${result.state === 'stale'
    ? 'The published observation is too old. Runtime values are hidden.'
    : 'No valid recent publication is available for this channel.'}</p><p>No provider call or bot action was requested.</p></section>`;
  const r = result.report;
  const values = (item, keys) => keys.filter(key => item[key] !== undefined)
    .map(key => `<div><span>${e(key)}</span><strong>${e(String(item[key]))}</strong></div>`).join('');
  const plugins = r.plugins.packages.map(p => `<tr><td>${e(p.name)}</td><td>${e(p.lifecycle)}</td><td>${e(p.policy)}</td>
    <td>${e(p.decision)}</td><td>${e(p.missing_capabilities)}</td><td>${e(p.quarantined_resources)}</td>
    <td>${e(p.retained_failures)}</td><td>${e(p.last_failure_at === null ? 'none in retained history' : timestamp(p.last_failure_at))}</td></tr>`).join('');
  return `<section class="mbw-card"><h2>Published observation</h2><p>${e(timestamp(r.observed_at))} · age ${e(result.age_seconds)}s · channel JOIN: ${e(r.channel_joined)}</p>
    <p>Observed runtime state and persisted flags are separate. An on flag does not prove delivery.</p></section>
    <section class="mbw-grid"><article class="mbw-card"><h2>RSS pacing</h2><p>State: ${e(r.rss.state)}. Gap in minutes; wait in seconds. Used counts reservations in 24 hours, including failed delivery attempts.</p>
    <div class="mbw-kv">${values(r.rss, ['source', 'gap', 'daily', 'used', 'wait'])}</div>
    <p>Retained feed errors: ${e(r.rss_failures.retained_feeds ?? r.rss_failures.state)}. Last database time: ${e(r.rss_failures.latest_db_time ?? 'unknown / none retained')} (database timezone).</p></article>
    <article class="mbw-card"><h2>RandomQuote attempts</h2><p>State: ${e(r.randomquote.state)}. Interval and wait in seconds. A ticket is not proof of an active worker or a delivered quote.</p>
    <div class="mbw-kv">${values(r.randomquote, ['source', 'interval', 'custom', 'wait', 'pending'])}</div>
    <p>Next attempt: ${e(r.randomquote.scheduled ? timestamp(r.randomquote.next_at) : 'not observed / unscheduled')}.</p></article></section>
    <section class="mbw-card"><h2>Persisted channel flags</h2><div class="mbw-taglist">${FLAGS.map(key => `<span>${e(key)}: ${e(r.flags[key])}</span>`).join('')}</div>
    <p>missing means absent from the catalogue; unknown means no reliable observation. Neither implies off.</p></section>
    <section class="mbw-card"><h2>Channel plugins · API v3</h2><p>Observation: ${e(r.plugins.state)}. Loaded instances with a policy or retained failure for this channel only. Coverage may be incomplete after retention, unload or restart.</p>
    ${plugins ? `<div class="mbw-table-wrap"><table class="mbw-data-table"><thead><tr><th>Plugin</th><th>Lifecycle</th><th>Policy</th><th>Decision</th><th>Missing grants</th><th>Recorded quarantines</th><th>Retained failures</th><th>Last retained failure</th></tr></thead><tbody>${plugins}</tbody></table></div>` : '<p>No channel-scoped plugin observation is available.</p>'}
    <p>No raw error, conversation, private configuration or other channel history is displayed. Instance scheduler details remain in the Master/Owner Partyline diagnostic.</p></section>`;
}
module.exports = { FLAGS, MAX_BYTES, MAX_AGE_SECONDS, projectReport, readChannelDiagnostics, renderChannelDiagnostics };
