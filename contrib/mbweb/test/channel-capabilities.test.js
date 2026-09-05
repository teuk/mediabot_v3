'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  CHANNEL_CAPABILITY_CHANSETS,
  normalizeCapabilityRows
} = require('../lib/channelCapabilities');

test('accepted 3.5 capability catalogue is explicit and stable', () => {
  assert.deepEqual(CHANNEL_CAPABILITY_CHANSETS, [
    'Hailo',
    'HailoLearn',
    'HailoRespond',
    'HailoChatter',
    'Gemini',
    'Spark',
    'SparkAction',
    'Fullop'
  ]);
});

test('channel capability rows preserve disabled and subordinate states', () => {
  const capabilities = normalizeCapabilityRows([
    { chanset: 'Hailo', enabled: 1 },
    { chanset: 'HailoLearn', enabled: 1 },
    { chanset: 'HailoRespond', enabled: 0 },
    { chanset: 'HailoChatter', enabled: 1 },
    { chanset: 'Gemini', enabled: 0 },
    { chanset: 'Spark', enabled: 1 },
    { chanset: 'SparkAction', enabled: 0 },
    { chanset: 'Fullop', enabled: 1 },
    { chanset: 'Unrelated', enabled: 1 }
  ]);

  assert.deepEqual(
    capabilities.map(({ key, state }) => [key, state]),
    [['hailo', 'enabled'], ['gemini', 'disabled'], ['spark', 'enabled'], ['fullop', 'enabled']]
  );
  assert.deepEqual(
    capabilities[0].features.map(({ key, enabled }) => [key, enabled]),
    [['learn', true], ['respond', false], ['chatter', true]]
  );
});

test('missing capability metadata is reported as unavailable, never enabled', () => {
  const capabilities = normalizeCapabilityRows(null);
  assert.equal(capabilities.length, 4);
  assert.ok(capabilities.every(item => item.state === 'unavailable' && item.enabled === false));
});
