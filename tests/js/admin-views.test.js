const assert = require('node:assert/strict');
const path = require('node:path');
const test = require('node:test');

const root = path.resolve(__dirname, '..', '..');
const views = require(path.join(root, 'nas-web', 'views.js'));

test('teacher navigation excludes every administrator surface', () => {
  assert.deepEqual(
    views.navigationItems('teacher').map((item) => item.view),
    ['records', 'trash'],
  );
});

test('administrator navigation includes account and audit surfaces', () => {
  assert.deepEqual(
    views.navigationItems('admin').map((item) => item.view),
    ['records', 'trash', 'users', 'audit'],
  );
});

test('permanent deletion requires admin role and a meaningful reason', () => {
  assert.deepEqual(views.validatePermanentDelete('teacher', '监护人要求删除'), {
    ok: false,
    message: '需要管理员权限',
  });
  assert.deepEqual(views.validatePermanentDelete('admin', '  '), {
    ok: false,
    message: '请填写至少 4 个字符的删除原因',
  });
  assert.deepEqual(views.validatePermanentDelete('admin', '  监护人要求删除  '), {
    ok: true,
    reason: '监护人要求删除',
  });
});

test('NAS logout cleanup never removes the Pages business workspace key', () => {
  assert.deepEqual(views.nasLogoutStorageKeys(), [
    'mkseed_diag_aicfg_v1',
    'mkseed_nas_ui_v1',
  ]);
  assert.equal(views.nasLogoutStorageKeys().includes('mkseed_diag_v3'), false);
});

test('generation states use teacher-facing Chinese labels', () => {
  assert.equal(views.generationStatusLabel('completed'), '已生成');
  assert.equal(views.generationStatusLabel('running'), '生成中');
  assert.equal(views.generationStatusLabel(null), '未生成');
});
