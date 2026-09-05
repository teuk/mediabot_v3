'use strict';

const { EventEmitter } = require('node:events');
const test = require('node:test');
const assert = require('node:assert/strict');

const { createHttpBoundaries } = require('../lib/httpBoundary');
const { escapeHtml } = require('../lib/html');
const {
  installGracefulShutdown,
  listenHttpServer
} = require('../lib/serverLifecycle');

function fakeResponse() {
  return {
    headersSent: false,
    statusCode: 200,
    payload: null,
    kind: null,
    status(code) { this.statusCode = code; return this; },
    send(payload) { this.payload = payload; this.kind = 'html'; return this; },
    json(payload) { this.payload = payload; this.kind = 'json'; return this; }
  };
}

function boundaries(isProduction = true) {
  return createHttpBoundaries({
    baseUrl: '/console',
    escapeHtml,
    renderPage: (title, body) => `${title}\n${body}`,
    safeBase: pathname => '/console' + pathname,
    logger: { error() {} },
    isProduction
  });
}

test('not-found rendering escapes the requested route', () => {
  const res = fakeResponse();
  boundaries().notFound({ originalUrl: '/<script>alert(1)</script>' }, res);
  assert.equal(res.statusCode, 404);
  assert.match(res.payload, /Unknown route\./);
  assert.doesNotMatch(res.payload, /<script>/);
  assert.doesNotMatch(res.payload, /alert/);
});

test('production error rendering hides private messages for HTML and JSON', () => {
  const err = Object.assign(new Error('password=private'), { status: 503 });
  const htmlRes = fakeResponse();
  boundaries(true).error(err, {
    method: 'GET', originalUrl: '/console/page', path: '/console/page', headers: {}
  }, htmlRes, () => {});
  assert.equal(htmlRes.statusCode, 503);
  assert.doesNotMatch(htmlRes.payload, /password=private/);
  assert.match(htmlRes.payload, /Internal server error/);

  const jsonRes = fakeResponse();
  boundaries(true).error(err, {
    method: 'GET', originalUrl: '/console/api/status', path: '/console/api/status', headers: {}
  }, jsonRes, () => {});
  assert.equal(jsonRes.kind, 'json');
  assert.deepEqual(jsonRes.payload, { ok: false, error: 'Internal server error' });
});

class FakeServer extends EventEmitter {
  constructor(mode = 'ok') {
    super();
    this.mode = mode;
    this.listening = false;
    this.closeCalls = 0;
  }

  listen(port, host) {
    this.args = { port, host };
    process.nextTick(() => {
      if (this.mode === 'error') this.emit('error', new Error('address unavailable'));
      else {
        this.listening = true;
        this.emit('listening');
      }
    });
  }

  close(callback) {
    this.closeCalls += 1;
    this.listening = false;
    process.nextTick(() => callback());
  }
}

test('startup resolves only after listen and rejects a listener failure', async () => {
  const good = new FakeServer();
  await listenHttpServer(good, { port: 0, host: '127.0.0.1' });
  assert.deepEqual(good.args, { port: 0, host: '127.0.0.1' });

  const bad = new FakeServer('error');
  await assert.rejects(
    listenHttpServer(bad, { port: 4002, host: '127.0.0.1' }),
    /address unavailable/
  );
});

test('graceful shutdown closes HTTP and DB resources once without a hanging timer', async () => {
  const processImpl = new EventEmitter();
  processImpl.exitCode = null;
  const server = new FakeServer();
  server.listening = true;
  let poolEnds = 0;
  const pool = { end: async () => { poolEnds += 1; } };
  const logger = { log() {}, error() {} };
  const shutdown = installGracefulShutdown({
    server,
    closeables: [pool],
    processImpl,
    logger,
    timeoutMs: 200
  });

  const [first, second] = await Promise.all([shutdown('test'), shutdown('duplicate')]);
  assert.deepEqual(first, { ok: true });
  assert.deepEqual(second, { ok: true });
  assert.equal(server.closeCalls, 1);
  assert.equal(poolEnds, 1);
  assert.equal(processImpl.exitCode, 0);
  assert.equal(processImpl.listenerCount('SIGTERM'), 0);
  assert.equal(processImpl.listenerCount('SIGINT'), 0);
});
