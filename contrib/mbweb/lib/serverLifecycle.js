'use strict';

const { logError } = require('./securityLog');

function listenHttpServer(server, { host, port }) {
  return new Promise((resolve, reject) => {
    const onError = err => {
      server.removeListener('listening', onListening);
      reject(err);
    };
    const onListening = () => {
      server.removeListener('error', onError);
      resolve(server);
    };

    server.once('error', onError);
    server.once('listening', onListening);
    server.listen(port, host);
  });
}

function closeHttpServer(server, { timeoutMs = 5000 } = {}) {
  if (!server || !server.listening) return Promise.resolve();

  return new Promise((resolve, reject) => {
    let settled = false;
    let timer = null;
    const finish = err => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      if (err) reject(err);
      else resolve();
    };

    timer = setTimeout(() => {
      if (typeof server.closeAllConnections === 'function') {
        server.closeAllConnections();
      }
      finish(new Error(`HTTP shutdown exceeded ${timeoutMs}ms`));
    }, Math.max(100, Number(timeoutMs) || 5000));
    timer.unref?.();

    server.close(finish);
  });
}

function installGracefulShutdown(options) {
  const {
    server,
    closeables = [],
    logger = console,
    processImpl = process,
    timeoutMs = 5000
  } = options || {};
  const signals = ['SIGINT', 'SIGTERM'];
  let shutdownPromise = null;

  async function shutdown(signal = 'manual') {
    if (shutdownPromise) return shutdownPromise;

    shutdownPromise = (async () => {
      logger.log(`[mbweb] graceful shutdown requested (${signal})`);
      let failed = false;

      try {
        await closeHttpServer(server, { timeoutMs });
      } catch (err) {
        failed = true;
        logError(logger, 'shutdown.http', err);
      }

      for (const closeable of closeables) {
        if (!closeable || typeof closeable.end !== 'function') continue;
        try {
          await closeable.end();
        } catch (err) {
          failed = true;
          logError(logger, 'shutdown.resource', err);
        }
      }

      for (const name of signals) processImpl.removeListener(name, handlers[name]);
      processImpl.exitCode = failed ? 1 : 0;
      return { ok: !failed };
    })();

    return shutdownPromise;
  }

  const handlers = Object.fromEntries(
    signals.map(name => [name, () => { shutdown(name).catch(() => {}); }])
  );
  for (const name of signals) processImpl.once(name, handlers[name]);

  return shutdown;
}

module.exports = {
  closeHttpServer,
  installGracefulShutdown,
  listenHttpServer
};
