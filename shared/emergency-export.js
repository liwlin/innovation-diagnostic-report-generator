(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  if (root) root.MakerSeedEmergencyExport = api;
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';

  const FORBIDDEN_KEYS = new Set(['apikey', 'api_key', 'authorization', 'cookie', 'password', 'token']);

  function sanitizedClone(value) {
    if (Array.isArray(value)) return value.map(sanitizedClone);
    if (value && typeof value === 'object') {
      const output = {};
      for (const [key, nested] of Object.entries(value)) {
        if (FORBIDDEN_KEYS.has(key.toLowerCase())) continue;
        output[key] = sanitizedClone(nested);
      }
      return output;
    }
    return value;
  }

  function build(input) {
    return {
      schema_version: 1,
      exported_at: input.exportedAt || new Date().toISOString(),
      source_version: String(input.sourceVersion || 'pages'),
      batches: sanitizedClone((input.workspace && input.workspace.batches) || []),
      class_list: sanitizedClone(input.classList || []),
      promo_text: String(input.promoText || ''),
    };
  }

  return Object.freeze({ build });
});
