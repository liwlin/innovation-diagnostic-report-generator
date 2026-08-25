(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  if (root) root.MakerSeedRuntime = api;
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';

  const LOCAL_DEFAULT = Object.freeze({
    storageMode: 'local',
    apiBaseUrl: '',
    appVersion: 'pages',
    commitSha: '',
  });

  function validate(input, locationLike) {
    const locationValue = locationLike || (typeof location !== 'undefined' ? location : { origin: '' });
    const storageMode = input && input.storageMode === 'api' ? 'api' : 'local';
    const apiBaseUrl = String((input && input.apiBaseUrl) || '');
    if (storageMode === 'api' && apiBaseUrl) {
      const resolved = new URL(apiBaseUrl, locationValue.origin || 'http://localhost');
      if (resolved.origin !== locationValue.origin) {
        throw new Error('api mode requires a same-origin API base URL');
      }
    }
    return {
      storageMode,
      apiBaseUrl,
      appVersion: String((input && input.appVersion) || (storageMode === 'local' ? 'pages' : 'dev')),
      commitSha: String((input && input.commitSha) || ''),
    };
  }

  function getConfig(locationLike, injected) {
    if (!injected) return { ...LOCAL_DEFAULT };
    return validate(injected, locationLike);
  }

  return Object.freeze({ getConfig, validate });
});
