const assert = require('node:assert/strict');
const path = require('node:path');
const test = require('node:test');

const root = path.resolve(__dirname, '..', '..');
const clients = require(path.join(root, 'nas-web', 'api-client.js'));

function response(status, body) {
  return {
    ok: status >= 200 && status < 300,
    status,
    async json() {
      return body;
    },
  };
}

test('mutation sends same-origin credentials and csrf header', async () => {
  const calls = [];
  const api = clients.createApiClient({
    cookieReader: () => 'mkseed_csrf=csrf-value',
    async fetchImpl(url, options) {
      calls.push({ url, options });
      return response(200, { ok: true });
    },
  });

  await api.trashEvaluation('11111111-1111-4111-8111-111111111111');

  assert.equal(calls[0].url, '/api/evaluations/11111111-1111-4111-8111-111111111111/trash');
  assert.equal(calls[0].options.method, 'POST');
  assert.equal(calls[0].options.credentials, 'same-origin');
  assert.equal(calls[0].options.headers['X-CSRF-Token'], 'csrf-value');
});

test('record filters are encoded without undefined values', async () => {
  const calls = [];
  const api = clients.createApiClient({
    async fetchImpl(url, options) {
      calls.push({ url, options });
      return response(200, { items: [], next_cursor: null });
    },
  });

  await api.listEvaluations({ q: '张 三', grade: '', limit: 20, trashed: false, cursor: null });

  assert.equal(calls[0].url, '/api/evaluations?q=%E5%BC%A0+%E4%B8%89&limit=20&trashed=false');
  assert.equal(calls[0].options.credentials, 'same-origin');
});

test('stable API error is thrown and 401 triggers signed-out callback', async () => {
  let signedOut = 0;
  const api = clients.createApiClient({
    onUnauthorized() {
      signedOut += 1;
    },
    async fetchImpl() {
      return response(401, {
        error: { code: 'authentication_required', message: '请先登录', details: {} },
      });
    },
  });

  await assert.rejects(
    () => api.getSession(),
    (error) => error.code === 'authentication_required' && error.status === 401,
  );
  assert.equal(signedOut, 1);
});

test('login sends JSON but no stale csrf header', async () => {
  const calls = [];
  const api = clients.createApiClient({
    cookieReader: () => 'mkseed_csrf=stale-value',
    async fetchImpl(url, options) {
      calls.push({ url, options });
      return response(200, { user: { username: 'teacher' } });
    },
  });

  await api.login('teacher', 'password');

  assert.equal(calls[0].url, '/api/auth/login');
  assert.equal(calls[0].options.headers['X-CSRF-Token'], undefined);
  assert.deepEqual(JSON.parse(calls[0].options.body), {
    username: 'teacher',
    password: 'password',
  });
});

test('emergency import uses multipart body with csrf and no manual content type', async () => {
  const calls = [];
  const api = clients.createApiClient({
    cookieReader: () => 'mkseed_csrf=csrf-value',
    async fetchImpl(url, options) {
      calls.push({ url, options });
      return response(200, { sha256: 'a'.repeat(64), counts: {} });
    },
  });
  const file = new Blob(['{}'], { type: 'application/json' });

  await api.previewEmergencyImport(file);

  assert.equal(calls[0].url, '/api/admin/imports/preview');
  assert.equal(calls[0].options.method, 'POST');
  assert.equal(calls[0].options.headers['X-CSRF-Token'], 'csrf-value');
  assert.equal(calls[0].options.headers['Content-Type'], undefined);
  assert.equal(calls[0].options.body instanceof FormData, true);
});
