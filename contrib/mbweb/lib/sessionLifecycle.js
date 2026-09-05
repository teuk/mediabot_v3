'use strict';

const { ensureCsrfToken } = require('./csrf');

function callbackPromise(invoke) {
  return new Promise((resolve, reject) => {
    invoke(err => err ? reject(err) : resolve());
  });
}

async function establishAuthenticatedSession(req, user, options = {}) {
  if (!req?.session || typeof req.session.regenerate !== 'function') {
    throw new TypeError('A regenerable session is required.');
  }
  await callbackPromise(done => req.session.regenerate(done));
  req.session.user = user;
  req.session._userRefreshedAt = Number(options.now?.() || Date.now());
  ensureCsrfToken(req.session, options.randomBytes);
  await callbackPromise(done => req.session.save(done));
  return req.session;
}

async function destroyAuthenticatedSession(req) {
  if (!req?.session || typeof req.session.destroy !== 'function') return;
  await callbackPromise(done => req.session.destroy(done));
}

module.exports = {
  callbackPromise,
  destroyAuthenticatedSession,
  establishAuthenticatedSession
};
