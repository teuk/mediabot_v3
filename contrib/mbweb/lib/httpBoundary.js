'use strict';

const { logError } = require('./securityLog');

function createHttpBoundaries(options) {
  const {
    baseUrl = '',
    escapeHtml,
    renderPage,
    safeBase,
    logger = console
  } = options || {};

  if (typeof escapeHtml !== 'function' || typeof renderPage !== 'function'
      || typeof safeBase !== 'function') {
    throw new TypeError('HTTP boundary render helpers are required');
  }

  function notFound(req, res) {
    res.status(404).send(renderPage('404', `
<section class="mbw-card">
  <h1>404</h1>
  <p>Unknown route.</p>
</section>
`, req));
  }

  function error(err, req, res, next) { // eslint-disable-line no-unused-vars
    const candidate = Number(err?.status || err?.statusCode || 500);
    const status = Number.isInteger(candidate) && candidate >= 400 && candidate <= 599
      ? candidate
      : 500;
    const message = 'Internal server error';
    logError(logger, 'http', err, { method: req.method, status });

    if (res.headersSent) return next(err);

    const wantsJson = req.path.startsWith(baseUrl + '/api/')
      || req.headers.accept?.includes('application/json');

    if (wantsJson) {
      return res.status(status).json({ ok: false, error: message });
    }

    return res.status(status).send(renderPage(
      status === 404 ? '404' : 'Error',
      `
<section class="mbw-card">
  <h1>${status === 404 ? '404 — Page not found' : 'Server error'}</h1>
  <p>${escapeHtml(message)}</p>
  <a href="${safeBase('/')}" class="mbw-btn-secondary">← Home</a>
</section>
`,
      req
    ));
  }

  return { notFound, error };
}

module.exports = {
  createHttpBoundaries
};
