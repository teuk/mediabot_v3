'use strict';

const CHANNEL_CAPABILITY_GROUPS = Object.freeze([
  Object.freeze({
    key: 'hailo',
    label: 'Hailo',
    primary: 'Hailo',
    features: Object.freeze([
      Object.freeze({ key: 'learn', label: 'learn', chanset: 'HailoLearn' }),
      Object.freeze({ key: 'respond', label: 'respond', chanset: 'HailoRespond' }),
      Object.freeze({ key: 'chatter', label: 'chatter', chanset: 'HailoChatter' })
    ])
  }),
  Object.freeze({
    key: 'gemini',
    label: 'Gemini',
    primary: 'Gemini',
    features: Object.freeze([])
  }),
  Object.freeze({
    key: 'spark',
    label: 'Spark',
    primary: 'Spark',
    features: Object.freeze([
      Object.freeze({ key: 'action', label: 'actions', chanset: 'SparkAction' })
    ])
  }),
  Object.freeze({
    key: 'fullop',
    label: 'Fullop',
    primary: 'Fullop',
    features: Object.freeze([])
  })
]);

const CHANNEL_CAPABILITY_CHANSETS = Object.freeze(
  [...new Set(CHANNEL_CAPABILITY_GROUPS.flatMap(group => [
    group.primary,
    ...group.features.map(feature => feature.chanset)
  ]))]
);

function normalizeCapabilityRows(rows) {
  const states = new Map();
  for (const row of Array.isArray(rows) ? rows : []) {
    const name = String(row?.chanset || '');
    if (!CHANNEL_CAPABILITY_CHANSETS.includes(name)) continue;
    states.set(name, Number(row?.enabled || 0) === 1);
  }

  return CHANNEL_CAPABILITY_GROUPS.map(group => {
    const available = states.has(group.primary);
    const enabled = available && states.get(group.primary) === true;
    const features = group.features.map(feature => ({
      key: feature.key,
      label: feature.label,
      chanset: feature.chanset,
      available: states.has(feature.chanset),
      enabled: states.get(feature.chanset) === true
    }));

    return {
      key: group.key,
      label: group.label,
      chanset: group.primary,
      available,
      enabled,
      state: available ? (enabled ? 'enabled' : 'disabled') : 'unavailable',
      features
    };
  });
}

module.exports = {
  CHANNEL_CAPABILITY_CHANSETS,
  CHANNEL_CAPABILITY_GROUPS,
  normalizeCapabilityRows
};
