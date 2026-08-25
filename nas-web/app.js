(function () {
  'use strict';

  const root = document.getElementById('app');
  const runtime = MakerSeedRuntime.getConfig(window.location, window.__MKSEED_RUNTIME__);
  const views = MakerSeedViews;
  const state = { session: null, activeView: 'records', records: [], filters: {}, loading: false, error: '', loginBusy: false, loginError: '' };
  const api = MakerSeedApiClient.createApiClient({ onUnauthorized: showLogin });

  function renderLogin() {
    views.replace(root, views.loginView({
      busy: state.loginBusy,
      error: state.loginError,
      async onSubmit(username, password) {
        state.loginBusy = true; state.loginError = ''; renderLogin();
        try { state.session = await api.login(username, password); state.loginBusy = false; await showRecords(false); }
        catch (error) { state.loginBusy = false; state.loginError = error.code === 'invalid_credentials' ? '账号或密码错误' : error.message; renderLogin(); }
      },
    }));
  }

  function showLogin() {
    state.session = null;
    state.loginBusy = false;
    renderLogin();
  }

  function renderShell(content) {
    views.replace(root, views.shell({
      session: state.session,
      version: runtime.appVersion + (runtime.commitSha ? ` · ${runtime.commitSha.slice(0, 7)}` : ''),
      activeView: state.activeView,
      content,
      onNavigate(view) { if (view === 'records') showRecords(false); else if (view === 'trash') showRecords(true); },
      async onLogout() { try { await api.logout(); } finally { showLogin(); } },
    }));
  }

  function renderRecords(trashed) {
    const workspace = views.recordWorkspace({
      records: state.records, filters: state.filters, trashed, loading: state.loading, error: state.error,
      onFilter(filters) { state.filters = filters; clearTimeout(state.filterTimer); state.filterTimer = setTimeout(() => loadRecords(trashed), 250); },
      onNew: showNewRecord,
      onEdit(record) { window.location.assign(`/editor?evaluation_id=${encodeURIComponent(record.evaluation_id)}`); },
      async onTrash(record) { if (window.confirm(`将“${record.student_name}”移入回收站？`)) { await api.trashEvaluation(record.evaluation_id); await loadRecords(false); } },
      async onRestore(record) { await api.restoreEvaluation(record.evaluation_id); await loadRecords(true); },
      async onReports(record) { const items = await api.listGenerations(record.evaluation_id); window.alert(items.length ? `共有 ${items.length} 次生成记录，请进入编辑页下载。` : '尚未生成报告。'); },
    });
    renderShell(workspace);
  }

  async function loadRecords(trashed) {
    state.loading = true; state.error = ''; renderRecords(trashed);
    try {
      const page = await api.listEvaluations({ ...state.filters, trashed, limit: 100 });
      state.records = page.items;
    } catch (error) { state.error = error.message; }
    state.loading = false; renderRecords(trashed);
  }

  async function showRecords(trashed) {
    state.activeView = trashed ? 'trash' : 'records'; state.filters = {}; state.records = [];
    await loadRecords(trashed);
  }

  function showNewRecord() {
    let dialog;
    async function submit(values) {
      const dateValue = values.event_date || new Date().toISOString().slice(0, 10);
      try {
        const batch = await api.createBatch({ display_name: values.display_name, event_date: dateValue, date_label: values.date_label, teacher_label: values.teacher_label, fill_date: dateValue });
        const editor = await api.createEvaluation(batch.id, {
          student: { name: values.student_name, grade: values.grade, slot: values.slot },
          payload: { schema_version: 1, mods: [], customMods: [], chart: 'radar', rates: [0,0,0,0,0], skills: [{m:'',p:'',r:0},{m:'',p:'',r:0},{m:'',p:'',r:0}], obs1:'', obs2:'', dir:-1, reason:'', classIndex:'', recommended_class:'', dirCustom:{name:'',desc:''}, attendp:'是', talk:'已完成', intent:'高', why:'', ref:'', follow:'', note:'', generated:false },
        });
        window.location.assign(`/editor?evaluation_id=${encodeURIComponent(editor.evaluation_id)}`);
      } catch (error) {
        const panel = dialog.querySelector('.dialog');
        let message = dialog.querySelector('.error-message');
        if (!message) {
          message = views.element('p', { className: 'error-message', role: 'alert' });
          panel.insertBefore(message, panel.querySelector('.dialog-actions'));
        }
        message.textContent = error.message;
      }
    }
    dialog = views.newRecordDialog({ busy: false, error: '', onCancel: () => dialog.remove(), onSubmit: submit });
    document.body.append(dialog);
  }

  async function boot() {
    try { state.session = await api.getSession(); await showRecords(false); }
    catch (error) { if (error.status !== 401) state.loginError = error.message; showLogin(); }
  }

  boot();
})();
