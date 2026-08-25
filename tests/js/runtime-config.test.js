const assert = require('node:assert/strict');
const path = require('node:path');
const test = require('node:test');

const root = path.resolve(__dirname, '..', '..');
const runtime = require(path.join(root, 'shared', 'runtime-config.js'));

test('Pages defaults to local mode without injected configuration', () => {
  const config = runtime.getConfig({ origin: 'https://liwlin.github.io' }, undefined);

  assert.deepEqual(config, {
    storageMode: 'local',
    apiBaseUrl: '',
    appVersion: 'pages',
    commitSha: '',
  });
});

test('api mode rejects a cross-origin API base URL', () => {
  assert.throws(
    () =>
      runtime.validate(
        { storageMode: 'api', apiBaseUrl: 'https://other.example', appVersion: '1.0.0' },
        { origin: 'https://nas.example' },
      ),
    /same-origin/,
  );
});

test('api mode accepts an empty same-origin base and preserves version metadata', () => {
  assert.deepEqual(
    runtime.validate(
      { storageMode: 'api', apiBaseUrl: '', appVersion: 'v1.2.3', commitSha: 'abcdef1' },
      { origin: 'https://nas.example' },
    ),
    { storageMode: 'api', apiBaseUrl: '', appVersion: 'v1.2.3', commitSha: 'abcdef1' },
  );
});

