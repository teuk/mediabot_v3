'use strict';

class RuntimeCache {
  constructor() {
    this.store = new Map();
  }

  async getOrSet(key, ttlMs, producer, { force = false } = {}) {
    const now = Date.now();
    const cached = this.store.get(key);

    if (!force && cached && cached.expiresAt > now) {
      return {
        value: cached.value,
        cached: true,
        ageMs: now - cached.createdAt,
        expiresInMs: cached.expiresAt - now
      };
    }

    const value = await producer();
    const entry = {
      value,
      createdAt: now,
      expiresAt: now + Math.max(1, Number(ttlMs) || 1)
    };

    this.store.set(key, entry);

    return {
      value,
      cached: false,
      ageMs: 0,
      expiresInMs: entry.expiresAt - now
    };
  }

  clear(prefix = null) {
    if (!prefix) {
      const count = this.store.size;
      this.store.clear();
      return count;
    }

    let count = 0;
    for (const key of Array.from(this.store.keys())) {
      if (key.startsWith(prefix)) {
        this.store.delete(key);
        count += 1;
      }
    }

    return count;
  }

  stats() {
    const now = Date.now();

    return Array.from(this.store.entries()).map(([key, entry]) => ({
      key,
      ageMs: now - entry.createdAt,
      expiresInMs: Math.max(0, entry.expiresAt - now),
      expired: entry.expiresAt <= now
    }));
  }
}

module.exports = {
  RuntimeCache
};
