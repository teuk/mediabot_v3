'use strict';

function cookieOptions(config) {
  const baseUrl = String(config.baseUrl || '');
  return {
    httpOnly: true,
    sameSite: 'lax',
    secure: config.nodeEnv === 'production',
    maxAge: config.session.maxAgeMs,
    path: baseUrl || '/'
  };
}

function sessionOptions(config, store) {
  const options = {
    name: 'mbweb.sid',
    secret: config.sessionSecret,
    resave: false,
    saveUninitialized: false,
    rolling: false,
    unset: 'destroy',
    proxy: undefined,
    cookie: cookieOptions(config)
  };
  if (store) options.store = store;
  return options;
}

module.exports = {
  cookieOptions,
  sessionOptions
};
