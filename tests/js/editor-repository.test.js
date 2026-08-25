const assert = require('node:assert/strict');
const path = require('node:path');
const test = require('node:test');

const root = path.resolve(__dirname, '..', '..');
const repositories = require(path.join(root, 'shared', 'editor-repository.js'));

function response(status, body) {
  return {
    ok: status >= 200 && status < 300,
    status,
    async json() {
      return body;
    },
  };
}

function editorDocument(version = 1, note = '') {
  return {
    evaluation_id: '11111111-1111-4111-8111-111111111111',
    version,
    batch: { id: '22222222-2222-4222-8222-222222222222', date: '8月25日' },
    student: { id: '33333333-3333-4333-8333-333333333333', name: '张三', grade: '三年级', slot: '' },
    payload: { schema_version: 1, note },
  };
}

test('local mode reads and writes only the established workspace key', async () => {
  const calls = [];
  const storage = {
    getItem(key) {
      calls.push(['get', key]);
      return JSON.stringify({ batches: [{ id: 'local' }] });
    },
    setItem(key, value) {
      calls.push(['set', key, JSON.parse(value)]);
    },
  };
  const repository = repositories.create({
    config: { storageMode: 'local', apiBaseUrl: '' },
    storage,
  });

  assert.deepEqual(await repository.load({}), { batches: [{ id: 'local' }] });
  repository.scheduleSave({ batches: [{ id: 'updated' }] });
  await repository.flush();

  assert.deepEqual(calls, [
    ['get', 'mkseed_diag_v3'],
    ['set', 'mkseed_diag_v3', { batches: [{ id: 'updated' }] }],
  ]);
});

test('api mode debounces to one versioned PUT and never stores business data locally', async () => {
  const fetchCalls = [];
  const storageCalls = [];
  let scheduled;
  const statuses = [];
  const repository = repositories.create({
    config: { storageMode: 'api', apiBaseUrl: '' },
    storage: {
      getItem() {
        throw new Error('api mode must not read business localStorage');
      },
      setItem(...args) {
        storageCalls.push(args);
      },
    },
    cookieReader: () => 'mkseed_csrf=csrf-token',
    setTimeoutImpl(callback, delay) {
      assert.equal(delay, 700);
      scheduled = callback;
      return 17;
    },
    clearTimeoutImpl() {},
    onStatus(status) {
      statuses.push(status.state);
    },
    async fetchImpl(url, options) {
      fetchCalls.push({ url, options });
      return response(200, editorDocument(2, JSON.parse(options.body).payload.note));
    },
  });

  repository.scheduleSave(editorDocument(1, 'first'));
  repository.scheduleSave(editorDocument(1, 'latest'));
  await scheduled();
  await repository.flush();

  assert.equal(fetchCalls.length, 1);
  assert.equal(fetchCalls[0].url, '/api/evaluations/11111111-1111-4111-8111-111111111111');
  assert.equal(fetchCalls[0].options.credentials, 'same-origin');
  assert.equal(fetchCalls[0].options.headers['X-CSRF-Token'], 'csrf-token');
  assert.deepEqual(JSON.parse(fetchCalls[0].options.body), {
    version: 1,
    student: editorDocument().student,
    payload: { schema_version: 1, note: 'latest' },
  });
  assert.equal(storageCalls.length, 0);
  assert.equal(repository.current().version, 2);
  assert.ok(statuses.includes('saving'));
  assert.equal(statuses.at(-1), 'saved');
});

test('api conflict freezes future autosaves until a reload', async () => {
  const fetchCalls = [];
  let scheduled;
  const statuses = [];
  const repository = repositories.create({
    config: { storageMode: 'api', apiBaseUrl: '' },
    storage: { getItem() {}, setItem() {} },
    cookieReader: () => 'mkseed_csrf=csrf-token',
    setTimeoutImpl(callback) {
      scheduled = callback;
      return 1;
    },
    clearTimeoutImpl() {},
    onStatus(status) {
      statuses.push(status.state);
    },
    async fetchImpl(url, options) {
      fetchCalls.push({ url, options });
      return response(409, {
        error: { code: 'version_conflict', details: { current_version: 3 } },
      });
    },
  });

  repository.scheduleSave(editorDocument(1, 'stale'));
  await scheduled();
  repository.scheduleSave(editorDocument(1, 'must-not-send'));
  await repository.flush();

  assert.equal(fetchCalls.length, 1);
  assert.equal(repository.isConflicted(), true);
  assert.equal(statuses.at(-1), 'conflict');
});

test('api 401 emits signed_out and disposal cancels a pending timer', async () => {
  let scheduled;
  const cleared = [];
  const statuses = [];
  const repository = repositories.create({
    config: { storageMode: 'api', apiBaseUrl: '' },
    storage: { getItem() {}, setItem() {} },
    cookieReader: () => 'mkseed_csrf=csrf-token',
    setTimeoutImpl(callback) {
      scheduled = callback;
      return 44;
    },
    clearTimeoutImpl(id) {
      cleared.push(id);
    },
    onStatus(status) {
      statuses.push(status.state);
    },
    async fetchImpl() {
      return response(401, { error: { code: 'authentication_required' } });
    },
  });

  repository.scheduleSave(editorDocument());
  repository.dispose();
  assert.deepEqual(cleared, [44]);

  const signedOutRepository = repositories.create({
    config: { storageMode: 'api', apiBaseUrl: '' },
    storage: { getItem() {}, setItem() {} },
    cookieReader: () => 'mkseed_csrf=csrf-token',
    setTimeoutImpl(callback) {
      scheduled = callback;
      return 45;
    },
    clearTimeoutImpl() {},
    onStatus(status) {
      statuses.push(status.state);
    },
    async fetchImpl() {
      return response(401, { error: { code: 'authentication_required' } });
    },
  });
  signedOutRepository.scheduleSave(editorDocument());
  await scheduled();
  assert.equal(statuses.at(-1), 'signed_out');
});
