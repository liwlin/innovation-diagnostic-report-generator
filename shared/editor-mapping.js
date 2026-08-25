(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  if (root) root.MakerSeedEditorMapping = api;
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';

  function clone(value) {
    return value == null ? value : JSON.parse(JSON.stringify(value));
  }

  function emptySkill() {
    return { m: '', p: '', r: 0 };
  }

  function statusFor(state) {
    const states = {
      loading: { text: '正在加载记录…', color: '#6B7280' },
      saving: { text: '正在保存…', color: '#6B7280' },
      saved: { text: '已保存', color: '#15803d' },
      failed: { text: '保存失败，请检查网络后重试', color: '#991b1b' },
      conflict: { text: '记录已被其他老师修改，请重新加载', color: '#991b1b' },
      signed_out: { text: '登录已失效，请重新登录', color: '#991b1b' },
    };
    return states[state] || { text: '', color: '#6B7280' };
  }

  function toWorkspace(documentValue, options) {
    const payload = clone(documentValue.payload || {});
    const student = {
      id: documentValue.student.id,
      name: documentValue.student.name || '',
      grade: documentValue.student.grade || '',
      slot: documentValue.student.slot || '',
      slotCustom: false,
      mods: Array.isArray(payload.mods) ? payload.mods : [],
      customMods: Array.isArray(payload.customMods) ? payload.customMods : [],
      chart: payload.chart || options.defaultChartType || 'radar',
      rates: Array.isArray(payload.rates) && payload.rates.length === 5 ? payload.rates : [0, 0, 0, 0, 0],
      skills: Array.isArray(payload.skills) && payload.skills.length === 3 ? payload.skills : [emptySkill(), emptySkill(), emptySkill()],
      obs1: payload.obs1 || '', obs2: payload.obs2 || '', dir: Number(payload.dir ?? -1), reason: payload.reason || '',
      classIndex: payload.classIndex || '', recommended_class: payload.recommended_class || '',
      dirCustom: clone(payload.dirCustom || { name: '', desc: '' }), attendp: payload.attendp || '',
      talk: payload.talk || '', intent: payload.intent || '', why: payload.why || '', ref: payload.ref || '',
      follow: payload.follow || '', note: payload.note || '', generated: Boolean(payload.generated),
      _apiEvaluationId: documentValue.evaluation_id, _apiVersion: documentValue.version,
    };
    return {
      batches: [{
        id: documentValue.batch.id,
        date: documentValue.batch.date || '',
        teacher: documentValue.batch.teacher || '',
        fillDate: documentValue.batch.fill_date || '',
        students: [student],
      }],
      activeBatch: 0, activeStudent: 0, mode: 'form', printing: false, showHistory: false,
      showCrossDay: false, batchEditOpen: false, status: '已保存', statusColor: '#15803d',
      exportBusy: false, printIncludeInternal: false, addingMod: false, newModDraft: '',
    };
  }

  function toDocument(workspace, classList) {
    const batch = workspace.batches[workspace.activeBatch];
    const student = batch.students[workspace.activeStudent];
    const classInfo = classList[Number(student.classIndex)];
    return {
      evaluation_id: student._apiEvaluationId,
      version: student._apiVersion || 1,
      batch: { id: batch.id, date: batch.date, teacher: batch.teacher, fill_date: batch.fillDate },
      student: { id: student.id, name: student.name || '', grade: student.grade || '', slot: student.slot || '' },
      payload: {
        schema_version: 1,
        mods: clone(student.mods || []),
        customMods: clone(student.customMods || []),
        chart: student.chart || 'radar',
        rates: clone(student.rates || [0, 0, 0, 0, 0]),
        skills: clone(student.skills || [emptySkill(), emptySkill(), emptySkill()]),
        obs1: student.obs1 || '', obs2: student.obs2 || '', dir: Number(student.dir), reason: student.reason || '',
        classIndex: student.classIndex || '',
        recommended_class: classInfo ? classInfo.name : (student.recommended_class || ''),
        dirCustom: clone(student.dirCustom || { name: '', desc: '' }),
        attendp: student.attendp || '', talk: student.talk || '', intent: student.intent || '',
        why: student.why || '', ref: student.ref || '', follow: student.follow || '', note: student.note || '',
        generated: Boolean(student.generated),
      },
    };
  }

  return Object.freeze({ statusFor, toDocument, toWorkspace });
});
