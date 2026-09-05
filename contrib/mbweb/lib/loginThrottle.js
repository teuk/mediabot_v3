'use strict';

class BoundedLoginThrottle {
  constructor(options = {}) {
    this.maxAttempts = Number(options.maxAttempts) || 5;
    this.windowMs = Number(options.windowMs) || 15 * 60 * 1000;
    this.maxEntries = Number(options.maxEntries) || 2048;
    this.now = options.now || Date.now;
    this.entries = new Map();
  }

  key(value) {
    return String(value || 'unknown').replace(/[\r\n\t]/g, '').slice(0, 128) || 'unknown';
  }

  prune(now = this.now()) {
    let removed = 0;
    for (const [key, entry] of this.entries) {
      if (entry.resetAt <= now) {
        this.entries.delete(key);
        removed += 1;
      }
    }
    return removed;
  }

  consume(source) {
    const now = this.now();
    const key = this.key(source);
    let entry = this.entries.get(key);

    if (entry && entry.resetAt <= now) {
      this.entries.delete(key);
      entry = null;
    }

    if (!entry && this.entries.size >= this.maxEntries) {
      return { allowed: false, saturated: true, retryAfterSec: 60 };
    }

    if (!entry) {
      entry = { count: 0, resetAt: now + this.windowMs };
      this.entries.set(key, entry);
    }

    entry.count += 1;
    const retryAfterSec = Math.max(1, Math.ceil((entry.resetAt - now) / 1000));
    return {
      allowed: entry.count <= this.maxAttempts,
      saturated: false,
      retryAfterSec,
      count: entry.count
    };
  }

  reset(source) {
    return this.entries.delete(this.key(source));
  }

  size() {
    return this.entries.size;
  }

  startPruning(options = {}) {
    const setIntervalImpl = options.setIntervalImpl || setInterval;
    const intervalMs = Number(options.intervalMs) || this.windowMs;
    const timer = setIntervalImpl(() => this.prune(), intervalMs);
    timer.unref?.();
    return timer;
  }
}

module.exports = {
  BoundedLoginThrottle
};
