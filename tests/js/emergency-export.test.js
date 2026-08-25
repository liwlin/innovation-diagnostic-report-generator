const assert = require('node:assert/strict');
const path = require('node:path');
const test = require('node:test');

const root = path.resolve(__dirname, '..', '..');
const emergency = require(path.join(root, 'shared', 'emergency-export.js'));

test('emergency export includes only the approved local workspace fields', () => {
  const output = emergency.build({
    workspace: { batches: [{ id: 'batch-1', students: [{ name: '张三' }] }], activeBatch: 0, activeStudent: 0, aiCfg: { apiKey: 'must-not-export' } },
    classList: [{ name: 'Python 研习社', time: '周五' }],
    promoText: '课程说明',
    sourceVersion: 'v1.2.3',
    exportedAt: '2026-08-26T00:00:00.000Z',
    apiKey: 'also-must-not-export',
  });

  assert.deepEqual(Object.keys(output).sort(), [
    'batches',
    'class_list',
    'exported_at',
    'promo_text',
    'schema_version',
    'source_version',
  ]);
  assert.equal(output.schema_version, 1);
  assert.equal(output.batches[0].students[0].name, '张三');
  const serialized = JSON.stringify(output);
  assert.equal(serialized.includes('must-not-export'), false);
  assert.equal(serialized.includes('apiKey'), false);
  assert.equal(serialized.includes('Authorization'), false);
});

