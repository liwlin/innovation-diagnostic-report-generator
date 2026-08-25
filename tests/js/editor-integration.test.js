const assert = require('node:assert/strict');
const path = require('node:path');
const test = require('node:test');

const root = path.resolve(__dirname, '..', '..');
const mapping = require(path.join(root, 'shared', 'editor-mapping.js'));

function editorDocument() {
  return {
    evaluation_id: '11111111-1111-4111-8111-111111111111',
    version: 7,
    batch: {
      id: '22222222-2222-4222-8222-222222222222',
      date: '8月26日',
      teacher: '李老师',
      fill_date: '2026-08-26',
    },
    student: {
      id: '33333333-3333-4333-8333-333333333333',
      name: '张三',
      grade: '三年级',
      slot: '批次1 · 上午场',
    },
    payload: {
      schema_version: 1,
      mods: ['乐高搭建'],
      customMods: ['机械挑战'],
      chart: 'dot',
      rates: [1, 2, 3, 4, 5],
      skills: [{ m: '乐高搭建', p: '结构稳定', r: 4 }, { m: '', p: '', r: 0 }, { m: '', p: '', r: 0 }],
      obs1: '课堂具体表现',
      obs2: '下一步建议',
      dir: 4,
      reason: '推荐理由',
      classIndex: '2',
      recommended_class: 'Python 研习社',
      dirCustom: { name: '智能机械', desc: '结构与控制' },
      attendp: '是',
      talk: '已完成',
      intent: '高',
      why: '喜欢机器人',
      ref: '家长诉求',
      follow: '三天内联系',
      note: '内部备注',
      generated: true,
    },
  };
}

test('API editor document round-trips every current business field', () => {
  const source = editorDocument();
  const workspace = mapping.toWorkspace(source, { defaultChartType: 'radar' });
  const result = mapping.toDocument(workspace, [
    { name: '头脑风暴1.0 V1' },
    { name: 'Scratch' },
    { name: 'Python 研习社' },
  ]);

  assert.equal(result.evaluation_id, source.evaluation_id);
  assert.equal(result.version, source.version);
  assert.deepEqual(result.batch, source.batch);
  assert.deepEqual(result.student, source.student);
  assert.deepEqual(result.payload, source.payload);
});

test('missing arrays are repaired without changing API identity', () => {
  const source = editorDocument();
  source.payload.mods = null;
  source.payload.customMods = null;
  source.payload.rates = [1];
  source.payload.skills = [];

  const workspace = mapping.toWorkspace(source, { defaultChartType: 'bar' });
  const student = workspace.batches[0].students[0];

  assert.equal(student._apiEvaluationId, source.evaluation_id);
  assert.equal(student._apiVersion, 7);
  assert.deepEqual(student.mods, []);
  assert.deepEqual(student.rates, [0, 0, 0, 0, 0]);
  assert.equal(student.skills.length, 3);
});

test('repository status maps to the approved visible save states', () => {
  assert.deepEqual(mapping.statusFor('saving'), { text: '正在保存…', color: '#6B7280' });
  assert.deepEqual(mapping.statusFor('saved'), { text: '已保存', color: '#15803d' });
  assert.deepEqual(mapping.statusFor('conflict'), {
    text: '记录已被其他老师修改，请重新加载',
    color: '#991b1b',
  });
  assert.deepEqual(mapping.statusFor('signed_out'), {
    text: '登录已失效，请重新登录',
    color: '#991b1b',
  });
});
